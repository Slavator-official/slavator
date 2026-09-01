"""Восстановление терминов и аббревиатур по словарю команды.

Задача, которую не решает ни один распознаватель: в записи звучит «си джей
эм», а в стенограмме должно быть «CJM». Модель физически не может этого
знать - она слышит звуки, а не то, как ваша команда пишет свои сокращения.

Здесь это чинится детерминированно, без нейросетей:

  1. для каждого термина из словаря строятся вероятные звучания
     («CJM» -> «си джей эм», «си джи эм», «сиджеем», ...);
  2. по стенограмме идёт скользящее окно из 1-4 слов;
  3. окно сравнивается со звучаниями; при достаточном сходстве
     подставляется каноническое написание из словаря.

Почему не отдать это языковой модели: она справляется с очевидными
случаями, но незаметно переписывает формулировки и путает похожие термины.
Детерминированная замена по словарю предсказуема и проверяема, а модель
подключается уже после неё - подчистить остатки.
"""
import re
import unicodedata
from difflib import SequenceMatcher
from typing import Dict, List, Sequence, Tuple

# Как в русской речи называют латинские буквы. Первый вариант - основной,
# остальные встречаются у разных людей и в разном темпе речи.
LETTER_NAMES: Dict[str, Tuple[str, ...]] = {
    "a": ("эй", "а"),
    "b": ("би", "бэ"),
    "c": ("си", "цэ", "ц"),
    "d": ("ди", "дэ"),
    "e": ("и", "е", "э"),
    "f": ("эф",),
    "g": ("джи", "гэ"),
    "h": ("эйч", "аш", "ха"),
    "i": ("ай", "и"),
    "j": ("джей", "джи", "йот"),
    "k": ("кей", "ка"),
    "l": ("эль", "эл"),
    "m": ("эм",),
    "n": ("эн",),
    "o": ("оу", "о"),
    "p": ("пи", "пэ"),
    "q": ("кью", "ку"),
    "r": ("ар", "эр"),
    "s": ("эс",),
    "t": ("ти", "тэ"),
    "u": ("ю", "у"),
    "v": ("ви", "вэ"),
    "w": ("дабл ю", "дабликс", "ве"),
    "x": ("икс",),
    "y": ("уай", "игрек"),
    "z": ("зед", "зет", "зи"),
}

# Русские буквы в аббревиатурах читают по алфавитным именам.
RU_LETTER_NAMES: Dict[str, Tuple[str, ...]] = {
    "б": ("бэ",), "в": ("вэ",), "г": ("гэ",), "д": ("дэ",), "ж": ("жэ",),
    "з": ("зэ",), "к": ("ка",), "л": ("эль",), "м": ("эм",), "н": ("эн",),
    "п": ("пэ",), "р": ("эр",), "с": ("эс",), "т": ("тэ",), "ф": ("эф",),
    "х": ("ха",), "ц": ("цэ",), "ч": ("че",), "ш": ("ша",), "щ": ("ща",),
}

# Насколько похожим должно быть окно, чтобы считать его термином.
DEFAULT_RATIO = 0.86
# Для однословных терминов планка выше: короткие слова легко спутать.
SHORT_RATIO = 0.90
# Отдельная, более мягкая планка для слов, записанных ЗАГЛАВНЫМИ. Если
# распознаватель написал слово капсом, он сам считает его аббревиатурой -
# остаётся выбрать подходящую из словаря. Так «СОК» становится «ЦОК»:
# буква расслышана неверно, но что это аббревиатура - понято верно.
CAPS_RATIO = 0.60


