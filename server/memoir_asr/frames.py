"""Data passed between the session (asyncio side) and the engine (ASR thread)."""

from dataclasses import dataclass

import numpy as np


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
