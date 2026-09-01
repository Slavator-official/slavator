#!/usr/bin/env python3
"""Плавающий виджет быстрой транскрибации.

Небольшая панель поверх всех окон: нажатие начинает запись, повторное
нажатие останавливает её и запускает расшифровку. Результат складывается в
папку, указанную в настройках.

Виджет запускается ОТДЕЛЬНЫМ процессом. Главное окно и виджет - оба на
tkinter, и делить один цикл событий с фоновой записью звука им нельзя:
запись блокировала бы отрисовку, а закрытие главного окна убивало бы виджет
посреди записи.

Запуск:
    python widget.py
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time
import wave
from pathlib import Path

import tkinter as tk

sys.path.insert(0, str(Path(__file__).resolve().parent))

import app_settings
import ui_theme

SAMPLE_RATE = 16000
CHANNELS = 1
WIDTH, HEIGHT = 208, 68

# Закрепление у краёв экрана.
SNAP_THRESHOLD = 56   # с какого расстояния виджет притягивается к краю
EDGE_INSET = 16       # зазор от края в закреплённом положении
MENUBAR_INSET = 40    # чтобы не залезать под строку меню macOS

ANCHORS = (
    "top-left", "top", "top-right",
    "left", "right",
    "bottom-left", "bottom", "bottom-right",
)


class Recorder:
    """Захват звука с устройства ввода.

    sounddevice - основной путь. Если его нет, честно сообщаем об этом, а не
    делаем вид, что запись идёт: молчаливый пустой WAV хуже явной ошибки.
    """

    def __init__(self):
        self.frames: list = []
        self.stream = None
        self.error = ""

    def start(self) -> bool:
        try:
            import sounddevice as sd
        except ImportError:
            self.error = "Не установлен компонент записи звука (sounddevice)."
            return False

        self.frames = []

        def callback(indata, _frames, _time, status):
            if status:
                pass  # переполнение буфера не должно ронять запись
            self.frames.append(bytes(indata))

        try:
            self.stream = sd.RawInputStream(
                samplerate=SAMPLE_RATE, channels=CHANNELS,
                dtype="int16", callback=callback,
            )
            self.stream.start()
        except Exception as exc:  # noqa: BLE001
            self.error = f"Микрофон недоступен: {exc}"
            self.stream = None
            return False
        return True

    def stop(self, target: Path) -> float:
        if self.stream is not None:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:  # noqa: BLE001
                pass
            self.stream = None

        if not self.frames:
            return 0.0

        target.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(target), "wb") as out:
            out.setnchannels(CHANNELS)
            out.setsampwidth(2)
            out.setframerate(SAMPLE_RATE)
            out.writeframes(b"".join(self.frames))
        size = sum(len(chunk) for chunk in self.frames)
        return size / (2 * CHANNELS * SAMPLE_RATE)


class Widget(tk.Tk):
    def __init__(self):
        super().__init__()
        self.settings = app_settings.load()
        self.theme = ui_theme.resolve(self.settings.get("theme", "dark"))
        self.colors = ui_theme.palette(self.theme)

        self.overrideredirect(True)
        self.attributes("-topmost", True)
        try:
            self.attributes("-transparent", True)
        except tk.TclError:
            pass
        self.configure(bg=self.colors["PANEL"])
        self._place()

        self.state = "idle"          # idle | recording | processing | done | error
        self.message = "Записать встречу"
        self.started_at = 0.0
        self.recorder = Recorder()
        self.proc = None
        self.events: queue.Queue = queue.Queue()
        self.drag_from = None

        self.canvas = tk.Canvas(self, width=WIDTH, height=HEIGHT,
                                bg=self.colors["PANEL"], highlightthickness=0, bd=0)
        self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<Button-1>", self._press)
        self.canvas.bind("<B1-Motion>", self._drag)
        self.canvas.bind("<ButtonRelease-1>", self._release)
        self.canvas.bind("<Button-3>", lambda _e: self._quit())

        self.font = ui_theme.resolve_font(set(self.tk.call("font", "families")))
        self.protocol("WM_DELETE_WINDOW", self._quit)
        self.render()
        self.after(200, self._tick)

    # ------------------------------------------------------------------
    # Положение на экране
    # ------------------------------------------------------------------

    def _anchor_slots(self) -> dict:
        """Координаты всех точек закрепления для текущего экрана."""
        sw, sh = self.winfo_screenwidth(), self.winfo_screenheight()
        left, right = EDGE_INSET, sw - WIDTH - EDGE_INSET
        top, bottom = MENUBAR_INSET, sh - HEIGHT - EDGE_INSET
        mid_x, mid_y = (sw - WIDTH) // 2, (sh - HEIGHT) // 2
        return {
            "top-left": (left, top), "top": (mid_x, top), "top-right": (right, top),
            "left": (left, mid_y), "right": (right, mid_y),
            "bottom-left": (left, bottom), "bottom": (mid_x, bottom),
            "bottom-right": (right, bottom),
        }

    def _place(self):
        """Поставить виджет туда, где его оставили.

        Закрепление хранится как имя угла, а не координаты: при смене
        разрешения или отключении внешнего монитора виджет остаётся в том же
        углу, а не уезжает за пределы экрана.
        """
        anchor = self.settings.get("widget_anchor", "top-right")
        if anchor in ANCHORS:
            x, y = self._anchor_slots()[anchor]
        else:
            x = self.settings.get("widget_x")
            y = self.settings.get("widget_y")
            if not isinstance(x, int) or not isinstance(y, int):
                x, y = self._anchor_slots()["top-right"]
        x = max(0, min(int(x), self.winfo_screenwidth() - WIDTH))
        y = max(0, min(int(y), self.winfo_screenheight() - HEIGHT))
        self.geometry(f"{WIDTH}x{HEIGHT}+{x}+{y}")

    def _snap(self, x: int, y: int):
        """Ближайшая точка закрепления, если виджет брошен у края.

        Возвращает (имя, x, y) либо (None, x, y), когда виджет оставлен
        свободно в середине экрана.
        """
        best, best_distance = None, None
        for name, (ax, ay) in self._anchor_slots().items():
            distance = max(abs(x - ax), abs(y - ay))
            if best_distance is None or distance < best_distance:
                best, best_distance = name, distance
        if best_distance is not None and best_distance <= SNAP_THRESHOLD:
            ax, ay = self._anchor_slots()[best]
            return best, ax, ay
        return None, x, y

    def _press(self, event):
        self.drag_from = (event.x_root, event.y_root, self.winfo_x(), self.winfo_y())

    def _drag(self, event):
        if not self.drag_from:
            return
        x0, y0, wx, wy = self.drag_from
        self.geometry(f"+{wx + event.x_root - x0}+{wy + event.y_root - y0}")

    def _release(self, event):
        if not self.drag_from:
            return
        x0, y0, _wx, _wy = self.drag_from
        moved = abs(event.x_root - x0) + abs(event.y_root - y0)
        self.drag_from = None
        if moved > 6:
            anchor, x, y = self._snap(self.winfo_x(), self.winfo_y())
            self.geometry(f"{WIDTH}x{HEIGHT}+{x}+{y}")
            self.settings = app_settings.update(
                widget_anchor=anchor or "free", widget_x=x, widget_y=y
            )
            return
        self._activate()

    # ------------------------------------------------------------------
    # Отрисовка
    # ------------------------------------------------------------------

    def render(self):
        c = self.colors
        self.canvas.delete("all")
        self.canvas.create_rectangle(0, 0, WIDTH, HEIGHT, fill=c["PANEL"], outline="")
        self.canvas.create_rectangle(0, 0, WIDTH - 1, HEIGHT - 1,
                                     outline=c["BORDER"], width=1)

        accent = {
            "idle": c["BLUE"], "recording": "#E5484D",
            "processing": c["BLUE_HOVER"], "done": c["GREEN"], "error": "#E5484D",
        }[self.state]

        cx, cy = 34, HEIGHT / 2
        self.canvas.create_oval(cx - 16, cy - 16, cx + 16, cy + 16, fill=accent, outline="")
        if self.state == "recording":
            self.canvas.create_rectangle(cx - 6, cy - 6, cx + 6, cy + 6,
                                         fill=c["WHITE"], outline="")
        elif self.state == "processing":
            self.canvas.create_arc(cx - 9, cy - 9, cx + 9, cy + 9, start=self._spin(),
                                   extent=110, style="arc", outline=c["WHITE"], width=3)
        elif self.state == "done":
            self.canvas.create_line(cx - 7, cy, cx - 2, cy + 6, cx + 8, cy - 6,
                                    fill=c["WHITE"], width=3)
        else:
            self.canvas.create_oval(cx - 6, cy - 6, cx + 6, cy + 6,
                                    fill=c["WHITE"], outline="")

        self.canvas.create_text(64, cy - 9, text="Славатор", anchor="w",
                                fill=c["MUTED_2"], font=(self.font, 9))
        self.canvas.create_text(64, cy + 8, text=self.message, anchor="w",
                                fill=c["TEXT"], font=(self.font, 11, "bold"))

    def _spin(self) -> int:
        return int((time.time() * 220) % 360)

    # ------------------------------------------------------------------
    # Действия
    # ------------------------------------------------------------------

    def _activate(self):
        if self.state == "idle" or self.state in ("done", "error"):
            self._start_recording()
        elif self.state == "recording":
            self._stop_recording()

    def _start_recording(self):
        if not self.recorder.start():
            self.state = "error"
            self.message = self.recorder.error[:26]
            self.render()
            return
        self.state = "recording"
        self.started_at = time.time()
        self.render()

    def _stop_recording(self):
        folder = Path(str(self.settings.get("widget_output_dir",
                                            Path.home() / "Downloads"))).expanduser()
        stamp = time.strftime("%Y-%m-%d_%H-%M")
        target = folder / f"Встреча {stamp}.wav"

        duration = self.recorder.stop(target)
        if duration < 1.0:
            self.state = "error"
            self.message = "Слишком короткая запись"
            self.render()
            return

        self.state = "processing"
        self.message = "Расшифровываю..."
        self.render()
        threading.Thread(target=self._run_pipeline, args=(target,), daemon=True).start()

    def _run_pipeline(self, wav: Path):
        backend = os.environ.get("MEETING_TRANSCRIBER_BACKEND", "")
        if not backend:
            backend = str(Path(__file__).resolve().parent / "meeting_transcriber_v25_1.py")
        if not Path(backend).is_file():
            self.events.put(("error", "Ядро не найдено"))
            return
        try:
            self.proc = subprocess.Popen(
                [sys.executable, backend, str(wav)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1, cwd=str(Path(backend).parent),
            )
            for line in self.proc.stdout or []:
                line = line.strip()
                if line.startswith("@@PROGRESS@@"):
                    try:
                        payload = json.loads(line[len("@@PROGRESS@@"):])
                        self.events.put(("progress", payload))
                    except json.JSONDecodeError:
                        pass
            code = self.proc.wait()
            self.events.put(("done" if code == 0 else "error",
                             "Готово" if code == 0 else "Ошибка обработки"))
        except Exception as exc:  # noqa: BLE001
            self.events.put(("error", str(exc)[:26]))

    def _tick(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "progress":
                    self.message = f"{value.get('pct', 0):.0f}% · {value.get('stage', '')}"
                elif kind == "done":
                    self.state, self.message = "done", "Готово"
                elif kind == "error":
                    self.state, self.message = "error", str(value)[:26]
        except queue.Empty:
            pass

        if self.state == "recording":
            elapsed = int(time.time() - self.started_at)
            self.message = f"Запись  {elapsed // 60:02d}:{elapsed % 60:02d}"

        if self.state in ("recording", "processing"):
            self.render()
        self.after(200, self._tick)

    def _quit(self):
        if self.state == "recording":
            self.recorder.stop(Path.home() / ".slavator_discard.wav")
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
        self.destroy()


if __name__ == "__main__":
    Widget().mainloop()
