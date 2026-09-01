#!/usr/bin/env python3
"""Постоянный процесс распознавания для диктовки.

Живёт, пока открыт Славатор, и держит модель в памяти. Это главное:
загрузка модели занимает секунды, и поднимать её на каждую фразу означало бы
ждать дольше, чем говоришь.

Общение через stdin/stdout построчным JSON — тот же приём, что у основного
ядра с его `@@PROGRESS@@`, только в обе стороны.

    ←  {"cmd": "transcribe", "path": "/tmp/фраза.wav"}
    →  {"text": "Давайте зафиксируем: бэклог закрываем в пятницу."}

    ←  {"cmd": "tidy", "text": "ну это, надо бы...", "level": "structure"}
    →  {"text": "Надо...", "ok": true}

Кириллица уходит в stdout как есть: Swift читает UTF-8.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

MODEL = os.environ.get("SLAVATOR_DICTATION_MODEL", "small")
LANGUAGE = os.environ.get("SLAVATOR_DICTATION_LANGUAGE", "ru")
GLOSSARY = Path(os.environ.get(
    "MEETING_TRANSCRIBER_GLOSSARY",
    str(Path.home() / "whisper-work" / "glossary.txt"),
))
OLLAMA = os.environ.get("MEETING_TRANSCRIBER_OLLAMA", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("MEETING_TRANSCRIBER_LLM", "qwen3:8b")
# Обработка идёт после того, как человек отпустил клавишу, и он ждёт.
# Лучше отдать сырой текст, чем заставить смотреть в пустое поле.
TIDY_TIMEOUT = int(os.environ.get("SLAVATOR_TIDY_TIMEOUT", "25"))


# Выдумки Whisper на тишине. Список повторяет тот, что в ядре
# (HALLUCINATION_PATTERNS), и дополнен тем, что вылезло на диктовке:
# модель уверенно печатает титры фильмов, которых никто не произносил.
import re

JUNK = [
    r"редактор\s+субтитр",
    r"корректор\s+[а-яё]\.",
    r"субтитры\s+(сделал|создал|подготовил|и\s+перевод)",
    r"продолжение\s+следует",
    r"спасибо\s+за\s+просмотр",
    r"подписывайтесь\s+на\s+канал",
    r"dimatorzok",
    r"amara\.org",
    r"^\W*\[?\s*(музыка|аплодисменты|смех|тишина)\s*\]?\W*$",
]
JUNK_RE = [re.compile(x, re.IGNORECASE) for x in JUNK]


def is_junk(text: str) -> bool:
    probe = text.strip()
    if not probe:
        return True
    # Строка целиком капсом — ремарка вроде «ПОЗИТИВНАЯ МУЗЫКА».
    #
    # Проверяем кодом, а не выражением: правило [А-ЯЁ]{8,} с флагом
    # IGNORECASE ловило ЛЮБОЙ русский текст и выбрасывало настоящую речь.
    # Потерять сказанное хуже, чем пропустить выдумку.
    letters = [c for c in probe if c.isalpha()]
    if len(letters) >= 8 and all(c.isupper() for c in letters):
        return True
    return any(rx.search(probe) for rx in JUNK_RE)


def send(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# --------------------------------------------------------------------------
# Словарь терминов
# --------------------------------------------------------------------------

def load_glossary() -> list:
    try:
        lines = GLOSSARY.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    return [x.strip() for x in lines if x.strip() and not x.strip().startswith("#")]


class _Line:
    """Обёртка под glossary_fix: ему нужен объект с полем text."""

    __slots__ = ("text",)

    def __init__(self, text: str):
        self.text = text


def repair(text: str, glossary: list, fixer) -> str:
    if not text or not glossary or fixer is None:
        return text
    line = _Line(text)
    try:
        fixer.repair([line], glossary)
    except Exception:
        return text
    return line.text


# --------------------------------------------------------------------------
# Обработка текста языковой моделью
# --------------------------------------------------------------------------

_COMMON = (
    "Ты редактор устной речи. Тебе дают расшифровку сказанного вслух.\n"
)
_TAIL = (
    "\n\nПример.\n"
    "Вход: ну короче э-э надо бы созвон перенести на среду и вот ещё макеты посмотреть\n"
    "Выход: Надо перенести созвон на среду и посмотреть макеты.\n\n"
    "Отвечай ТОЛЬКО готовым текстом, без пояснений и без вступлений."
)

LEVELS = {
    "clean": _COMMON + (
        "Убери слова-паразиты (так, ну, вот, значит, э-э, как бы, типа), повторы и "
        "оговорки. Расставь знаки препинания и заглавные буквы. "
        "Слова и порядок мыслей сохрани, ничего не добавляй и не сокращай."
    ) + _TAIL,
    "structure": _COMMON + (
        "Убери слова-паразиты (так, ну, вот, значит, э-э, как бы, типа), повторы и "
        "оговорки. Расставь знаки препинания и заглавные буквы. Если человек "
        "перечислял - оформи списком, каждый пункт с новой строки и дефиса. "
        "Смысл и формулировки сохрани, ничего не выдумывай."
    ) + _TAIL,
    "shrink": _COMMON + (
        "Убери слова-паразиты, повторы, штампы и канцелярит, замени страдательный "
        "залог действительным, сократи. Смысл сохрани полностью, фактов не добавляй."
    ) + _TAIL,
}


def tidy(text: str, level: str) -> tuple:
    """Причесать надиктованное. Возвращает (текст, получилось ли)."""
    system = LEVELS.get(level, LEVELS["structure"])
    payload = {
        "model": OLLAMA_MODEL,
        "stream": False,
        # Размышления вслух здесь не нужны и очень дороги: с ними правка
        # короткой фразы занимала 24,7 с, без них - 2,2 с. Качество
        # добирается примером в задании, а не рассуждениями.
        "think": False,
        "keep_alive": "10m",
        "options": {"temperature": 0.1},
        "messages": [
            {"role": "system", "content": system + " Отвечай ТОЛЬКО готовым текстом, без пояснений."},
            {"role": "user", "content": text},
        ],
    }
    request = urllib.request.Request(
        f"{OLLAMA}/api/chat",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIDY_TIMEOUT) as response:
            answer = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        return text, False

    result = str(answer.get("message", {}).get("content", "")).strip()
    # Модель qwen3 иногда рассуждает вслух в тегах <think>.
    if "</think>" in result:
        result = result.split("</think>", 1)[1].strip()
    if not result:
        return text, False
    # Защита от подмены: обработка не вправе раздувать текст вдвое или
    # выбрасывать почти всё. Такое случается, когда модель поняла задание
    # как «ответь на вопрос», а не «отредактируй».
    if not (0.3 <= len(result) / max(1, len(text)) <= 2.0):
        return text, False
    return result, True


# --------------------------------------------------------------------------

def main() -> int:
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        send({"error": f"нет faster-whisper: {exc}"})
        return 1

    try:
        model = WhisperModel(MODEL, device="cpu", compute_type="int8")
    except Exception as exc:  # noqa: BLE001 - Swift покажет текст как есть
        send({"error": f"не удалось загрузить модель {MODEL}: {exc}"})
        return 1

    glossary = load_glossary()
    fixer = None
    if glossary:
        try:
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import glossary_fix as fixer  # noqa: F401
        except Exception:
            fixer = None

    hotwords = ", ".join(glossary[:64]) if glossary else None
    prompt = (
        "Рабочая диктовка. В речи встречаются термины: "
        + ", ".join(glossary[:48]) + "."
        if glossary else None
    )

    send({"ready": True, "model": MODEL, "glossary": len(glossary)})

    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            command = json.loads(raw)
        except ValueError:
            continue

        name = command.get("cmd")
        if name == "quit":
            break

        if name == "transcribe":
            path = command.get("path", "")
            if not path or not Path(path).is_file():
                send({"id": command.get("id"), "text": ""})
                continue
            try:
                segments, _info = model.transcribe(
                    path,
                    language=None if LANGUAGE in ("", "auto") else LANGUAGE,
                    beam_size=1,                    # скорость важнее полутонов
                    condition_on_previous_text=False,
                    vad_filter=False,               # см. ядро: VAD терял речь
                    # Термины называем заранее. Без этого быстрая модель
                    # пишет заимствования латиницей - «Backlock» вместо
                    # «бэклог», - а починить это потом почти нечем:
                    # обратной транслитерации у заимствований нет.
                    hotwords=hotwords,
                    initial_prompt=prompt,
                )
                # Фильтруем ПОКУСОЧНО: выдумка приходит отдельным отрезком,
                # и склеенную строку отсеять целиком уже нельзя, не потеряв
                # настоящую речь рядом с ней.
                text = " ".join(
                    piece for piece in (s.text.strip() for s in segments)
                    if not is_junk(piece)
                ).strip()
            except Exception as exc:  # noqa: BLE001
                send({"id": command.get("id"), "text": "", "error": str(exc)[:200]})
                continue
            send({"id": command.get("id"), "text": repair(text, glossary, fixer)})
            continue

        if name == "tidy":
            text, ok = tidy(command.get("text", ""), command.get("level", "structure"))
            # Модель охотно роняет аббревиатуры в нижний регистр: «ЦОК» -> «цок».
            send({"id": command.get("id"),
                  "text": repair(text, glossary, fixer), "ok": ok})
            continue

    return 0


if __name__ == "__main__":
    sys.exit(main())
