"""One meeting on one WebSocket: turns network audio into model frames and model output into messages."""

import re
from dataclasses import dataclass, field

import numpy as np

from .frames import StepResult, StreamFrame
from .protocol import SAMPLE_RATE

# The model often emits a sentence's closing punctuation one step after its end-of-utterance cut,
# so it shows up at the start of the next segment ("? Alice will …"). It belongs to the previous final.
LEADING_PUNCT = re.compile(r"^[\s.,!?;:…]+")


@dataclass
class Source:
    name: str
    stream_id: int
    pcm: bytearray = field(default_factory=bytearray)  # s16le samples not yet sent to the model
    next_offset: int = 0  # sample offset the next network frame should start at
    fed: int = 0  # samples sent to the model so far
    started: bool = False
    ended: bool = False
    seg: int = 0
    partial: str = ""
    last_final_end: float = 0.0
    last_final: dict | None = None  # the previous final message, which late punctuation may amend


class Session:
    def __init__(self, meeting_id: str, sources: list[str], frame_samples: int, new_stream_id) -> None:
        self.meeting_id = meeting_id
        self.frame_samples = frame_samples
        self.sources = {name: Source(name, new_stream_id()) for name in sources}
        self._by_stream = {s.stream_id: s for s in self.sources.values()}

    def ingest(self, source: str, sample_offset: int, pcm: bytes) -> None:
        """Add a network frame: silence fills gaps, overlap with audio already received is dropped."""
        src = self.sources.get(source)
        if src is None or src.ended:
            return
        if sample_offset > src.next_offset:
            src.pcm.extend(bytes(2 * (sample_offset - src.next_offset)))
            src.next_offset = sample_offset
        skip = src.next_offset - sample_offset
        if skip * 2 >= len(pcm):
            return
        src.pcm.extend(pcm[2 * skip:])
        src.next_offset += len(pcm) // 2 - skip

    def ready_frames(self) -> list[StreamFrame]:
        """At most one full model frame per source."""
        frames = []
        nbytes = 2 * self.frame_samples
        for src in self.sources.values():
            if len(src.pcm) >= nbytes:
                frames.append(self._frame(src, bytes(src.pcm[:nbytes]), is_last=False))
                del src.pcm[:nbytes]
        return frames

    def final_frames(self) -> list[StreamFrame]:
        """The last, zero-padded frame of every source that ever sent audio — ends its model stream."""
        frames = []
        for src in self.sources.values():
            if src.ended or (not src.started and not src.pcm):
                continue
            rest = bytes(src.pcm[: 2 * self.frame_samples])
            src.pcm.clear()
            frames.append(self._frame(src, rest, is_last=True))
            src.ended = True
        return frames

    def handle(self, results: list[StepResult]) -> list[dict]:
        """Model output → `final` / `partial` messages, in that order per source.

        A `final` re-sent with an earlier `seg` replaces that segment (late punctuation moved back).
        """
        messages = []
        for r in results:
            src = self._by_stream.get(r.stream_id)
            if src is None:
                continue
            upto = round(src.fed / SAMPLE_RATE, 3)
            final = self._carry_punctuation(src, r.final, upto, messages)
            if final:
                t0 = r.final_start if r.final_start is not None else src.last_final_end
                t1 = r.final_end if r.final_end is not None else upto
                self._emit_final(src, final, t0, t1, upto, messages)
            partial = self._carry_punctuation(src, r.partial, upto, messages)  # after this step's final
            if r.final or partial != src.partial:
                src.partial = partial
                messages.append({"type": "partial", "source": src.name, "seg": src.seg,
                                 "t0": round(src.last_final_end, 2), "text": partial, "upto": upto})
        return messages

    def flush_partials(self) -> list[dict]:
        """At stream end, promote any text the end-of-utterance detector never closed to a final."""
        messages = []
        for src in self.sources.values():
            if src.partial:
                upto = round(src.fed / SAMPLE_RATE, 3)
                self._emit_final(src, src.partial, src.last_final_end, upto, upto, messages)
                src.partial = ""
        return messages

    def _emit_final(self, src: Source, text: str, t0: float, t1: float, upto: float, messages: list) -> None:
        msg = {"type": "final", "source": src.name, "seg": src.seg,
               "t0": round(t0, 2), "t1": round(t1, 2), "text": text, "upto": upto}
        messages.append(msg)
        src.seg += 1
        src.last_final_end = t1
        src.last_final = msg
        src.partial = ""

    @staticmethod
    def _carry_punctuation(src: Source, text: str, upto: float, messages: list) -> str:
        """Strip leading punctuation; if the previous final lacks it, amend that final once."""
        match = LEADING_PUNCT.match(text)
        if not match:
            return text
        punct = match.group().strip()
        prev = src.last_final
        if punct and prev is not None and not prev["text"].endswith(punct):
            prev = {**prev, "text": prev["text"].rstrip() + punct, "upto": upto}
            src.last_final = prev
            messages.append(prev)
        return text[match.end():]

    def _frame(self, src: Source, pcm: bytes, is_last: bool) -> StreamFrame:
        valid = len(pcm) // 2
        samples = np.zeros(self.frame_samples, dtype=np.float32)
        samples[:valid] = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        # The last frame counts its silence padding as real audio: with only a few valid samples the
        # pipeline skips the step, and with it the tail flush that emits the final punctuation.
        frame = StreamFrame(src.stream_id, samples, is_first=not src.started, is_last=is_last,
                            length=self.frame_samples)
        src.started = True
        src.fed += valid
        return frame
