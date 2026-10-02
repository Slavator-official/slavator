"""Общие настройки и окружение Python-приложений; без GUI и тяжёлых импортов."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

APP_NAME = "Славатор"
LOCAL_OLLAMA = "http://127.0.0.1:11434"
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


def ollama_host() -> str:
    """Адрес языковой модели. Два имени переменной живут исторически — читаем оба,
    чтобы диктовка и ядро не разошлись, если процесс запущен мимо environment()."""
    host = os.environ.get("MEETING_TRANSCRIBER_OLLAMA_HOST") or os.environ.get("MEETING_TRANSCRIBER_OLLAMA")
    return (host or LOCAL_OLLAMA).rstrip("/")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        # URLError, а не ValueError: все вызывающие уже ловят OSError.
        raise urllib.error.URLError("перенаправление запроса к языковой модели запрещено")


def open_model(request: urllib.request.Request, timeout: float):
    """Открыть запрос к Ollama мимо прокси и без перенаправлений.

    В запросах уходят стенограммы и надиктованный текст. Обычный urlopen берёт
    HTTP_PROXY из окружения и идёт за редиректом — так приватный текст может
    оказаться не там, куда его отправляли.
    """
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    return opener.open(request, timeout=timeout)


def model_json(url: str, payload: dict | None = None, timeout: float = 30) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"},
                                     method="POST" if data else "GET")
    with open_model(request, timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def quiet_onnxruntime() -> None:
    """Выключить телеметрию ONNX Runtime.

    Пакет onnxruntime 1.29 (его тянет детектор речи faster-whisper) шлёт
    телеметрию Microsoft на mobile.events.data.microsoft.com — по умолчанию,
    без спроса. 02.10.2026 ответ на такую отправку пришёл, когда ядро уже
    завершалось, и процесс упал на разрушенном мьютексе: обработка прошла,
    а приложение показало «Обработка не завершилась». Славатор обещает, что
    ничего не уходит с машины, — значит, выключаем до первого сеанса.
    """
    try:
        import onnxruntime
        onnxruntime.disable_telemetry_events()
    except Exception:  # noqa: BLE001 - нет пакета или старая версия: слать нечему
        pass
