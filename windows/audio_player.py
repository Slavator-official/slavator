#!/usr/bin/env python3
"""Small isolated WAV player used by the Windows GUI."""
from __future__ import annotations

import sys
from pathlib import Path


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        return 2
    source = Path(argv[1])
    if not source.is_file() or source.suffix.lower() != ".wav":
        return 2
    if sys.platform != "win32":
        return 3
    import winsound

    winsound.PlaySound(str(source), winsound.SND_FILENAME)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
