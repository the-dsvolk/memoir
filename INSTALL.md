# memoir — Install

How to install the **memoir ASR server** on the DGX Spark `spark-0e81`: Nemotron Speech Streaming EN
0.6B on NeMo, in a rootless `uv` environment (Plan A in [`DESIGN.md`](./DESIGN.md) §5.2). The Mac app
comes later (M2/M3). Everything here runs as my user — **no sudo, no Docker**.

**Status:** installed and verified on `spark-0e81` on 2026-10-17 (see [Verified](#verified)).

## Requirements

| Requirement | Needed | On `spark-0e81` (checked 2026-10-17) |
|---|---|---|
| Hardware | NVIDIA DGX Spark (GB10, aarch64) | ✅ |
| OS | Linux | ✅ Ubuntu 24.04.4 |
| NVIDIA driver | supports CUDA 13.0 | ✅ 580.173.02 — **pinned, don't upgrade** (590.x blocked) |
| Python | 3.12 | ✅ 3.12.3 |
| `uv` | any recent | ✅ 0.11.29 at `~/.local/bin/uv` |
| `libsndfile` | for `soundfile` | ✅ system library present |
| Disk | ~8 GB (5.2 GB venv + 2.4 GB model) | ✅ 3.2 TB free |
| Network | PyPI, `download.pytorch.org`, Hugging Face | ✅ |
| GPU memory | ~5 GB | ✅ ~62 GB free next to qmx's ~39 GB |

**Not needed:** `sudo`, Docker, `ffmpeg` / `sox` (we feed raw PCM, not audio files), a compiler or
Python headers (every dependency has a pure-Python or aarch64 wheel).

### Python packages ([`server/pyproject.toml`](./server/pyproject.toml), locked in `server/uv.lock`)

| Package | Version | Note |
|---|---|---|
| `torch` | 2.11.0+cu130 | **from `https://download.pytorch.org/whl/cu130` only** — PyPI's aarch64 torch can be CPU-only |
| `nemo-toolkit[asr]` | 3.0.0 | NeMo speech stack; pulls lightning, lhotse, librosa, transformers, … (171 packages in all) |
| `silero-vad` | 6.2.3 | segment ends (§5.3) |
| `fastapi`, `uvicorn[standard]` | 0.143.3, 0.54.0 | WebSocket server (M1) |

The project is locked to Linux aarch64 (`[tool.uv] environments`) because the cu130 index has no
macOS wheels.

### Model

`nvidia/nemotron-speech-streaming-en-0.6b` at revision **`ebe59e5`** — the `.nemo` file (2.47 GB),
downloaded on first use into **memoir's own Hugging Face cache, `~/.cache/memoir/huggingface`** (see
install log #2). NVIDIA Open Model License.

## Steps

### 1. Get the code on the Spark

```bash
git clone https://github.com/the-dsvolk/memoir.git ~/GitHub/the-dsvolk/memoir
cd ~/GitHub/the-dsvolk/memoir && git checkout docs/design   # until it's merged to main
```

### 2. Create the environment (~70 s)

```bash
cd ~/GitHub/the-dsvolk/memoir/server
~/.local/bin/uv sync --frozen
```

After this, run everything with **`uv run --no-sync`** (install log #1).

### 3. Check torch sees the GPU and NeMo imports

```bash
~/.local/bin/uv run --no-sync python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
WANDB_MODE=disabled ~/.local/bin/uv run --no-sync python -c "import nemo; import nemo.collections.asr; print('nemo', nemo.__version__)"
```

Expect `2.11.0+cu130 13.0 True` and `nemo 3.0.0` (the NeMo import takes ~10 s).

### 4. Download the model and transcribe a test file

Make 16 kHz mono WAVs on the Mac and copy them over (`*.wav` is git-ignored):

```bash
say -o hello.wav --data-format=LEI16@16000 "Hello, this is a memoir transcription test."
scp hello.wav spark-0e81.local:GitHub/the-dsvolk/memoir/server/
```

Then on the Spark:

```bash
cd ~/GitHub/the-dsvolk/memoir/server
~/.local/bin/uv run --no-sync python tools/smoke_test.py hello.wav
```

The smoke test sets `WANDB_MODE=disabled` and `HF_HOME=~/.cache/memoir/huggingface` itself. Expect
`loaded … | sample rate 16000 | att_context_size [70, 6]` and the sentence printed back. NeMo prints a
long model config and a few warnings about training/validation data — those are harmless.

## Privacy

NeMo pulls `wandb` and NVIDIA's `nv-one-logger` telemetry packages. Checked on import: **OneLogger is
disabled with no exporters** ("No exporters were provided. This means that no telemetry data will be
collected."). `wandb` stays off with `WANDB_MODE=disabled` — set it in every environment that runs
memoir (the smoke test does).

## Verified

2026-10-17 on `spark-0e81`, with qmx's services running:

| Check | Result |
|---|---|
| `uv sync --frozen` | 171 packages in 71 s; `.venv` is 5.2 GB |
| torch | `2.11.0+cu130`, CUDA 13.0, sees the **NVIDIA GB10** |
| NeMo | 3.0.0 imports in ~10 s; telemetry off |
| Model load | 32.6 s on the first run, including the 2.47 GB download |
| `hello.wav` (2.6 s) | "Hello, this is a memoir transcription test." |
| `meeting.wav` (12.0 s) | "Okay, let's get started. The plan for next quarter is to ship the beta by March fifteenth. Can we confirm the budget is still forty two thousand dollars? Alice will follow up with the vendor on Tuesday." — word-perfect |
| Speed / memory | both files (14.6 s of audio) in 0.71 s; peak GPU memory 4.99 GB (F32 weights) |

Both transcripts came out word-perfect with punctuation and capitals. Numbers come out as **words**
("forty two thousand dollars", "March fifteenth"): there's no inverse text normalisation — see
`DESIGN.md` open question 10. The test audio is synthetic (`say`), so this proves the install, not
accuracy on real calls; that's M0's next step.

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
   default in `tools/smoke_test.py`, and set in `~/.config/memoir/env` for the service.
