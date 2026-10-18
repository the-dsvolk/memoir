# memoir — Install

How to install the **memoir ASR server** on the DGX Spark `spark-0e81`: Nemotron Speech Streaming EN
0.6B on NeMo, in a rootless `uv` environment (Plan A in [`DESIGN.md`](./DESIGN.md) §5.2). The Mac app
comes later (M2/M3). Everything here runs as my user — **no sudo, no Docker**.

## Requirements

| Requirement | Needed | On `spark-0e81` (checked 2026-10-17) |
|---|---|---|
| Hardware | NVIDIA DGX Spark (GB10, aarch64) | ✅ |
| OS | Linux | ✅ Ubuntu 24.04.4 |
| NVIDIA driver | supports CUDA 13.0 | ✅ 580.173.02 — **pinned, don't upgrade** (590.x blocked) |
| Python | 3.12 | ✅ 3.12.3 |
| `uv` | any recent | ✅ 0.11.29 at `~/.local/bin/uv` |
| `libsndfile` | for `soundfile` | ✅ system library present |
| Disk | ~10 GB (venv + 2.47 GB model) | ✅ 3.2 TB free |
| Network | PyPI, `download.pytorch.org`, Hugging Face | ✅ |
| GPU memory | a few GB | ✅ ~62 GB free next to qmx's ~39 GB |

**Not needed:** `sudo`, Docker, `ffmpeg` / `sox` (we feed raw PCM, not audio files), a compiler or
Python headers (every dependency has a pure-Python or aarch64 wheel).

### Python packages ([`server/pyproject.toml`](./server/pyproject.toml))

| Package | Version | Note |
|---|---|---|
| `torch` | 2.11.0 (+cu130) | **from `https://download.pytorch.org/whl/cu130` only** — PyPI's aarch64 torch can be CPU-only |
| `nemo-toolkit[asr]` | 3.0.0 | NeMo speech stack; pulls lightning, lhotse, librosa, transformers, … |
| `silero-vad` | 6.2.3 | segment ends (§5.3) |
| `fastapi`, `uvicorn[standard]` | latest | WebSocket server (M1) |

The project is locked to Linux aarch64 (`[tool.uv] environments`) because the cu130 index has no
macOS wheels.

### Model

`nvidia/nemotron-speech-streaming-en-0.6b` at revision **`ebe59e5`** — the `.nemo` file (2.47 GB),
downloaded into the Hugging Face cache (`~/.cache/huggingface`) on first use. NVIDIA Open Model License.

## Steps

### 1. Get the code on the Spark

```bash
git clone https://github.com/the-dsvolk/memoir.git ~/GitHub/the-dsvolk/memoir
cd ~/GitHub/the-dsvolk/memoir && git checkout docs/design   # until it's merged to main
```

### 2. Create the environment

```bash
cd ~/GitHub/the-dsvolk/memoir/server
~/.local/bin/uv sync
```

### 3. Check torch sees the GPU and NeMo imports

```bash
~/.local/bin/uv run python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
WANDB_MODE=disabled ~/.local/bin/uv run python -c "import nemo.collections.asr; print('nemo ok')"
```

Expect `2.11.0+cu130 13.0 True` and `nemo ok`.

### 4. Download the model and transcribe a test file

Make a 16 kHz mono WAV on the Mac and copy it over:

```bash
say -o hello.wav --data-format=LEI16@16000 "Hello, this is a memoir transcription test."
scp hello.wav spark-0e81.local:GitHub/the-dsvolk/memoir/server/
```

Then on the Spark:

```bash
cd ~/GitHub/the-dsvolk/memoir/server
~/.local/bin/uv run python tools/smoke_test.py hello.wav
```

Expect the model to load (first run downloads 2.47 GB), report `sample rate 16000`, and print the
sentence back.

## Privacy

NeMo pulls `wandb` and NVIDIA's `nv-one-logger` telemetry packages. Always run with
`WANDB_MODE=disabled` (the smoke test sets it); the `nv-one-logger` behaviour is recorded in the
install log below.

## Install log

Problems hit while installing, and their fixes (newest last).
