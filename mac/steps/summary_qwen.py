#!/usr/bin/env python3
"""memoir Summary step on a local model: Qwen on the Spark writes <call>/summary.md (DESIGN.md §4.8).

usage: python3 summary_qwen.py <call-folder>

Two passes against an OpenAI-compatible server (vLLM):
  1. summary: prompts/summary.md + the call's meeting.json, transcript.txt, prep.md, notes.md -> a draft;
  2. check:   prompts/verify.md + transcript, notes, prep and the draft -> JSON with a verdict and quotes for
     every decision, action item and confirmed note, plus the corrected summary.
[mm:ss] times are stripped in code after each pass, and the "Date:" line is computed here from meeting.json
in this Mac's time zone, so the model never converts times. Nothing leaves the network: no tools, no web.

summary.md is written only when both passes finish: a temp file, then a rename. If either pass comes back
empty, cut off or unreadable, the step exits non-zero and an earlier summary.md stays as it was. The draft,
the check results, the thinking and the timings go to <call>/pipeline/summary/.

Environment (all optional):
  MEMOIR_LLM_URL      base URL of the server   (default http://spark-0e81.local:8000/v1)
  MEMOIR_LLM_MODEL    model name               (default qwen3.8-judge)
  MEMOIR_LLM_EFFORT   low | medium | xhigh     (default medium; xhigh can think until it runs out of tokens)
  MEMOIR_ME_NAME      who "Me" is, e.g. "Dmitry Volkov" (default: none, the summary says "Me")

Standard library only; runs on macOS's /usr/bin/python3 (3.9).
"""
import datetime
import json
import os
import re
import signal
import socket
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROMPTS = HERE / "prompts"

URL = os.environ.get("MEMOIR_LLM_URL", "http://spark-0e81.local:8000/v1").rstrip("/")
MODEL = os.environ.get("MEMOIR_LLM_MODEL", "qwen3.8-judge")
EFFORT = os.environ.get("MEMOIR_LLM_EFFORT", "medium")
ME_NAME = os.environ.get("MEMOIR_ME_NAME", "").strip()

PASS1_MAX_TOKENS = 32000
PASS2_MAX_TOKENS = 40000
REQUEST_TIMEOUT = 1800  # seconds per pass; the step's own timeout (pipeline.toml) covers the whole run

FOLLOW_UP_LINE = "Follow-up: not researched (local model, no tools)"
FOLLOW_UP_WORDS = re.compile(r"\b(research|confirm|check|verify|look up|find out|investigate|dig into)\b", re.I)

TIME = r"\[(?:\d{1,2}:)?\d{1,2}:\d{2}(?:\s*[–-]\s*(?:\d{1,2}:)?\d{1,2}:\d{2})?\]"

CHECK_SCHEMA = {
    "type": "object",
    "properties": {
        "checks": {"type": "array", "items": {"type": "object", "properties": {
            "section": {"type": "string", "enum": ["decision", "action_item", "note"]},
            "item": {"type": "string"},
            "owner_in_draft": {"type": "string"},
            "verdict": {"type": "string",
                        "enum": ["supported", "overstated", "unsupported", "wrong_owner", "duplicate"]},
            "evidence": {"type": "string"},
            "agreement": {"type": "string"},
            "fix": {"type": "string"}},
            "required": ["section", "item", "owner_in_draft", "verdict", "evidence", "agreement", "fix"],
            "additionalProperties": False}},
        "missing": {"type": "array", "items": {"type": "object", "properties": {
            "section": {"type": "string", "enum": ["decision", "action_item"]},
            "item": {"type": "string"},
            "owner": {"type": "string"},
            "evidence": {"type": "string"}},
            "required": ["section", "item", "owner", "evidence"],
            "additionalProperties": False}},
        "summary_md": {"type": "string"}},
    "required": ["checks", "missing", "summary_md"],
    "additionalProperties": False,
}


class StepError(Exception):
    """A failure that ends the step with a one-line message (the app shows the last line of the log)."""


def log(msg):
    print(msg, flush=True)


# ---- text helpers ---------------------------------------------------------------------------------------

def strip_times(md):
    """Remove [mm:ss] / [h:mm:ss] markers (and '(at [mm:ss])' wrappers); leave clock times alone."""
    n = len(re.findall(TIME, md))
    md = re.sub(r"[ \t]*\((?:at |around |~)?" + TIME + r"\)", "", md)
    md = re.sub(r"[ \t]+" + TIME + r"[ \t]*$", "", md, flags=re.M)  # at the end of a line, with its space
    md = re.sub(TIME + r"[ \t]*", "", md)
    return md, n


def parse_iso(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        d = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))  # 3.9 doesn't take "Z"
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)


