# memoir — Install

How to install and run memoir's MVP:
- the **ASR server** `memoir-asr` on the DGX Spark `spark-0e81` — Nemotron Speech Streaming EN 0.6B
  on NeMo's streaming pipeline, in a rootless `uv` environment (Plan A in [`DESIGN.md`](./DESIGN.md)
  §5.2), and
- the **Mac command-line client** `memoir` — streams the microphone to the server and prints the live
  transcript.

Everything runs as my user — **no sudo, no Docker**. The menu-bar app comes later (M3).

**Status:** server installed, MVP verified end to end on 2026-10-17 (see [Verified](#verified)).

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
swift test                        # 6 tests
```

### 2. Copy the token from the Spark

```bash
mkdir -p ~/.config/memoir && chmod 700 ~/.config/memoir
scp spark-0e81.local:.config/memoir/token ~/.config/memoir/token && chmod 600 ~/.config/memoir/token
```

### 3. Listen

```bash
.build/release/memoir listen                       # microphone; Ctrl-C to stop
.build/release/memoir listen --source system       # what the Mac plays (YouTube, a call, …) as "Them"
.build/release/memoir listen --source mic+system   # both, labelled Me: / Them: — use headphones
.build/release/memoir listen --save me.wav         # also keep the audio (16 kHz mono; mic+system → me-me.wav, me-them.wav)
.build/release/memoir listen --input meeting.wav   # stream a file in real time instead
```

Partial text updates in place (dim, on stderr); finished sentences print to stdout as
`[mm:ss] text` (with two sources `[mm:ss] Me: …` / `[mm:ss] Them: …`), so
`memoir listen > transcript.txt` keeps just the transcript. Default server:
`ws://spark-0e81.local:8770/v1/stream` (`--server` to change).

Permissions, asked on first use **for your terminal app** (Terminal, iTerm, …):
- **Microphone** (`mic`) — Privacy & Security › Microphone.
- **System Audio Recording** (`system`) — Privacy & Security › Screen & System Audio Recording ›
  *System Audio Recording Only*. There's no API to check it: when it's denied the tap just delivers
  silence, so `memoir` prints a hint after 5 s of silence. A grant only takes effect after the terminal
  app restarts.

`--source system` taps **everything the Mac plays** except memoir itself (a Core Audio process tap,
macOS 14.4+), before the speakers — speakers or headphones don't matter, and notification sounds come
along too. Tapping a single app (Zoom, Teams, a browser) comes with M2.

## Privacy

NeMo pulls `wandb` and NVIDIA's `nv-one-logger` telemetry packages. Checked on import: **OneLogger is
disabled with no exporters** ("No exporters were provided. This means that no telemetry data will be
collected."). `wandb` stays off with `WANDB_MODE=disabled` — the server and smoke test set it. Audio
and transcripts stay on the LAN; the server needs the bearer token.

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
| Soak: 7.4 min in real time (30 × `meeting.wav`) | every repeat word-correct; the server kept pace — `upto` 446.4 s when stopped at 446 s, no backlog (stopped early to free the server for the live test) |

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
