"""Persistent, explicit voice identity. A diarization ID is local to one meeting."""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

EXTRA = "доп файлы, на случай ошибки summary"


def link_voice(result: Path, speaker_id: str, profile_key: str) -> None:
    if not speaker_id or not profile_key or not (result / "transcript.json").is_file():
        raise ValueError("Не найдена встреча или голос")
    path = result / EXTRA / "speaker_links.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    links = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    if not isinstance(links, dict):
        raise ValueError("Повреждены привязки голосов; исходный файл не изменён")
    links[speaker_id] = profile_key
    fd, temporary = tempfile.mkstemp(prefix=".speaker-links-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(links, handle, ensure_ascii=False, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def link_sample(sample: Path, profile_key: str) -> None:
    # Only samples exported under a result directory carry a meeting identity.
    result = next((p for p in sample.parents if p.name.endswith("_result")), None)
    if result is not None:
        speaker_id = sample.stem.split(" — ", 1)[0]
        link_voice(result, speaker_id, profile_key)