def date_line(meeting):
    """'Date: Monday, November 16, 2026, 9:32–10:16 AM PST', in this Mac's time zone."""
    start = parse_iso(meeting.get("started_at"))
    if start is None:
        return "Date: not recorded"
    start = start.astimezone()
    end = parse_iso(meeting.get("ended_at"))
    end = end.astimezone() if end else None

    def clock(d):
        return d.strftime("%I:%M").lstrip("0")

    day = "{}, {} {}, {}".format(start.strftime("%A"), start.strftime("%B"), start.day, start.year)
    if end is None:
        return "Date: {}, {} {} {} (end not recorded)".format(day, clock(start), start.strftime("%p"),
                                                             start.strftime("%Z"))
    if end.date() == start.date() and end.strftime("%p") == start.strftime("%p"):
        times = "{}–{} {}".format(clock(start), clock(end), end.strftime("%p"))
    else:
        times = "{} {}–{} {}".format(clock(start), start.strftime("%p"), clock(end), end.strftime("%p"))
    return "Date: {}, {} {}".format(day, times, start.strftime("%Z"))


def fix_date_line(md, line):
    """Put the computed Date line in place of whatever 'Date:' line the model wrote (it may reformat it)."""
    new, n = re.subn(r"(?m)^([ \t]*[-*]?[ \t]*\**)Date:.*$", lambda m: line, md, count=1)
    return new, n > 0


def fill(template, date):
    if ME_NAME:
        me_line = 'I am {0}: "Me" is {0}, one person, so never list me twice (as {0} and as "Me"). '.format(ME_NAME)
        me_attendee = 'as "{}"'.format(ME_NAME)
    else:
        me_line, me_attendee = "", 'as "Me"'
    return (template.replace("{me_line}", me_line).replace("{me_attendee}", me_attendee)
            .replace("{date_line}", date))


def follow_up_notes(notes):
    return [ln for ln in notes.splitlines() if ln.lstrip().startswith(("-", "*")) and FOLLOW_UP_WORDS.search(ln)]


# ---- files ----------------------------------------------------------------------------------------------

def read(call, name):
    p = call / name
    return p.read_text(encoding="utf-8").rstrip() if p.is_file() else None


def inline(call, names):
    parts = []
    for name in names:
        text = read(call, name)
        if text is not None:
            parts += ["===== {} =====".format(name), text, ""]
    return parts


def write_private(path, text):
    """Write via a temp file in the same folder, then rename: readers never see half a file. Mode 0600."""
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, str(path))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# ---- the model ------------------------------------------------------------------------------------------

