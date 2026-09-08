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
import threading
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
TIDY_TIMEOUT = int(os.environ.get("SLAVATOR_TIDY_TIMEOUT", "45"))
# Короткое удержание после правки: не занимать память надолго на 8 ГБ.
KEEP_ALIVE = os.environ.get("SLAVATOR_KEEP_ALIVE", "1m")


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
    "Ты редактор устной речи. Тебе дают расшифровку сказанного вслух — с\n"
    "паразитами, оговорками и рваным порядком слов.\n\n"
    "Всегда, на любом уровне правки:\n"
    "1. Убери слова-паразиты и заполнители пауз: ну, вот, так, значит, э-э,\n"
    "   как бы, типа, короче, в общем, собственно, скажем так.\n"
    "2. Убери повторы и самоперебивы: из «надо это, надо созвон перенести»\n"
    "   остаётся «надо перенести созвон».\n"
    "3. ГЛАВНОЕ: после выброшенных слов согласуй фразу заново — падежи,\n"
    "   окончания, предлоги, порядок слов. Читатель не должен догадываться,\n"
    "   что здесь что-то убрали. Обрубок вроде «перенести созвон среду» —\n"
    "   это брак, правильно «перенести созвон на среду».\n"
    "4. Расставь знаки препинания и заглавные буквы, раздели на предложения.\n"
    "5. Ничего не выдумывай: ни фактов, ни имён, ни цифр, которых не было.\n"
    "6. Отвечай на языке говорящего.\n"
)
_TAIL = (
    "\n\nОтвечай ТОЛЬКО готовым текстом: без пояснений, без вступлений, "
    "без кавычек вокруг ответа."
)

LEVELS = {
    # Бережная правка: слова человека остаются его словами.
    "clean": _COMMON + (
        "\nУровень правки — бережный. Формулировки и порядок мыслей оставь "
        "как есть, ничего не сокращай и не переписывай. Твоя работа — убрать "
        "мусор и починить согласование.\n\n"
        "Пример.\n"
        "Вход: ну э-э я вчера созванивался с этими, с подрядчиками, и они "
        "сказали что сроки они сдвигают на неделю\n"
        "Выход: Вчера я созванивался с подрядчиками. Они сказали, что "
        "сдвигают сроки на неделю."
    ) + _TAIL,
    "structure": _COMMON + (
        "\nДополнительно: если человек перечислял три пункта и больше, оформи "
        "перечисление списком — каждый пункт с новой строки и дефиса, пункты "
        "в одной грамматической форме. Если перечисления не было, список не "
        "выдумывай: обычный связный текст. Смысл и формулировки сохрани.\n\n"
        "Пример.\n"
        "Вход: значит нам нужно это самое макеты доделать ну и текст "
        "написать и вот ещё созвон назначить на среду\n"
        "Выход: Нужно:\n"
        "- доделать макеты;\n"
        "- написать текст;\n"
        "- назначить созвон на среду."
    ) + _TAIL,
    # «Пиши, сокращай»: сильная правка, но без вранья и без отсебятины.
    "shrink": _COMMON + (
        "\nУровень правки — сильный, по принципам «Пиши, сокращай»:\n"
        "- выброси стоп-слова: усилители (очень, крайне, максимально), "
        "оценки (замечательный, эффективный), вводные (на самом деле, "
        "как известно, хотелось бы отметить);\n"
        "- канцелярит замени человеческими словами: «осуществить звонок» — "
        "«позвонить», «в связи с тем что» — «потому что»;\n"
        "- отглагольные существительные верни в глаголы: «принять решение о "
        "переносе» — «перенести»;\n"
        "- страдательный залог замени действительным: «работа была сделана "
        "командой» — «команда сделала работу»;\n"
        "- убери всё, без чего смысл не меняется.\n"
        "Смысл сохрани полностью. Сокращать — не значит терять факты: даты, "
        "числа, имена и договорённости остаются все до одной.\n\n"
        "Пример.\n"
        "Вход: ну в общем хотелось бы отметить что нами было принято решение "
        "о переносе созвона на среду в связи с тем что макеты пока не готовы\n"
        "Выход: Переносим созвон на среду: макеты не готовы."
    ) + _TAIL,
}


def warm() -> None:
    """Заранее поднять языковую модель в память.

    Первая правка после запуска уходила в тайм-аут: модель грузится секунды,
    а человек в это время ждёт свой текст и видит, что «не сработало».
    Отправляем пустяковый запрос сразу, пока никто не ждёт.
    """
    payload = {
        "model": OLLAMA_MODEL, "stream": False, "think": False,
        "keep_alive": KEEP_ALIVE,
        "messages": [{"role": "user", "content": "ок"}],
    }
    request = urllib.request.Request(
        f"{OLLAMA}/api/chat",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIDY_TIMEOUT):
            pass
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        pass          # нет Ollama — узнаем об этом в свой срок, при правке


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
        "keep_alive": KEEP_ALIVE,
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

    # Прогрев в стороне: он не должен задерживать готовность диктовки.
    # Warm only when the user requests tidy mode; conserve RAM.

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

        if name == "warm":
            # Ответа не ждём: прогрев идёт в стороне, пока человек говорит.
            threading.Thread(target=warm, daemon=True).start()
            send({"id": command.get("id"), "text": "", "ok": True})
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
