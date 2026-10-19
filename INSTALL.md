# memoir — Install

How to install and run memoir:
- the **ASR server** `memoir-asr` on the DGX Spark `spark-0e81` — Nemotron Speech Streaming EN 0.6B
  on NeMo's streaming pipeline, in a rootless `uv` environment (Plan A in [`DESIGN.md`](./DESIGN.md)
  §5.2);
- the **Mac command-line client** `memoir` — streams the mic and/or the Mac's audio to the server,
  prints the live transcript and records each call in its own folder; and
- the **Mac app** `Memoir.app` — the same, from the menu bar, with a floating transcript overlay.

Everything runs as my user — **no sudo, no Docker**. The CLI and the app share one core (`MemoirKit`)
and one settings file (`~/.config/memoir/config.toml`).

**Status:** server installed, MVP verified end to end on 2026-10-17; the app builds and signs
(2026-10-18) — see [Verified](#verified).

## Requirements

| Requirement | Needed | On `spark-0e81` (checked 2026-10-17) |
|---|---|---|
| Hardware | NVIDIA DGX Spark (GB10, aarch64) | ✅ |
| OS | Linux | ✅ Ubuntu 24.04.4 |
| NVIDIA driver | supports CUDA 13.0 | ✅ 580.173.02 — **pinned, don't upgrade** (590.x blocked) |
| Python | 3.12 **with headers** | uv-managed CPython 3.12.13 (the system 3.12.3 has no headers — install log #4) |
| `uv` | any recent | ✅ 0.11.29 at `~/.local/bin/uv` |
| C compiler | `gcc` (Triton builds a small helper at first GPU kernel launch) | ✅ gcc 13.3 |
| `libsndfile` | for `soundfile` | ✅ system library present |
| Disk | ~8 GB (5.2 GB venv + 2.4 GB model) | ✅ 3.2 TB free |
| Network | PyPI, `download.pytorch.org`, Hugging Face, `python-build-standalone` | ✅ |
| GPU memory | ~5 GB | ✅ ~62 GB free next to qmx's ~39 GB |

**Not needed:** `sudo`, Docker, `ffmpeg` / `sox` (we feed raw PCM, not audio files).

On the **Mac**: Xcode 26 (Swift 6.2), macOS 14+, the same LAN as the Spark.

### Python packages ([`server/pyproject.toml`](./server/pyproject.toml), locked in `server/uv.lock`)

| Package | Version | Note |
|---|---|---|
| `torch` | 2.11.0+cu130 | **from `https://download.pytorch.org/whl/cu130` only** — PyPI's aarch64 torch can be CPU-only |
| `nemo-toolkit[asr]` | 3.0.0 | NeMo speech stack incl. the streaming pipeline; pulls lightning, lhotse, transformers, … (171 packages) |
| `silero-vad` | 6.2.3 | installed for later; the MVP uses the pipeline's own end-of-utterance detector |
| `fastapi`, `uvicorn[standard]` | 0.143.3, 0.54.0 | WebSocket server |

`server/pyproject.toml` pins `python-preference = "only-managed"` (uv's own CPython, which ships its
headers) and locks the project to Linux aarch64 (the cu130 index has no macOS wheels).

### Model

`nvidia/nemotron-speech-streaming-en-0.6b` at revision **`ebe59e5`** — the `.nemo` file (2.47 GB),
downloaded on first use into **memoir's own cache, `~/.cache/memoir/huggingface`** (install log #2).
NVIDIA Open Model License.

## Server (spark-0e81)

### 1. Get the code

```bash
git clone https://github.com/the-dsvolk/memoir.git ~/GitHub/the-dsvolk/memoir
cd ~/GitHub/the-dsvolk/memoir && git checkout feat/mvp-mic   # until it's merged to main
```

### 2. Create the environment (~70 s the first time)

```bash
cd ~/GitHub/the-dsvolk/memoir/server
~/.local/bin/uv sync --frozen
```

uv downloads its managed CPython if needed. After this, run everything with **`uv run --no-sync`**
(install log #1). If an older `.venv` was built on the system Python, recreate it:
`rm -rf .venv && ~/.local/bin/uv sync --frozen`.

### 3. Check torch sees the GPU and NeMo imports

```bash
~/.local/bin/uv run --no-sync python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
WANDB_MODE=disabled ~/.local/bin/uv run --no-sync python -c "import nemo; import nemo.collections.asr; print('nemo', nemo.__version__)"
```

Expect `2.11.0+cu130 13.0 True` and `nemo 3.0.0` (the NeMo import takes ~10 s).

### 4. Smoke test: download the model and transcribe a file

Make a 16 kHz mono WAV on the Mac and copy it over (`*.wav` is git-ignored):

```bash
say -o hello.wav --data-format=LEI16@16000 "Hello, this is a memoir transcription test."
scp hello.wav spark-0e81.local:GitHub/the-dsvolk/memoir/server/
```

On the Spark:

```bash
cd ~/GitHub/the-dsvolk/memoir/server
~/.local/bin/uv run --no-sync python tools/smoke_test.py hello.wav
```

Expect `loaded … | sample rate 16000 | att_context_size [70, 6]` and the sentence printed back. NeMo
prints a long model config and a few warnings about training/validation data — harmless.

### 5. Create the bearer token

```bash
mkdir -p ~/.config/memoir && chmod 700 ~/.config/memoir
( umask 077; openssl rand -hex 32 > ~/.config/memoir/token )
```

The server reads `MEMOIR_TOKEN` or this file; clients send it as `Authorization: Bearer <token>`.

### 6. Run the server

For development, as a transient user service (survives logout; gone after a reboot):

```bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)     # needed for systemctl --user over SSH
systemd-run --user --unit=memoir-asr-dev \
  --working-directory=$HOME/GitHub/the-dsvolk/memoir/server --setenv=PYTHONUNBUFFERED=1 \
  $HOME/.local/bin/uv run --no-sync python -m memoir_asr
journalctl --user -u memoir-asr-dev -f          # wait for "Uvicorn running on http://0.0.0.0:8770"
systemctl --user stop memoir-asr-dev            # stop it
```

Or in the foreground: `cd server && ~/.local/bin/uv run --no-sync python -m memoir_asr`. Start-up takes
~40 s (model load + one warm-up step), then the log shows
`engine ready: nvidia/nemotron-speech-streaming-en-0.6b@ebe59e5, 8960-sample frames (0.56 s)`. The
permanent `systemd --user` unit is in `DESIGN.md` §9 (M4).

Settings (environment): `MEMOIR_HOST` (0.0.0.0), `MEMOIR_PORT` (8770), `MEMOIR_TOKEN` /
`MEMOIR_TOKEN_FILE`, `MEMOIR_MODEL`, `MEMOIR_MODEL_REVISION`, `MEMOIR_CHUNK_MS` (80 / 160 / **560** /
1120), `MEMOIR_DATA_DIR` (`~/.memoir`). Transcripts go to `~/.memoir/meetings/<date>/<HHMM>-<id>.jsonl`
(mode 0600).

### 7. Check it end to end on the Spark

```bash
cd ~/GitHub/the-dsvolk/memoir/server
~/.local/bin/uv run --no-sync python tools/replay.py meeting.wav     # streams in real time
~/.local/bin/uv run --no-sync python -m unittest discover -s tests   # 10 session/protocol tests
```

`replay.py` prints the live transcript and latency: *after chunk end* (the server's own delay) and
*after chunk start* (the worst case for a word).

## Mac client

### 1. Build

```bash
cd mac/MemoirKit
swift build -c release            # → .build/release/memoir
swift test                        # 27 tests
```

### 2. Copy the token from the Spark

```bash
mkdir -p ~/.config/memoir && chmod 700 ~/.config/memoir
scp spark-0e81.local:.config/memoir/token ~/.config/memoir/token && chmod 600 ~/.config/memoir/token
```

### 3. Listen

```bash
.build/release/memoir listen --name "Weekly sync"            # microphone; Ctrl-C to stop
.build/release/memoir listen --source system                 # what the Mac plays (YouTube, a call, …) as "Them"
.build/release/memoir listen --source mic+system \
    --name "Weekly sync" --prep "Attendees: Alice, Bob"      # both, labelled Me: / Them: — use headphones
.build/release/memoir listen --prep-file agenda.md           # prep from a file (attendees, agenda, docs…)
.build/release/memoir listen --save-audio                    # also keep the audio, one WAV per source
.build/release/memoir listen --input meeting.wav --no-record # stream a file in real time, no call folder
```

Every call is recorded in its own folder — `~/memoir/2026-10-18_weekly-sync/` with `transcript.txt`,
`transcript.jsonl`, `prep.md` (material for the call), `notes.md` (notes during it), `meeting.json`
(and `me.wav` / `them.wav` with `--save-audio`) — written as the call goes (DESIGN.md §4.7). A name already used that day gets `_2`. `--out DIR`
changes the save folder for one run; the default comes from `~/.config/memoir/config.toml` (shared with
the app):

```toml
save_dir   = "~/memoir"
save_audio = false
server     = "ws://spark-0e81.local:8770/v1/stream"
token_file = "~/.config/memoir/token"
```

Partial text updates in place (dim, on stderr); finished sentences print to stdout as
`[mm:ss] text` (with two sources `[mm:ss] Me: …` / `[mm:ss] Them: …`).

Permissions, asked on first use **for your terminal app** (Terminal, iTerm, …):
- **Microphone** (`mic`) — Privacy & Security › Microphone.
- **System Audio Recording** (`system`) — Privacy & Security › Screen & System Audio Recording ›
  *System Audio Recording Only*. There's no API to check it: when it's denied the tap just delivers
  silence, so `memoir` prints a hint after 5 s of silence. A grant only takes effect after the terminal
  app restarts.

`--source system` taps **everything the Mac plays** except memoir itself (a Core Audio process tap,
macOS 14.4+), before the speakers — speakers or headphones don't matter, and notification sounds come
along too. Tapping a single app (Zoom, Teams, a browser) comes with M2.

## Mac app (Memoir.app)

### 1. Requirements

- **Xcode 26** and **XcodeGen** (`brew install xcodegen`) — `mac/MemoirApp/project.yml` is the source;
  the `.xcodeproj` is generated and not committed.
- A **code-signing identity named "Memoire Dev"** in the login keychain — a stable identity keeps the
  app's Microphone / System Audio Recording grants across rebuilds. To make one: Keychain Access ›
  Certificate Assistant › Create a Certificate…, name `Memoire Dev`, *Self Signed Root*, *Code Signing*.
- The token in `~/.config/memoir/token` (Mac client step 2).

### 2. Build and run

```bash
cd mac/MemoirApp
xcodegen generate
xcodebuild -project Memoir.xcodeproj -scheme Memoir -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Memoir.app      # or copy it to /Applications first
```

The app lives in the **menu bar** (a waveform icon; a red dot while recording) — no Dock icon.

### 3. Use it

- **New Call…** (⌘N in the menu): the call's **name**, what to **listen to** (microphone + this Mac's
  audio for calls, microphone only in person, or the Mac's audio only) and **prep** — attendees,
  agenda, past notes, docs; the editor grows with the window. It shows the folder it will save to.
  **Start**.
- The **overlay** floats above full-screen apps: status (`connecting…` / `live` / `saving…` /
  `error`), the call's name (edit it and press Enter to rename — the folder follows), the elapsed time,
  the live transcript (grey while still changing), and on the right a **Notes | Prep** pane with a
  multi-line editor (⌘↩ adds; an entry is stamped with the meeting time when you start typing):
  **Notes** for your notes during the call (`notes.md`), **Prep** to add material as the call goes —
  someone joined, a doc was pasted — appended with its time to `prep.md`. **Stop** ends the call; the
  overlay then shows the after-the-call steps (next section).
- **After the call** (in New Call): a checkbox per step of your pipeline — e.g. **Summary** and
  **Google Doc** — and **Keep local only**. After **Stop** the overlay shows `✓ Saved · ◌ Summary 0:42 ·
  ○ Google Doc`, then **Open Summary**, **Open Google Doc** and **Copy Link**; a notification says when
  it's ready (click it to open the doc). The **⋯** menu runs a step again, shows its log or opens the
  folder. **Recent Calls** in the menu bar does the same for earlier calls.
- **Settings…** (⌘,): the font and size for transcript and notes; save folder, save audio, server —
  the last three written to `~/.config/memoir/config.toml`, which the CLI reads too.

On first use macOS asks **for Memoir itself** (separately from your terminal): **Microphone**,
**System Audio Recording** (Privacy & Security › Screen & System Audio Recording › *System Audio
Recording Only*; restart Memoir after granting) and **Local Network**.

## After the call (pipeline)

Steps that run **on the Mac** once a call is saved — by Memoir.app when you stop, by `memoir listen`
after Ctrl-C, or any time with `memoir process` (DESIGN.md §4.8). They're listed in
`~/.config/memoir/pipeline.toml`; the example sets up two:

| Step | Runs | Makes |
|---|---|---|
| **Summary** | `uv run python main.py <call>` in `~/GitHub/Cruise/CursorSDKExample`, with `CURSOR_API_KEY` from the Keychain — a Cursor agent | `summary.md` in the call folder: summary, decisions, action items, your notes expanded |
| **Google Doc** | `~/.claude/skills/md-to-gdoc/create_gdoc.sh <call>/summary.md "<name> — <date>"` | a new Google Doc in My Drive; its link is shown in the app |

### 1. Set it up

```bash
cp mac/pipeline.example.toml ~/.config/memoir/pipeline.toml
# The Cursor API key, once, in the login Keychain (it prompts for the key):
security add-generic-password -a "$USER" -s cursor-api-key -w
```

Each step runs through **your login shell** (`bash -l` here), so it sees the same PATH as Terminal
(`uv`, `gcloud`, …) even though the app isn't started from one. Secrets come from the Keychain via
`security find-generic-password -a "$USER" -s <service> -w` — the same command you'd use by hand.

### 2. Check it

With the CLI from the Mac client build (`mac/MemoirKit/.build/release/memoir`):

```bash
memoir process ~/memoir/2026-10-18_weekly-sync --list   # steps, what's been done, links
memoir process ~/memoir/2026-10-18_weekly-sync           # the steps chosen for that call (else the defaults)
memoir process ~/memoir/2026-10-18_weekly-sync --step gdoc   # one step again (plus what it needs)
```

Progress goes to stderr, the links to stdout; `-v` shows each step's output live; Ctrl-C cancels.
Every step logs to `<call>/pipeline/<step>.log`, and `<call>/pipeline/state.json` records how it went.
A step counts as done only if it exits 0 **and** wrote its `outputs` during that run (an old
`summary.md` doesn't count). Calls shorter than `min_finals` lines (5) aren't processed automatically.

`memoir listen` records the choice too: `--steps summary,gdoc`, `--keep-local`, or `--no-process`.

## Privacy

NeMo pulls `wandb` and NVIDIA's `nv-one-logger` telemetry packages. Checked on import: **OneLogger is
disabled with no exporters** ("No exporters were provided. This means that no telemetry data will be
collected."). `wandb` stays off with `WANDB_MODE=disabled` — the server and smoke test set it. Audio
and transcripts stay on the LAN; the server needs the bearer token.

**The pipeline is different:** steps marked `remote = true` send the call off the Mac — Summary sends
the transcript, prep and notes to Cursor (and its model provider), Google Doc puts the summary in your
Drive. Untick them, or tick **Keep local only** (`--keep-local`), for calls that must stay local;
running a remote step on such a call later asks first (`--allow-remote` in the CLI).

## Verified

2026-10-17, server on `spark-0e81` with qmx's services running:

| Check | Result |
|---|---|
| `uv sync --frozen` | 171 packages in 71 s; `.venv` is 5.2 GB; rebuild on managed Python 1.2 s from cache |
| torch | `2.11.0+cu130`, CUDA 13.0, sees the **NVIDIA GB10** |
| NeMo | 3.0.0 imports in ~10 s; telemetry off |
| Model load | 32.6 s on the first run, including the 2.47 GB download |
| Smoke test | `hello.wav` and `meeting.wav` word-perfect; 14.6 s of audio in 0.71 s; peak GPU memory 4.99 GB |
| Server start | ~40 s to `engine ready` (560 ms frames) |
| Streaming (replay on the Spark and `memoir listen --input` from the Mac) | partials word by word; finals `[00:00] … forty two thousand dollars?` and `[00:10] Alice will follow up with the vendor on Tuesday.` — word-perfect, correct punctuation |
| Latency (partials) | **0.02–0.03 s after a 560 ms chunk ends**, 0.56–0.62 s after it starts → a word shows up in ~0.3 s typically, ≤ 0.65 s worst |
| Tests | 10 server tests (unittest), 6 Swift tests — all pass |
| **Live microphone** (Yeti Stereo USB mic → `memoir listen` → server) | works first time; same latency (0.03 s after a chunk ends, 0.62 s after it starts); text right apart from a first name misheard and one sentence split at a mid-sentence pause |
| **System audio** (`--source system`, a YouTube trailer playing in the browser) | works first time: the terminal app got System Audio Recording permission on this managed Mac — no app bundle needed; tap on the LG ULTRAWIDE output at 48 kHz stereo; same latency (0.03 s / 0.62 s). Clear lines transcribed well; fast cross-talk over music lost punctuation and merged into long segments |
| Soak: 7.4 min in real time (30 × `meeting.wav`) | every repeat word-correct; the server kept pace — `upto` 446.4 s when stopped at 446 s, no backlog (stopped early to free the server for the live test) |
| **Memoir.app** (2026-10-18) | builds with XcodeGen + `xcodebuild`, no warnings; signed with "Memoire Dev", hardened runtime, `audio-input` entitlement; Info.plist carries the Microphone / System Audio / Local Network texts directly. **Not yet run on a real call.** |
| Shared core + CLI (2026-10-18) | 13 Swift tests (call folder, `_2` on clashes, rename, config round-trip, transcript model, …) pass |
| **Pipeline** (2026-10-18) | 27 Swift tests pass (TOML reader, config checks, runner: outputs, links, stale outputs, skipped needs, re-runs, timeout, cancel stops the whole process group, leftovers outside it stopped, one runner per call). Dry run of `memoir process` from an **empty environment** (as an app gets): Keychain key loaded, `uv` and `gcloud` found through `bash -l`, `cursor_sdk` imports in the CursorSDKExample folder, the printed link kept. **From the app** (Recent Calls › youtube test 2 › Run All Again): Summary 35 s, Google Doc 9 s, link shown, notification. |

Synthetic test audio (`say`) proves the pipeline; the live-mic run shows it works on a real voice.
Accuracy on real calls (and the other side's audio) comes with the call tap (M2).

## Install log

Problems hit while installing, and their fixes (newest last).

1. **`uv run` reinstalls `nvidia-cusparselt-cu13` every time** (2026-10-17). Every sync printed
   "Uninstalled 1 package / Installed 1 package"; `uv sync --dry-run -vv` showed
   `Platform tags mismatch for nvidia-cusparselt-cu13==0.8.0`. Cause: NVIDIA's wheel is *named*
   `…-py3-none-manylinux2014_aarch64.whl` but its `WHEEL` metadata says
   `Tag: py3-none-manylinux2014_sbsa`, which uv doesn't recognise as a platform tag. Harmless (it
   reinstalls from cache in ~7 ms). **Fix:** sync once with `uv sync --frozen`, then always run with
   `uv run --no-sync` — including the systemd unit.
2. **`PermissionError` writing `~/.cache/huggingface/hub`** (2026-10-17). That directory and its
   contents are owned by **root**, left by Docker runs (vLLM / Nemotron-120B) that mounted it. No sudo
   to `chown` it. **Fix:** memoir uses its own cache, `HF_HOME=~/.cache/memoir/huggingface` — the
   default in the server and `tools/smoke_test.py`.
3. **`PermissionError` writing `~/.triton/cache`** (2026-10-17). Also root-owned, from the same Docker
   runs (as are `~/.cache/flashinfer` and `~/.cache/vllm`, which memoir doesn't use). **Fix:**
   `TRITON_CACHE_DIR=~/.cache/memoir/triton`, defaulted in the server and the smoke test.
4. **Triton's runtime build fails: `gcc … cuda_utils.c` → `CalledProcessError`** (2026-10-17). The
   first Triton kernel launch compiles a small C helper against the Python headers, and the system
   Python 3.12.3 has none (no `python3.12-dev`, no sudo to install it). The kernel came from NeMo's
   **per-stream context biasing**, on in NeMo's default streaming config. **Fix:** (a) biasing off —
   no custom vocabulary yet; (b) `python-preference = "only-managed"`, so the venv runs on uv's own
   CPython 3.12.13, which ships `Python.h` — Triton's driver then builds fine
   (`rm -rf .venv && uv sync --frozen`).
5. **The last sentence lost its closing punctuation** (2026-10-17). NeMo's `return_tail_result` emits
   the words in the *right padding* of a stream's last frame — often just the final "." — and the
   pipeline skips a last frame with almost no audio. When the audio happened to divide evenly into
   560 ms frames, the last frame had 1 valid sample, so the period never came. **Fix:** the last frame
   always has ≥ 0.25 s of audio (silence counts) **and** some padding (`server/memoir_asr/session.py`).
6. **"The Internet connection appears to be offline" while the LAN works** (2026-10-18). `memoir`
   failed to connect (`NSURLErrorDomain -1009`) even by IP, while `ssh`, `curl` and `nc` reached the
   Spark fine. Cause: macOS **Local Network privacy** — Apple's own tools are exempt, a third-party
   binary needs the *responsible app* (the terminal, or the app itself) to have Local Network access;
   a background process that can't show the prompt is silently denied, and `URLSession` reports it as
   "offline". **Fix:** allow the app under Privacy & Security › Local Network and restart it. memoir
   now says so instead of "offline". For **Memoir.app**, macOS lists it under Local Network only once it
   has asked, and the prompt can appear after the first failed attempt — so the app retries for ~20 s
   ("waiting for network…"); after clicking **Allow** it connected (2026-10-18). **Fallback** if a
   corporate filter blocks LAN access outright (this Mac also runs Cisco Secure Client's socket filter
   and CrowdStrike): an SSH tunnel — `ssh -N -L 127.0.0.1:8770:127.0.0.1:8770 spark-0e81.local` — with
   the server set to `ws://127.0.0.1:8770/v1/stream`; loopback isn't subject to Local Network privacy,
   and the audio is encrypted on the way (tested: the tunnel reached the server).
7. **Memoir.app crashed at launch — "Library not loaded: @rpath/Memoir.debug.dylib … different Team
   IDs"** (2026-10-18). Xcode 16+ splits Debug builds into a stub plus `Memoir.debug.dylib` (for SwiftUI
   previews); with hardened runtime, macOS only loads libraries signed by the app's Team ID, and a
   self-signed "Memoire Dev" identity has none. **Fix:** `ENABLE_DEBUG_DYLIB: NO` in `project.yml` —
   one binary, nothing to validate (better than turning library validation off).
8. **Every Summary run left a `cursor-sdk-bridge` (node) running** (2026-10-18) — 66–196 MB each, eight
   by the time it was noticed (seven from running `main.py` by hand). `cursor-sdk` 1.0.38 starts its
   bridge through a shell wrapper (`bin/cursor-sdk-bridge`) that runs `"$DIR/node" …` **without
   `exec`**; at exit the SDK sends SIGTERM to the wrapper, and node is orphaned. It also escapes the
   step's process group, because `uv run` gives Python a group of its own. **Fix (memoir):** the runner
   notes everything a step starts while it runs (descendants of its first process, 4× a second, with
   start times) and, when the step ends — done, failed, cancelled or timed out — stops whatever is still
   running, plus anything in those processes' groups. Running `main.py` by hand still leaks; the SDK
   fix is `exec "$DIR/node" …` in its wrapper.
9. **"Run All Again" from Recent Calls seemed to do nothing** (2026-10-18) — it ran (Summary 35 s,
   then the Google Doc), but nothing was on screen: the overlay only showed the call recorded in that
   session. **Fix:** running steps on any call opens the overlay on that call (its transcript and the
   progress row); the menu-bar icon turns into an hourglass while processing; Recent Calls › Show Call.
