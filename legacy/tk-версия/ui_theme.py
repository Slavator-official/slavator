"""Токены оформления Славатора: светлая и тёмная тема.

Светлая палитра взята из дизайн-кита Cardbox (файл kit/ui/color.svg) с
сохранением исходных ролей и итальянских имён токенов в комментариях.
Брендовые цвета Госуслуг - Gosblue #0D4CD3 и Gosred #EE3F58 - намеренно НЕ
используются: у приложения свой акцент.

Тёмная тема - производная: кит светлый, поэтому для тёмной взяты значения из
референсных макетов приложения, разложенные по тем же ролям. Благодаря этому
любой экран описывается одним набором имён и переключается целиком.

Модуль намеренно не зависит от tkinter: его можно импортировать в тестах и в
виджете строки меню.
"""

# --------------------------------------------------------------------------
# Акцент. Один на обе темы, чтобы приложение оставалось узнаваемым.
# --------------------------------------------------------------------------

ACCENT = "#2F6FF5"

DARK = {
    # поверхности
    "BG": "#0B1522",
    "SIDEBAR": "#0D1928",
    "SIDEBAR_BORDER": "#182A3F",
    "PANEL": "#101D2D",
    "PANEL_2": "#16253A",
    "PANEL_3": "#1A2B43",
    "ROW_BG": "#13243A",
    "ROW_BORDER": "#1B3049",
    "INPUT_BG": "#1B2C42",
    # границы
    "BORDER": "#243A54",
    "BORDER_2": "#1D324B",
    "CARD_BORDER": "#223850",
    "CARD_BORDER_2": "#20354E",
    "INPUT_BORDER": "#2A415D",
    "DIVIDER": "#21364F",
    "DROP_BORDER": "#2A527E",
    # текст
    "TEXT": "#F3F6FB",
    "MUTED": "#93A1B4",
    "MUTED_2": "#718197",
    "NAV_TEXT": "#C7D0DC",
    "TEXT_EMPTY": "#66778D",
    "FOOTER": "#516177",
    "DROP_ICON": "#9FB1C7",
    # акцент и состояния
    "BLUE": ACCENT,
    "BLUE_HOVER": "#3D7BFF",
    "LINK": "#4D8BFF",
    "NAV_ACTIVE": "#18365F",
    "GREEN": "#19C37D",
    "PILL_OK_BG": "#123A2D",
    "WHITE": "#FFFFFF",
    # кнопки
    "BTN_BORDER": "#2D4663",
    "BTN_BG_DISABLED": "#1C2C42",
    "BTN_BORDER_DISABLED": "#2A405B",
    "BTN_TEXT_DISABLED": "#607087",
    # прочее
    "AVATAR": "#7C8EB1",
    "WAVE": "#7894B8",
    "TOGGLE_OFF": "#23344A",
    "TOGGLE_OFF_BORDER": "#2E415A",
}

LIGHT = {
    # поверхности
    "BG": "#F5F7FA",           # Fessura
    "SIDEBAR": "#FFFFFF",
    "SIDEBAR_BORDER": "#E5EAF5",
    "PANEL": "#FFFFFF",
    "PANEL_2": "#FAFCFF",      # Fondazione
    "PANEL_3": "#ECF0F8",      # Osso grigio
    "ROW_BG": "#FAFCFF",
    "ROW_BORDER": "#ECF0F8",
    "INPUT_BG": "#FFFFFF",
    # границы
    "BORDER": "#D1D5DF",       # Calcestruzzo
    "BORDER_2": "#E5EAF5",     # Pervinca
    "CARD_BORDER": "#E5EAF5",
    "CARD_BORDER_2": "#E5EAF5",
    "INPUT_BORDER": "#D1D5DF",
    "DIVIDER": "#E5EAF5",
    "DROP_BORDER": "#99B1E6",  # Divisore
    # текст
    "TEXT": "#0B1F33",         # Summer night
    "MUTED": "#66727F",        # Interlineare
    "MUTED_2": "#86909C",      # Telegrey scuro
    "NAV_TEXT": "#66727F",
    "TEXT_EMPTY": "#86909C",
    "FOOTER": "#86909C",
    "DROP_ICON": "#86909C",
    # акцент и состояния
    "BLUE": ACCENT,
    "BLUE_HOVER": "#1D5DEB",   # Vertigini blu
    "LINK": "#1D5DEB",
    "NAV_ACTIVE": "#E4ECFD",   # Solitario
    "GREEN": "#12A06A",
    "PILL_OK_BG": "#DDF5E7",   # Giovani steli
    "WHITE": "#FFFFFF",
    # кнопки
    "BTN_BORDER": "#D1D5DF",
    "BTN_BG_DISABLED": "#F5F7FA",
    "BTN_BORDER_DISABLED": "#E5EAF5",
    "BTN_TEXT_DISABLED": "#86909C",
    # прочее
    "AVATAR": "#66727F",       # белые инициалы читаются, в отличие от Divisore
    "WAVE": "#99B1E6",
    "TOGGLE_OFF": "#E5EAF5",
    "TOGGLE_OFF_BORDER": "#D1D5DF",
}

