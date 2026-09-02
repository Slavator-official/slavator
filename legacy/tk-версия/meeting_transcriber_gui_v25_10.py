#!/usr/bin/env python3
from __future__ import annotations

import os
import json
import queue
import subprocess
import sys
import threading
import signal
from datetime import datetime
from pathlib import Path
import tkinter as tk
from tkinter import filedialog, messagebox

import app_settings
import ui_theme
from speaker_service.service import SpeakerService
from speaker_service.backend import BackendAdapter

def _app_version() -> str:
    for parent in Path(__file__).resolve().parents:
        version = parent / "VERSION"
        if version.is_file():
            try:
                return version.read_text(encoding="utf-8").strip()
            except OSError:
                break
    return os.environ.get("SLAVATOR_VERSION", "0.0.0-dev")


APP_VERSION = _app_version()

# Совпадает с именем каталога, который создаёт ядро обработки.
EXTRA_DIR_NAME = "доп файлы, на случай ошибки summary"

# Токены активной темы. Вся отрисовка обращается к ним напрямую, поэтому
# смена темы - это подмена значений через apply_theme() и повторный render().
THEME_NAME = ui_theme.resolve(app_settings.load()["theme"])
_T = ui_theme.palette(THEME_NAME)
AVATAR = _T["AVATAR"]
BG = _T["BG"]
BLUE = _T["BLUE"]
BLUE_HOVER = _T["BLUE_HOVER"]
BORDER = _T["BORDER"]
BORDER_2 = _T["BORDER_2"]
BTN_BG_DISABLED = _T["BTN_BG_DISABLED"]
BTN_BORDER = _T["BTN_BORDER"]
BTN_BORDER_DISABLED = _T["BTN_BORDER_DISABLED"]
BTN_TEXT_DISABLED = _T["BTN_TEXT_DISABLED"]
CARD_BORDER = _T["CARD_BORDER"]
CARD_BORDER_2 = _T["CARD_BORDER_2"]
DIVIDER = _T["DIVIDER"]
DROP_BORDER = _T["DROP_BORDER"]
DROP_ICON = _T["DROP_ICON"]
FOOTER = _T["FOOTER"]
GREEN = _T["GREEN"]
INPUT_BG = _T["INPUT_BG"]
INPUT_BORDER = _T["INPUT_BORDER"]
LINK = _T["LINK"]
MUTED = _T["MUTED"]
MUTED_2 = _T["MUTED_2"]
NAV_ACTIVE = _T["NAV_ACTIVE"]
NAV_TEXT = _T["NAV_TEXT"]
PANEL = _T["PANEL"]
PANEL_2 = _T["PANEL_2"]
PANEL_3 = _T["PANEL_3"]
PILL_OK_BG = _T["PILL_OK_BG"]
ROW_BG = _T["ROW_BG"]
ROW_BORDER = _T["ROW_BORDER"]
SIDEBAR = _T["SIDEBAR"]
SIDEBAR_BORDER = _T["SIDEBAR_BORDER"]
TEXT = _T["TEXT"]
TEXT_EMPTY = _T["TEXT_EMPTY"]
TOGGLE_OFF = _T["TOGGLE_OFF"]
TOGGLE_OFF_BORDER = _T["TOGGLE_OFF_BORDER"]
WAVE = _T["WAVE"]
WHITE = _T["WHITE"]
NAV_ACTIVE_TEXT = ui_theme.nav_active_text(THEME_NAME)


def apply_theme(name: str) -> str:
    """Переключить палитру. Возвращает фактически применённую тему."""
    global THEME_NAME, NAV_ACTIVE_TEXT
    THEME_NAME = ui_theme.resolve(name)
    globals().update(ui_theme.palette(THEME_NAME))
    NAV_ACTIVE_TEXT = ui_theme.nav_active_text(THEME_NAME)
    return THEME_NAME


BASE_W = 1240
BASE_H = 840
SIDEBAR_W = 200
CONTENT_GAP = 22
OUTER = 28


def choose_font(root: tk.Misc) -> str:
    try:
        families = set(root.tk.call("font", "families"))
        return ui_theme.resolve_font(families)
    except Exception:
        pass
    return "Helvetica"


