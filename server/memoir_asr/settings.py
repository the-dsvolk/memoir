"""Server settings, read from MEMOIR_* environment variables (see DESIGN.md §9)."""

import os
from dataclasses import dataclass
from pathlib import Path

CHUNK_MS_TO_RIGHT_CONTEXT = {80: 0, 160: 1, 560: 6, 1120: 13}


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    token: str
    model: str
    revision: str
    chunk_ms: int
    data_dir: Path

    @classmethod
    def from_env(cls) -> "Settings":
        token = os.environ.get("MEMOIR_TOKEN", "").strip()
        if not token:
            token_file = Path(os.environ.get("MEMOIR_TOKEN_FILE", "~/.config/memoir/token")).expanduser()
            if token_file.exists():
                token = token_file.read_text().strip()
        if not token:
            raise SystemExit("No token: set MEMOIR_TOKEN or create ~/.config/memoir/token (INSTALL.md)")
        chunk_ms = int(os.environ.get("MEMOIR_CHUNK_MS", "560"))
        if chunk_ms not in CHUNK_MS_TO_RIGHT_CONTEXT:
            raise SystemExit(f"MEMOIR_CHUNK_MS must be one of {sorted(CHUNK_MS_TO_RIGHT_CONTEXT)}")
        return cls(
            host=os.environ.get("MEMOIR_HOST", "0.0.0.0"),
            port=int(os.environ.get("MEMOIR_PORT", "8770")),
            token=token,
            model=os.environ.get("MEMOIR_MODEL", "nvidia/nemotron-speech-streaming-en-0.6b"),
            revision=os.environ.get("MEMOIR_MODEL_REVISION", "ebe59e5a817142986528bbbee5dba8db7b38ed50"),
            chunk_ms=chunk_ms,
            data_dir=Path(os.environ.get("MEMOIR_DATA_DIR", "~/.memoir")).expanduser(),
        )
