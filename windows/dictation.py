#!/usr/bin/env python3
"""Диктовка в любое текстовое поле на Windows.

Устройство то же, что на маке: удержание клавиши включает микрофон,
накопленный звук раз в полторы секунды уходит в постоянный процесс
`core/dictation_worker.py` с загруженной моделью, а устоявшаяся часть
расшифровки печатается синтезированными нажатиями туда, где стоит курсор.

Ключевое правило: **напечатанное не переписывается**. Модель уточняет только
хвост последней фразы; всё, что перед ним, зафиксировано. Иначе пришлось бы
слать Backspace вслепую в чужой редактор — а что человек успел там сделать за
эту секунду, мы не знаем.

Чем отличается от мака.
    Клавиша ловится низкоуровневым хуком клавиатуры, текст печатается через
    SendInput с флагом KEYEVENTF_UNICODE — это ровно то же, что на маке делают
    CGEvent tap и keyboardSetUnicodeString. Прав администратора не нужно.
"""
from __future__ import annotations

import ctypes
import json
import os
import subprocess
import sys
import threading
import time
import wave
from ctypes import wintypes
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
WORKER = ROOT / "core" / "dictation_worker.py"

RATE = 16000
BLOCK = 1600
CHUNK_SECONDS = 1.5          # как часто спрашиваем расшифровку
PAUSE_CLOSES_PHRASE = 1.1    # тишина дольше этого закрывает фразу
SILENCE_LEVEL = 0.015        # ниже этого считаем, что речи нет

VK_RMENU = 0xA5              # правый Alt: в одиночку его почти не жмут
VK_SHIFT = 0x10
WH_KEYBOARD_LL = 13
WM_KEYDOWN, WM_KEYUP = 0x0100, 0x0101
WM_SYSKEYDOWN, WM_SYSKEYUP = 0x0104, 0x0105
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_KEYUP = 0x0002
INPUT_KEYBOARD = 1


# --------------------------------------------------------------------------
# Синтез ввода
# --------------------------------------------------------------------------

class _KeyBdInput(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD),
                ("dwExtraInfo", ctypes.POINTER(wintypes.ULONG))]


class _InputUnion(ctypes.Union):
    _fields_ = [("ki", _KeyBdInput)]


class _Input(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("union", _InputUnion)]


def type_text(text: str) -> None:
    """Напечатать текст туда, где стоит курсор.

    KEYEVENTF_UNICODE шлёт символ как есть, не привязываясь к раскладке, —
    иначе кириллица на английской раскладке превратилась бы в мусор.
    """
    if not text or os.name != "nt":
        return
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    events = []
    for char in text:
        for flags in (KEYEVENTF_UNICODE, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP):
            item = _Input(type=INPUT_KEYBOARD)
            item.union.ki = _KeyBdInput(wVk=0, wScan=ord(char), dwFlags=flags,
                                        time=0, dwExtraInfo=None)
            events.append(item)
    if not events:
        return
    array = (_Input * len(events))(*events)
    user32.SendInput(len(events), ctypes.byref(array), ctypes.sizeof(_Input))


# --------------------------------------------------------------------------
# Постоянный процесс распознавания
# --------------------------------------------------------------------------