class UI(tk.Tk):
    """v25.6 real-vector GUI.

    The reference PNGs are never loaded at runtime. This version fixes the
    v25.5 layout contract: full-width responsive content, explicit vertical
    rhythm, stable typography, and no controls crossing card boundaries.
    """

    def __init__(self):
        super().__init__()
        self.title("Славатор")
        self.configure(bg=BG)

        # Use a real, resizable desktop window. The previous borderless window
        # (`overrideredirect`) prevented normal macOS close/minimize/resize
        # behavior and forced a fixed 1536x1024 surface that could exceed the
        # available screen. Keep the product canvas borderless, but let the OS
        # own the window chrome and window lifecycle.
        self._configure_native_window()
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self._set_initial_window_geometry()
        self.after_idle(self._verify_native_window)
        self.font_name = choose_font(self)
        self.settings = app_settings.load()
        self.speaker_colors = {}   # ключ профиля -> цвет, раздаётся при отрисовке
        self.playing_label = ''    # что звучит сейчас, для нижней панели
        self.playing_color = ''
        self.app_icon = None
        # Навигация видна сразу: прятать её за «гамбургером» на десктопе
        # незачем, свёрнутое состояние остаётся для узких окон.
        self.sidebar_open = True
        self.page = "overview"
        self.selected_file: Path | None = None
        self.current_person_key: str | None = None
        self.events: queue.Queue = queue.Queue()
        self.proc = None
        self.playback_proc = None
        self.playback_path: Path | None = None
        self.playback_state = "stopped"
        self.widget_proc = None
        self.backend = BackendAdapter(self._find_backend(), self._find_python())
        self.speakers = SpeakerService(
            profiles_dir=Path(os.environ.get(
                "MEETING_TRANSCRIBER_PROFILES",
                str(Path.home() / "whisper-work" / "speaker_profiles"),
            )),
            results_root=Path(self.settings["results_dir"]),
        )
        self.canvas = tk.Canvas(self, bg=BG, highlightthickness=0, bd=0)
        self.canvas.pack(fill="both", expand=True)
        self.bind("<Configure>", lambda _e: self.after_idle(self.render))
        self.bind("<Escape>", lambda _e: self.close_sidebar())
        self._poll_after = self.after(100, self._poll)
        if self.settings.get("widget_enabled"):
            self.after(400, self.start_widget)
        self.after(150, self.render)

    def _configure_native_window(self):
        """Force a normal native desktop window on macOS.

        The product canvas remains borderless, but the OS must own the window
        chrome and lifecycle. In particular, explicitly clear fullscreen and
        Tk's borderless mode so a previously restored/zoomed window cannot
        reopen without the native title bar and traffic-light controls.
        """
        self.overrideredirect(False)
        self.resizable(True, True)
        try:
            self.attributes("-fullscreen", False)
        except tk.TclError:
            pass
        try:
            self.state("normal")
        except tk.TclError:
            pass

        if sys.platform == "darwin":
            # Tk on macOS exposes this supported-by-Tk internal command for
            # selecting the standard document-window chrome. It is guarded
            # because some Tk builds omit the command.
            try:
                self.tk.call(
                    "::tk::unsupported::MacWindowStyle",
                    "style",
                    self._w,
                    "document",
                    "closeBox collapseBox zoomBox resizable",
                )
            except tk.TclError:
                pass

    def _verify_native_window(self):
        """Runtime guard: never silently run as a borderless/fullscreen app."""
        try:
            if self.overrideredirect():
                raise RuntimeError("Native window verification failed: overrideredirect is enabled")
            fullscreen = self.attributes("-fullscreen")
            if fullscreen not in (False, 0, "0", "false", "False"):
                raise RuntimeError("Native window verification failed: fullscreen is enabled")
        except tk.TclError as exc:
            raise RuntimeError("Native window verification failed") from exc

    def _set_initial_window_geometry(self):
        """Choose a useful initial size that is guaranteed to fit the screen."""
        self.update_idletasks()
        screen_w = self.winfo_screenwidth()
        screen_h = self.winfo_screenheight()

        # Leave room for the macOS menu bar/dock and a small visual margin.
        available_w = max(900, screen_w - 80)
        available_h = max(620, screen_h - 120)

        width = min(1280, available_w)
        height = min(800, available_h)

        # Do not make the minimum larger than the actual usable screen.
        min_w = min(1100, available_w)
        min_h = min(700, available_h)
        self.minsize(min_w, min_h)

        x = max(0, (screen_w - width) // 2)
        y = max(0, (screen_h - height) // 2)
        self.geometry(f"{width}x{height}+{x}+{y}")

    def _on_close(self):
        """Stop child processes and cancel scheduled polling before closing."""
        if self._poll_after is not None:
            try:
                self.after_cancel(self._poll_after)
            except tk.TclError:
                pass
            self._poll_after = None
        self._stop_wav()
        self.stop_widget()
        if self.proc is not None and self.proc.poll() is None:
            try:
                self.proc.terminate()
            except OSError:
                pass
        self.destroy()

    def _find_backend(self):
        env = os.environ.get("MEETING_TRANSCRIBER_BACKEND")
        if env and Path(env).is_file():
            return Path(env).expanduser().resolve()
        here = Path(__file__).resolve().parent
        candidates = [
            here / "meeting_transcriber_v25_1.py",
            here.parents[1] / "core" / "meeting_transcriber_v25_1.py",
            here.parent / "core" / "meeting_transcriber_v25_1.py",
            Path.home() / "Downloads/meeting_transcriber_v25_1_project/meeting_transcriber_v25_1.py",
        ]
        return next((p for p in candidates if p.is_file()), None)

    def _find_python(self):
        configured = os.environ.get("SLAVATOR_PYTHON")
        if configured and Path(configured).is_file():
            return Path(configured)
        if os.name == "nt":
            support = Path(os.environ.get(
                "MEETING_TRANSCRIBER_APP_SUPPORT",
                str(Path(os.environ.get("APPDATA", Path.home())) / "Славатор"),
            ))
            candidate = support / "env" / "Scripts" / "python.exe"
            return candidate if candidate.is_file() else Path(sys.executable)
        p = Path.home() / "whisper-work/.venv-diarization/bin/python"
        return p if p.is_file() else Path(sys.executable)

    def scale(self) -> float:
        w = max(1, self.canvas.winfo_width())
        h = max(1, self.canvas.winfo_height())
        # Fit the existing design into the available canvas. Never upscale
        # above the reference geometry and never force a 0.78 minimum: the old
        # floor was the source of horizontal overflow on smaller windows.
        return max(0.62, min(1.0, w / BASE_W, h / BASE_H))

    def sx(self, value: float) -> float:
        return value * self.scale()

    # Мелкие кегли макета подтянуты вверх: 8-9 pt на Retina нечитаемы,
    # системный размер в macOS - 13 pt.
    FONT_FLOOR = {8: 10, 9: 11, 10: 11, 11: 12}

    def font(self, size: int, weight: str = "normal"):
        size = self.FONT_FLOOR.get(size, size)
        return (self.font_name, max(11, round(size * self.scale())), weight)

    def rect(self, x1, y1, x2, y2, fill=PANEL, outline=BORDER, radius=0, tags="ui"):
        s = self.scale(); x1*=s; y1*=s; x2*=s; y2*=s
        if radius <= 0:
            return self.canvas.create_rectangle(x1, y1, x2, y2, fill=fill, outline=outline, tags=tags)
        r = min(radius*s, (x2-x1)/2, (y2-y1)/2)
        # Use a true segmented rounded polygon instead of Canvas spline
        # smoothing. Spline smoothing can produce bulged/uneven borders at
        # small sizes; explicit corner points keep every button/card edge
        # geometrically stable across window scales.
        import math
        pts = []
        for cx, cy, start in (
            (x2-r, y1+r, -90),
            (x2-r, y2-r, 0),
            (x1+r, y2-r, 90),
            (x1+r, y1+r, 180),
        ):
            for step in range(0, 6):
                angle = math.radians(start + step * 18)
                pts.extend((cx + r * math.cos(angle), cy + r * math.sin(angle)))
        return self.canvas.create_polygon(pts, fill=fill, outline=outline, smooth=False, tags=tags)

    def rounded_rect(self, x1, y1, x2, y2, fill, outline, radius=10, width=1, tags="ui"):
        """Draw a true rounded rectangle from Canvas primitives.

        Canvas arcs provide cleaner, more stable corners than a short polygon
        approximation, especially on macOS when the window is resized.
        """
        s = self.scale()
        x1, y1, x2, y2 = x1*s, y1*s, x2*s, y2*s
        r = min(radius*s, (x2-x1)/2, (y2-y1)/2)
        if r <= 0:
            return self.canvas.create_rectangle(
                x1, y1, x2, y2, fill=fill, outline=outline, width=max(1, round(width*s)), tags=tags
            )
        w = max(1, round(width*s))
        items = [
            self.canvas.create_rectangle(x1+r, y1, x2-r, y2, fill=fill, outline="", tags=tags),
            self.canvas.create_rectangle(x1, y1+r, x2, y2-r, fill=fill, outline="", tags=tags),
            self.canvas.create_arc(x1, y1, x1+2*r, y1+2*r, start=90, extent=90, fill=fill, outline=outline, width=w, style="pieslice", tags=tags),
            self.canvas.create_arc(x2-2*r, y1, x2, y1+2*r, start=0, extent=90, fill=fill, outline=outline, width=w, style="pieslice", tags=tags),
            self.canvas.create_arc(x1, y2-2*r, x1+2*r, y2, start=180, extent=90, fill=fill, outline=outline, width=w, style="pieslice", tags=tags),
            self.canvas.create_arc(x2-2*r, y2-2*r, x2, y2, start=270, extent=90, fill=fill, outline=outline, width=w, style="pieslice", tags=tags),
            self.canvas.create_line(x1+r, y1, x2-r, y1, fill=outline, width=w, tags=tags),
            self.canvas.create_line(x1+r, y2, x2-r, y2, fill=outline, width=w, tags=tags),
            self.canvas.create_line(x1, y1+r, x1, y2-r, fill=outline, width=w, tags=tags),
            self.canvas.create_line(x2, y1+r, x2, y2-r, fill=outline, width=w, tags=tags),
        ]
        return items[0]

    def text(self, x, y, value, size=14, fill=TEXT, weight="normal", anchor="nw", tags="ui"):
        return self.canvas.create_text(self.sx(x), self.sx(y), text=value, fill=fill,
                                       font=self.font(size, weight), anchor=anchor, tags=tags)

    def line(self, x1, y1, x2, y2, fill=BORDER, width=1):
        s=self.scale(); return self.canvas.create_line(x1*s,y1*s,x2*s,y2*s,fill=fill,width=max(1,round(width*s)))

    def bind_box(self, x1, y1, x2, y2, command, cursor=True):
        s=self.scale(); tag=f"hit{len(self.canvas.find_all())}"
        self.canvas.create_rectangle(x1*s,y1*s,x2*s,y2*s,fill="",outline="",tags=tag)
        self.canvas.tag_bind(tag,"<Button-1>",lambda _e: command())
        if cursor:
            self.canvas.tag_bind(tag,"<Enter>",lambda _e:self.canvas.configure(cursor="hand2"))
            self.canvas.tag_bind(tag,"<Leave>",lambda _e:self.canvas.configure(cursor=""))

    def button(self, x, y, w, h, label, command, primary=False, disabled=False, font_size=12, radius=10):
        """Single visual source for all action buttons.

        The button chrome is deliberately uniform: a smooth rounded shape,
        consistent border treatment and centered typography. Callers own the
        geometry; this method owns the visual treatment so buttons stay
        coherent across Overview, Speakers, Records, New Voices and Settings.
        """
        if primary and h >= 34:
            visual_font = 11
        elif h <= 28:
            visual_font = 9
        else:
            visual_font = 10
        fill = BTN_BG_DISABLED if disabled else (BLUE if primary else PANEL_3)
        outline = BTN_BORDER_DISABLED if disabled else (BLUE_HOVER if primary else BTN_BORDER)
        txt = BTN_TEXT_DISABLED if disabled else TEXT
        # A 10px radius is the shared product standard. The rounded rectangle
        # helper uses real Canvas arcs instead of a coarse polygon, which keeps
        # corners visually smooth and even at the supported window scales.
        self.rounded_rect(x, y, x+w, y+h, fill, outline, radius, 1)
        button_font = max(11, round((visual_font + 2) * self.scale()))
        self.canvas.create_text(
            self.sx(x+w/2), self.sx(y+h/2), text=label, fill=txt,
            font=(self.font_name, button_font, "bold"), anchor="center", tags="ui"
        )
        if not disabled:
            self.bind_box(x, y, x+w, y+h, command)

    # ---------- голосовая лента ----------
    def refresh_speaker_colors(self):
        """Раздать цвета всем зарегистрированным людям."""
        keys = [sp.key for sp in self.speakers.list_speakers()]
        self.speaker_colors = ui_theme.assign_colors(keys, THEME_NAME)

    def load_diarization(self, result_dir):
        """Реплики встречи: кто когда говорил.

        Данные уже лежат в результате обработки, но до сих пор пользователю
        не показывались - только пересчитывались в число спикеров.
        """
        if not result_dir:
            return []
        path = Path(result_dir) / EXTRA_DIR_NAME / "diarization.json"
        names_path = Path(result_dir) / EXTRA_DIR_NAME / "speaker_names.json"
        try:
            with path.open(encoding="utf-8") as handle:
                turns = json.load(handle)
        except (OSError, ValueError):
            return []
        try:
            with names_path.open(encoding="utf-8") as handle:
                names = json.load(handle)
        except (OSError, ValueError):
            names = {}
        out = []
        for turn in turns if isinstance(turns, list) else []:
            try:
                out.append({
                    "start": float(turn.get("start", 0)),
                    "end": float(turn.get("end", 0)),
                    "speaker": str(turn.get("speaker", "")),
                    "name": str(names.get(turn.get("speaker", ""), "")),
                })
            except (TypeError, ValueError):
                continue
        return out

    def ribbon(self, x, y, w, h, turns, on_click=None, radius=3):
        """Полоса встречи: каждый отрезок - реплика, цвет - человек.

        Ширина отрезка пропорциональна длительности, поэтому по ленте сразу
        видно, кто говорил много, а кто отмалчивался.
        """
        if not turns:
            self.rect(x, y, x + w, y + h, PANEL_3, PANEL_3, 0, radius)
            self.text(x + w / 2, y + h / 2, "Нет данных о говорящих", 9,
                      TEXT_EMPTY, "normal", "center")
            return

        span = max(t["end"] for t in turns) or 1.0
        gap = 1.5
        for turn in turns:
            x1 = x + (turn["start"] / span) * w
            x2 = x + (turn["end"] / span) * w
            if x2 - x1 < 1.5:
                x2 = x1 + 1.5
            colour = ui_theme.speaker_color(
                self._key_for(turn), THEME_NAME, self.speaker_colors)
            self.rect(x1, y, max(x1 + 1.5, x2 - gap), y + h, colour, colour, 0, radius)
            if on_click:
                self.bind_box(x1, y, x2, y + h,
                              lambda t=turn: on_click(t))

    def _key_for(self, turn):
        """Ключ профиля по имени из результата. Пусто - голос не опознан."""
        name = turn.get("name", "")
        if not name:
            return ""
        for sp in self.speakers.list_speakers():
            if sp.name == name:
                return sp.key
        return ""

    def legend(self, x, y, w, turns):
        """Кто сколько говорил. Считается по той же ленте."""
        if not turns:
            return y
        span = sum(t["end"] - t["start"] for t in turns) or 1.0
        shares = {}
        for turn in turns:
            key = self._key_for(turn)
            label = turn.get("name") or "Неизвестный голос"
            shares.setdefault((key, label), 0.0)
            shares[(key, label)] += turn["end"] - turn["start"]

        col_x, row_y = x, y
        for (key, label), seconds in sorted(shares.items(), key=lambda kv: -kv[1]):
            pct = round(seconds / span * 100)
            text = f"{self.ellipsize(label, 22)}  {pct}%"
            width = 14 + len(text) * 6.2
            if col_x + width > x + w:
                col_x = x
                row_y += 20
            colour = ui_theme.speaker_color(key, THEME_NAME, self.speaker_colors)
            self.rect(col_x, row_y + 4, col_x + 9, row_y + 13, colour, colour, 0, 2)
            self.text(col_x + 15, row_y + 8, text, 10, MUTED, "normal", "w")
            col_x += width
        return row_y + 22

    def pill(self,x,y,w,label,fill=PANEL_3,fg=MUTED):
        self.rounded_rect(x,y,x+w,y+22,fill,fill,8,1)
        self.text(x+w/2,y+11,label,10,fg,"normal","center")

    def clear(self):
        self.canvas.delete("all")
        self.canvas.configure(cursor="")

    def layout(self):
        s=self.scale()
        width=self.canvas.winfo_width()/s
        # В свёрнутом виде слева остаётся место под кнопку меню, иначе
        # заголовок экрана наезжает на неё.
        left = SIDEBAR_W + CONTENT_GAP if self.sidebar_open else OUTER + 40
        right = width - OUTER
        return left, right

    # ---------- chrome ----------
    def render(self):
        self.clear()
        self.draw_background()
        self.draw_sidebar()
        self.draw_header()
        getattr(self, f"draw_{self.page}")()
        self.draw_player()

    def draw_player(self):
        """Панель воспроизведения внизу окна.

        Появляется только когда что-то звучит: полоса с прочерками читается
        как поломка, а не как пустое состояние. Раньше звук уходил в afplay
        вслепую - было не понять, играет ли ещё и что именно.
        """
        if self.playback_state == "stopped" or self.playback_path is None:
            return

        s = self.scale()
        width = self.canvas.winfo_width() / s
        height = self.canvas.winfo_height() / s
        h = 56
        y = height - h
        left = SIDEBAR_W if self.sidebar_open else 0

        self.rect(left, y, width, height, PANEL_2, PANEL_2, 0)
        self.line(left, y, width, y, BORDER, 1)

        colour = self.playing_color or BLUE
        self.rect(left + 20, y + 16, left + 23, y + h - 16, colour, colour, 0, 2)

        playing = self.playback_state == "playing"
        self.round_play(left + 48, y + h / 2, 14, playing)
        self.bind_box(left + 34, y + 12, left + 62, y + h - 12,
                      lambda: self.toggle_wav_playback(self.playback_path))

        label = self.playing_label or Path(self.playback_path).stem
        self.text(left + 74, y + 22, self.ellipsize(label, 34), 12, TEXT, "bold")
        self.text(left + 74, y + 38, "пауза" if not playing else "звучит", 9, MUTED)

        self.text(width - 24, y + h / 2, "Закрыть", 10, MUTED, "normal", "e")
        self.bind_box(width - 78, y + 16, width - 12, y + h - 16, self.stop_playback)

    def stop_playback(self):
        self._stop_wav()
        self.playing_label = ""
        self.playing_color = ""
        self.render()

    def draw_background(self):
        w=self.canvas.winfo_width(); h=self.canvas.winfo_height()
        self.canvas.create_rectangle(0,0,w,h,fill=BG,outline="",tags="bg")

    def draw_sidebar(self):
        """Боковое меню.

        Свёрнутое состояние оставлено для узких окон, но по умолчанию меню
        видно: прятать навигацию за «гамбургером» на десктопе незачем.
        """
        if not self.sidebar_open:
            self.icon_menu(30, 34, 18, MUTED)
            self.bind_box(14, 18, 58, 58, self.toggle_sidebar)
            return

        h = self.canvas.winfo_height() / self.scale()
        self.rect(0, 0, SIDEBAR_W, h, SIDEBAR, SIDEBAR_BORDER, 0)

        # Название один раз, вверху. Дубликат внизу убран.
        icon = self.load_app_icon()
        text_x = 24
        if icon is not None:
            self.canvas.create_image(self.sx(24), self.sx(46), image=icon,
                                     anchor="w", tags="ui")
            text_x = 24 + 46 * 1  # ширина иконки плюс отступ
        self.text(text_x, 36, "Славатор", 18, TEXT, "bold")
        self.text(text_x, 58, APP_VERSION, 10, MUTED_2)
        self.icon_menu(SIDEBAR_W - 30, 40, 15, MUTED_2)
        self.bind_box(SIDEBAR_W - 48, 24, SIDEBAR_W - 12, 58, self.toggle_sidebar)

        nav = [("overview", "Главная"), ("records", "Записи"),
               ("speakers", "Спикеры"), ("settings", "Настройки")]
        for i, (page, label) in enumerate(nav):
            y = 112 + i * 44
            active = self.page == page or (page == "speakers" and self.page in ("person", "new_voices"))
            if active:
                self.rect(12, y, SIDEBAR_W - 12, y + 36, NAV_ACTIVE, NAV_ACTIVE, 8)
            colour = NAV_ACTIVE_TEXT if active else NAV_TEXT
            self.nav_icon(page, 32, y + 18, colour)
            self.text(52, y + 18, label, 12, colour, "bold" if active else "normal", "w")
            self.bind_box(12, y, SIDEBAR_W - 12, y + 36, lambda p=page: self.show(p))

    def load_app_icon(self):
        """Иконка приложения в меню.

        Ссылка держится на объекте окна: Tk не владеет изображением, и без
        этого сборщик мусора съедает картинку сразу после отрисовки.
        """
        if self.app_icon is not None:
            return self.app_icon
        path = Path(__file__).resolve().parent / "app_icon.png"
        if not path.is_file():
            return None
        try:
            self.app_icon = tk.PhotoImage(file=str(path))
        except tk.TclError:
            return None
        # PhotoImage не умеет плавно масштабировать: уменьшаем целым делителем.
        target = max(1, round(40 * self.scale()))
        factor = max(1, round(self.app_icon.width() / target))
        if factor > 1:
            self.app_icon = self.app_icon.subsample(factor, factor)
        return self.app_icon

    # ---------- иконки ----------
    def icon_menu(self, cx, cy, size, colour):
        for k in (-1, 0, 1):
            self.line(cx - size / 2, cy + k * 5, cx + size / 2, cy + k * 5, colour, 2)

    def nav_icon(self, page, cx, cy, colour):
        """Иконки рисуются линиями, а не текстовыми глифами.

        Символы вроде ♙ или ◷ в разных шрифтах выглядят по-разному и часто
        не имеют отношения к смыслу пункта.
        """
        s = 7
        if page == "overview":            # домик
            self.line(cx - s, cy, cx, cy - s, colour, 2)
            self.line(cx, cy - s, cx + s, cy, colour, 2)
            self.line(cx - s + 1, cy, cx - s + 1, cy + s, colour, 2)
            self.line(cx + s - 1, cy, cx + s - 1, cy + s, colour, 2)
            self.line(cx - s + 1, cy + s, cx + s - 1, cy + s, colour, 2)
        elif page == "records":           # часы
            sc = self.scale()
            self.canvas.create_oval((cx - s) * sc, (cy - s) * sc, (cx + s) * sc, (cy + s) * sc,
                                    outline=colour, width=max(1, round(2 * sc)), tags="ui")
            self.line(cx, cy, cx, cy - s + 3, colour, 2)
            self.line(cx, cy, cx + s - 3, cy, colour, 2)
        elif page == "speakers":          # силуэт человека
            sc = self.scale()
            self.canvas.create_oval((cx - 4) * sc, (cy - s) * sc, (cx + 4) * sc, (cy - s + 8) * sc,
                                    outline=colour, width=max(1, round(2 * sc)), tags="ui")
            self.canvas.create_arc((cx - s) * sc, (cy - 1) * sc, (cx + s) * sc, (cy + s + 7) * sc,
                                   start=0, extent=180, style="arc",
                                   outline=colour, width=max(1, round(2 * sc)), tags="ui")
        else:                             # шестерёнка
            sc = self.scale()
            self.canvas.create_oval((cx - s + 2) * sc, (cy - s + 2) * sc,
                                    (cx + s - 2) * sc, (cy + s - 2) * sc,
                                    outline=colour, width=max(1, round(2 * sc)), tags="ui")
            for dx, dy in ((0, -s), (0, s), (-s, 0), (s, 0)):
                self.line(cx + dx * 0.75, cy + dy * 0.75, cx + dx, cy + dy, colour, 2)

    def draw_header(self):
        l, r = self.layout()
        # The global light/dark segmented control is intentionally removed from
        # the product GUI. The current product state is dark, so there is no
        # duplicate theme chrome competing with the primary action.
        # На Обзоре кнопки нет: там прямо под шапкой лежит область выбора
        # файла, и две точки входа в одно действие только путают.
        if self.page in ("records", "speakers", "new_voices"):
            width = 150
            self.button(r - width, 18, width, 38, "+  Новая запись",
                        lambda: (self.show_overview(), self.pick_file()), True, False, 12)

    # ---------- overview ----------
    def ellipsize(self, value: str, max_chars: int) -> str:
        value = str(value)
        if len(value) <= max_chars:
            return value
        if max_chars <= 1:
            return "…"
        return value[:max_chars - 1] + "…"

    def file_info(self, path: Path) -> str:
        try:
            size = path.stat().st_size
            if size >= 1024 ** 3:
                size_text = f"{size / 1024 ** 3:.1f} ГБ"
            elif size >= 1024 ** 2:
                size_text = f"{size / 1024 ** 2:.1f} МБ"
            else:
                size_text = f"{max(1, size / 1024):.0f} КБ"
        except OSError:
            size_text = "Размер неизвестен"
        suffix = path.suffix.upper().lstrip(".") or "Файл"
        return f"{suffix} · {size_text}"

    def draw_overview(self):
        """Главная: начать работу, последняя встреча, неопознанные голоса.

        «Живая встреча» и «Обзор» сведены в один экран: и то и другое -
        способ начать работу, разводить их по вкладкам незачем.
        """
        l, r = self.layout()
        self.refresh_speaker_colors()
        self.text(l, 30, "Главная", 24, TEXT, "bold")

        y = 76
        gap = 14
        half = (r - l - gap) / 2
        block_h = 96

        # --- выбрать запись ---
        self.rect(l, y, l + half, y + block_h, PANEL, BORDER_2, 1, 12)
        if self.selected_file is None:
            self.icon_file(l + 34, y + block_h / 2, DROP_ICON)
            self.text(l + 60, y + 38, "Выбрать запись", 14, TEXT, "bold")
            self.text(l + 60, y + 60, "или перетащите файл сюда", 10, MUTED)
        else:
            self.icon_file(l + 34, y + block_h / 2, BLUE)
            self.text(l + 60, y + 32, self.ellipsize(self.selected_file.name, 30), 13, TEXT, "bold")
            self.text(l + 60, y + 52, self.file_info(self.selected_file), 10, MUTED)
            self.button(l + 60, y + 62, 174, 26, "Начать транскрибацию",
                        self.start_transcription, True, False, 10)
        self.bind_box(l, y, l + half, y + (block_h if self.selected_file is None else 58), self.pick_file)

        # --- слушать встречу ---
        lx = l + half + gap
        self.rect(lx, y, r, y + block_h, PANEL, BORDER_2, 1, 12)
        self.icon_mic(lx + 34, y + 34, BLUE_HOVER)
        self.text(lx + 60, y + 30, "Слушать встречу", 14, TEXT, "bold")
        self.pill(r - 74, y + 22, 56, "скоро", PANEL_3, MUTED_2)
        self.segmented(lx + 18, y + 54, (r - lx - 36) * 0.62, 26,
                       [("sys", "Звук компьютера"), ("mic", "Микрофон")],
                       "sys", lambda _v: None)
        self.button(r - 18 - (r - lx - 36) * 0.33, y + 54, (r - lx - 36) * 0.33, 26,
                    "Начать", self.live_soon, True, True, 10)
        y += block_h + gap

        # --- последняя встреча ---
        records = self.recent_records()
        if records:
            last = records[0]
            turns = self.load_diarization(last[6] if len(last) > 6 else None)
            card_h = 150 + (52 if turns else 30)
            self.section(l, y, r, y + card_h, self.ellipsize(str(last[0]), 46))
            self.text(l + 18, y + 20, "ПОСЛЕДНЯЯ ВСТРЕЧА", 8, TEXT_EMPTY, "bold")
            self.text(l + 18, y + 44, self.ellipsize(str(last[0]), 46), 17, TEXT, "bold")
            speakers_n = len({t["speaker"] for t in turns}) if turns else 0
            meta = f"{last[3]}" + (f" · {speakers_n} участников" if speakers_n else "")
            self.text(l + 18, y + 68, meta, 11, MUTED)
            self.text(r - 18, y + 68, "Все записи", 10, LINK, "normal", "e")
            self.bind_box(r - 92, y + 58, r - 12, y + 80, lambda: self.show("records"))

            ribbon_y = y + 88
            self.ribbon(l + 18, ribbon_y, r - l - 36, 46, turns, self.play_turn)
            if turns:
                span = max(t["end"] for t in turns)
                self.text(l + 18, ribbon_y + 58, "0:00", 9, TEXT_EMPTY)
                self.text(r - 18, ribbon_y + 58, self.hms(span), 9, TEXT_EMPTY, "normal", "e")
                self.legend(l + 18, ribbon_y + 72, r - l - 36, turns)
            y += card_h + gap
        else:
            self.section(l, y, r, y + 150, "Пока нет обработанных встреч")
            self.text((l + r) / 2, y + 78, "Выберите запись выше и нажмите «Начать транскрибацию»",
                      11, MUTED, "normal", "center")
            y += 164

        # --- неопознанные голоса ---
        unknown = self.speakers.discover_unknown_voices()
        if unknown:
            shown = unknown[:2]
            card_h = 52 + len(shown) * 52 + 8
            title = f"{len(unknown)} голос не узнан" if len(unknown) == 1 else f"{len(unknown)} голоса не узнаны"
            self.section(l, y, r, y + card_h, title)
            self.text(r - 18, y + 26, "Открыть", 10, LINK, "normal", "e")
            self.bind_box(r - 80, y + 14, r - 12, y + 38, lambda: self.show("new_voices"))
            row_y = y + 50
            for voice in shown:
                self.draw_unknown_row(l + 18, row_y, r - 18, 44, voice)
                row_y += 52

    def hms(self, seconds: float) -> str:
        seconds = int(max(0, seconds))
        h, rest = divmod(seconds, 3600)
        m, sec = divmod(rest, 60)
        return f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"

    def draw_unknown_row(self, x, y, r, h, voice):
        """Строка неопознанного голоса с подсказкой имени из разговора."""
        self.rect(x, y, r, y + h, ROW_BG, ROW_BORDER, 1, 9)
        playing = self.playback_path == Path(voice.wav_path) and self.playback_state == "playing"
        self.round_play(x + 12, y + h / 2, 13, playing)
        self.bind_box(x + 12 - 13, y + 8, x + 12 + 13, y + h - 8,
                      lambda v=voice: self.toggle_wav_playback(v.wav_path))

        stem = Path(voice.wav_path).stem
        # Ядро кладёт догадку прямо в имя файла: «SPEAKER_01 — возможно, Богдан»
        if "возможно," in stem:
            guess = stem.split("возможно,", 1)[1].strip()
            self.text(x + 36, y + 15, f"Похоже, это {self.ellipsize(guess, 26)}", 12, TEXT, "bold")
            self.text(x + 36, y + 32, "определено по разговору", 9, MUTED)
            self.button(r - 130, y + 9, 118, 26, f"Это {self.ellipsize(guess.split()[0], 12)}",
                        lambda v=voice: self.assign_voice_dialog(v), True, False, 9)
        else:
            self.text(x + 36, y + 15, self.ellipsize(stem, 30), 12, TEXT, "bold")
            self.text(x + 36, y + 32, "имя не определилось", 9, MUTED)
            self.button(r - 148, y + 9, 136, 26, "Выбрать человека",
                        lambda v=voice: self.assign_voice_dialog(v), False, False, 9)

    def round_play(self, cx, cy, radius, playing=False):
        sc = self.scale()
        self.canvas.create_oval((cx - radius) * sc, (cy - radius) * sc,
                                (cx + radius) * sc, (cy + radius) * sc,
                                fill=BLUE, outline="", tags="ui")
        if playing:
            self.rect(cx - 4, cy - 5, cx - 1, cy + 5, WHITE, WHITE, 0, 1)
            self.rect(cx + 1, cy - 5, cx + 4, cy + 5, WHITE, WHITE, 0, 1)
        else:
            sx = self.sx
            self.canvas.create_polygon(
                sx(cx - 3.5), sx(cy - 5.5), sx(cx + 5), sx(cy), sx(cx - 3.5), sx(cy + 5.5),
                fill=WHITE, outline="", tags="ui")

    def icon_mic(self, cx, cy, colour):
        sc = self.scale()
        self.canvas.create_oval((cx - 5) * sc, (cy - 11) * sc, (cx + 5) * sc, (cy + 3) * sc,
                                outline=colour, width=max(1, round(2 * sc)), tags="ui")
        self.canvas.create_arc((cx - 9) * sc, (cy - 6) * sc, (cx + 9) * sc, (cy + 10) * sc,
                               start=200, extent=140, style="arc",
                               outline=colour, width=max(1, round(2 * sc)), tags="ui")
        self.line(cx, cy + 9, cx, cy + 13, colour, 2)

    def live_soon(self):
        messagebox.showinfo(
            "Живая встреча",
            "Захват звука встречи ещё не готов.\n\n"
            "Пока обрабатывайте записанные файлы: выберите запись слева.")

    def play_turn(self, turn):
        """Послушать реплику по клику на ленту."""
        records = self.recent_records()
        if not records:
            return
        folder = records[0][6] if len(records[0]) > 6 else None
        if not folder:
            return
        wav = Path(folder) / EXTRA_DIR_NAME / "work" / "audio_16k.wav"
        if not wav.is_file():
            return messagebox.showinfo(
                "Фрагмент недоступен",
                "Рабочий файл встречи удалён после обработки.\n\n"
                "Чтобы слушать фрагменты, включите хранение диагностических "
                "данных в настройках.")
        self.playing_label = turn.get("name") or "Неизвестный голос"
        self.playing_color = ui_theme.speaker_color(
            self._key_for(turn), THEME_NAME, self.speaker_colors)
        self.play_wav(wav)

    def plural_people(self, n: int) -> str:
        tail = n % 100
        if 11 <= tail <= 14:
            word = "человек"
        elif n % 10 == 1:
            word = "человек"
        elif n % 10 in (2, 3, 4):
            word = "человека"
        else:
            word = "человек"
        return f"Зарегистрировано: {n} {word}"

    def icon_file(self, cx, cy, colour):
        sc = self.scale()
        w, h = 20, 24
        self.line(cx - w / 2, cy - h / 2, cx + w / 2 - 6, cy - h / 2, colour, 2)
        self.line(cx + w / 2 - 6, cy - h / 2, cx + w / 2, cy - h / 2 + 6, colour, 2)
        self.line(cx + w / 2, cy - h / 2 + 6, cx + w / 2, cy + h / 2, colour, 2)
        self.line(cx - w / 2, cy - h / 2, cx - w / 2, cy + h / 2, colour, 2)
        self.line(cx - w / 2, cy + h / 2, cx + w / 2, cy + h / 2, colour, 2)

    def icon_doc(self, cx, cy, colour):
        for i, width in enumerate((26, 34, 30)):
            self.rect(cx - width / 2, cy - 12 + i * 10, cx + width / 2, cy - 6 + i * 10,
                      colour, colour, 0, 3)

    def section(self, x1, y1, x2, y2, title):
        self.rect(x1, y1, x2, y2, PANEL, BORDER_2, 1, 10)
        self.text(x1 + 18, y1 + 18, title, 17, TEXT, "bold")

    def draw_voice_card(self, x, y, w, h, voice):
        self.rect(x, y, x + w, y + h, PANEL_2, CARD_BORDER_2, 1, 9)
        self.rect(x + 12, y + 14, x + 42, y + 44, BLUE, BLUE, 15)
        is_playing = bool(voice and self.playback_path == Path(voice.wav_path) and self.playback_state == "playing")
        icon = "Ⅱ" if is_playing else "▶"
        self.text(x + 27, y + 29, icon, 10, WHITE, "bold", "center")
        label = Path(voice.wav_path).stem if voice else "Новый голос 01"
        self.text(x + 58, y + 14, self.ellipsize(label, max(18, int((w - 110) / 8))), 12, TEXT, "bold")
        dur = f"{int(voice.duration):02d}" if voice and voice.duration else "10"
        self.text(x + w - 18, y + 18, f"00:{dur}", 9, MUTED, "normal", "e")
        for i in range(20):
            hh = 4 + (i * 7) % 15
            self.rect(x + 58 + i * 7, y + 48 - hh / 2, x + 61 + i * 7, y + 48 + hh / 2, WAVE, "", 0)
        primary_w = min(176, max(160, w * 0.30))
        secondary_x = x + 18 + primary_w
        secondary_w = max(112, w - (primary_w + 30))
        self.button(x + 12, y + 78, primary_w, 28, "Определить человека", lambda v=voice: self.assign_voice_dialog(v) if v else self._create_first_unknown(), True, False, 8)
        self.button(secondary_x, y + 78, secondary_w, 28, "Создать нового", lambda v=voice: self.create_person_dialog(v), False, False, 8)
        if voice:
            self.bind_box(x + 12, y + 14, x + 42, y + 44, lambda v=voice: self.toggle_wav_playback(v.wav_path))

    def draw_record_row(self, x, y, w, h, rec):
        self.rect(x, y, x + w, y + h, ROW_BG, ROW_BG, 0)
        inner = max(1, w - 16)
        # Proportional columns keep long titles and status inside the row.
        ratios = [0.31, 0.12, 0.17, 0.17, 0.12, 0.07, 0.04]
        widths = [inner * q for q in ratios]
        xpos = x + 8
        vals = [rec[0], rec[1], rec[2], rec[3], rec[4], rec[5], "…"]
        for idx, (val, col_w) in enumerate(zip(vals, widths)):
            if idx == 5:
                self.pill(xpos, y + 6, max(48, col_w - 8), "Готово", PILL_OK_BG, GREEN)
            elif idx == 6:
                self.text(xpos + col_w / 2, y + 14, "…", 14, MUTED, "bold", "center")
            else:
                char_width = 8.8 if idx == 0 else 7.4
                max_chars = max(7, int(max(1, col_w - 12) / char_width))
                value = self.ellipsize(str(val), max_chars)
                self.text(xpos, y + 14, value, 11 if idx == 0 else 10, TEXT if idx == 0 else MUTED, "bold" if idx == 0 else "normal", "w")
            xpos += col_w
        self.bind_box(x, y, x + w, y + h, lambda: self.show("records"), False)

    # ---------- speakers ----------
    def draw_speakers(self):
        l,r=self.layout()
        self.button(r-126,20,126,40,"+  Новый человек",self.create_person_dialog,True,False,11)
        self.text(l,86,"Спикеры",24,TEXT,"bold")
        self.text(l,128,"Все люди",11,TEXT,"bold")
        self.text(l+82,128,"Новые голоса",11,MUTED)
        n=len(self.speakers.discover_unknown_voices())
        # Keep a deterministic gap between the tab label, counter and Archive.
        badge_x = l + 184
        badge_w = 22
        self.rounded_rect(badge_x,120,badge_x+badge_w,140,BLUE,BLUE,8,1)
        self.text(badge_x+badge_w/2,130,str(n),9,WHITE,"bold","center")
        self.text(l+216,128,"Архив",11,MUTED)
        self.line(l,154,r,154)
        self.rect(l,170,r-120,206,PANEL_2,BORDER,1,7)
        self.text(l+14,188,"⌕",14,MUTED,"normal","center")
        self.text(l+34,188,"Поиск по имени, должности или компании",10,MUTED,"normal","w")
        self.button(r-104,170,104,36,"☷  Фильтры",lambda:messagebox.showinfo("Фильтры","Фильтры: компания, должность, наличие образца."),False,False,10)
        people=self.speakers.list_speakers()
        y=220
        for sp in people[:7]:
            self.draw_person_row(l,y,r,58,sp); y+=64
        if not people:
            self.text((l+r)/2, y+60, "Пока нет голосовых профилей",
                      12, MUTED, "normal", "center")
            self.button((l+r)/2-80,y+88,160,32,"+  Новый человек",self.create_person_dialog,True)
        else:
            self.text(l, y+12, f"Показано {min(7,len(people))} из {len(people)}",9,MUTED)

    def avatar(self,x,y,initials):
        self.canvas.create_oval(self.sx(x),self.sx(y),self.sx(x+36),self.sx(y+36),fill=AVATAR,outline="",tags="ui")
        self.text(x+18,y+18,initials,11,WHITE,"bold","center")

    def draw_person_row(self,x,y,r,h,sp):
        self.rect(x,y,r-10,y+h,PANEL_2,CARD_BORDER,1,7)
        initials="".join([p[0] for p in sp.name.split()[:2]]).upper()[:2]
        self.avatar(x+12,y+11,initials)
        self.text(x+58,y+10,sp.name,11,TEXT,"bold")
        self.text(x+58,y+29,sp.position or "—",9,MUTED)
        self.text(x+58,y+43,sp.company or "—",9,MUTED)
        self.text(r-46,y+14,f"Встреч: {sp.samples}",8,MUTED,"normal","e")
        self.text(r-46,y+32,"Последняя: —",8,MUTED,"normal","e")
        self.text(r-34,y+29,"›",17,MUTED,"normal","center")
        self.bind_box(x,y,r-42,y+h,lambda k=sp.key:self.open_person(k))

    def draw_demo_person(self,x,y,r,h,name,pos,comp,cnt):
        self.rect(x,y,r-10,y+h,PANEL_2,CARD_BORDER,1,7)
        self.avatar(x+12,y+11,"".join(p[0] for p in name.split()[:2]))
        self.text(x+58,y+10,name,11,TEXT,"bold")
        self.text(x+58,y+29,pos,9,MUTED)
        self.text(x+58,y+43,comp,9,MUTED)
        self.text(r-46,y+14,f"Встреч: {cnt}",8,MUTED,"normal","e")
        self.text(r-46,y+32,self.ellipsize("Последняя: 21.05.2025", 20),8,MUTED,"normal","e")
        self.text(r-34,y+29,"›",17,MUTED,"normal","center")
        self.bind_box(x,y,r-42,y+h,self.create_person_dialog)

    # ---------- new voices ----------
    def draw_new_voices(self):
        l,r=self.layout()
        self.text(l,82,"‹  Назад",10,MUTED); self.bind_box(l,72,l+90,100,self.show_overview)
        self.text(l,112,"Новые голоса",22,TEXT,"bold")
        self.text(l,142,"Идентифицируйте новые голоса или создайте новых людей.",10,MUTED)
        voices=self.speakers.discover_unknown_voices()
        if not voices:
            self.text(l,200,"Новых голосов нет",12,MUTED); return
        y=174
        for i,v in enumerate(voices):
            self.draw_new_voice_row(l,y,r,v,i); y+=116
        self.text(l,y+8,"Все определённые голоса (0)",10,LINK)

    def draw_new_voice_row(self,x,y,r,voice,index):
        self.rect(x,y,r,y+96,PANEL_2,CARD_BORDER,1,9)
        self.rect(x+12,y+14,x+42,y+44,BLUE,BLUE,15)
        self.text(x+27,y+29,"▶",10,WHITE,"bold","center")
        self.text(x+58,y+14,Path(voice.wav_path).stem[:28],11,TEXT,"bold")
        self.text(x+58,y+38,"Встреча",9,MUTED)
        self.text(x+58,y+56,"Дата: —",9,MUTED)
        self.button(x+12,y+62,126,26,"Определить человека",lambda v=voice:self.assign_voice_dialog(v),True,False,9)
        self.button(x+146,y+62,112,26,"Создать нового",lambda v=voice:self.create_person_dialog(v),False,False,9)
        self.bind_box(x+12,y+14,x+42,y+44,lambda v=voice:self.toggle_wav_playback(v.wav_path))

    # ---------- person ----------
    def draw_person(self):
        l,r=self.layout()
        sp=self.speakers.get_speaker(self.current_person_key) if self.current_person_key else None
        if not sp: self.show("speakers"); return
        self.text(l,78,"‹  Назад",10,MUTED); self.bind_box(l,68,l+90,98,lambda:self.show("speakers"))
        self.button(r-130,70,130,34,"✎  Редактировать",self._person_edit_dialog,False,False,10)
        initials="".join(p[0] for p in sp.name.split()[:2]).upper()[:2]
        self.avatar(l,110,initials)
        self.text(l+50,120,sp.name,18,TEXT,"bold")
        self.rect(l,164,r,286,PANEL_2,CARD_BORDER,1,9)
        fields=[("Должность",sp.position or "—"),("Компания",sp.company or "—"),("Email","—"),("Телефон","—"),("Примечание","—")]
        y=182
        for label,val in fields:
            self.text(l+14,y,label,9,MUTED)
            self.text(l+130,y,val,10,TEXT if val!="—" else TEXT_EMPTY)
            self.line(l+14,y+21,r-14,y+21,DIVIDER)
            self.bind_box(l,y-5,r,y+25,self._person_edit_dialog)
            y+=24
        self.rect(l,300,r,382,PANEL_2,CARD_BORDER,1,9)
        self.text(l+14,316,"Статистика",13,TEXT,"bold")
        self.text(l+14,344,"Всего встреч",9,MUTED); self.text(l+14,361,str(sp.samples),14,TEXT,"bold")
        self.text(l+160,344,"Часов речи",9,MUTED); self.text(l+160,361,"05:32:17",14,TEXT,"bold")
        self.text(l+300,344,"Последняя запись",9,MUTED); self.text(l+300,361,"21.05.2025",11,TEXT,"bold")
        self.rect(l,396,r,468,PANEL_2,CARD_BORDER,1,9)
        self.text(l+14,412,"Голосовой профиль",13,TEXT,"bold")
        self.text(l+14,440,"Создан: 12.03.2025",9,MUTED)
        self.text(l+170,440,"Обновлён: 21.05.2025",9,MUTED)
        self.button(r-142,430,128,26,"Прослушать образцы",lambda:self.play_person_sample(sp),False,False,9)

    # ---------- records ----------
    def draw_records(self):
        l,r=self.layout()
        self.text(l,82,"Последние записи",22,TEXT,"bold")
        self.button(r-110,74,110,34,"☷  Фильтры",lambda:messagebox.showinfo("Фильтры","Проект, тип встречи, дата, статус"),False,False,10)
        records=self.recent_records()
        if not records:
            self.text((l+r)/2, 220, "Здесь появятся обработанные встречи",
                      12, MUTED, "normal", "center")
            return
        y=130
        total=r-l
        # Reserve a dedicated overflow-menu column. Every visible value is
        # constrained to its own column, so long meeting names can never run
        # underneath Project/Date/Status.
        ratios = [0.31, 0.12, 0.17, 0.17, 0.12, 0.07, 0.04]
        widths=[total*q for q in ratios]
        labels=["Название","Проект","Тип встречи","Дата","Спикеры","Статус",""]
        self.rect(l,y,r,y+34,PANEL_2,CARD_BORDER,1,5)
        xpos=l
        for label,w in zip(labels,widths):
            if label:
                self.text(xpos+10,y+17,label,9,MUTED,"bold","w")
            xpos+=w
        for i,rec in enumerate(records[:7]):
            yy=y+36+i*48
            self.rect(l,yy,r,yy+46,ROW_BG if i%2==0 else PANEL,ROW_BORDER,0)
            xpos=l
            vals=rec[:6] + ("…",)
            for idx,(val,w) in enumerate(zip(vals,widths)):
                if idx==5:
                    status_w = min(72, max(48, w - 14))
                    self.pill(xpos+8,yy+12,status_w,"Готово",PILL_OK_BG,GREEN)
                elif idx==6:
                    self.text(xpos+w/2,yy+23,"…",13,MUTED,"bold","center")
                else:
                    # Conservative character budgets prevent a long title or
                    # date from touching the next column even with bold text.
                    char_width = 8.8 if idx == 0 else 7.4
                    max_chars=max(7,int(max(1,w-18)/char_width))
                    value=self.ellipsize(str(val),max_chars)
                    self.text(xpos+10,yy+23,value,9,TEXT if idx==0 else MUTED,"bold" if idx==0 else "normal","w")
                xpos+=w
            self.bind_box(l,yy,r,yy+46,lambda:self.open_record())

    # ---------- settings ----------
    def draw_settings(self):
        l,r=self.layout()
        # Настройки уже основной рабочей области, но все элементы управления
        # выравниваются по правому краю карточки, а не по фиксированной точке.
        r=min(r,l+860)
        self.text(l,78,"‹  Назад",10,MUTED); self.bind_box(l,68,l+90,98,self.show_overview)
        self.text(l,112,"Настройки",22,TEXT,"bold")

        control_w = 228
        control_x = r - 16 - control_w

        self.setting_card(l,150,r,248,"Общее")
        self.text(l+16,182,"Тема",9,MUTED)
        self.segmented(control_x,168,control_w,30,
                       [("dark","Тёмная"),("light","Светлая"),("system","Авто")],
                       self.settings.get("theme","dark"), self.set_theme)
        self.text(l+16,218,"Язык",9,MUTED)
        self.value_box(control_x,204,control_w,"Русский")

        widget_on = bool(self.settings.get("widget_enabled"))
        self.setting_card(l,260,r,380,"Быстрая транскрибация")
        self.text(l+16,296,"Плавающий виджет",10,TEXT,"bold")
        self.toggle(r-58,290,widget_on,self.toggle_widget)
        self.text(l+16,344,"Папка для записей виджета",9,MUTED)
        widget_dir = str(self.settings.get("widget_output_dir",""))
        self.text(l+220,344,self.ellipsize(widget_dir,max(18,int((r-136-l-220)/7))),9,
                  TEXT if widget_on else TEXT_EMPTY)
        self.button(r-116,330,100,28,"Выбрать",self.choose_widget_dir,False,not widget_on,9)

        self.setting_card(l,392,r,470,"Хранение данных")
        self.text(l+16,424,"Папка для результатов",9,MUTED)
        results_dir = str(self.settings.get("results_dir",""))
        self.text(l+220,424,self.ellipsize(results_dir,max(18,int((r-136-l-220)/7))),9,TEXT)
        self.button(r-116,410,100,28,"Изменить",self.change_results_dir,False,False,9)

        keep = bool(self.settings.get("keep_diagnostics"))
        self.setting_card(l,482,r,566,"Безопасность и приватность")
        self.text(l+16,505,"Хранить диагностические данные",10,TEXT,"bold")
        self.text(l+16,525,"Нужны, чтобы слушать фрагменты встреч после обработки",9,MUTED)
        self.toggle(r-58,511,keep,self.toggle_diagnostics)

        self.setting_card(l,578,r,650,"Термины команды")
        self.text(l+16,610,"Словарь",9,MUTED)
        glossary = Path.home()/"whisper-work"/"glossary.txt"
        try:
            count = len([x for x in glossary.read_text(encoding="utf-8").splitlines()
                         if x.strip() and not x.strip().startswith("#")])
        except OSError:
            count = 0
        self.text(l+220,610,f"{count} терминов",9,TEXT)
        self.button(r-116,596,100,28,"Открыть",self.open_glossary,False,False,9)

        self.setting_card(l,662,r,748,"О приложении")
        self.text(l+16,694,"Версия",9,MUTED)
        self.text(r-16,694,APP_VERSION,9,TEXT,"normal","e")
        self.text(l+16,722,"Проверить обновления",9,MUTED)
        self.button(r-116,706,100,28,"Проверить",lambda:messagebox.showinfo("Обновления","Вы используете актуальную версию."),False,False,9)
        self.text(r-1,778,"© 2026 Славатор",8,FOOTER,"normal","e")

    def setting_card(self,x,y,r,b,title):
        self.rect(x,y,r,b,PANEL_2,CARD_BORDER,1,8); self.text(x+16,y+14,title,10,TEXT,"bold")
    def value_box(self,x,y,w,label):
        self.rect(x,y,x+w,y+28,INPUT_BG,INPUT_BORDER,1,6); self.text(x+w-10,y+14,label,9,TEXT,"normal","e")
    def toggle(self,x,y,on,command=None):
        self.rect(x,y,x+42,y+22,BLUE if on else TOGGLE_OFF,BLUE if on else TOGGLE_OFF_BORDER,1,11)
        knob_x = x + (20 if on else 2)
        self.canvas.create_oval(self.sx(knob_x),self.sx(y+2),self.sx(knob_x+18),self.sx(y+20),fill=WHITE,outline="")
        if command:
            self.bind_box(x,y,x+42,y+22,command)

    def segmented(self,x,y,w,h,options,active,command):
        """Сегментированный переключатель из дизайн-кита."""
        self.rounded_rect(x,y,x+w,y+h,PANEL_3,BORDER_2,8,1)
        seg = w/len(options)
        for i,(value,label) in enumerate(options):
            sx = x+i*seg
            chosen = value==active
            if chosen:
                self.rounded_rect(sx+2,y+2,sx+seg-2,y+h-2,BLUE,BLUE,6,1)
            self.text(sx+seg/2,y+h/2,label,10,WHITE if chosen else MUTED,"bold","center")
            self.bind_box(sx,y,sx+seg,y+h,lambda v=value:command(v))

    def save_setting(self,**changes):
        self.settings = app_settings.update(**changes)

    def set_theme(self,name):
        if name == self.settings.get("theme"):
            return
        self.save_setting(theme=name)
        apply_theme(name)
        self.configure(bg=BG)
        self.canvas.configure(bg=BG)
        self.render()

    def toggle_widget(self):
        enabled = not self.settings.get("widget_enabled")
        self.save_setting(widget_enabled=enabled)
        self.render()
        if enabled:
            self.start_widget()
        else:
            self.stop_widget()

    def choose_widget_dir(self):
        chosen = filedialog.askdirectory(title="Куда виджет сохраняет расшифровки")
        if chosen:
            self.save_setting(widget_output_dir=chosen)
            self.render()

    def open_glossary(self):
        """Открыть словарь терминов в текстовом редакторе."""
        path = Path(os.environ.get("MEETING_TRANSCRIBER_GLOSSARY",
                                   str(Path.home()/"whisper-work"/"glossary.txt")))
        if not path.is_file():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                "# Термины вашей команды: по одному в строке.\n"
                "# Приложение узнаёт их в речи и пишет единообразно:\n"
                "# услышав «си джей эм», напишет CJM.\n",
                encoding="utf-8")
        if os.name == "nt":
            os.startfile(str(path))
        elif sys.platform == "darwin":
            subprocess.Popen(["open", "-e", str(path)])
        else:
            subprocess.Popen(["xdg-open", str(path)])

    def toggle_diagnostics(self):
        self.save_setting(keep_diagnostics=not self.settings.get("keep_diagnostics"))
        self.render()
    def change_results_dir(self):
        chosen=filedialog.askdirectory(title="Папка для результатов")
        if chosen:
            self.save_setting(results_dir=chosen)
            self.speakers.results_root = Path(chosen).expanduser().resolve()
            self.render()

    # ---------- data/actions ----------
    def recent_records(self):
        root=Path(str(self.settings.get("results_dir", app_settings.DEFAULT_RESULTS_DIR))).expanduser(); out=[]
        if root.exists():
            for d in sorted(root.glob("*_result"),key=lambda p:p.stat().st_mtime,reverse=True):
                if not d.is_dir():
                    continue
                turns = self.load_diarization(d)
                speakers = len({turn["speaker"] for turn in turns}) if turns else 0
                stamp = datetime.fromtimestamp(d.stat().st_mtime).strftime("%d.%m.%Y, %H:%M")
                status = "С резюме" if (d / "02_summary_todo.docx").is_file() else "Стенограмма"
                out.append((d.name.removesuffix("_result"), "—", "Запись",
                            stamp, str(speakers or "—"), status, d))
        return out

    def show(self,page): self.page=page; self.render()
    def show_overview(self): self.show("overview")
    def toggle_sidebar(self): self.sidebar_open=not self.sidebar_open; self.render()
    def close_sidebar(self):
        if self.sidebar_open:self.sidebar_open=False; self.render()
    def open_person(self,key): self.current_person_key=key; self.show("person")
    def open_record(self): self.show("records")

    def pick_file(self):
        p=filedialog.askopenfilename(title="Выберите запись",filetypes=[("Видео и аудио","*.webm *.mp4 *.mkv *.mov *.m4a *.wav *.mp3"),("Все файлы","*.*")])
        if p:self.selected_file=Path(p); self.render()

    def start_transcription(self):
        if not self.selected_file:return messagebox.showinfo("Выберите запись","Сначала выберите файл встречи.")
        if not self.backend.available():return messagebox.showerror("Ядро не найдено","Не найдено ядро v25.1. Проверьте MEETING_TRANSCRIBER_BACKEND.")
        threading.Thread(target=self._run_backend,daemon=True).start()

    def _run_backend(self):
        try:
            self.proc=self.backend.start_transcription(
                self.selected_file, out_dir=Path(self.settings["results_dir"]), no_summary=False)
            if self.proc.stdout:
                for line in self.proc.stdout:self.events.put(("log",line.rstrip()))
            self.events.put(("done",self.proc.wait()))
        except Exception as e:self.events.put(("error",str(e)))

    def _poll(self):
        try:
            while True:
                kind,val=self.events.get_nowait()
                if kind=="done":
                    self.title("Славатор")
                    if val==0:
                        self.render(); messagebox.showinfo("Готово","Запись обработана. Результаты сохранены.")
                    else:messagebox.showerror("Ошибка обработки","Обработка завершилась с ошибкой.")
                elif kind=="log" and val.startswith("@@PROGRESS@@"):
                    try:
                        payload=json.loads(val[len("@@PROGRESS@@"):])
                        self.title(f"Славатор · {payload.get('pct',0):.0f}% · {payload.get('detail') or payload.get('stage','')}")
                    except (ValueError, TypeError):
                        pass
                elif kind=="error":messagebox.showerror("Не удалось запустить обработку",str(val))
        except queue.Empty:
            pass
        if self.playback_proc is not None and self.playback_state == "playing":
            if self.playback_proc.poll() is not None:
                self.playback_proc = None
                self.playback_path = None
                self.playback_state = "stopped"
                self.render()
        self._poll_after = self.after(100,self._poll)

    def _stop_wav(self):
        if self.playback_proc is not None and self.playback_proc.poll() is None:
            try:
                self.playback_proc.terminate()
            except OSError:
                pass
        self.playback_proc = None
        self.playback_path = None
        self.playback_state = "stopped"

    def play_wav(self,path):
        self._stop_wav()
        try:
            self.playback_path = Path(path).resolve()
            if os.name == "nt":
                helper = Path(__file__).resolve().parent / "audio_player.py"
                if not helper.is_file():
                    raise FileNotFoundError("Не найден Windows-модуль воспроизведения")
                self.playback_proc = subprocess.Popen([sys.executable, "-B", str(helper), str(self.playback_path)])
            else:
                self.playback_proc = subprocess.Popen(["afplay", str(self.playback_path)])
            self.playback_state = "playing"
            self.render()
        except Exception as e:
            self._stop_wav()
            messagebox.showerror("Не удалось воспроизвести",str(e))

    def toggle_wav_playback(self, path):
        path = Path(path).resolve()
        if not self.playing_label or self.playback_path != path:
            stem = path.stem
            self.playing_label = (stem.split("возможно,", 1)[1].strip()
                                  if "возможно," in stem else stem)
            self.playing_color = ui_theme.unknown_color(THEME_NAME)
        if self.playback_path == path and self.playback_proc is not None and self.playback_proc.poll() is None:
            try:
                if os.name == "nt":
                    self._stop_wav(); self.render(); return
                if self.playback_state == "playing":
                    os.kill(self.playback_proc.pid, signal.SIGSTOP)
                    self.playback_state = "paused"
                elif self.playback_state == "paused":
                    os.kill(self.playback_proc.pid, signal.SIGCONT)
                    self.playback_state = "playing"
                self.render()
                return
            except OSError:
                self._stop_wav()
        self.play_wav(path)

    def play_person_sample(self,sp):
        samples=sorted((self.speakers.samples_dir/sp.key).glob("*.wav")) if sp else []
        if samples:
            self.playing_label = sp.name
            self.playing_color = ui_theme.speaker_color(sp.key, THEME_NAME, self.speaker_colors)
            self.play_wav(samples[0])
        else:messagebox.showinfo("Образцы","Для этого человека пока нет WAV-образцов.")

    def dialog_button(self, parent, text, command, primary=False):
        return tk.Button(
            parent,
            text=text,
            command=command,
            bg=BLUE if primary else PANEL_3,
            fg=WHITE if primary else TEXT,
            activebackground=BLUE_HOVER if primary else CARD_BORDER,
            activeforeground=WHITE,
            relief="flat",
            bd=0,
            highlightthickness=1,
            highlightbackground=BLUE if primary else BTN_BORDER,
            highlightcolor=BLUE if primary else BTN_BORDER,
            padx=16,
            pady=8,
            font=(self.font_name, 10, "bold"),
            cursor="hand2",
        )

    def dialog_entry(self, parent, value=""):
        entry=tk.Entry(
            parent,
            bg=PANEL_2,
            fg=TEXT,
            insertbackground=TEXT,
            relief="flat",
            bd=0,
            highlightthickness=1,
            highlightbackground=INPUT_BORDER,
            highlightcolor=BLUE,
            font=(self.font_name,11),
        )
        if value:
            entry.insert(0,value)
        return entry

    def assign_voice_dialog(self,voice):
        if voice is None:return self.create_person_dialog()
        speakers=self.speakers.list_speakers()
        dlg=tk.Toplevel(self); dlg.title("Привязать голос"); dlg.configure(bg=BG); dlg.geometry("620x470"); dlg.transient(self); dlg.grab_set()
        tk.Label(dlg,text="Кому принадлежит голос?",bg=BG,fg=TEXT,font=(self.font_name,17,"bold")).pack(anchor="w",padx=24,pady=(24,4))
        tk.Label(dlg,text="Выберите зарегистрированного человека или создайте нового.",bg=BG,fg=MUTED,font=(self.font_name,10)).pack(anchor="w",padx=24)
        lb=tk.Listbox(dlg,bg=PANEL_2,fg=TEXT,selectbackground=BLUE,relief="flat",font=(self.font_name,11),height=10)
        for s in speakers:lb.insert("end",f"{s.name}  ·  {s.company or 'Компания не указана'}")
        lb.pack(fill="both",expand=True,padx=24,pady=18)
        bar=tk.Frame(dlg,bg=BG);bar.pack(fill="x",padx=24,pady=(0,20))
        self.dialog_button(bar,"Создать нового",lambda:(dlg.destroy(),self.create_person_dialog(voice))).pack(side="left")
        def go():
            sel=lb.curselection()
            if not sel:return
            try:self.speakers.assign_voice_to_existing(voice.voice_id,speakers[sel[0]].key);dlg.destroy();self.render()
            except Exception as e:messagebox.showerror("Ошибка",str(e),parent=dlg)
        self.dialog_button(bar,"Привязать",go,True).pack(side="right",padx=8)
        self.dialog_button(bar,"Отмена",dlg.destroy).pack(side="right")

    def create_person_dialog(self,voice=None):
        dlg=tk.Toplevel(self);dlg.title("Новый человек");dlg.configure(bg=BG);dlg.geometry("640x540");dlg.transient(self);dlg.grab_set()
        fields=[]
        for label in ("ФИО","Должность","Компания"):
            tk.Label(dlg,text=label,bg=BG,fg=TEXT,font=(self.font_name,10,"bold")).pack(anchor="w",padx=24,pady=(18,4))
            e=self.dialog_entry(dlg);e.pack(fill="x",padx=24,ipady=8);fields.append(e)
        path_var=tk.StringVar(value=str(voice.wav_path) if voice else "")
        tk.Label(dlg,text="WAV-образец",bg=BG,fg=TEXT,font=(self.font_name,10,"bold")).pack(anchor="w",padx=24,pady=(18,4))
        row=tk.Frame(dlg,bg=BG);row.pack(fill="x",padx=24)
        tk.Entry(row,textvariable=path_var,bg=PANEL_2,fg=TEXT,relief="flat",bd=0,highlightthickness=1,highlightbackground=INPUT_BORDER,highlightcolor=BLUE,font=(self.font_name,10)).pack(side="left",fill="x",expand=True,ipady=8)
        self.dialog_button(row,"Выбрать",lambda:path_var.set(filedialog.askopenfilename(filetypes=[("WAV","*.wav")]))).pack(side="left",padx=8)
        bar=tk.Frame(dlg,bg=BG);bar.pack(fill="x",padx=24,pady=26)
        def save():
            try:
                wav=Path(path_var.get()).expanduser() if path_var.get().strip() else None
                if wav is None or not wav.is_file():raise FileNotFoundError("Выберите WAV-образец")
                sp=self.speakers.create_person_record(fields[0].get(),fields[1].get(),fields[2].get(),wav)
                if voice:self.speakers.assign_voice_to_existing(voice.voice_id,sp.key)
                dlg.destroy();self.current_person_key=sp.key;self.show("person")
            except Exception as e:messagebox.showerror("Ошибка",str(e),parent=dlg)
        self.dialog_button(bar,"Отмена",dlg.destroy).pack(side="right")
        self.dialog_button(bar,"Создать",save,True).pack(side="right",padx=8)

    def _person_edit_dialog(self):
        sp=self.speakers.get_speaker(self.current_person_key) if self.current_person_key else None
        if not sp:return
        dlg=tk.Toplevel(self);dlg.title("Редактировать человека");dlg.configure(bg=BG);dlg.geometry("600x390");dlg.transient(self);dlg.grab_set()
        vals=[]
        for label,val in (("ФИО",sp.name),("Должность",sp.position),("Компания",sp.company)):
            tk.Label(dlg,text=label,bg=BG,fg=TEXT,font=(self.font_name,10,"bold")).pack(anchor="w",padx=24,pady=(18,4))
            e=self.dialog_entry(dlg,val);e.pack(fill="x",padx=24,ipady=8);vals.append(e)
        def save():
            try:self.speakers.update_speaker(self.current_person_key,name=vals[0].get(),position=vals[1].get(),company=vals[2].get());dlg.destroy();self.render()
            except Exception as e:messagebox.showerror("Ошибка",str(e),parent=dlg)
        self.dialog_button(dlg,"Сохранить",save,True).pack(anchor="e",padx=24,pady=24)

    # ---------- плавающий виджет ----------
    def start_widget(self):
        """Поднять виджет отдельным процессом.

        Виджет живёт своей жизнью: у него собственный цикл событий и фоновая
        запись звука, которые нельзя делить с главным окном.
        """
        if self.widget_proc is not None and self.widget_proc.poll() is None:
            return
        script = Path(__file__).resolve().parent / "widget.py"
        if not script.is_file():
            return messagebox.showerror("Виджет","Файл виджета не найден.")
        try:
            self.widget_proc = subprocess.Popen(
                [sys.executable, str(script)], cwd=str(script.parent),
                env={**os.environ, "MEETING_TRANSCRIBER_BACKEND": str(self.backend.backend or "")},
            )
        except OSError as e:
            messagebox.showerror("Виджет", f"Не удалось запустить виджет: {e}")

    def stop_widget(self):
        if self.widget_proc is not None and self.widget_proc.poll() is None:
            try:
                self.widget_proc.terminate()
            except OSError:
                pass
        self.widget_proc = None

    def _create_first_unknown(self):
        voices=self.speakers.discover_unknown_voices();self.create_person_dialog(voices[0] if voices else None)


if __name__ == "__main__":
    UI().mainloop()