# --------------------------------------------------------------------------
# Палитра спикеров.
#
# Цвет здесь - не украшение, а идентичность человека: по нему он узнаётся на
# голосовой ленте встречи. Оттенок закрепляется за профилем навсегда, иначе
# на каждой встрече один и тот же человек был бы разного цвета.
# --------------------------------------------------------------------------

SPEAKERS_DARK = ("#E0A33C", "#35A9A0", "#8E7DE8", "#E0705F", "#56B37F", "#7B96C4")
SPEAKERS_LIGHT = ("#C7862A", "#1E8F87", "#6F5FD0", "#CB5647", "#3E9866", "#5C7CAC")

# Неопознанный голос намеренно бесцветный: он не человек, пока его не назвали.
UNKNOWN_DARK = "#4A5D75"
UNKNOWN_LIGHT = "#A9B6C6"


def speaker_palette(theme: str):
    return SPEAKERS_LIGHT if theme == "light" else SPEAKERS_DARK


def unknown_color(theme: str = "dark") -> str:
    return UNKNOWN_LIGHT if theme == "light" else UNKNOWN_DARK


def assign_colors(keys, theme: str = "dark") -> dict:
    """Раздать цвета участникам без повторов.

    Раздача идёт по месту в отсортированном списке, а не по хешу ключа.
    Хеш давал коллизии - двое на одной встрече получали один оттенок, и
    лента переставала их различать, ради чего она и существует.

    Порядок сортировки делает цвет устойчивым: пока состав людей не меняется,
    человек всегда одного цвета. Больше шести участников - оттенки начинают
    повторяться, но это уже предел различимости на глаз.
    """
    palette = speaker_palette(theme)
    result = {}
    for index, key in enumerate(sorted(k for k in keys if k)):
        result[key] = palette[index % len(palette)]
    return result


def speaker_color(key: str, theme: str = "dark", assigned=None) -> str:
    """Цвет человека. Пустой ключ - неопознанный голос."""
    if not key:
        return unknown_color(theme)
    if assigned and key in assigned:
        return assigned[key]
    return speaker_palette(theme)[sum(ord(c) for c in key) % len(speaker_palette(theme))]


THEMES = {"dark": DARK, "light": LIGHT}

# В светлой теме активный пункт меню - светлая плашка, поэтому подпись на нём
# должна быть тёмной. Значение читается отдельно от NAV_ACTIVE.
NAV_ACTIVE_TEXT = {"dark": DARK["TEXT"], "light": LIGHT["TEXT"]}

# --------------------------------------------------------------------------
# Типографика. Кит построен на Lato; если шрифт не установлен, откатываемся
# на системные гарнитуры, чтобы приложение не разъезжалось.
# --------------------------------------------------------------------------

FONT_STACK = ("Lato", "SF Pro Display", "SF Pro Text", "Inter", "Helvetica Neue", "Helvetica")


def palette(name: str) -> dict:
    """Набор токенов темы. Неизвестное имя откатывается на тёмную."""
    return dict(THEMES.get(name, DARK))


def nav_active_text(name: str) -> str:
    return NAV_ACTIVE_TEXT.get(name, DARK["TEXT"])


def resolve_font(available) -> str:
    """Первый доступный шрифт из стека кита."""
    families = set(available or ())
    for candidate in FONT_STACK:
        if candidate in families:
            return candidate
    return "Helvetica"


def system_appearance() -> str:
    """Тема macOS: 'dark' или 'light'. При любой ошибке - светлая."""
    import subprocess

    try:
        result = subprocess.run(
            ["defaults", "read", "-g", "AppleInterfaceStyle"],
            capture_output=True, text=True, timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return "light"
    return "dark" if "dark" in result.stdout.strip().lower() else "light"


def resolve(name: str) -> str:
    """Превратить настройку темы в конкретную палитру."""
    if name == "system":
        return system_appearance()
    return name if name in THEMES else "dark"