def normalize(text: str) -> str:
    """Свести написание к сравнимому виду: регистр, ё, знаки, пробелы."""
    text = unicodedata.normalize("NFKC", text).casefold().replace("ё", "е")
    text = re.sub(r"[^\w\s]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def spoken_forms(term: str) -> List[str]:
    """Вероятные звучания термина в русской речи."""
    forms = {normalize(term)}
    compact = re.sub(r"[^A-Za-zА-Яа-я0-9]", "", term)

    # Аббревиатура целиком заглавными - её произносят по буквам.
    if compact and compact.upper() == compact and len(compact) <= 6:
        per_letter: List[Tuple[str, ...]] = []
        for char in compact.lower():
            if char in LETTER_NAMES:
                per_letter.append(LETTER_NAMES[char])
            elif char in RU_LETTER_NAMES:
                per_letter.append(RU_LETTER_NAMES[char])
            else:
                per_letter = []
                break

        if per_letter:
            # Основной вариант и вариант со вторыми чтениями букв: полный
            # перебор дал бы сотни строк на ровном месте.
            primary = " ".join(names[0] for names in per_letter)
            forms.add(primary)
            forms.add(primary.replace(" ", ""))
            if any(len(names) > 1 for names in per_letter):
                alt = " ".join(names[1] if len(names) > 1 else names[0] for names in per_letter)
                forms.add(alt)
                forms.add(alt.replace(" ", ""))

        # Русские аббревиатуры часто читают как слово: «ЦОК» -> «цок».
        if re.fullmatch(r"[А-Яа-я]+", compact):
            forms.add(normalize(compact))

    return [f for f in forms if f]


def is_acronym(term: str) -> bool:
    """Аббревиатура ли это.

    Граница важна: аббревиатуры не склоняются, поэтому их можно подставлять
    по приблизительному совпадению. Обычные слова склоняются, и подстановка
    словарной формы вместо «бэклогу» испортила бы падеж.
    """
    compact = re.sub(r"[^A-Za-zА-Яа-я0-9]", "", term)
    return bool(compact) and compact.upper() == compact and len(compact) <= 6


def build_index(glossary: Sequence[str]) -> List[Tuple[str, str, int, bool]]:
    """Список (звучание, каноническое написание, длина в словах, аббревиатура)."""
    index: List[Tuple[str, str, int, bool]] = []
    for term in glossary:
        term = term.strip()
        if not term:
            continue
        acronym = is_acronym(term)
        for form in spoken_forms(term):
            index.append((form, term, len(form.split()), acronym))
    # Длинные звучания проверяем первыми: «эм ви пи» важнее, чем «пи».
    index.sort(key=lambda item: (-item[2], -len(item[0])))
    return index


def _similar(a: str, b: str) -> float:
    return SequenceMatcher(None, a, b).ratio()


def repair_text(text: str, index: Sequence[Tuple[str, str, int, bool]],
                max_window: int = 4) -> Tuple[str, int]:
    """Вернуть текст с восстановленными терминами и число замен."""
    if not text.strip() or not index:
        return text, 0

    tokens = text.split()
    out: List[str] = []
    fixed = 0
    position = 0

    while position < len(tokens):
        matched = False
        # Длинные окна вперёд: иначе «эм» подменится раньше, чем «эм ви пи».
        for size in range(min(max_window, len(tokens) - position), 0, -1):
            window = tokens[position:position + size]
            probe = normalize(" ".join(window))
            if not probe:
                continue

            for form, canonical, words, acronym in index:
                if words != size:
                    continue

                if probe == form:
                    pass  # точное попадание
                elif not acronym:
                    # Обычное слово трогаем только при точном совпадении:
                    # приблизительная замена сломала бы падеж.
                    continue
                else:
                    raw = " ".join(window).strip(".,!?;:—-")
                    shouty = len(raw) >= 2 and raw.upper() == raw and raw.lower() != raw
                    ratio = _similar(probe, form)

                    if shouty:
                        # Слово написано капсом: сверяем со словарём мягче,
                        # но требуем сопоставимой длины, чтобы «ЦОК» не
                        # притянулся к «CJM».
                        if ratio < CAPS_RATIO or abs(len(probe) - len(form)) > 1:
                            continue
                    else:
                        threshold = SHORT_RATIO if size == 1 else DEFAULT_RATIO
                        if ratio < threshold:
                            continue
                        # Короткие слова легко «дотягиваются» случайно.
                        if size == 1 and min(len(probe), len(form)) <= 3:
                            continue

                # Уже написано ровно как в словаре - менять нечего.
                if window[-1].rstrip(".,!?;:") == canonical or (
                    size == 1 and window[0].rstrip(".,!?;:") == canonical
                ):
                    break

                # Хвостовая пунктуация исходного текста сохраняется.
                tail = re.search(r"[^\w\s]+$", window[-1])
                out.append(canonical + (tail.group(0) if tail else ""))
                fixed += 1
                position += size
                matched = True
                break
            if matched:
                break

        if not matched:
            out.append(tokens[position])
            position += 1

    return " ".join(out), fixed


def repair(utterances, glossary: Sequence[str]) -> int:
    """Починить термины во всех репликах. Возвращает число замен."""
    index = build_index(glossary)
    if not index:
        return 0
    total = 0
    for item in utterances:
        text, fixed = repair_text(item.text, index)
        if fixed:
            item.text = text
            total += fixed
    return total