def chat(user, max_tokens, schema=None):
    body = {"model": MODEL, "messages": [{"role": "user", "content": user}], "max_tokens": max_tokens,
            "chat_template_kwargs": {"enable_thinking": True, "reasoning_effort": EFFORT}}
    if schema:
        body["response_format"] = {"type": "json_schema",
                                   "json_schema": {"name": "check", "schema": schema, "strict": True}}
    req = urllib.request.Request(URL + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        raise StepError("{} answered HTTP {}: {}".format(URL, e.code, detail))
    except urllib.error.URLError as e:
        raise StepError("can't reach {} ({}). Away from home, port 8000 must come through the Spark tunnel."
                        .format(URL, e.reason))
    except (socket.timeout, TimeoutError):
        raise StepError("{} didn't answer within {} s".format(URL, REQUEST_TIMEOUT))
    choice = (resp.get("choices") or [{}])[0]
    msg = choice.get("message") or {}
    meta = {"wall_s": round(time.time() - t0, 1), "usage": resp.get("usage"),
            "finish_reason": choice.get("finish_reason"), "max_tokens": max_tokens, "prompt_chars": len(user)}
    reasoning = msg.get("reasoning_content") or msg.get("reasoning") or ""
    return (msg.get("content") or "").strip(), reasoning, meta


def parse_check(raw):
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", raw, re.S)
        if not m:
            return None
        try:
            return json.loads(m.group(0))
        except json.JSONDecodeError:
            return None


# ---- the step -------------------------------------------------------------------------------------------

def run(call, extras, record):
    transcript = read(call, "transcript.txt")
    if not transcript:
        raise StepError("no transcript.txt in {} (or it is empty)".format(call))
    try:
        meeting = json.loads(read(call, "meeting.json") or "{}")
    except json.JSONDecodeError:
        meeting = {}
    date = date_line(meeting)
    notes = read(call, "notes.md") or ""
    follow_ups = follow_up_notes(notes)

    # ---- pass 1: the summary
    user1 = "\n".join([fill((PROMPTS / "summary.md").read_text(encoding="utf-8").rstrip(), date), ""]
                      + inline(call, ("meeting.json", "transcript.txt", "prep.md", "notes.md")))
    log("pass 1 (summary): {} at {} effort, {} prompt chars…".format(MODEL, EFFORT, len(user1)))
    draft, reasoning1, meta1 = chat(user1, PASS1_MAX_TOKENS)
    write_private(extras / "reasoning-pass1.txt", reasoning1)
    record["pass1"] = meta1
    log("pass 1: {} s, finish_reason={}, usage={}".format(meta1["wall_s"], meta1["finish_reason"],
                                                          json.dumps(meta1["usage"])))
    if meta1["finish_reason"] != "stop" or not draft:
        raise StepError("pass 1 came back {} (finish_reason={}); nothing written, pass 2 not run"
                        .format("empty" if not draft else "cut off", meta1["finish_reason"]))
    draft, meta1["timestamps_stripped"] = strip_times(draft)
    draft, meta1["date_line_fixed"] = fix_date_line(draft, date)
    write_private(extras / "draft.md", draft + "\n")

    # ---- pass 2: check every decision, action item and confirmed note against the transcript
    user2 = "\n".join([fill((PROMPTS / "verify.md").read_text(encoding="utf-8").rstrip(), date), ""]
                      + inline(call, ("transcript.txt", "notes.md", "prep.md"))
                      + ["===== summary.md (draft to check) =====", draft, ""])
    log("pass 2 (check): {} prompt chars…".format(len(user2)))
    raw2, reasoning2, meta2 = chat(user2, PASS2_MAX_TOKENS, schema=CHECK_SCHEMA)
    write_private(extras / "reasoning-pass2.txt", reasoning2)
    write_private(extras / "pass2-raw.json", raw2 + "\n")
    record["pass2"] = meta2
    log("pass 2: {} s, finish_reason={}, usage={}".format(meta2["wall_s"], meta2["finish_reason"],
                                                          json.dumps(meta2["usage"])))
    if meta2["finish_reason"] != "stop":
        raise StepError("pass 2 was cut off (finish_reason={}); the unchecked draft is in {}"
                        .format(meta2["finish_reason"], extras / "draft.md"))
    result = parse_check(raw2)
    if not isinstance(result, dict) or not str(result.get("summary_md") or "").strip():
        raise StepError("pass 2 returned no usable summary (see pass2-raw.json); the unchecked draft is in {}"
                        .format(extras / "draft.md"))

    final, meta2["timestamps_stripped"] = strip_times(str(result["summary_md"]).strip())
    final, meta2["date_line_fixed"] = fix_date_line(final, date)
    checks, missing = result.get("checks") or [], result.get("missing") or []
    verdicts = {}
    for c in checks:
        verdicts[c.get("verdict")] = verdicts.get(c.get("verdict"), 0) + 1
    meta2["verdicts"] = verdicts
    meta2["missing_added"] = len(missing)
    write_private(extras / "checks.json",
                  json.dumps({"checks": checks, "missing": missing}, indent=2, ensure_ascii=False) + "\n")

    # Warnings only: the model wrote summary_md; these say where to look.
    warnings = []
    unbacked = [c for c in checks if c.get("verdict") == "supported" and c.get("section") in ("decision", "note")
                and re.match(r"\s*none found", str(c.get("agreement", "")), re.I)]
    if unbacked:
        warnings.append("{} decision(s)/note(s) kept as supported with no agreement quoted".format(len(unbacked)))
    if not meta2["date_line_fixed"]:
        warnings.append("no Date: line in the summary")
    if follow_ups and final.count(FOLLOW_UP_LINE) < len(follow_ups):
        warnings.append("{} follow-up note(s) but {} '{}' line(s)"
                        .format(len(follow_ups), final.count(FOLLOW_UP_LINE), FOLLOW_UP_LINE))
    record["warnings"] = warnings
    for w in warnings:
        log("warning: " + w)

    write_private(call / "summary.md", final + "\n")
    return verdicts, len(missing)


def main():
    if len(sys.argv) != 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 64
    # Cancel / timeout send SIGTERM: unwind normally so temp files are removed and run.json is written.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

    call = Path(sys.argv[1]).expanduser().resolve()
    if not call.is_dir():
        print("summary: no such call folder: {}".format(call), file=sys.stderr)
        return 66
    extras = call / "pipeline" / "summary"
    extras.mkdir(mode=0o700, parents=True, exist_ok=True)
    record = {"url": URL, "model": MODEL, "effort": EFFORT, "me_name": ME_NAME or None,
              "started_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
    t0 = time.time()
    code = 0
    try:
        verdicts, n_missing = run(call, extras, record)
        mins, secs = divmod(int(time.time() - t0), 60)
        log("summary.md written in {}m{:02d}s: checks {}, {} missing item(s) added".format(
            mins, secs, json.dumps(verdicts, sort_keys=True), n_missing))
    except StepError as e:
        record["error"] = str(e)
        print("summary: " + str(e), file=sys.stderr, flush=True)
        code = 1
    except SystemExit as e:
        record["error"] = "stopped (exit {})".format(e.code)
        code = e.code if isinstance(e.code, int) else 1
    finally:
        record["total_s"] = round(time.time() - t0, 1)
        write_private(extras / "run.json", json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
