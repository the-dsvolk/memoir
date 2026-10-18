"""One meeting on one WebSocket: turns network audio into model frames and model output into messages."""

from dataclasses import dataclass, field

import numpy as np

from .engine import StepResult, StreamFrame
from .protocol import SAMPLE_RATE


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
        """Model output → `final` / `partial` messages, in that order per source."""
        messages = []
        for r in results:
            src = self._by_stream.get(r.stream_id)
            if src is None:
                continue
            upto = round(src.fed / SAMPLE_RATE, 3)
            if r.final:
                t0 = r.final_start if r.final_start is not None else src.last_final_end
                t1 = r.final_end if r.final_end is not None else upto
                messages.append({"type": "final", "source": src.name, "seg": src.seg,
                                 "t0": round(t0, 2), "t1": round(t1, 2), "text": r.final, "upto": upto})
                src.seg += 1
                src.last_final_end = t1
                src.partial = ""
            if r.partial != src.partial:
                src.partial = r.partial
                messages.append({"type": "partial", "source": src.name, "seg": src.seg,
                                 "t0": round(src.last_final_end, 2), "text": r.partial, "upto": upto})
        return messages

    def flush_partials(self) -> list[dict]:
        """At stream end, promote any text the end-of-utterance detector never closed to a final."""
        messages = []
        for src in self.sources.values():
            if src.partial:
                upto = round(src.fed / SAMPLE_RATE, 3)
                messages.append({"type": "final", "source": src.name, "seg": src.seg,
                                 "t0": round(src.last_final_end, 2), "t1": upto, "text": src.partial, "upto": upto})
                src.seg += 1
                src.partial = ""
        return messages

    def _frame(self, src: Source, pcm: bytes, is_last: bool) -> StreamFrame:
        valid = len(pcm) // 2
        samples = np.zeros(self.frame_samples, dtype=np.float32)
        samples[:valid] = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        frame = StreamFrame(src.stream_id, samples, is_first=not src.started, is_last=is_last,
                            length=max(valid, 1) if is_last else self.frame_samples)
        src.started = True
        src.fed += valid
        return frame
