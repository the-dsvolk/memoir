"""Version and protocol checks — standard library only: `python3 -m unittest discover -s tests -p test_version.py`."""

import unittest

from memoir_asr.protocol import PROTOCOL, ProtocolMismatch, validate_start
from memoir_asr.version import current, format_described


class VersionTest(unittest.TestCase):
    def test_format(self):
        self.assertEqual(format_described("v0.2.0-0-g3005f27"), "0.2.0")
        self.assertEqual(format_described("v0.2.0-3-g3005f27a\n"), "0.2.0+3 (3005f27)")
        self.assertEqual(format_described("v0.2.0-3-g3005f27-dirty"), "0.2.0+3 (3005f27, modified)")
        self.assertEqual(format_described("v0.2.0-0-g3005f27-dirty"), "0.2.0 (3005f27, modified)")
        self.assertIsNone(format_described("3005f27"))
        self.assertIsNone(format_described(""))

    def test_current_falls_back_without_git(self):
        self.assertEqual(current(repo=__import__("pathlib").Path("/nonexistent")), "0.0.0")


class ProtocolVersionTest(unittest.TestCase):
    START = {"type": "start", "meeting_id": "m1", "sources": ["me"]}

    def test_same_or_unsaid_protocol_is_accepted(self):
        validate_start({**self.START, "protocol": PROTOCOL})
        validate_start(self.START)  # clients before 0.3 don't say: protocol 1

    def test_other_protocol_is_refused_with_its_own_code(self):
        with self.assertRaises(ProtocolMismatch) as raised:
            validate_start({**self.START, "protocol": PROTOCOL + 1})
        self.assertEqual(raised.exception.code, "protocol_mismatch")
        self.assertIn("update the server", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
