from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

class BackendAdapter:
    """GUI-facing adapter for the existing v25.1 pipeline."""

    def __init__(self, backend: Path | None = None, python: Path | None = None):
        self.backend = backend
        self.python = python or Path(sys.executable)

    def available(self) -> bool:
        return bool(self.backend and self.backend.exists())

    def start_transcription(
        self,
        input_file: Path,
        *,
        out_dir: Path | None = None,
        no_summary: bool = False,
        speakers: int = 0,
        env: dict[str, str] | None = None,
    ):
        if not self.available():
            raise RuntimeError("Ядро транскрибации не найдено.")
        command = [str(self.python), "-B", str(self.backend), str(input_file)]
        if no_summary:
            command.append("--no-summary")
        if out_dir is not None:
            command += ["--out-dir", str(out_dir)]
        if speakers > 0:
            command += ["--speakers", str(speakers)]
        return subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            # Кодировку задаём с обеих сторон явно. По умолчанию питон берёт
            # кодовую страницу системы, и на Windows без кириллицы ядро
            # обрывалось на первом русском слове, а интерфейс получал обрубок.
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            cwd=str(self.backend.parent),
            env={**os.environ, "PYTHONUNBUFFERED": "1",
                 "PYTHONIOENCODING": "utf-8", **(env or {})},
        )
