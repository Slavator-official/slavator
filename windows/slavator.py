#!/usr/bin/env python3
"""Windows launcher for the cross-platform Tk desktop application."""
from __future__ import annotations

import os
import runpy
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "core"))
import app_config

APP_NAME = "Славатор"


def project_root() -> Path:
    """Works both from a checkout and from %LOCALAPPDATA%\\Programs."""
    return Path(__file__).resolve().parent.parent


def support_dir() -> Path:
    return app_config.support_dir()


def load_config(path: Path) -> None:
    """Read the deliberately small KEY=VALUE format written by install.ps1."""
    for key, value in app_config.read_env(path).items():
        os.environ.setdefault(key, value)


def configure() -> tuple[Path, Path]:
    root = project_root()
    support = support_dir()
    support.mkdir(parents=True, exist_ok=True)
    runtime = app_config.environment()
    # Остальные настройки читает адаптер при каждом запуске, чтобы изменение
    # модели в GUI не перекрывалось старым значением в окружении запускателя.
    for key in ("MEETING_TRANSCRIBER_APP_SUPPORT", "MEETING_TRANSCRIBER_PROFILES",
                "MEETING_TRANSCRIBER_MODELS", "MEETING_TRANSCRIBER_GLOSSARY",
                "PYTHONUTF8", "PYTHONIOENCODING", "PYTHONDONTWRITEBYTECODE"):
        os.environ.setdefault(key, runtime[key])

    core = root / "core"
    desktop = root / "legacy" / "tk-версия"
    for folder in (str(core), str(desktop)):
        if folder not in sys.path:
            sys.path.insert(0, folder)

    os.environ.setdefault("MEETING_TRANSCRIBER_APP_SUPPORT", str(support))
    os.environ.setdefault("MEETING_TRANSCRIBER_BACKEND", str(core / "meeting_transcriber_v25_1.py"))
    os.environ.setdefault("MEETING_TRANSCRIBER_PROFILES", str(support / "speaker_profiles"))
    os.environ.setdefault("MEETING_TRANSCRIBER_MODELS", str(support / "models"))
    os.environ.setdefault("MEETING_TRANSCRIBER_GLOSSARY", str(support / "glossary.txt"))
    os.environ.setdefault("SLAVATOR_PYTHON", sys.executable)
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    os.environ.setdefault("PYTHONUTF8", "1")
    return root, support


def diagnose() -> int:
    root, support = configure()
    expected = [
        root / "core" / "meeting_transcriber_v25_1.py",
        root / "legacy" / "tk-версия" / "meeting_transcriber_gui_v25_10.py",
    ]
    missing = [str(path) for path in expected if not path.is_file()]
    print(f"project={root}")
    print(f"support={support}")
    print(f"python={sys.executable}")
    if missing:
        print("missing=" + ";".join(missing))
        return 1
    print("status=ok")
    return 0


def main() -> int:
    if "--diagnose" in sys.argv:
        return diagnose()
    root, _support = configure()
    gui = root / "legacy" / "tk-версия" / "meeting_transcriber_gui_v25_10.py"
    if not gui.is_file():
        raise SystemExit(f"Не найден интерфейс: {gui}")
    runpy.run_path(str(gui), run_name="__main__")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
