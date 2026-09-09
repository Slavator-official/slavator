"""Совместимость Tk/виджета с общим модулем настроек в core/."""
from pathlib import Path
import sys

_core = Path(__file__).resolve().parents[2] / "core"
if str(_core) not in sys.path:
    sys.path.insert(0, str(_core))

from app_config import (  # noqa: E402,F401
    APP_NAME, default_results_dir, defaults, load, save, settings_path, support_dir, update,
)

DEFAULT_RESULTS_DIR = default_results_dir()
DEFAULTS = defaults()
VALID_THEMES = ("dark", "light", "system")
