"""ASR engine: NeMo's cache-aware streaming pipeline around Nemotron Speech Streaming EN.

The pipeline keeps per-stream encoder/feature caches and its own end-of-utterance detector, and
turns one fixed-size audio frame per stream per step into partial and final (punctuated) text.
Everything here must run on one thread — the server's single ASR executor (DESIGN.md §5.4).
"""

import logging
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
from huggingface_hub import hf_hub_download
from omegaconf import OmegaConf
from nemo.collections.asr.inference.factory.pipeline_builder import PipelineBuilder
from nemo.collections.asr.inference.streaming.framing.request import Frame
from nemo.collections.asr.inference.streaming.framing.request_options import ASRRequestOptions

from .settings import CHUNK_MS_TO_RIGHT_CONTEXT

log = logging.getLogger(__name__)
CONFIG = Path(__file__).parent / "conf" / "cache_aware_rnnt.yaml"


@dataclass(frozen=True)
class StreamFrame:
    """One model frame for one stream: exactly `Engine.frame_samples` float32 samples."""

    stream_id: int
    samples: np.ndarray
    is_first: bool
    is_last: bool
    length: int  # valid samples; the rest is zero padding (only on the last frame)


@dataclass(frozen=True)
class StepResult:
    stream_id: int
    partial: str  # text since the last end of utterance, still subject to change
    final: str  # text finalised in this step ("" if none)
    final_start: float | None  # seconds from the stream's start
    final_end: float | None


class Engine:
    def __init__(self, model: str, revision: str, chunk_ms: int) -> None:
        nemo_file = hf_hub_download(model, f"{model.split('/')[-1]}.nemo", revision=revision)
        cfg = OmegaConf.load(CONFIG)
        cfg.asr.model_name = nemo_file
        cfg.streaming.att_context_size = [70, CHUNK_MS_TO_RIGHT_CONTEXT[chunk_ms]]
        cfg.streaming.batch_size = 4  # me / them / room, plus headroom
        cfg.streaming.num_slots = 8
        cfg.enable_itn = False  # numbers stay words for now (DESIGN.md open question 10)
        cfg.enable_nmt = False
        cfg.return_tail_result = True  # flush the last words when a stream ends
        cfg.log_level = 30
        self.pipeline = PipelineBuilder.build_pipeline(cfg)
        self.sample_rate = int(self.pipeline.sample_rate)
        self.frame_samples = round(self.pipeline.chunk_size_in_secs * self.sample_rate)
        self.model_label = f"{model}@{revision[:7]}"
        self._next_stream_id = 0
        self.pipeline.open_session()
        self._warm_up()
        log.info("engine ready: %s, %d-sample frames (%.2f s)", self.model_label, self.frame_samples,
                 self.frame_samples / self.sample_rate)

    def new_stream_id(self) -> int:
        self._next_stream_id += 1
        return self._next_stream_id

    def step(self, frames: list[StreamFrame]) -> list[StepResult]:
        requests = [
            Frame(
                samples=torch.from_numpy(f.samples),
                stream_id=f.stream_id,
                is_first=f.is_first,
                is_last=f.is_last,
                length=f.length,
                options=ASRRequestOptions() if f.is_first else None,
            )
            for f in frames
        ]
        results = []
        for out in self.pipeline.transcribe_step(requests):
            segments = out.final_segments or []
            results.append(StepResult(
                stream_id=out.stream_id,
                partial=out.partial_transcript.strip(),
                final=out.final_transcript.strip(),
                final_start=segments[0].start if segments else None,
                final_end=segments[-1].end if segments else None,
            ))
        return results

    def _warm_up(self) -> None:
        silence = np.zeros(self.frame_samples, dtype=np.float32)
        sid = self.new_stream_id()
        self.step([StreamFrame(sid, silence, True, False, self.frame_samples)])
        self.step([StreamFrame(sid, silence, False, True, self.frame_samples)])