class Worker:
    """Модель грузится секунды, поэтому процесс живёт всё время работы."""

    def __init__(self, python: Path, model: str, env: dict):
        self.python = python
        self.model = model
        self.env = env
        self.task: subprocess.Popen | None = None
        self.ready = False
        self.failure = ""
        self._lock = threading.Lock()

    def start(self) -> bool:
        if self.task and self.task.poll() is None:
            return True
        if not WORKER.exists():
            self.failure = f"Не найден {WORKER}"
            return False
        env = dict(self.env)
        env["SLAVATOR_DICTATION_MODEL"] = self.model
        env["PYTHONUNBUFFERED"] = "1"
        # Ядро лежит в установленной папке; кэш .pyc туда писать не надо.
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0  # type: ignore[attr-defined]
        try:
            self.task = subprocess.Popen(
                [str(self.python), "-B", str(WORKER)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True,
                encoding="utf-8", errors="replace",
                cwd=str(WORKER.parent), env=env, creationflags=flags)
        except OSError as exc:
            self.failure = str(exc)
            return False

        line = self.task.stdout.readline() if self.task.stdout else ""
        try:
            answer = json.loads(line or "{}")
        except ValueError:
            answer = {}
        if answer.get("error"):
            self.failure = answer["error"]
            return False
        self.ready = bool(answer.get("ready"))
        return self.ready

    def call(self, command: dict, timeout: float = 120.0) -> dict:
        """Один запрос-ответ. Процесс однопоточный, поэтому под замком."""
        if not self.task or self.task.poll() is not None:
            return {}
        with self._lock:
            try:
                self.task.stdin.write(json.dumps(command, ensure_ascii=False) + "\n")
                self.task.stdin.flush()
                line = self.task.stdout.readline()
            except (OSError, ValueError):
                return {}
        try:
            return json.loads(line or "{}")
        except ValueError:
            return {}

    def stop(self) -> None:
        if self.task and self.task.poll() is None:
            try:
                self.task.stdin.write('{"cmd":"quit"}\n')
                self.task.stdin.flush()
            except (OSError, ValueError):
                pass
            self.task.terminate()
        self.task = None
        self.ready = False


# --------------------------------------------------------------------------
# Диктовка целиком
# --------------------------------------------------------------------------

class Dictation:
    """Держите правый Alt — текст появляется там, где курсор."""

    def __init__(self, python: Path, model: str, env: dict, level: str = "structure"):
        self.worker = Worker(python, model, env)
        self.level = level
        self.state = "off"       # off | starting | idle | listening | finishing | failed
        self.failure = ""
        self.typed = ""
        self.spoken = ""
        self.level_meter = 0.0
        self.seconds = 0.0
        self.tidy = False        # держали ли Shift: причесать перед вставкой

        self._hook = None
        self._hook_thread: threading.Thread | None = None
        self._audio_thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._samples: list = []
        self._samples_lock = threading.Lock()
        self._last_loud = 0.0
        self._heard = False
        self._last_text = ""
        self._down = False

    # ---------- жизненный цикл ----------

    def enable(self) -> dict:
        if os.name != "nt":
            return {"ok": False, "error": "Диктовка работает только на Windows"}
        self.state = "starting"
        if not self.worker.start():
            self.state = "failed"
            self.failure = self.worker.failure or "Не удалось поднять распознавание"
            return {"ok": False, "error": self.failure}
        if not self._install_hook():
            self.state = "failed"
            self.failure = "Не удалось перехватить клавишу"
            return {"ok": False, "error": self.failure}
        self.state = "idle"
        return {"ok": True}

    def disable(self) -> dict:
        self._stop.set()
        self.worker.stop()
        self._uninstall_hook()
        self.state = "off"
        return {"ok": True}

    def status(self) -> dict:
        return {"state": self.state, "failure": self.failure,
                "level": round(self.level_meter, 3),
                "seconds": round(self.seconds, 1),
                "typed": self.typed}

    # ---------- клавиша ----------

    def _install_hook(self) -> bool:
        user32 = ctypes.WinDLL("user32", use_last_error=True)
        proto = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_int,
                                   wintypes.WPARAM, wintypes.LPARAM)

        def handler(code, wparam, lparam):
            if code == 0:
                key = ctypes.cast(
                    lparam, ctypes.POINTER(wintypes.DWORD)).contents.value
                if key == VK_RMENU:
                    down = wparam in (WM_KEYDOWN, WM_SYSKEYDOWN)
                    if down != self._down:
                        self._down = down
                        shift = bool(user32.GetAsyncKeyState(VK_SHIFT) & 0x8000)
                        threading.Thread(
                            target=self._begin if down else self._end,
                            args=(shift,) if down else (),
                            daemon=True).start()
            return user32.CallNextHookEx(None, code, wparam, lparam)

        self._callback = proto(handler)   # ссылку держим: иначе соберёт мусорщик

        def pump() -> None:
            self._hook = user32.SetWindowsHookExW(
                WH_KEYBOARD_LL, self._callback, None, 0)
            message = wintypes.MSG()
            # Хук живёт только вместе с очередью сообщений своего потока.
            while not self._stop.is_set() and user32.GetMessageW(
                    ctypes.byref(message), None, 0, 0) > 0:
                user32.TranslateMessage(ctypes.byref(message))
                user32.DispatchMessageW(ctypes.byref(message))

        self._stop.clear()
        self._hook_thread = threading.Thread(target=pump, daemon=True)
        self._hook_thread.start()
        time.sleep(0.3)
        return self._hook is not None

    def _uninstall_hook(self) -> None:
        if self._hook:
            ctypes.WinDLL("user32").UnhookWindowsHookEx(self._hook)
        self._hook = None

    # ---------- сама диктовка ----------

    def _begin(self, shift: bool) -> None:
        if self.state != "idle":
            return
        self.tidy = shift
        self.typed = self.spoken = self._last_text = ""
        self.seconds = 0.0
        self._heard = False
        with self._samples_lock:
            self._samples = []
        self.state = "listening"
        self._stop_audio = threading.Event()
        self._audio_thread = threading.Thread(target=self._record, daemon=True)
        self._audio_thread.start()
        # Сырой режим печатает на ходу; режим обработки молчит до конца —
        # причесать уже напечатанное нельзя, не стирая его.
        if not self.tidy:
            threading.Thread(target=self._poll_loop, daemon=True).start()

    def _record(self) -> None:
        try:
            import numpy as np
            import soundcard as sc
        except ImportError as exc:
            self.failure = f"Нет библиотеки записи: {exc}"
            self.state = "failed"
            return
        started = time.perf_counter()
        try:
            with sc.default_microphone().recorder(
                    samplerate=RATE, channels=1, blocksize=BLOCK) as source:
                while not self._stop_audio.is_set():
                    block = source.record(numframes=BLOCK)
                    mono = block[:, 0] if block.ndim > 1 else block
                    peak = float(abs(mono).max())
                    self.level_meter = min(1.0, peak)
                    self.seconds = time.perf_counter() - started
                    if peak > SILENCE_LEVEL:
                        self._last_loud = time.perf_counter()
                        self._heard = True
                    ints = np.clip(mono * 32767, -32768, 32767).astype(np.int16)
                    with self._samples_lock:
                        self._samples.append(ints)
        except Exception as exc:  # noqa: BLE001
            self.failure = str(exc)
            self.state = "failed"

    def _snapshot(self) -> Path | None:
        """Всё, что записано на этот миг, одним WAV."""
        import numpy as np
        with self._samples_lock:
            if not self._samples:
                return None
            data = np.concatenate(self._samples)
        if len(data) < RATE // 10:
            return None
        path = Path(os.environ.get("TEMP", ".")) / "slavator-dictation.wav"
        with wave.open(str(path), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(RATE)
            out.writeframes(data.tobytes())
        return path

    def _poll_loop(self) -> None:
        while self.state == "listening":
            time.sleep(CHUNK_SECONDS)
            if self.state != "listening":
                break
            self._poll(final=False)

    def _poll(self, final: bool) -> None:
        # Тишину не распознаём: на пустом звуке Whisper уверенно печатает
        # титры фильмов, которых никто не произносил.
        if not self._heard:
            return
        wav = self._snapshot()
        if wav is None:
            return
        answer = self.worker.call({"cmd": "transcribe", "path": str(wav)})
        text = (answer.get("text") or "").strip()
        if not text:
            return

        if final:
            self._commit(text)
            return

        # Пауза закрывает фразу: дописываем её целиком и начинаем запись
        # заново. Это чинит и рост задержки, и накопление правок в начале.
        if time.perf_counter() - self._last_loud > PAUSE_CLOSES_PHRASE:
            self._commit(text + " ")
            self.spoken += text + " "
            with self._samples_lock:
                self._samples = []
            self._heard = False
            self.typed = self._last_text = ""
        else:
            self._commit(self._stable(self._last_text, text))
            self._last_text = text

    @staticmethod
    def _stable(previous: str, current: str) -> str:
        """Общее начало двух расшифровок, обрезанное по границе слова."""
        if not previous:
            return ""
        limit = 0
        for a, b in zip(previous, current):
            if a != b:
                break
            limit += 1
        head = previous[:limit]
        if limit < len(current) and " " in head:
            head = head[: head.rfind(" ") + 1]
        return head

    def _commit(self, target: str) -> None:
        """Допечатать то, чего ещё нет в поле.

        Сравнения «начинается ровно с напечатанного» здесь быть не должно:
        получив продолжение фразы, модель правит знаки в её начале, совпадение
        ломается — и на маке диктовка из-за этого замолкала навсегда.
        """
        if self.tidy or len(target) <= len(self.typed):
            return
        type_text(target[len(self.typed):])
        self.typed = target

    def _end(self) -> None:
        if self.state != "listening":
            return
        self.state = "finishing"
        self._stop_audio.set()
        if self._audio_thread:
            self._audio_thread.join(timeout=3)
        self._poll(final=True)

        if self.tidy:
            raw = (self.spoken + self.typed).strip() or self._last_text
            if raw:
                answer = self.worker.call(
                    {"cmd": "tidy", "text": raw, "level": self.level}, timeout=60)
                type_text(answer.get("text") or raw)
        self.level_meter = 0.0
        self.state = "idle" if self.state == "finishing" else self.state


if __name__ == "__main__":  # pragma: no cover - ручная проверка
    print(json.dumps({"windows": os.name == "nt",
                      "worker": WORKER.exists()}, ensure_ascii=False))
