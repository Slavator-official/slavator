from __future__ import annotations
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

    def start_transcription(self, input_file: Path):
        if not self.available():
            raise RuntimeError("Ядро транскрибации не найдено.")
        return subprocess.Popen(
            [str(self.python), str(self.backend), str(input_file)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            cwd=str(self.backend.parent),
        )
