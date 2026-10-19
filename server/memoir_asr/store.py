"""Per-meeting transcript store: one JSONL file, appended as finals arrive (DESIGN.md §5.5)."""

import json
import os
from datetime import datetime
from pathlib import Path


class Store:
    def __init__(self, data_dir: Path, meeting: dict, model: str) -> None:
        now = datetime.now().astimezone()
        day = data_dir / "meetings" / now.strftime("%Y-%m-%d")
        day.mkdir(parents=True, exist_ok=True)
        self.path = day / f"{now.strftime('%H%M')}-{meeting['meeting_id']}.jsonl"
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        self._file = os.fdopen(fd, "a", encoding="utf-8")
        if self._file.tell() == 0:
            self.append({"type": "meeting", "meeting_id": meeting["meeting_id"], "title": meeting.get("title", ""),
                         "app": meeting.get("app", ""), "sources": meeting["sources"],
                         "started_at": now.isoformat(timespec="seconds"), "model": model})

    def append(self, record: dict) -> None:
        self._file.write(json.dumps(record, ensure_ascii=False) + "\n")
        self._file.flush()

    def close(self) -> None:
        self._file.close()
