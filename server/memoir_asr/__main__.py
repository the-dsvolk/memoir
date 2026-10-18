"""Run the server: `uv run --no-sync python -m memoir_asr` (from server/)."""

import logging
import os

os.environ.setdefault("WANDB_MODE", "disabled")
# memoir's own model cache: ~/.cache/huggingface/hub on spark-0e81 is root-owned (INSTALL.md #2).
os.environ.setdefault("HF_HOME", os.path.expanduser("~/.cache/memoir/huggingface"))

import uvicorn  # noqa: E402

from .app import create_app  # noqa: E402
from .engine import Engine  # noqa: E402
from .settings import Settings  # noqa: E402


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    settings = Settings.from_env()
    engine = Engine(settings.model, settings.revision, settings.chunk_ms)  # load before accepting clients
    uvicorn.run(create_app(settings, engine), host=settings.host, port=settings.port, log_level="info")


if __name__ == "__main__":
    main()
