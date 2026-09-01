"""Пользовательские настройки Славатора.

Отдельный модуль, потому что настройки нужны трём разным процессам: главному
окну, виджету в строке меню и мастеру установки. Формат простой и правится
руками, если приложение вдруг не запускается.
"""
import json
import os
from pathlib import Path

APP_NAME = "Славатор"

DEFAULTS = {
    "theme": "dark",              # dark | light | system
    "language": "ru",
    "results_dir": str(Path.home() / "Downloads"),
    "widget_enabled": False,
    "widget_output_dir": str(Path.home() / "Downloads"),
    "keep_diagnostics": False,
    "widget_anchor": "top-right",  # угол/край экрана или "free"
    "widget_x": None,
    "widget_y": None,
}

VALID_THEMES = ("dark", "light", "system")


def support_dir() -> Path:
    """Каталог приложения. Совпадает с тем, что задаёт launcher бандла."""
    override = os.environ.get("MEETING_TRANSCRIBER_APP_SUPPORT", "").strip()
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / APP_NAME


def settings_path() -> Path:
    return support_dir() / "settings.json"


def load() -> dict:
    """Настройки поверх значений по умолчанию. Битый файл не роняет приложение."""
    values = dict(DEFAULTS)
    path = settings_path()
    if not path.is_file():
        return values
    try:
        with path.open("r", encoding="utf-8") as handle:
            stored = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return values
    if isinstance(stored, dict):
        for key in DEFAULTS:
            if key in stored:
                values[key] = stored[key]
    if values["theme"] not in VALID_THEMES:
        values["theme"] = DEFAULTS["theme"]
    return values


def save(values: dict) -> dict:
    """Записать настройки целиком, атомарно."""
    merged = dict(DEFAULTS)
    merged.update({k: v for k, v in values.items() if k in DEFAULTS})
    path = settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(merged, handle, ensure_ascii=False, indent=2)
    tmp.replace(path)
    return merged


def update(**changes) -> dict:
    """Поменять отдельные значения, не трогая остальные."""
    values = load()
    values.update(changes)
    return save(values)
