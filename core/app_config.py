"""Общие настройки и окружение Python-приложений; без GUI и тяжёлых импортов."""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

APP_NAME = "Славатор"
CONTRACT = json.loads(Path(__file__).with_name("desktop_contract.json").read_text(encoding="utf-8"))


def support_dir() -> Path:
    override = os.environ.get("MEETING_TRANSCRIBER_APP_SUPPORT", "").strip()
    if override:
        return Path(override).expanduser()
    if sys.platform == "win32":
        base = os.environ.get("APPDATA") or os.environ.get("LOCALAPPDATA")
        return (Path(base) if base else Path.home()) / APP_NAME
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_NAME
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / APP_NAME


def default_results_dir() -> Path:
    if sys.platform == "win32":
        return Path(os.environ.get("USERPROFILE") or Path.home()) / "Documents" / APP_NAME
    return Path.home() / "Downloads"


def defaults() -> dict:
    return {**CONTRACT["settings"], "results_dir": str(default_results_dir()),
            "widget_output_dir": str(default_results_dir()), "widget_anchor": "top-right",
            "widget_x": None, "widget_y": None}


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def settings_path() -> Path:
    return support_dir() / "settings.json"


def load() -> dict:
    values = defaults()
    configured_model = read_env(support_dir() / "config.env").get("MEETING_TRANSCRIBER_LLM", "")
    if configured_model.strip():
        values["llm_model"] = configured_model
    configured_asr = read_env(support_dir() / "config.env").get("MEETING_TRANSCRIBER_WHISPER_MODEL", "")
    if configured_asr.strip():
        values["asr_model"] = configured_asr
    for key, value in read_json(settings_path()).items():
        if key not in values or values[key] is None or type(value) is type(values[key]):
            values[key] = value
    if values["theme"] not in ("dark", "light", "system"):
        values["theme"] = defaults()["theme"]
    for key in ("results_dir", "widget_output_dir", "llm_model", "asr_model"):
        if not values[key].strip():
            values[key] = defaults()[key]
    return values


def save(values: dict) -> dict:
    # Не выкидываем поля другого интерфейса или более новой версии.
    merged = {**load(), **values}
    path = settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".settings-", suffix=".json", dir=path.parent)
    tmp = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(merged, handle, ensure_ascii=False, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)
    return merged


def update(**changes) -> dict:
    return save(changes)


def read_env(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except (OSError, UnicodeError):
        return {}
    values = {}
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key:
            values[key] = value
    return values


def environment(settings: dict | None = None) -> dict[str, str]:
    support = support_dir()
    # Существующие Mac-данные остаются на прежнем месте, без миграции биометрии.
    data = Path.home() / "whisper-work" if sys.platform == "darwin" else support
    env = {
        "MEETING_TRANSCRIBER_APP_SUPPORT": str(support),
        "MEETING_TRANSCRIBER_PROFILES": str(data / "speaker_profiles"),
        "MEETING_TRANSCRIBER_MODELS": str(data / "models"),
        "MEETING_TRANSCRIBER_GLOSSARY": str(data / "glossary.txt"),
        "MEETING_TRANSCRIBER_WHISPER_MODEL": CONTRACT["settings"]["asr_model"],
        **read_env(support / "config.env"),
    }
    stored = settings if settings is not None else read_json(settings_path())
    if isinstance(stored.get("llm_model"), str) and stored["llm_model"].strip():
        env["MEETING_TRANSCRIBER_LLM"] = stored["llm_model"]
    if isinstance(stored.get("asr_model"), str) and stored["asr_model"].strip():
        env["MEETING_TRANSCRIBER_WHISPER_MODEL"] = stored["asr_model"]
    env.update(os.environ)
    host = env.get("MEETING_TRANSCRIBER_OLLAMA_HOST") or env.get("MEETING_TRANSCRIBER_OLLAMA")
    if host:
        env["MEETING_TRANSCRIBER_OLLAMA_HOST"] = host.rstrip("/")
        env["MEETING_TRANSCRIBER_OLLAMA"] = host.rstrip("/")
    env.update(PYTHONUNBUFFERED="1", PYTHONDONTWRITEBYTECODE="1", PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
    return env
