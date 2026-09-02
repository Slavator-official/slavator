#!/usr/bin/env python3
"""Запись живой встречи на Windows: звук компьютера и микрофон.

Что здесь происходит.
    Собеседников слышно только через динамики, а вас — только через микрофон.
    Поэтому пишутся две дорожки, и сводить их нельзя: в сумме собеседник
    попадёт в запись дважды — из динамиков и повторно через микрофон, — и
    распознавание на такой каше разваливается. Ядро разбирает дорожки по
    отдельности и склеивает стенограммы по времени.

Чем берётся звук компьютера.
    Петлёй WASAPI: Windows позволяет слушать то, что уходит в динамики, как
    обычный вход. Виртуальные устройства вроде VB-Cable ставить не надо.
    На маке ту же задачу решают Core Audio process taps.

Про общее время.
    Дорожки заводятся не одновременно, а файл начинается с первого пришедшего
    кадра. Без общей точки отсчёта нулевая секунда у двух файлов означала бы
    разные моменты: на маке из-за этого реплики вставали не в том порядке,
    пока не выровняли. Здесь та же защита — у каждой дорожки считается,
    сколько кадров она должна была записать к этому мигу, и недостача
    добивается тишиной.
"""
from __future__ import annotations

import threading
import time
import wave
from pathlib import Path

RATE = 16000
BLOCK = 1600          # 0,1 с: задержка выравнивания не превышает одного блока


class CaptureError(RuntimeError):
    """Понятная человеку причина, почему запись не пошла."""


def _soundcard():
    try:
        import soundcard
    except ImportError as exc:  # pragma: no cover - зависит от установки
        raise CaptureError(
            "Не установлена библиотека soundcard. "
            "Выполните windows\\install.ps1 заново."
        ) from exc
    return soundcard


class Track:
    """Одна дорожка: пишет в WAV и сама держится реального времени."""

    def __init__(self, path: Path, origin: float):
        self.path = path
        self.origin = origin
        self.written = 0
        path.parent.mkdir(parents=True, exist_ok=True)
        self.file = wave.open(str(path), "wb")
        self.file.setnchannels(1)
        self.file.setsampwidth(2)
        self.file.setframerate(RATE)
        self.lock = threading.Lock()

    def write(self, samples) -> None:
        """Дописать кадры, добив тишиной отставание от часов."""
        import numpy as np

        with self.lock:
            elapsed = time.perf_counter() - self.origin
            expected = int(elapsed * RATE)
            behind = expected - self.written - len(samples)
            # Порог в 20 мс — чтобы не реагировать на обычное дрожание.
            # Верхняя граница защищает от дикого скачка часов.
            if behind > RATE // 50:
                silence = np.zeros(min(behind, RATE * 300), dtype=np.int16)
                self.file.writeframes(silence.tobytes())
                self.written += len(silence)
            self.file.writeframes(samples.tobytes())
            self.written += len(samples)

    def close(self) -> None:
        with self.lock:
            try:
                self.file.close()
            except Exception:  # noqa: BLE001 - закрыть надо в любом случае
                pass

    @property
    def seconds(self) -> float:
        return self.written / RATE


