# Changelog

memoir's versions are git tags `vX.Y.Z` on `main` (DESIGN.md §9.1). Builds between releases show as
`0.2.0+3 (3005f27)`. A release's section is written in the PR that prepares it; `scripts/release.sh X.Y.Z`
tags `main` and publishes the section as the GitHub Release notes.

## Unreleased

- **Local Summary step.** `mac/steps/summary_qwen.py`: Qwen (`qwen3.8-judge`) on the Spark writes
  `summary.md`, so nothing leaves your network and "Keep local only" calls get a summary too
  (`remote = false`). It's now the Summary in `mac/pipeline.example.toml`, with the Cursor agent kept as a
  commented-out alternative. Standard-library Python on macOS's `/usr/bin/python3`; no key needed.
  - **Two passes:** a draft, then a check of every decision, action item and confirmed note against the
    transcript. A decision is kept only if the check quotes the answer or acceptance, not just the question.
  - **Your name:** "Me" is named in the prompt (`MEMOIR_ME_NAME`), so you're listed once.
  - **Safe failures:** if a pass comes back empty or cut off, the step fails and an earlier `summary.md`
    stays; the file is written via a temp file and a rename.
  - **Clean output:** the `Date:` line is computed from `meeting.json`; `[mm:ss]` times are stripped in code;
    follow-up notes are marked "not researched (local model, no tools)".
  - **Extras:** the draft, the checks, the thinking and the timings go to `<call>/pipeline/summary/`.
  - **Speed:** about 15 minutes for a 45-minute call, against ~2 for the Cursor agent.
- **Reconnecting.** A dropped connection no longer ends the call ("lost the server: … Software caused
  connection abort"): Memoir keeps recording, shows *reconnecting…*, reconnects within seconds and re-sends
  the audio from the last finished line, so the transcript has no gap. Gives up only after 5 minutes without
  a connection, or for errors retrying can't fix. Each drop is listed in the call's `meeting.json`
  (`reconnects`). Works for Memoir.app and `memoir listen`; no server change.
- **Versions.** The app, the CLI and the server know their version, from the last tag:
  - **Memoir.app:** About Memoir in the menu bar; a Version row in Settings with **Copy** (for bug reports).
  - **CLI:** `memoir --version`; build it with `scripts/build-cli.sh` to stamp it in (a plain `swift build` says `dev`).
  - **Server:** sends its version in `ready` and logs it at start.
- Each call's `meeting.json` records `client_version` and `server_version`; each pipeline step records the
  `memoir_version` that ran it.
- **Wire protocol version** (`protocol: 1` in `start` / `ready`): a mismatched app and server now fail with
  "update the server" / "update the app" instead of misbehaving. Clients and servers before this don't send
  it and count as protocol 1.
- `scripts/release.sh` and this changelog.

## 0.2.0 — 2026-10-25

The first tagged version: everything up to here.

- **Server** (`memoir-asr` on spark-0e81): Nemotron Speech Streaming EN 0.6B on NeMo's streaming pipeline,
  over a WebSocket; partials and finals with late-punctuation fixes; a JSONL backup per call.
- **CLI** (`memoir listen`): microphone and/or the Mac's audio (Core Audio process tap), as Me / Them;
  `memoir process` for the after-the-call pipeline.
- **Memoir.app:** menu bar, New Call (name, sources, prep), the always-on-top overlay (live transcript,
  Notes | Prep, resizable), Settings (font, background, calls, pipeline), Recent Calls.
- **Call folder** on the Mac (`~/memoir/YYYY-MM-DD_<name>/`) as the record: transcript, prep, notes,
  `meeting.json`, optional audio.
- **After the call:** `~/.config/memoir/pipeline.toml` steps — today a Cursor-agent summary, then a
  Google Doc in a Drive folder — run by the app or `memoir process`.
- **Echo gate:** with mic + system audio, the call leaking from headphones into the mic no longer shows up
  as Me.
