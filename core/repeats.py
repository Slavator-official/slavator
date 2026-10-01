"""Схлопывание зацикленного текста распознавателя.

Whisper на шуме и паузах зацикливается внутри одного отрезка: «и так далее
и так далее и так далее». Ядро уже схлопывает одинаковые реплики подряд, но
повтор внутри реплики проходил насквозь — в стенограмму, в резюме и в
диктовку.

Приём взят у Meetily (whisper_engine.rs, clean_repetitive_text), только
мягче: у них слово, сказанное дважды, уже считается повтором, а «да да» и
«нет нет» в русской речи настоящие. Здесь повтором считается кусок из одного
или нескольких слов, прозвучавший три раза подряд и больше, — так живой
человек почти не говорит, а зациклившаяся модель — постоянно.
"""
import re
from typing import Any

# Сколько раз подряд должен прозвучать кусок, чтобы считаться зацикливанием.
MIN_RUNS = 3
# Самый длинный повторяющийся кусок, который ищем, в словах.
MAX_UNIT = 8


def _key(token: str) -> str:
    """Слово без регистра и знаков: «Далее,» и «далее» — одно и то же."""
    return re.sub(r"[^\w]+", "", token.casefold())


def _plan(keys: list[str]) -> tuple[list[tuple[int, int, int]], int]:
    """Где схлопывать: список (начало, длина куска, сколько раз подряд).

    Берётся самый короткий повторяющийся кусок: «да да да да» — это одно
    «да» четыре раза, а не «да да» дважды.
    """
    spans: list[tuple[int, int, int]] = []
    removed = 0
    i = 0
    while i < len(keys):
        found = None
        for size in range(1, MAX_UNIT + 1):
            if i + size * MIN_RUNS > len(keys):
                break
            unit = keys[i:i + size]
            if not all(unit):
                continue
            runs = 1
            while keys[i + runs * size:i + (runs + 1) * size] == unit:
                runs += 1
            if runs >= MIN_RUNS:
                found = (i, size, runs)
                break
        if found:
            spans.append(found)
            removed += (found[2] - 1) * found[1]
            i += found[1] * found[2]
        else:
            i += 1
    return spans, removed


def collapse_text(text: str) -> tuple[str, int]:
    """Схлопнуть повторы в строке. Возвращает текст и сколько слов убрано.

    От повтора остаётся первое вхождение, но знак в конце берётся у
    последнего: «и так далее, и так далее, и так далее.» — «и так далее.»
    """
    tokens = text.split()
    spans, removed = _plan([_key(token) for token in tokens])
    if not spans:
        return text, 0
    out: list[str] = []
    i = 0
    for start, size, runs in spans:
        out.extend(tokens[i:start])
        unit = tokens[start:start + size]
        last = tokens[start + size * runs - 1]
        tail = last[len(last.rstrip(".,;:!?…")):]
        unit[-1] = unit[-1].rstrip(".,;:!?…") + tail
        out.extend(unit)
        i = start + size * runs
    out.extend(tokens[i:])
    return " ".join(out), removed


def collapse_words(words: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], int]:
    """То же для слов с метками времени.

    Текст реплики ядро при разбивке по голосам собирает заново из слов, и
    схлопнутый только в строке повтор вернулся бы обратно. Остаётся первое
    вхождение целиком — с его метками, без склейки времени из разных мест.
    """
    spans, removed = _plan([_key(str(word.get("word", ""))) for word in words])
    if not spans:
        return words, 0
    out: list[dict[str, Any]] = []
    i = 0
    for start, size, runs in spans:
        out.extend(words[i:start + size])
        i = start + size * runs
    out.extend(words[i:])
    return out, removed