class LiveCapture:
    """Две дорожки: звук компьютера и микрофон."""

    def __init__(self) -> None:
        self.system: Track | None = None
        self.mic: Track | None = None
        self.recording = False
        self.level = 0.0
        self.failure = ""
        self._threads: list[threading.Thread] = []
        self._stop = threading.Event()

    # ---------- запуск ----------

    def start(self, folder: str, with_system: bool = True) -> dict:
        if self.recording:
            return {"ok": False, "error": "Запись уже идёт"}
        try:
            sc = _soundcard()
            import numpy  # noqa: F401 - нужен внутри дорожек
        except CaptureError as exc:
            return {"ok": False, "error": str(exc)}

        try:
            mic_device = sc.default_microphone()
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": f"Микрофон недоступен: {exc}"}

        loop_device = None
        if with_system:
            try:
                speaker = sc.default_speaker()
                loop_device = sc.get_microphone(str(speaker.name), include_loopback=True)
            except Exception as exc:  # noqa: BLE001
                return {"ok": False,
                        "error": f"Не удалось слушать звук компьютера: {exc}"}

        base = Path(folder)
        stem = "Встреча " + time.strftime("%Y-%m-%d_%H-%M")
        self.failure = ""
        self._stop.clear()
        self._threads = []
        origin = time.perf_counter()

        # Основной файл — звук компьютера: в нём собеседники, то есть большая
        # часть встречи. Микрофон идёт отдельной дорожкой рядом.
        if with_system:
            self.system = Track(base / f"{stem}.wav", origin)
            self.mic = Track(base / f"{stem} — мой голос.wav", origin)
        else:
            self.system = None
            self.mic = Track(base / f"{stem}.wav", origin)

        self.recording = True
        if loop_device is not None:
            self._threads.append(self._pump(loop_device, self.system, meter=False))
        self._threads.append(self._pump(mic_device, self.mic, meter=True))
        return {"ok": True, "file": str((self.system or self.mic).path)}

    def _pump(self, device, track: Track, meter: bool) -> threading.Thread:
        def loop() -> None:
            import numpy as np
            try:
                with device.recorder(samplerate=RATE, channels=1,
                                     blocksize=BLOCK) as source:
                    while not self._stop.is_set():
                        block = source.record(numframes=BLOCK)
                        mono = block[:, 0] if block.ndim > 1 else block
                        ints = np.clip(mono * 32767, -32768, 32767).astype(np.int16)
                        track.write(ints)
                        if meter:
                            self.level = float(min(1.0, abs(mono).max()))
            except Exception as exc:  # noqa: BLE001 - показываем причину человеку
                self.failure = str(exc)
                self._stop.set()

        thread = threading.Thread(target=loop, daemon=True)
        thread.start()
        return thread

    # ---------- остановка ----------

    def stop(self) -> dict:
        self._stop.set()
        for thread in self._threads:
            thread.join(timeout=3)
        self._threads = []
        self.recording = False
        self.level = 0.0

        system, mic = self.system, self.mic
        for track in (system, mic):
            if track:
                track.close()
        self.system = self.mic = None

        result = {"ok": True, "failure": self.failure,
                  "seconds": round((system or mic).seconds if (system or mic) else 0, 1)}

        # Если петля промолчала, отдавать её в обработку нельзя: получится
        # «в файле нет звука». Тогда основным становится микрофон — он
        # записал хотя бы вашу половину встречи.
        if system and system.seconds < 1.0:
            try:
                system.path.unlink(missing_ok=True)
            except OSError:
                pass
            result["file"] = str(mic.path) if mic else ""
            result["voice"] = ""
            result["failure"] = self.failure or (
                "Звук компьютера не записался: система не отдала ни одного кадра. "
                "Сохранена запись с микрофона.")
        elif system:
            result["file"] = str(system.path)
            result["voice"] = str(mic.path) if mic else ""
        else:
            result["file"] = str(mic.path) if mic else ""
            result["voice"] = ""
        return result

    def state(self) -> dict:
        current = self.system or self.mic
        return {"recording": self.recording,
                "level": round(self.level, 3),
                "seconds": round(current.seconds if current else 0, 1),
                "failure": self.failure}


def devices() -> dict:
    """Что система вообще может слушать. Нужно для проверки на сборке."""
    try:
        sc = _soundcard()
    except CaptureError as exc:
        return {"ok": False, "error": str(exc)}
    try:
        speakers = [str(x.name) for x in sc.all_speakers()]
        mics = [str(x.name) for x in sc.all_microphones()]
        with_loop = [str(x.name) for x in sc.all_microphones(include_loopback=True)]
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}
    return {"ok": True, "speakers": speakers, "microphones": mics,
            "loopback": [x for x in with_loop if x not in mics]}


if __name__ == "__main__":  # pragma: no cover - ручная проверка
    import json
    print(json.dumps(devices(), ensure_ascii=False, indent=2))
