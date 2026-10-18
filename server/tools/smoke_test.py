"""M0 smoke test: load Nemotron Speech Streaming EN on the GPU and transcribe WAV files.

Usage (on spark-0e81, from server/):
    uv run python tools/smoke_test.py hello.wav [more.wav ...]

Env: MEMOIR_MODEL, MEMOIR_MODEL_REVISION, MEMOIR_CHUNK_MS (80 | 160 | 560 | 1120).
"""

import os
import sys
import time

os.environ.setdefault("WANDB_MODE", "disabled")

import torch  # noqa: E402
from huggingface_hub import hf_hub_download  # noqa: E402
import nemo.collections.asr as nemo_asr  # noqa: E402

MODEL = os.environ.get("MEMOIR_MODEL", "nvidia/nemotron-speech-streaming-en-0.6b")
REVISION = os.environ.get("MEMOIR_MODEL_REVISION", "ebe59e5a817142986528bbbee5dba8db7b38ed50")
RIGHT_CONTEXT = {80: 0, 160: 1, 560: 6, 1120: 13}[int(os.environ.get("MEMOIR_CHUNK_MS", "560"))]


def main(paths: list[str]) -> None:
    if not torch.cuda.is_available():
        sys.exit("CUDA not available — check the torch build (must be +cu130)")
    print(f"torch {torch.__version__} | CUDA {torch.version.cuda} | {torch.cuda.get_device_name(0)}")

    t = time.perf_counter()
    nemo_file = hf_hub_download(MODEL, f"{MODEL.split('/')[-1]}.nemo", revision=REVISION)
    model = nemo_asr.models.ASRModel.restore_from(nemo_file, map_location="cuda").eval()
    model.encoder.set_default_att_context_size([70, RIGHT_CONTEXT])
    rate = model.cfg.preprocessor.sample_rate
    print(f"loaded {MODEL}@{REVISION[:7]} in {time.perf_counter() - t:.1f} s | "
          f"sample rate {rate} | att_context_size [70, {RIGHT_CONTEXT}]")
    assert rate == 16000, f"expected a 16 kHz model, got {rate}"

    if not paths:
        return
    t = time.perf_counter()
    results = model.transcribe(paths, batch_size=1)
    elapsed = time.perf_counter() - t
    for path, result in zip(paths, results):
        print(f"{path}: {getattr(result, 'text', result)}")
    print(f"transcribed {len(paths)} file(s) in {elapsed:.2f} s | "
          f"peak GPU memory {torch.cuda.max_memory_allocated() / 1e9:.2f} GB")


if __name__ == "__main__":
    main(sys.argv[1:])
