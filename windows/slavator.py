#!/usr/bin/env python3
"""Славатор для Windows: окно с интерфейсом и мост к питоновскому ядру.

Почему так, а не на Tk.
    Интерфейс на маке написан на SwiftUI, и перенести его нельзя: на Windows
    SwiftUI не существует. Прежняя попытка воскресила старый интерфейс на Tk —
    тот самый, от которого ушли в августе, потому что на Tk Canvas нет ни
    теней, ни скруглений, ни нормальной типографики.

    Здесь берётся ровно тот же визуал, что на маке: цвета и шрифты в
    `ui/index.html` перенесены из тех же значений, что в Theme.swift.
    Показывает его движок Edge, встроенный в Windows, — отдельного браузера
    ставить не надо.

Устройство.
    Питон держит состояние и запускает ядро подпроцессом, разбирая его
    строки `@@PROGRESS@@` — ровно как это делает Swift на маке. Интерфейс
    зовёт методы класса Bridge, ответы приходят обычными словарями.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path

APP_NAME = "Славатор"
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
# live_capture и dictation лежат рядом; при запуске по ярлыку текущий каталог
# другой, поэтому путь добавляем явно.
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))


# --------------------------------------------------------------------------
# Пути
# --------------------------------------------------------------------------

def support_dir() -> Path:
    """Где лежит окружение: %APPDATA%\\Славатор на Windows.

    Ветки для мака и Linux нужны не для красоты: без них этот файл нельзя
    ни запустить для проверки на другой машине, ни прогнать в сборке на
    сервере. Пути совпадают с теми, что использует приложение на маке.
    """
    override = os.environ.get("MEETING_TRANSCRIBER_APP_SUPPORT", "").strip()
    if override:
        return Path(override).expanduser()
    if os.name == "nt":
        base = os.environ.get("APPDATA") or os.environ.get("LOCALAPPDATA")
        return (Path(base) if base else Path.home()) / APP_NAME
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_NAME
    return Path.home() / ".local" / "share" / APP_NAME


SUPPORT = support_dir()
SETTINGS_FILE = SUPPORT / "settings.json"
CHATS_FILE = SUPPORT / "chats.json"
CONFIG_FILE = SUPPORT / "config.env"
CORE = ROOT / "core" / "meeting_transcriber_v25_1.py"

STAGES = {
    "prepare": "Подготовка",
    "audio": "Извлечение аудио",
    "asr": "Распознавание речи",
    "quality": "Проверка качества",
    "diarization": "Разделение на спикеров",
    "identify": "Опознание голосов",
    "names": "Определение имён",
    "transcript": "Сборка стенограммы",
    "summary": "Анализ встречи",
    "documents": "Формирование документов",
}

DEFAULTS = {
    "theme": "dark",
    "results_dir": str(Path.home() / "Downloads"),
    "my_name": "Вы",
    "llm_model": "qwen3:8b",
    "dictation_enabled": False,
    # small — текст идёт на ходу; large-v3-turbo точнее, но ждать три секунды.
    "dictation_model": "small",
    "dictation_level": "structure",
}


def venv_path() -> Path:
    """Где должен лежать питон окружения."""
    return (SUPPORT / "env" / "Scripts" / "python.exe" if os.name == "nt"
            else SUPPORT / "env" / "bin" / "python3")


def venv_python() -> Path:
    """Питон из окружения, а не тот, которым запущено окно.

    Окно может подняться на системном питоне, а тяжёлые библиотеки стоят
    только в окружении — путать их нельзя.
    """
    candidate = venv_path()
    return candidate if candidate.exists() else Path(sys.executable)


def read_config() -> dict:
    """KEY=VALUE, который пишет установщик."""
    values: dict[str, str] = {}
    try:
        lines = CONFIG_FILE.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def read_json(path: Path, fallback):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return fallback


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


# --------------------------------------------------------------------------
# Мост между интерфейсом и ядром
# --------------------------------------------------------------------------

class Bridge:
    """Всё, что интерфейс может попросить у питона."""

    def __init__(self) -> None:
        self.window = None
        self.capture = None
        self.dictation = None
        self.task: subprocess.Popen | None = None
        self.stage = ""
        self.percent = 0.0
        self.detail = ""
        self.log: list[str] = []
        self.failure = ""
        self.busy = False

    # ---------- состояние ----------

    def settings(self) -> dict:
        values = dict(DEFAULTS)
        values.update(read_json(SETTINGS_FILE, {}))
        return values

    def save_settings(self, values: dict) -> dict:
        current = self.settings()
        current.update(values or {})
        write_json(SETTINGS_FILE, current)
        return current

    def environment(self) -> dict:
        """Готово ли всё для работы: по этому интерфейс решает, что показать."""
        version_file = ROOT / "VERSION"
        return {
            # Готовность — это наличие окружения, а не отличие от текущего
            # питона: окно вполне может быть запущено этим же питоном, и
            # тогда прежняя проверка врала, что ничего не установлено.
            "ready": venv_path().exists() and CORE.exists(),
            "python": str(venv_python()),
            "core_exists": CORE.exists(),
            "ollama": self._ollama_alive(),
            "version": version_file.read_text(encoding="utf-8").strip()
            if version_file.exists() else "0.0.0",
        }

    def _ollama_alive(self) -> bool:
        try:
            with urllib.request.urlopen(
                    "http://127.0.0.1:11434/api/version", timeout=2):
                return True
        except (urllib.error.URLError, OSError):
            return False

    # ---------- файлы ----------

    def pick_file(self) -> str:
        import webview
        chosen = self.window.create_file_dialog(
            webview.OPEN_DIALOG, allow_multiple=False,
            file_types=("Записи встреч (*.mp4;*.mov;*.mkv;*.webm;*.wav;*.mp3;*.m4a)",
                        "Все файлы (*.*)"))
        return chosen[0] if chosen else ""

    def pick_folder(self) -> str:
        import webview
        chosen = self.window.create_file_dialog(webview.FOLDER_DIALOG)
        return chosen[0] if chosen else ""

    def reveal(self, path: str) -> bool:
        """Открыть файл или папку средствами системы."""
        target = Path(path)
        if not target.exists():
            return False
        try:
            if os.name == "nt":
                os.startfile(str(target))  # noqa: S606 - штатный способ Windows
            else:
                subprocess.run(["open", str(target)], check=False)
            return True
        except OSError:
            return False

    def file_info(self, path: str) -> dict:
        target = Path(path)
        if not target.is_file():
            return {"name": "", "size": ""}
        size = float(target.stat().st_size)
        units = ("Б", "КБ", "МБ", "ГБ")
        index = 0
        while size >= 1024 and index < len(units) - 1:
            size /= 1024
            index += 1
        return {"name": target.name,
                "size": f"{target.suffix.lstrip('.').upper()} · {size:.1f} {units[index]}"}

    # ---------- обработка ----------

    def transcribe(self, path: str, speakers: int = 0) -> dict:
        if self.busy:
            return {"ok": False, "error": "Обработка уже идёт"}
        target = Path(path)
        if not target.is_file():
            return {"ok": False, "error": "Файл не найден"}
        arguments = ["-B", str(CORE), str(target),
                     "--no-summary",
                     "--out-dir", self.settings()["results_dir"]]
        if speakers and int(speakers) > 0:
            arguments += ["--speakers", str(int(speakers))]
        return self._launch(arguments, target.name)

    def summarize(self, folder: str) -> dict:
        if self.busy:
            return {"ok": False, "error": "Обработка уже идёт"}
        return self._launch(["-B", str(CORE), "--summarize", folder], Path(folder).name)

    def cancel(self) -> dict:
        if self.task and self.task.poll() is None:
            self.task.terminate()
        self.busy = False
        self.stage = "Прервано"
        return {"ok": True}

    def progress(self) -> dict:
        """Интерфейс опрашивает это раз в полсекунды."""
        return {"busy": self.busy, "stage": self.stage,
                "percent": round(self.percent, 1), "detail": self.detail,
                "error": self.failure, "log": self.log[-14:]}

    def _launch(self, arguments: list, caption: str) -> dict:
        if not CORE.exists():
            return {"ok": False, "error": f"Не найдено ядро: {CORE}"}

        env = dict(os.environ)
        env.update(read_config())
        env["PYTHONUNBUFFERED"] = "1"
        # Ядро лежит рядом с исходниками, кэш .pyc там не нужен.
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"

        self.busy = True
        self.stage = "Запуск"
        self.percent = 0.0
        self.detail = caption
        self.log = []
        self.failure = ""

        # Иначе на Windows мигает чёрное окно консоли.
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0  # type: ignore[attr-defined]

        try:
            self.task = subprocess.Popen(
                [str(venv_python())] + arguments,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace",
                cwd=str(CORE.parent), env=env, creationflags=flags)
        except OSError as exc:
            self.busy = False
            self.failure = f"Не удалось запустить обработку: {exc}"
            return {"ok": False, "error": self.failure}

        threading.Thread(target=self._read_output, daemon=True).start()
        return {"ok": True}

    def _read_output(self) -> None:
        assert self.task is not None
        for line in self.task.stdout or []:
            line = line.rstrip("\n")
            if line.startswith("@@PROGRESS@@"):
                try:
                    data = json.loads(line[len("@@PROGRESS@@"):])
                except ValueError:
                    continue
                self.percent = float(data.get("pct", self.percent))
                self.stage = STAGES.get(data.get("stage", ""), data.get("stage", ""))
                self.detail = data.get("detail", "") or self.detail
                continue
            self.log.append(line)
            if len(self.log) > 400:
                del self.log[:-400]

        code = self.task.wait()
        self.busy = False
        if code == 0:
            self.percent = 100.0
            self.stage = "Готово"
        else:
            self.stage = "Ошибка"
            meaningful = [x for x in self.log
                          if "ОШИБКА" in x or "Подсказка" in x or x.startswith("  - ")]
            self.failure = "\n".join(meaningful or self.log[-10:]) \
                or "Ядро завершилось с ошибкой"

    # ---------- живая запись ----------

    def capture_start(self, with_system: bool = True) -> dict:
        if self.busy:
            return {"ok": False, "error": "Идёт обработка — сначала дождитесь её"}
        try:
            from live_capture import LiveCapture
        except ImportError as exc:
            return {"ok": False, "error": f"Не загрузился модуль записи: {exc}"}
        if self.capture is None:
            self.capture = LiveCapture()
        return self.capture.start(self.settings()["results_dir"], with_system)

    def capture_stop(self) -> dict:
        if self.capture is None:
            return {"ok": False, "error": "Запись не шла"}
        result = self.capture.stop()
        # Слишком короткую обрабатывать нечего, но и молчать нельзя.
        if result.get("seconds", 0) < 3:
            for key in ("file", "voice"):
                path = result.get(key)
                if path:
                    try:
                        Path(path).unlink(missing_ok=True)
                    except OSError:
                        pass
            return {"ok": False, "error": "Записано меньше трёх секунд"}
        # Живой режим и готовый файл сходятся в один конвейер: разведёшь их —
        # разъедется и качество.
        started = self.transcribe(result.get("file", ""))
        result["started"] = started.get("ok", False)
        return result

    def capture_state(self) -> dict:
        if self.capture is None:
            return {"recording": False, "level": 0, "seconds": 0, "failure": ""}
        return self.capture.state()

    # ---------- диктовка ----------

    def dictation_enable(self) -> dict:
        try:
            from dictation import Dictation
        except ImportError as exc:
            return {"ok": False, "error": f"Не загрузился модуль диктовки: {exc}"}
        env = dict(os.environ)
        env.update(read_config())
        settings = self.settings()
        if self.dictation is None:
            self.dictation = Dictation(
                venv_python(), settings.get("dictation_model", "small"),
                env, settings.get("dictation_level", "structure"))
        return self.dictation.enable()

    def dictation_disable(self) -> dict:
        if self.dictation is None:
            return {"ok": True}
        return self.dictation.disable()

    def dictation_status(self) -> dict:
        if self.dictation is None:
            return {"state": "off", "failure": "", "level": 0, "seconds": 0}
        return self.dictation.status()

    # ---------- записи ----------

    def records(self) -> list:
        root = Path(self.settings()["results_dir"])
        if not root.is_dir():
            return []
        result = []
        folders = sorted(root.glob("*_result"),
                         key=lambda p: p.stat().st_mtime, reverse=True)
        for folder in folders:
            transcript = folder / "transcript.json"
            if not transcript.is_file():
                continue
            data = read_json(transcript, {})
            result.append({
                "dir": str(folder),
                "title": folder.name[: -len("_result")],
                "date": datetime.fromtimestamp(folder.stat().st_mtime)
                        .strftime("%d.%m.%Y %H:%M"),
                "duration": data.get("duration", 0),
                "turns": self._ribbon(folder, data.get("utterances", [])),
                "transcript": str(folder / "01_transcript.docx")
                if (folder / "01_transcript.docx").exists() else "",
                "summary": str(folder / "02_summary_todo.docx")
                if (folder / "02_summary_todo.docx").exists() else "",
            })
        return result

    def _ribbon(self, folder: Path, utterances: list) -> list:
        """Отрезки для голосовой ленты — те же, что рисует мак."""
        extra = folder / "доп файлы, на случай ошибки summary"
        turns = read_json(extra / "diarization.json", [])
        names = read_json(extra / "speaker_names.json", {})
        if not turns:
            turns = [{"start": u.get("start", 0), "end": u.get("end", 0),
                      "speaker": u.get("speaker_id", "")} for u in utterances]
        return [{"start": t.get("start", 0), "end": t.get("end", 0),
                 "speaker": t.get("speaker", ""),
                 "name": names.get(t.get("speaker", ""), "")} for t in turns]

    def speakers(self) -> list:
        profiles = Path.home() / "whisper-work" / "speaker_profiles" / "profiles.json"
        data = read_json(profiles, {})
        people = [{"key": key, "name": value.get("name", key),
                   "position": value.get("position", ""),
                   "company": value.get("company", ""),
                   "samples": value.get("samples", 0)}
                  for key, value in data.items() if isinstance(value, dict)]
        return sorted(people, key=lambda x: x["name"].lower())

    # ---------- чат ----------

    def chats(self) -> list:
        return read_json(CHATS_FILE, [])

    def chat_new(self) -> dict:
        items = self.chats()
        # Пустой черновик не плодим: если верхняя переписка ещё без сообщений,
        # «новая» — это она и есть.
        if items and not items[0].get("messages"):
            return items[0]
        fresh = {"id": str(uuid.uuid4()), "title": "Новый чат",
                 "updated": time.time(), "messages": []}
        items.insert(0, fresh)
        write_json(CHATS_FILE, items)
        return fresh

    def chat_delete(self, chat_id: str) -> list:
        items = [x for x in self.chats() if x.get("id") != chat_id]
        write_json(CHATS_FILE, items)
        return items

    def ask(self, chat_id: str, text: str, thinking: bool = False) -> dict:
        """Один вопрос модели.

        Ответ приходит целиком, без потока: окно всё равно перерисовывается
        по опросу, а поток усложнил бы мост ради незаметной разницы.
        """
        text = (text or "").strip()
        if not text:
            return {"ok": False}

        items = self.chats()
        index = next((i for i, x in enumerate(items) if x.get("id") == chat_id), None)
        if index is None:
            chat_id = self.chat_new()["id"]
            items = self.chats()
            index = 0

        if not items[index]["messages"]:
            flat = " ".join(text.split())
            items[index]["title"] = flat[:41] + "…" if len(flat) > 42 else flat
        items[index]["messages"].append({"role": "user", "text": text})
        write_json(CHATS_FILE, items)

        model = read_config().get("MEETING_TRANSCRIBER_LLM",
                                  self.settings()["llm_model"])
        payload = {
            "model": model,
            "stream": False,
            # Размышления вслух дороже ответа в разы: замер на короткой
            # правке текста — 24,7 с против 2,2 с. Включаются переключателем.
            "think": bool(thinking),
            "keep_alive": "10m",
            "messages": [{"role": "user" if m["role"] == "user" else "assistant",
                          "content": m["text"]} for m in items[index]["messages"]],
        }
        try:
            request = urllib.request.Request(
                "http://127.0.0.1:11434/api/chat",
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=600) as response:
                answer = json.loads(response.read().decode("utf-8"))
            reply = str(answer.get("message", {}).get("content", "")).strip()
        except (urllib.error.URLError, OSError, ValueError, TimeoutError) as exc:
            return {"ok": False, "id": chat_id,
                    "error": f"Модель не ответила: {exc}\n\n"
                             "Ollama запущена? Она отвечает за резюме встреч "
                             "и за этот чат."}

        if reply:
            items[index]["messages"].append({"role": "model", "text": reply})
        items[index]["updated"] = time.time()
        write_json(CHATS_FILE, items)
        return {"ok": True, "id": chat_id, "messages": items[index]["messages"]}


# --------------------------------------------------------------------------

def main() -> int:
    try:
        import webview
    except ImportError:
        sys.stderr.write(
            "Не установлен pywebview. Выполните windows\\install.ps1 заново.\n")
        return 1

    page = HERE / "ui" / "index.html"
    if not page.is_file():
        sys.stderr.write(f"Не найден интерфейс: {page}\n")
        return 1

    SUPPORT.mkdir(parents=True, exist_ok=True)
    bridge = Bridge()
    window = webview.create_window(
        APP_NAME, str(page), js_api=bridge,
        width=1240, height=820, min_size=(1080, 640),
        background_color="#0A1420")
    bridge.window = window
    webview.start()
    return 0


if __name__ == "__main__":
    sys.exit(main())
