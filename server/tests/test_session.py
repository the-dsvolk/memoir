"""Session logic without a GPU: `uv run --no-sync python -m unittest discover -s tests` (from server/)."""

import itertools
import unittest

import numpy as np

from memoir_asr.frames import StepResult
from memoir_asr.protocol import HEADER, ProtocolError, parse_audio_frame, validate_start
from memoir_asr.session import Session

FRAME = 8960  # 560 ms model frame


def pcm(n: int, value: int = 1000) -> bytes:
    return np.full(n, value, dtype="<i2").tobytes()


def session(sources=("me",)) -> Session:
    ids = itertools.count(1)
    return Session("m1", list(sources), FRAME, lambda: next(ids))


class IngestTest(unittest.TestCase):
    def test_frames_are_cut_at_model_size(self):
        s = session()
        for i in range(0, 2 * FRAME, 1600):
            s.ingest("me", i, pcm(1600))
        first = s.ready_frames()
        self.assertEqual(len(first), 1)
        self.assertTrue(first[0].is_first)
        self.assertEqual(first[0].length, FRAME)
        self.assertAlmostEqual(float(first[0].samples[0]), 1000 / 32768, places=6)
        second = s.ready_frames()
        self.assertFalse(second[0].is_first)
        self.assertEqual(s.ready_frames(), [])

    def test_gap_is_filled_with_silence_and_overlap_dropped(self):
        s = session()
        s.ingest("me", 0, pcm(1600))
        s.ingest("me", 3200, pcm(1600))  # 1600-sample gap
        s.ingest("me", 4000, pcm(1600))  # 800 samples overlap
        self.assertEqual(s.sources["me"].next_offset, 5600)
        self.assertEqual(len(s.sources["me"].pcm), 2 * 5600)
        self.assertEqual(bytes(s.sources["me"].pcm[3200:6400]), bytes(3200))

    def test_last_frame_has_audio_and_padding(self):
        s = session()
        s.ingest("me", 0, pcm(1000))
        (last,) = s.final_frames()
        self.assertTrue(last.is_last and last.is_first)
        self.assertEqual(last.length, 4000)  # ≥ 0.25 s of audio (silence counts) and < a full frame
        self.assertEqual(last.samples.shape, (FRAME,))
        self.assertEqual(float(last.samples[1000]), 0.0)
        self.assertEqual(s.final_frames(), [])  # already ended

    def test_last_frame_keeps_long_tail_and_padding(self):
        s = session()
        s.ingest("me", 0, pcm(FRAME - 10))
        (last,) = s.final_frames()
        self.assertEqual(last.length, FRAME - 10)

    def test_last_frame_when_audio_divides_evenly(self):
        s = session()
        s.ingest("me", 0, pcm(FRAME))
        s.ready_frames()
        (last,) = s.final_frames()  # nothing left: a silent last frame still flushes the tail
        self.assertEqual((last.is_last, last.length, float(abs(last.samples).max())), (True, 4000, 0.0))


class MessageTest(unittest.TestCase):
    def step(self, s, partial="", final="", start=None, end=None):
        return s.handle([StepResult(1, partial, final, start, end)])

    def test_partial_then_final(self):
        s = session()
        self.assertEqual(self.step(s, partial="hello")[0]["text"], "hello")
        self.assertEqual(self.step(s, partial="hello"), [])  # unchanged → nothing
        msgs = self.step(s, final="Hello there", start=0.1, end=1.2)
        self.assertEqual([m["type"] for m in msgs], ["final", "partial"])
        self.assertEqual((msgs[0]["seg"], msgs[0]["t0"], msgs[0]["t1"]), (0, 0.1, 1.2))
        self.assertEqual(msgs[1]["seg"], 1)

    def test_late_punctuation_moves_to_previous_final(self):
        s = session()
        self.step(s, final="Can we confirm the budget", start=0.0, end=2.0)
        msgs = self.step(s, partial="? Alice will")
        self.assertEqual(msgs[0], {**msgs[0], "type": "final", "seg": 0, "text": "Can we confirm the budget?"})
        self.assertEqual(msgs[1]["text"], "Alice will")
        self.assertEqual(self.step(s, partial="? Alice will follow")[0]["text"], "Alice will follow")  # no re-amend

    def test_punctuation_only_final_is_dropped(self):
        s = session()
        self.step(s, final="See you Tuesday", start=0.0, end=1.0)
        msgs = self.step(s, final=".")
        finals = [m for m in msgs if m["type"] == "final"]
        self.assertEqual(finals, [{**finals[0], "seg": 0, "text": "See you Tuesday."}])
        self.assertEqual(s.sources["me"].seg, 1)

    def test_flush_promotes_open_partial(self):
        s = session()
        self.step(s, partial="unfinished thought")
        (msg,) = s.flush_partials()
        self.assertEqual((msg["type"], msg["seg"], msg["text"]), ("final", 0, "unfinished thought"))


class ProtocolTest(unittest.TestCase):
    def test_frame_header(self):
        source, offset, data = parse_audio_frame(HEADER.pack(1, 12345) + pcm(4))
        self.assertEqual((source, offset, len(data)), ("them", 12345, 8))
        with self.assertRaises(ProtocolError):
            parse_audio_frame(b"\x00" * 5)

    def test_start_validation(self):
        self.assertEqual(validate_start({"type": "start", "meeting_id": "a1"})["sources"], ["me"])
        with self.assertRaises(ProtocolError):
            validate_start({"type": "start", "meeting_id": "../x"})


if __name__ == "__main__":
    unittest.main()
