"""Offline tests for summary_qwen.py: a fake OpenAI-style server stands in for the Spark.

run: /usr/bin/python3 -m unittest discover -s mac/steps -v
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "summary_qwen.py"
spec = importlib.util.spec_from_file_location("summary_qwen", SCRIPT)
sq = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sq)

DRAFT = "## Summary\nDate: wrong\n- [01:02] Dmitry: ok\n## Decisions\n- Ship it (at [00:10])\n"
CHECKED = {
    "checks": [{"section": "decision", "item": "Ship it", "owner_in_draft": "", "verdict": "supported",
                "evidence": "[00:10] ship it?", "agreement": "none found", "fix": "keep"}],
    "missing": [],
    "summary_md": "## Summary\n**Date:** Tuesday 9am\n## Decisions\n- Ship it [00:10]\n"
                  "## My notes, expanded\n- verify cost\n  Follow-up: not researched (local model, no tools)\n",
}


class FakeServer:
    """Answers pass 1 (no response_format) and pass 2 (json_schema); `mode` picks a failure."""

    def __init__(self, mode):
        self.mode, self.prompts = mode, {}
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                check = "response_format" in body
                outer.prompts[2 if check else 1] = body["messages"][0]["content"]
                if check:
                    content, finish = json.dumps(CHECKED), "length" if outer.mode == "cut2" else "stop"
                    if outer.mode == "garbage2":
                        content = "not json"
                else:
                    content = "" if outer.mode == "empty1" else DRAFT
                    finish = "length" if outer.mode == "cut1" else "stop"
                out = json.dumps({"choices": [{"message": {"content": content, "reasoning_content": "hmm"},
                                               "finish_reason": finish}], "usage": {}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(out)

        self.httpd = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:{}/v1".format(self.httpd.server_port)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class StepTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.call = Path(self.tmp.name) / "2026-11-16_test"
        self.call.mkdir()
        (self.call / "meeting.json").write_text(json.dumps(
            {"name": "test", "started_at": "2026-11-16T09:32:05-08:00", "ended_at": "2026-11-16T10:16:40-08:00"}))
        (self.call / "transcript.txt").write_text("[00:10] Them: ship it?\n[00:12] Me: yes\n")
        (self.call / "notes.md").write_text("- [00:20] verify cost\n- [00:30] nice\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_step(self, mode, url=None):
        server = FakeServer(mode) if url is None else None
        env = dict(os.environ, MEMOIR_LLM_URL=url or server.url, MEMOIR_ME_NAME="Dmitry Volkov", TZ="America/Los_Angeles")
        try:
            p = subprocess.run([sys.executable, "-I", str(SCRIPT), str(self.call)], env=env,
                               capture_output=True, text=True, timeout=60)
        finally:
            if server:
                server.close()
        return p, server

    def test_success_writes_checked_summary(self):
        p, server = self.run_step("ok")
        self.assertEqual(p.returncode, 0, p.stderr)
        summary = (self.call / "summary.md").read_text()
        self.assertIn("Date: Monday, November 16, 2026, 9:32–10:16 AM PST\n", summary)
        self.assertNotIn("[00:10]", summary)
        self.assertIn("- Ship it\n", summary)  # the time and the space before it are gone
        self.assertIn("no agreement quoted", p.stdout)
        self.assertIn('I am Dmitry Volkov', server.prompts[1])
        self.assertIn('I am Dmitry Volkov', server.prompts[2])
        extras = self.call / "pipeline" / "summary"
        for name in ("draft.md", "checks.json", "run.json", "reasoning-pass1.txt", "reasoning-pass2.txt"):
            self.assertTrue((extras / name).is_file(), name)
        self.assertEqual(oct((self.call / "summary.md").stat().st_mode & 0o777), "0o600")

    def test_failures_keep_the_old_summary(self):
        for mode in ("empty1", "cut1", "cut2", "garbage2"):
            with self.subTest(mode=mode):
                (self.call / "summary.md").write_text("old good summary\n")
                p, server = self.run_step(mode)
                self.assertEqual(p.returncode, 1)
                self.assertEqual((self.call / "summary.md").read_text(), "old good summary\n")
                self.assertTrue(p.stderr.strip().splitlines()[-1].startswith("summary: "))
                if mode in ("empty1", "cut1"):
                    self.assertNotIn(2, server.prompts)  # pass 2 never runs on a bad draft
                self.assertEqual([f.name for f in self.call.iterdir() if f.name.endswith(".tmp")], [])

    def test_unreachable_server(self):
        p, _ = self.run_step("ok", url="http://127.0.0.1:1/v1")
        self.assertEqual(p.returncode, 1)
        self.assertIn("can't reach", p.stderr)
        self.assertFalse((self.call / "summary.md").exists())


class HelperTests(unittest.TestCase):
    def test_strip_times(self):
        self.assertEqual(sq.strip_times("- Ship it [00:10]"), ("- Ship it", 1))
        self.assertEqual(sq.strip_times("### [12:03] note")[0], "### note")
        self.assertEqual(sq.strip_times("- a (at [1:02:03]) b")[0], "- a b")
        self.assertEqual(sq.strip_times("Date: Monday, 9:32–10:16 AM PST"), ("Date: Monday, 9:32–10:16 AM PST", 0))

    def test_follow_up_notes(self):
        notes = "- [00:20] verify cost\n- [00:30] nice\n- [01:00] Check with Ann\n"
        self.assertEqual(len(sq.follow_up_notes(notes)), 2)

    def test_fix_date_line(self):
        self.assertEqual(sq.fix_date_line("## S\n- **Date:** x\nrest", "Date: D"), ("## S\nDate: D\nrest", True))
        self.assertEqual(sq.fix_date_line("no date", "Date: D"), ("no date", False))


if __name__ == "__main__":
    unittest.main()
