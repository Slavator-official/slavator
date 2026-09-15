#!/usr/bin/env python3
"""Meeting Transcriber - ядро обработки встреч (v25.1, полная перезапись).

Локальный офлайн-пайплайн:

    видео/аудио -> PyAV            -> WAV 16 kHz mono
                -> faster-whisper  -> распознавание речи
                -> sherpa-onnx     -> диаризация + эмбеддинги голосов
                -> сведение        -> стенограмма С МЕТКАМИ СПИКЕРОВ
                -> Ollama          -> summary, решения, поручения
                -> DOCX + mindmap

Запуск:
    python meeting_transcriber_v25_1.py <файл записи>

Контракт с GUI v25.10 (нельзя менять без правки speaker_service):
  * результат          -> <stem>_result/ рядом с исходным файлом;
  * неопознанные голоса-> <stem>_result/<EXTRA>/Новые спикеры/*.wav;
  * профили спикеров   -> ~/whisper-work/speaker_profiles/profiles.json;
  * модуль экспортирует save_speaker_profile(...) для регистрации человека из GUI.

ВАЖНО: GUI загружает этот модуль через importlib только ради
save_speaker_profile(), поэтому на верхнем уровне разрешена ТОЛЬКО
стандартная библиотека. Любой тяжёлый импорт (sherpa_onnx, faster_whisper,
numpy, docx) выполняется лениво внутри функций.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
import wave
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable, Optional, Sequence, Tuple, Union

def _read_version() -> str:
    """Версия одна на весь проект и лежит в файле VERSION в корне.

    Раньше их было две — «25.1» в ядре и «25.10» в манифесте приложения, — и
    понять по номеру, что у человека установлено, было нельзя.
    """
    for parent in (Path(__file__).resolve().parent, Path(__file__).resolve().parent.parent):
        candidate = parent / "VERSION"
        if candidate.is_file():
            try:
                return candidate.read_text(encoding="utf-8").strip()
            except OSError:
                break
    return "0.0.0-dev"


APP_VERSION = os.environ.get("SLAVATOR_VERSION") or _read_version()

# --------------------------------------------------------------------------
# Конфигурация. Всё переопределяется переменными окружения, чтобы GUI и
# install-скрипт могли настроить пайплайн без правки кода.
# --------------------------------------------------------------------------

SAMPLE_RATE = 16000

# Движок распознавания: gigaam (лучше на русском) или faster-whisper
# (универсальнее на смешанных ru/en записях).
# faster-whisper по умолчанию: он единственный сохраняет латиницу, цифры и
# пунктуацию. У ONNX-сборки GigaAM словарь из 34 строчных кириллических
# символов, поэтому «CJM» превратится в «си джей эм» - для встреч с
# англицизмами и аббревиатурами это не годится. GigaAM оставлен как вариант
# для записей на чистом русском: он заметно быстрее и точнее на них.
ASR_ENGINE = os.environ.get("MEETING_TRANSCRIBER_ASR", "faster-whisper").strip().lower()

# Словарь домена: аббревиатуры, названия проектов, англицизмы. Одна строка -
# один термин. Ни одна ASR-модель не знает «ЦОК» или «CJM», поэтому термины
# подсказываются распознавателю и выправляются после него.
GLOSSARY_PATH = Path(
    os.environ.get(
        "MEETING_TRANSCRIBER_GLOSSARY", str(Path.home() / "whisper-work" / "glossary.txt")
    )
).expanduser()
# Сверка терминов языковой моделью по умолчанию ВЫКЛЮЧЕНА.
#
# Замер: один запрос на 60 строк не укладывается и в десять минут даже с
# выключенными размышлениями — модель обязана выдать все строки заново в
# JSON, а это больше тысячи токенов на локальной модели. На стенограмме в
# 120 реплик шаг гарантированно отваливается по времени и пропускается,
# то есть даёт ноль пользы за минуты ожидания.
#
# Аббревиатуры при этом никуда не деваются: их чинит мгновенный
# детерминированный проход по словарю (glossary_fix), он остаётся включён
# всегда. Включить проход моделью: MEETING_TRANSCRIBER_NORMALIZE=1
NORMALIZE_TERMS = os.environ.get("MEETING_TRANSCRIBER_NORMALIZE", "0") not in ("0", "", "false", "no")

# Определение имён участников по ходу разговора: обращения по имени,
# самопредставления, упоминания в третьем лице. Ниже порога имя не
# подставляется автоматически, а предлагается пользователю в интерфейсе.
INFER_NAMES = os.environ.get("MEETING_TRANSCRIBER_INFER_NAMES", "1") not in ("0", "false", "no")
NAME_CONFIDENCE = float(os.environ.get("MEETING_TRANSCRIBER_NAME_CONFIDENCE", "0.75"))

WHISPER_MODEL = os.environ.get("MEETING_TRANSCRIBER_WHISPER_MODEL", "large-v3")
WHISPER_THREADS = max(1, min(16, int(os.environ.get("MEETING_TRANSCRIBER_CPU_THREADS", "4"))))
# Детектор речи включён. Он пропускает тишину мимо модели, а её на встрече
# около половины: замер на 180 секундах реального разговора дал 384 секунды
# счёта против 670 без него — почти вдвое быстрее при том же тексте
# (359 распознанных слов против 357).
#
# Раньше он был выключен, потому что выбрасывал до 80% реплик. Дело было не в
# самом детекторе, а в его пороге: со стандартным 0.5 тихий собеседник из
# динамиков не считался речью вовсе. Параметры ниже — мягкие, см. VAD_OPTIONS.
USE_VAD = os.environ.get("MEETING_TRANSCRIBER_VAD", "1") not in ("0", "", "false", "no")

# Порог намеренно вдвое ниже стандартного: на записи звонка речь приходит из
# динамиков, она тише живого голоса рядом с микрофоном. Отступы по краям и
# длинная пауза перед разрезом берегут начала и концы фраз - именно они
# терялись, когда детектор отключали.
VAD_OPTIONS = {
    "threshold": float(os.environ.get("MEETING_TRANSCRIBER_VAD_THRESHOLD", "0.25")),
    "min_silence_duration_ms": 700,
    "speech_pad_ms": 400,
}
WHISPER_COMPUTE = os.environ.get("MEETING_TRANSCRIBER_WHISPER_COMPUTE", "int8")
WHISPER_DEVICE = os.environ.get("MEETING_TRANSCRIBER_WHISPER_DEVICE", "cpu")
WHISPER_LANGUAGE = os.environ.get("MEETING_TRANSCRIBER_LANGUAGE", "ru")
WHISPER_BEAM = int(os.environ.get("MEETING_TRANSCRIBER_WHISPER_BEAM", "5"))

# Разделение по голосам работает на sherpa-onnx: те же модели, но в
# открытых ONNX-сборках. Прежний путь через pyannote требовал от каждого
# пользователя аккаунт на HuggingFace, токен и принятие условий двух моделей -
# для программы, которую передают коллеге одним файлом, это неприемлемо.
# Заодно ушёл torch: установка сократилась примерно с 3 ГБ до 250 МБ.
# Порог выверен на настоящей встрече с известным составом: четверо, двое
# говорят помногу, один почти молчит. Замер на всех 32 минутах записи:
#
#   0.45 (было) - 26 голосов, из них существенных 6
#   0.62        - 11 голосов, существенных 4: 11.1, 9.6, 3.6, 1.5 мин
#   0.74        -  6 голосов, существенных 4, но на другом материале
#                  склеивал пятерых в двоих
#
# Выбран 0.62, а не более чистый 0.74, намеренно: он ошибается в сторону
# дробления. Склеить двух разных людей необратимо, а разделённого человека
# пользователь собирает обратно двумя щелчками на экране «Новые голоса».
DIARIZATION_THRESHOLD = float(os.environ.get("MEETING_TRANSCRIBER_DIARIZATION_THRESHOLD", "0.62"))
# Порог автоматического объединения голосов. Намеренно высокий.
#
# Ошибки здесь несимметричны: разделённого человека пользователь сольёт
# руками на экране «Новые голоса», а вот склеенных разных людей разделить
# уже нечем - в стенограмме они навсегда останутся одним. Поэтому объединяем
# только при почти полном совпадении отпечатков, а остальное оставляем
# человеку.
MERGE_THRESHOLD = float(os.environ.get("MEETING_TRANSCRIBER_MERGE_THRESHOLD", "0.95"))
# Голос, говоривший меньше этого, не объединяем: отпечаток на коротком
# фрагменте неустойчив и легко совпадает с кем угодно.
MERGE_MIN_SPEECH = float(os.environ.get("MEETING_TRANSCRIBER_MERGE_MIN_SPEECH", "8.0"))
# Сегментация отдаёт речь мелкой крошкой: медиана отрезка около секунды, треть
# короче. Соседние куски одного голоса склеиваем обратно во фразу.
# Зазор подобран замером на двух часовых записях: до секунды склейка
# возвращает речь, дальше выигрыш почти исчезает, а во фрагменты начинает
# набираться тишина вместо голоса.
TURN_JOIN_GAP = float(os.environ.get("MEETING_TRANSCRIBER_TURN_JOIN_GAP", "1.0"))
TURN_MIN = float(os.environ.get("MEETING_TRANSCRIBER_TURN_MIN", "0.4"))
# Голос, набравший пару секунд за всю запись, - почти всегда шум кластеризации.
# Предлагать его к опознанию бессмысленно: и отпечаток по нему недостоверен,
# и человеку разбирать десятки таких карточек невозможно.
UNKNOWN_MIN_SPEECH = float(os.environ.get("MEETING_TRANSCRIBER_UNKNOWN_MIN_SPEECH", "5.0"))
# Сколько секунд голоса класть в образец для прослушивания и опознания.
SAMPLE_TARGET = float(os.environ.get("MEETING_TRANSCRIBER_SAMPLE_TARGET", "8.0"))
NUM_SPEAKERS = int(os.environ.get("MEETING_TRANSCRIBER_NUM_SPEAKERS", "-1"))

# Порог косинусной близости для признания голоса «знакомым».
#
# 0.90 получен измерением на 22 образцах семи реальных людей: у одного и того
# же человека близость лежит в 0.826-0.977, у разных доходит до 0.914. Прежнее
# значение 0.60 досталось от эмбеддингов pyannote и для WeSpeaker означало бы,
# что 176 чужих пар из 195 признаются одним человеком - то есть все участники
# встречи схлопывались бы в одного.
VOICE_THRESHOLD = float(os.environ.get("MEETING_TRANSCRIBER_VOICE_THRESHOLD", "0.90"))
# Одного порога мало: лучший кандидат должен ещё и заметно опережать второго.
# На тех же данных верное совпадение опережало следующее минимум на 0.050.
VOICE_MARGIN = float(os.environ.get("MEETING_TRANSCRIBER_VOICE_MARGIN", "0.03"))
# Сколько образцов нужно карточке, чтобы подписывать голос её именем без
# спроса. Отпечаток из одного образца — это один микрофон и один день: запись
# 15.09 с голосом Славы через наушники оказалась ближе к единственному образцу
# Мигалина (0.83), чем к шести образцам самого Славы (0.67), и 88% встречи
# было подписано чужим именем. Такое совпадение предлагаем, а не применяем.
MIN_PROFILE_SAMPLES = int(os.environ.get("MEETING_TRANSCRIBER_MIN_PROFILE_SAMPLES", "2"))
# Эмбеддинг с короткого фрагмента нестабилен, поэтому есть нижняя граница.
MIN_EMBED_SECONDS = 0.8
# Длина WAV-образца для неопознанного голоса, который увидит пользователь в GUI.
SNIPPET_SECONDS = 10.0

OLLAMA_HOST = os.environ.get("MEETING_TRANSCRIBER_OLLAMA_HOST", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.environ.get("MEETING_TRANSCRIBER_LLM", "qwen3:8b")
OLLAMA_NUM_CTX = int(os.environ.get("MEETING_TRANSCRIBER_NUM_CTX", "8192"))
OLLAMA_TIMEOUT = int(os.environ.get("MEETING_TRANSCRIBER_LLM_TIMEOUT", "600"))
# Сверка терминов делает десятки обращений подряд, поэтому ждёт каждое
# заметно меньше, чем разовые запросы, и ограничена по общему времени.
NORMALIZE_REQUEST_TIMEOUT = int(
    os.environ.get("MEETING_TRANSCRIBER_NORMALIZE_TIMEOUT", "120"))
NORMALIZE_BUDGET = float(
    os.environ.get("MEETING_TRANSCRIBER_NORMALIZE_BUDGET", "300"))
NAMES_REQUEST_TIMEOUT = int(
    os.environ.get("MEETING_TRANSCRIBER_NAMES_TIMEOUT", "180"))
# Размышления модели вслух: качественнее, но в разы дольше. По умолчанию
# выключены — см. пояснение в ollama_chat.
THINK_ALOUD = os.environ.get("MEETING_TRANSCRIBER_LLM_THINK", "0") not in ("0", "", "false", "no")

DEFAULT_PROFILES_DIR = Path(
    os.environ.get(
        "MEETING_TRANSCRIBER_PROFILES", str(Path.home() / "whisper-work" / "speaker_profiles")
    )
).expanduser()

# Имена каталогов/файлов - часть контракта с speaker_service. Не переименовывать.
EXTRA_DIR_NAME = "доп файлы, на случай ошибки summary"
UNKNOWN_DIR_NAME = "Новые спикеры"

TRANSCRIPT_DOCX = "01_transcript.docx"
SUMMARY_DOCX = "02_summary_todo.docx"
MINDMAP_MD = "03_mindmap.md"
TRANSCRIPT_JSON = "transcript.json"
MEETING_JSON = "meeting.json"

# Типы встреч заданы списком и не пополняются моделью. Свободная формулировка
# через месяц даёт «техническая», «техвстреча» и «тех. созвон» как три разных
# типа, и группировать становится нечем.
MEETING_TYPES = ("техническая", "продуктовая", "планёрка", "один-на-один",
                 "клиентская", "исследование", "ретроспектива", "другое")

STAGES = [
    ("prepare", "Подготовка"),
    ("audio", "Извлечение аудио"),
    ("asr", "Распознавание речи"),
    ("quality", "Проверка качества расшифровки"),
    ("diarization", "Разделение на спикеров"),
    ("identify", "Опознание голосов"),
    ("names", "Определение имён по контексту"),
    ("transcript", "Сборка стенограммы"),
    ("summary", "Анализ встречи"),
    ("documents", "Формирование документов"),
]


# --------------------------------------------------------------------------
# Ошибки. Классификация нужна, чтобы GUI показывал пользователю понятный
# текст, а технические детали уходили только в лог (TD-11 из аудита).
# --------------------------------------------------------------------------


class PipelineError(Exception):
    """Ошибка с текстом, который не стыдно показать пользователю."""

    user_message = "Не удалось обработать запись."

    def __init__(self, message: str, hint: str = ""):
        super().__init__(message)
        self.hint = hint


class DependencyError(PipelineError):
    user_message = "Не хватает компонентов для обработки."


class InputError(PipelineError):
    user_message = "Проблема с исходным файлом."


class TranscriptionError(PipelineError):
    user_message = "Распознавание речи не дало пригодного результата."


class DiarizationError(PipelineError):
    user_message = "Не удалось разделить запись на спикеров."


class LLMError(PipelineError):
    user_message = "Локальная модель не смогла подготовить резюме встречи."


class SecurityError(PipelineError):
    user_message = "Обнаружены некорректные данные профиля спикера."


# --------------------------------------------------------------------------
# Лог и прогресс. GUI читает stdout построчно, поэтому пишем без буферизации:
# человекочитаемые строки + машиночитаемые @@PROGRESS@@, которые интерфейс
# может разобрать, чтобы показать прогресс вместо неподвижного окна.
# --------------------------------------------------------------------------


def speak_utf8() -> None:
    """Весь вывод — в utf-8, какой бы ни была кодовая страница системы.

    На Windows с некириллической страницей ядро падало на первом же русском
    слове: print уходил в cp1252 и обрывался UnicodeEncodeError посреди
    работы. Интерфейс читает этот поток как utf-8, сборка — тоже. Под
    pythonw потоков может не быть вовсе, поэтому ошибки здесь не страшны.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass


def log(message: str) -> None:
    print(message, flush=True)


def warn(message: str) -> None:
    print(f"[!] {message}", flush=True)


def progress(stage: str, pct: float, detail: str = "") -> None:
    index = next((i for i, (key, _) in enumerate(STAGES) if key == stage), 0)
    payload = {
        "stage": stage,
        "step": index + 1,
        "steps": len(STAGES),
        "pct": round(max(0.0, min(100.0, pct)), 1),
        "detail": detail,
    }
    print("@@PROGRESS@@ " + json.dumps(payload, ensure_ascii=False), flush=True)


def stage_start(stage: str) -> None:
    index = next((i for i, (key, _) in enumerate(STAGES) if key == stage), 0)
    title = next((name for key, name in STAGES if key == stage), stage)
    log(f"[{index + 1}/{len(STAGES)}] {title}...")
    progress(stage, index / len(STAGES) * 100)


def stage_pct(stage: str, fraction: float, detail: str = "") -> None:
    """Прогресс внутри этапа, пересчитанный в общий прогресс пайплайна."""
    index = next((i for i, (key, _) in enumerate(STAGES) if key == stage), 0)
    span = 100.0 / len(STAGES)
    progress(stage, index * span + span * max(0.0, min(1.0, fraction)), detail)


# --------------------------------------------------------------------------
# Модели данных
# --------------------------------------------------------------------------


@dataclass
class Utterance:
    start: float
    end: float
    text: str
    speaker_id: str = ""          # SPEAKER_00 из диаризации
    speaker_name: str = ""        # человеческое имя, если голос опознан
    confidence: float = 0.0
    words: list[dict[str, Any]] = field(default_factory=list)

    @property
    def label(self) -> str:
        return self.speaker_name or self.speaker_id or "Неизвестный"


@dataclass
class SpeakerMatch:
    speaker_id: str
    profile_key: str = ""
    name: str = ""
    similarity: float = 0.0
    total_speech: float = 0.0
    best_segment: Optional[Tuple[float, float]] = None
    # На кого голос похож, если имя не применено: карточке не хватило
    # образцов. Уходит в подсказку «по голосу», решает человек.
    voice_guess: str = ""

    @property
    def known(self) -> bool:
        return bool(self.profile_key)


@dataclass
class RunPaths:
    source: Path
    out_dir: Path
    extra_dir: Path
    unknown_dir: Path
    work_dir: Path
    wav: Path
    archived_from: Optional[Path] = None


@dataclass
class RunState:
    paths: RunPaths
    duration: float = 0.0
    utterances: list[Utterance] = field(default_factory=list)
    matches: list[SpeakerMatch] = field(default_factory=list)
    analysis: dict[str, Any] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)
    name_hints: dict[str, Any] = field(default_factory=dict)


# --------------------------------------------------------------------------
# Ленивые импорты. Каждый обёрнут, чтобы вместо traceback пользователь
# получал конкретную команду установки.
# --------------------------------------------------------------------------


def _local(name: str):
    """Импортировать модуль, лежащий рядом с этим файлом."""
    import importlib

    here = str(Path(__file__).resolve().parent)
    if here not in sys.path:
        sys.path.insert(0, here)
    return importlib.import_module(name)


def _engine():
    """Модуль onnx_engine рядом с этим файлом.

    Импорт отложенный и через явное дополнение sys.path: главное окно
    подгружает ядро через importlib только ради работы с профилями, и в этом
    режиме каталог ядра в sys.path не попадает.
    """
    return _local("onnx_engine")


def _require(module: str, package: str, extra: str = ""):
    try:
        return __import__(module)
    except ImportError as exc:  # pragma: no cover - зависит от окружения
        hint = f"pip install {package}"
        raise DependencyError(
            f"Не установлен компонент «{package}». {extra}".strip(), hint
        ) from exc


def _np():
    return _require("numpy", "numpy")


def _av():
    return _require("av", "av", "Он нужен для чтения видео и аудио без ffmpeg.")


def packages_missing(need_diarization: bool = True) -> list:
    """Каких библиотек не хватает. Список, а не исключение: этим же знанием
    пользуется отчёт о готовности, а он ничего не роняет."""
    checks = [("av", "av"), ("numpy", "numpy"), ("docx", "python-docx")]
    if need_diarization or ASR_ENGINE.startswith("giga"):
        checks.append(("sherpa_onnx", "sherpa-onnx"))
    if not ASR_ENGINE.startswith("giga"):
        checks.append(("faster_whisper", "faster-whisper"))

    absent = []
    for module, package in checks:
        try:
            __import__(module)
        except ImportError:
            absent.append(package)
    return absent


# --------------------------------------------------------------------------
# Проект встречи и её тип
#
# Проект решает, в какую папку ляжет результат. Ошибиться здесь дороже, чем
# не ответить: разложенная не туда встреча теряется молча, а непристроенная
# видна и ждёт одного нажатия. Поэтому модель вправе сказать «не знаю» и
# задать вопросы, а новые проекты заводит человек, не она.
# --------------------------------------------------------------------------

PROJECTS_PATH = Path(
    os.environ.get("MEETING_TRANSCRIBER_PROJECTS")
    or str(GLOSSARY_PATH.parent / "projects.json")
).expanduser()

# Ниже этого порога встреча не раскладывается, а помечается «уточнить».
PROJECT_CONFIDENCE = float(os.environ.get("MEETING_TRANSCRIBER_PROJECT_MIN", "0.65"))

CLASSIFY_SYSTEM = """Ты помощник, который относит рабочую встречу к проекту и
определяет её тип.

Тебе дают резюме встречи и список известных проектов. Реши, о каком проекте
шла речь, и выбери тип встречи.

Правила.
1. Проект выбирай из списка. Совпадение по смыслу, а не по буквам: «ЛК
   учителя» и «личный кабинет учителя» — один проект.
2. Если подходящего проекта в списке нет, но из резюме ясно, о чём речь, —
   назови новый и поставь known=false. Заводить его будет человек.
3. Если понять нельзя, поставь confidence ниже 0.3 и задай от одного до трёх
   коротких вопросов, ответы на которые решат дело. Спрашивай о том, чего
   нет в резюме, а не о том, что там уже написано.
   Догадка по общим словам запрещена: «планы», «задачи», «созвон»,
   «обсудили работу» не указывают ни на какой проект. Нет названия продукта,
   системы или задачи из проекта — значит проект неизвестен, и это честный
   ответ, а не поражение.
4. Тип встречи выбирай СТРОГО из списка: %s.
5. Ничего не выдумывай: ни проектов, которых не было в разговоре, ни фактов.

Ответ — только JSON:
{"project": "название", "known": true/false, "confidence": 0.0-1.0,
 "type": "тип из списка", "questions": ["вопрос", ...], "why": "одна фраза"}
""" % ", ".join(MEETING_TYPES)


def load_projects() -> list:
    """Список проектов: имя и синонимы, которыми его называют в речи."""
    try:
        raw = json.loads(PROJECTS_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    items = raw.get("projects", raw) if isinstance(raw, dict) else raw
    projects = []
    for item in items if isinstance(items, list) else []:
        if isinstance(item, str):
            projects.append({"name": item, "aliases": []})
        elif isinstance(item, dict) and item.get("name"):
            projects.append({"name": str(item["name"]),
                             "aliases": [str(a) for a in item.get("aliases", [])]})
    return projects


def classify_meeting(analysis: dict, projects: list, notes: str = "") -> dict:
    """Определить проект и тип встречи по уже собранному резюме.

    Работаем по резюме, а не по всей стенограмме: она длиннее контекста
    модели, а темы, решения и заголовок уже вытянуты из неё на прошлом шаге.
    """
    known_list = "\n".join(
        f"- {p['name']}" + (f" (он же: {', '.join(p['aliases'])})" if p["aliases"] else "")
        for p in projects
    ) or "(список пуст)"

    card = {
        "title": analysis.get("title", ""),
        "summary": analysis.get("summary", ""),
        "topics": analysis.get("topics", [])[:12],
        "decisions": analysis.get("decisions", [])[:12],
        "participants": analysis.get("participants", [])[:12],
    }
    user = (f"Известные проекты:\n{known_list}\n\n"
            f"Резюме встречи:\n{json.dumps(card, ensure_ascii=False, indent=2)}")
    if notes.strip():
        # Ответы человека весомее резюме: он был на встрече, а модель нет.
        user += ("\n\nЧеловек ответил на твои вопросы. Это достоверно, верь "
                 f"этому больше, чем резюме:\n{notes.strip()}")
        card["уточнения"] = notes.strip()

    try:
        raw = ollama_chat(CLASSIFY_SYSTEM, user, json_mode=True, timeout=180)
        answer = parse_json_response(raw)
    except (LLMError, PipelineError, ValueError) as exc:
        warn(f"Проект определить не удалось: {exc}")
        return {"needs_review": True, "questions": [], "error": str(exc)}

    name = str(answer.get("project", "")).strip()
    kind = str(answer.get("type", "")).strip().lower()
    if kind not in MEETING_TYPES:
        kind = "другое"
    try:
        confidence = float(answer.get("confidence", 0))
    except (TypeError, ValueError):
        confidence = 0.0

    # Совпадение с известным проектом проверяем сами: модель охотно
    # соглашается, что придуманное ею название «уже есть в списке».
    known = None
    for project in projects:
        variants = [project["name"]] + project["aliases"]
        if any(v.strip().lower() == name.lower() for v in variants if v.strip()):
            known = project["name"]
            break

    questions = [str(q).strip() for q in answer.get("questions", []) if str(q).strip()][:3]

    # Проверка поверх ответа модели: проект должен быть на самом деле назван
    # в резюме. На пустом «созвоне о планах» модель уверенно выдавала первый
    # проект из списка с confidence 0,9 — такая встреча молча уехала бы не в
    # ту папку, а найти её потом некому.
    mentioned = _mentions(known or name, projects, card)
    if known is not None and not mentioned:
        confidence = min(confidence, 0.3)
        if not questions:
            questions = [f"Это встреча по проекту «{known}»? В резюме он прямо не назван."]

    settled = known is not None and mentioned and confidence >= PROJECT_CONFIDENCE

    return {
        "project": known or name,
        "known": known is not None,
        "confidence": round(confidence, 2),
        "type": kind,
        "why": str(answer.get("why", "")).strip(),
        "questions": questions,
        # Пока встреча не пристроена, она ждёт человека — и видно, чего ждёт.
        "needs_review": not settled,
    }


def _mentions(project: str, projects: list, card: dict) -> bool:
    """Назван ли проект в самом резюме, а не только в ответе модели.

    Сверяем по корням слов: «кабинет учителя» должно узнаваться и в «кабинета
    учителю». Точное совпадение здесь бесполезно — русский текст склоняется.
    """
    text = json.dumps(card, ensure_ascii=False).lower()
    variants = [project]
    for item in projects:
        if item["name"] == project:
            variants += item["aliases"]
    for variant in variants:
        words = [w[:5] for w in re.findall(r"\w{4,}", variant.lower())]
        if not words:
            continue
        hits = sum(1 for w in words if w in text)
        if hits and hits >= (len(words) + 1) // 2:
            return True
    return False


def move_to_project(out_dir: Path, project: str, previous: str = "") -> Path:
    """Переложить готовый результат в папку проекта.

    Переносим в самом конце, когда всё записано: перенос — это переименование
    каталога, оно мгновенно и не оставляет полурезультата, если что-то пойдёт
    не так раньше.

    Проект могут поменять — тогда встреча уже лежит в чужой папке, и класть
    новую внутрь неё нельзя: получилась бы матрёшка «Кабинет/Витрина/встреча».
    Поэтому от папки проекта поднимаемся к корню результатов.
    """
    root = out_dir.parent
    names = {folder_name(p["name"]) for p in load_projects()}
    if previous:
        names.add(folder_name(previous))
    # Поднимаемся, пока над нами папки проектов: встречу могли переносить не
    # раз, и одной ступени не хватает — вложенность копится.
    hops = 0
    while root.name in names and hops < 3 and root.parent != root:
        root = root.parent
        hops += 1

    target = root / folder_name(project)
    try:
        target.mkdir(parents=True, exist_ok=True)
        destination = target / out_dir.name
        if destination.exists():
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            destination = target / f"{out_dir.name.removesuffix('_result')}_{stamp}_result"
        old_home = out_dir.parent
        out_dir.rename(destination)
        # Опустевшая папка прежнего проекта — мусор, который человек примет
        # за живой проект. Убираем, но только если она и правда пуста.
        if old_home != root and old_home.name in names:
            try:
                old_home.rmdir()
            except OSError:
                pass
        return destination
    except OSError as exc:
        warn(f"не удалось переложить встречу в папку проекта: {exc}")
        return out_dir


def remember_project(name: str) -> None:
    """Добавить проект в список. Заводит его человек, а не модель."""
    projects = load_projects()
    if any(p["name"].strip().lower() == name.strip().lower() for p in projects):
        return
    projects.append({"name": name, "aliases": []})
    try:
        PROJECTS_PATH.parent.mkdir(parents=True, exist_ok=True)
        write_json(PROJECTS_PATH, {"projects": projects})
        log(f"    проект «{name}» добавлен в список")
    except OSError as exc:
        warn(f"не удалось сохранить список проектов: {exc}")


def assign_project(result_dir: Path, project: str, remember: bool = False) -> int:
    """Отнести встречу к проекту, названному человеком.

    Человеку не задают вопросов о его же решении: раз проект назван, встреча
    считается разобранной и сразу переезжает в его папку.
    """
    result_dir = result_dir.expanduser().resolve()
    if not (result_dir / TRANSCRIPT_JSON).is_file():
        log(f"ОШИБКА: это не каталог встречи: {result_dir}")
        return 1

    if remember:
        remember_project(project)

    try:
        card = json.loads((result_dir / MEETING_JSON).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        card = {}
    previous = str(card.get("project", ""))
    card.update({
        "project": project,
        "known": True,
        "confidence": 1.0,
        "questions": [],
        "needs_review": False,
        "why": "выбрано человеком",
    })
    card.setdefault("type", "другое")
    write_json(result_dir / MEETING_JSON, card)
    final = move_to_project(result_dir, project, previous=previous)
    log(f"Встреча отнесена к проекту «{project}»: {final}")
    return 0


def clarify_project(result_dir: Path, answers: str) -> int:
    """Переспросить модель, добавив к резюме ответы человека."""
    result_dir = result_dir.expanduser().resolve()
    analysis_path = result_dir / EXTRA_DIR_NAME / "final_analysis.json"
    try:
        analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        log("ОШИБКА: у встречи ещё нет резюме — сначала соберите его.")
        return 1

    try:
        previous = str(json.loads(
            (result_dir / MEETING_JSON).read_text(encoding="utf-8")).get("project", ""))
    except (OSError, ValueError):
        previous = ""

    card = classify_meeting(analysis, load_projects(), notes=answers)
    write_json(result_dir / MEETING_JSON, card)
    if card.get("needs_review"):
        log("Проект по-прежнему не определён.")
        for question in card.get("questions", []):
            log(f"  - {question}")
        return 0
    final = move_to_project(result_dir, card["project"], previous=previous)
    log(f"Встреча отнесена к проекту «{card['project']}»: {final}")
    return 0


def folder_name(project: str) -> str:
    """Имя папки проекта: без разделителей пути и без пустого имени."""
    cleaned = "".join(" " if ch in "/\\:" else ch for ch in project).strip()
    return cleaned or "Без проекта"


def preflight(need_llm: bool = True, need_diarization: bool = True) -> bool:
    """Проверить все зависимости разом.

    Пайплайн на длинной записи может дойти до Ollama через полчаса работы.
    Падать в этот момент из-за отсутствующего пакета недопустимо, поэтому
    всё проверяется до начала обработки.

    Возвращает True, если доступна языковая модель. Отсутствие Ollama - не
    ошибка, а частичная функциональность.
    """
    problems: list[str] = []

    for package in packages_missing(need_diarization):
        problems.append(f"  - нет пакета {package}")

    if problems:
        support_hint = (
            "%APPDATA%\\Славатор" if os.name == "nt"
            else "~/Library/Application Support/Славатор"
        )
        raise DependencyError(
            "Окружение не готово к обработке:\n" + "\n".join(problems),
            f"Переустановите окружение в {support_hint} и запустите "
            "приложение заново.",
        )

    # Ollama проверяется отдельно и мягко: без неё не будет только резюме,
    # а расшифровка и разделение по голосам работают. Ронять из-за этого
    # весь запуск - значит отнимать у пользователя работающую половину.
    if need_llm:
        ok, detail = ollama_health()
        if not ok:
            warn(f"Ollama недоступна: {detail}")
            warn("Резюме и определение имён по контексту будут пропущены.")
            return False
    return True


# --------------------------------------------------------------------------
# Аудио. PyAV несёт в себе библиотеки ffmpeg, поэтому отдельный бинарник
# ffmpeg ставить не нужно - это заметно упрощает установку на чистой машине.
# --------------------------------------------------------------------------


def _resampled(resampler, frame) -> list:
    out = resampler.resample(frame)
    if out is None:
        return []
    if isinstance(out, list):
        return out
    return [out]


def decode_to_wav16k(src: Path, dst: Path) -> float:
    """Свести любую дорожку к mono 16 kHz PCM. Возвращает длительность в секундах."""
    av = _av()
    dst.parent.mkdir(parents=True, exist_ok=True)

    written = 0
    try:
        container = av.open(str(src))
    except Exception as exc:
        raise InputError(
            f"Не удалось открыть файл «{src.name}». Возможно, формат не поддерживается "
            "или файл повреждён.",
            str(exc),
        ) from exc

    with container:
        stream = next((s for s in container.streams if s.type == "audio"), None)
        if stream is None:
            raise InputError(f"В файле «{src.name}» нет звуковой дорожки.")
        stream.thread_type = "AUTO"

        total = float(container.duration / av.time_base) if container.duration else 0.0
        resampler = av.AudioResampler(format="s16", layout="mono", rate=SAMPLE_RATE)

        with wave.open(str(dst), "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(SAMPLE_RATE)

            last_report = 0.0
            for frame in container.decode(stream):
                for chunk in _resampled(resampler, frame):
                    out.writeframes(chunk.to_ndarray().tobytes())
                    written += chunk.samples
                seconds = written / SAMPLE_RATE
                if total and seconds - last_report >= 15:
                    last_report = seconds
                    stage_pct("audio", seconds / total, f"{int(seconds)} с из {int(total)} с")
            for chunk in _resampled(resampler, None):
                out.writeframes(chunk.to_ndarray().tobytes())
                written += chunk.samples

    duration = written / SAMPLE_RATE
    if duration < 1.0:
        raise InputError(
            f"В файле «{src.name}» практически нет звука "
            f"(распознано {duration:.1f} с). Проверьте запись."
        )
    return duration


def wav_duration(path: Path) -> float:
    try:
        with wave.open(str(path), "rb") as handle:
            rate = handle.getframerate() or SAMPLE_RATE
            return handle.getnframes() / float(rate)
    except (wave.Error, OSError):
        return 0.0


def write_wav_slice(src: Path, dst: Path, start: float, end: float) -> float:
    """Вырезать фрагмент [start, end) из 16-кГц WAV. Возвращает фактическую длину."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(src), "rb") as source:
        rate = source.getframerate()
        width = source.getsampwidth()
        channels = source.getnchannels()
        total = source.getnframes()

        first = max(0, int(start * rate))
        last = min(total, int(end * rate))
        if last <= first:
            return 0.0

        source.setpos(first)
        frames = source.readframes(last - first)

    with wave.open(str(dst), "wb") as out:
        out.setnchannels(channels)
        out.setsampwidth(width)
        out.setframerate(rate)
        out.writeframes(frames)
    return (last - first) / float(rate)


# --------------------------------------------------------------------------
# Распознавание речи
# --------------------------------------------------------------------------

_whisper_model = None


def load_glossary() -> list:
    """Термины домена: аббревиатуры, названия проектов, англицизмы."""
    if not GLOSSARY_PATH.is_file():
        return []
    terms = []
    for line in GLOSSARY_PATH.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            terms.append(line)
    return terms


def whisper_model():
    """Модель грузится один раз на процесс (TD-08: не перезагружать модели)."""
    global _whisper_model
    if _whisper_model is None:
        try:
            from faster_whisper import WhisperModel
        except ImportError as exc:
            raise DependencyError(
                "Не установлен faster-whisper.", "pip install faster-whisper"
            ) from exc
        log(f"    модель {WHISPER_MODEL} ({WHISPER_DEVICE}/{WHISPER_COMPUTE})")
        _whisper_model = WhisperModel(
            cached_whisper_path() or WHISPER_MODEL, device=WHISPER_DEVICE, compute_type=WHISPER_COMPUTE,
            cpu_threads=WHISPER_THREADS, num_workers=1,
        )
    return _whisper_model


def _transcribe_gigaam(wav: Path, duration: float, glossary: list) -> list:
    """GigaAM v3 в ONNX: быстрее и точнее на чистом русском.

    Осознанное ограничение: словарь модели - 34 строчных кириллических
    символа. Латиница, цифры и пунктуация в вывод не попадут, поэтому для
    встреч с англицизмами и аббревиатурами нужен faster-whisper.
    """
    engine = _engine()
    engine.ensure_models(engine.ASR_MODELS_CTC, log=log)
    try:
        chunks = engine.transcribe_ctc(
            wav,
            progress=lambda frac, done, total: stage_pct(
                "asr", frac, f"фрагмент {done} из {total}"
            ),
        )
    except Exception as exc:
        raise TranscriptionError(
            "GigaAM не смог обработать запись.",
            f"{type(exc).__name__}: {str(exc)[:200]}",
        ) from exc

    return [
        Utterance(start=c["start"], end=c["end"], text=c["text"])
        for c in chunks if c["text"]
    ]


def _transcribe_whisper(wav: Path, duration: float, glossary: list) -> list:
    model = whisper_model()
    language = None if WHISPER_LANGUAGE in ("", "auto") else WHISPER_LANGUAGE

    # Два штатных рычага faster-whisper под доменную лексику: hotwords
    # поднимает вероятность терминов при декодировании, initial_prompt
    # задаёт стилистический контекст.
    hotwords = ", ".join(glossary[:64]) if glossary else None
    prompt = (
        "Рабочая встреча. В речи встречаются термины: " + ", ".join(glossary[:48]) + "."
        if glossary
        else None
    )

    # Детектор речи включён и настроен мягко (VAD_OPTIONS).
    #
    # Прежний замер (216 с) с ним давал одну реплику и 10 слов против 13
    # реплик и 47 слов без него - и его выключили. Причиной был стандартный
    # порог 0.5: речь из динамиков до него не дотягивала. С порогом 0.25 и
    # отступами по краям на 180 секундах разговора выходит 359 слов против
    # 357 без детектора, а счёт идёт почти вдвое быстрее.
    #
    # От выдумок на тишине защищает HALLUCINATION_PATTERNS ниже по конвейеру.
    segments, info = model.transcribe(
        str(wav),
        language=language,
        beam_size=WHISPER_BEAM,
        vad_filter=USE_VAD,
        vad_parameters=VAD_OPTIONS if USE_VAD else None,
        condition_on_previous_text=False,  # снижает зацикливание на повторах
        hotwords=hotwords,
        initial_prompt=prompt,
        # Метки по словам позволяют обрезать реплику по реальной речи, а не
        # по границе окна: без них короткая фраза растягивалась на полминуты
        # тишины и накрывала собой чужие слова при разметке говорящих.
        word_timestamps=True,
    )

    detected = getattr(info, "language", language) or "?"
    log(f"    язык: {detected}")
    total = duration or getattr(info, "duration", 0.0) or 0.0

    result = []
    for segment in segments:
        text = (segment.text or "").strip()
        if not text:
            continue
        confidence = 0.0
        if getattr(segment, "avg_logprob", None) is not None:
            # avg_logprob -> грубая вероятность, только для отображения
            confidence = float(min(1.0, max(0.0, 2 ** segment.avg_logprob)))
        # Границы берём по словам: Whisper растягивает отрезок до края окна,
        # и реплика в два слова получала полминуты длины.
        start, end = float(segment.start), float(segment.end)
        words = getattr(segment, "words", None)
        if words:
            start = float(words[0].start)
            end = float(words[-1].end)
        result.append(
            Utterance(start=start, end=end, text=text, confidence=confidence,
                      words=[{"start":float(w.start),"end":float(w.end),"word":w.word}
                             for w in (words or [])])
        )
        if total:
            stage_pct("asr", segment.end / total, f"{int(segment.end)} с из {int(total)} с")
    return result


def transcribe(wav: Path, duration: float) -> list:
    glossary = load_glossary()
    if glossary:
        log(f"    словарь домена: {len(glossary)} терминов")

    started_at = time.time()
    if ASR_ENGINE in ("gigaam", "giga", "gigaam-v3", "gigaam-onnx"):
        result = _transcribe_gigaam(wav, duration, glossary)
    elif ASR_ENGINE in ("faster-whisper", "whisper", "faster_whisper"):
        result = _transcribe_whisper(wav, duration, glossary)
    else:
        raise DependencyError(
            f"Неизвестный движок распознавания: «{ASR_ENGINE}».",
            "Допустимо: gigaam или faster-whisper",
        )

    if not result:
        raise TranscriptionError(
            "В записи не распознано ни одной реплики. "
            "Проверьте, что в файле есть разборчивая речь."
        )
    spent = time.time() - started_at
    # Время распознавания пишем всегда: это самый долгий шаг, и когда
    # обработка кажется зависшей, первым делом смотрят сюда. Отношение к
    # длине записи важнее секунд: по нему сразу видно, во сколько раз счёт
    # медленнее реального времени.
    if duration > 0:
        log(f"    распознавание заняло {spent / 60:.1f} мин "
            f"({spent / duration:.1f}x длины записи)")
    else:
        log(f"    распознавание заняло {spent / 60:.1f} мин")
    log(f"    распознано реплик: {len(result)}")
    return result


# --------------------------------------------------------------------------
# Контроль качества расшифровки. В v24 эти проверки были потеряны по
# сравнению с v20 (TD-02) - возвращаем их до того, как мусор уйдёт дальше
# в диаризацию и в LLM.
# --------------------------------------------------------------------------

HALLUCINATION_PATTERNS = [
    r"^\s*субтитры\s+(сделал|создал|подготовил)",
    r"^\s*редактор\s+субтитров",
    r"^\s*продолжение\s+следует",
    r"^\s*спасибо\s+за\s+просмотр",
    r"^\s*подписывайтесь\s+на\s+канал",
    r"^\s*dimatorzok",
    r"^\s*субтитры\s+и\s+перевод",
    r"^\s*amara\.org",
]


def _normalized(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    return re.sub(r"[^\w\s]+", " ", text).strip()


def quality_gate(utterances: list[Utterance], duration: float) -> tuple[list[Utterance], list[str]]:
    """Отсеять типовой мусор Whisper и оценить пригодность результата."""
    warnings: list[str] = []

    cleaned: list[Utterance] = []
    dropped_hallucinations = 0
    for item in utterances:
        low = item.text.casefold()
        if any(re.search(pattern, low) for pattern in HALLUCINATION_PATTERNS):
            dropped_hallucinations += 1
            continue
        cleaned.append(item)

    if dropped_hallucinations:
        warnings.append(
            f"Удалено служебных фраз распознавателя: {dropped_hallucinations}"
        )

    if not cleaned:
        raise TranscriptionError(
            "После очистки в расшифровке не осталось содержательного текста."
        )

    # Зацикливание: одна и та же фраза подряд много раз.
    collapsed: list[Utterance] = []
    repeats = 0
    for item in cleaned:
        if collapsed and _normalized(collapsed[-1].text) == _normalized(item.text):
            collapsed[-1].end = item.end
            repeats += 1
            continue
        collapsed.append(item)
    if repeats:
        warnings.append(f"Схлопнуто повторов подряд: {repeats}")

    unique = {_normalized(item.text) for item in collapsed}
    if len(collapsed) >= 12 and len(unique) / len(collapsed) < 0.25:
        raise TranscriptionError(
            "Расшифровка состоит почти целиком из повторов - это признак сбоя "
            "распознавания. Дальнейшая обработка остановлена, чтобы не получить "
            "бессмысленное резюме.",
            "Попробуйте другую модель Whisper или проверьте качество записи.",
        )

    words = sum(len(item.text.split()) for item in collapsed)
    if duration > 60 and words / (duration / 60.0) < 8:
        warnings.append(
            f"Плотность речи низкая ({words / (duration / 60.0):.0f} слов/мин) - "
            "возможно, часть записи не распозналась."
        )

    low_conf = [i for i in collapsed if 0 < i.confidence < 0.35]
    if collapsed and len(low_conf) / len(collapsed) > 0.5:
        warnings.append("Больше половины реплик распознаны с низкой уверенностью.")

    for message in warnings:
        warn(message)
    log(f"    к обработке принято реплик: {len(collapsed)}, слов: {words}")
    return collapsed, warnings


def drop_echo(own: list, others: list, overlap: float = 0.5,
              similarity: float = 0.75) -> list:
    """Убрать с микрофонной дорожки то, что на самом деле сказали в динамиках.

    Даже с эхоподавлением микрофон немного слышит колонки, и распознаватель
    честно превращает это в реплики. Без чистки собеседник появлялся бы в
    стенограмме дважды - своим голосом и вашим.
    """
    import difflib

    kept = []
    for mine in own:
        echo = False
        for other in others:
            span = min(mine.end, other.end) - max(mine.start, other.start)
            if span <= 0:
                continue
            shorter = min(mine.duration if hasattr(mine, "duration") else mine.end - mine.start,
                          other.end - other.start) or 1.0
            if span / shorter < overlap:
                continue
            ratio = difflib.SequenceMatcher(
                None, _normalized(mine.text), _normalized(other.text)).ratio()
            if ratio >= similarity:
                echo = True
                break
        if not echo:
            kept.append(mine)
    return kept


# --------------------------------------------------------------------------
# Диаризация
# --------------------------------------------------------------------------

def diarize(wav: Path, speakers: int = 0) -> list:
    """Разделить запись по голосам через sherpa-onnx.

    Модели те же, что раньше давал pyannote, но в открытых ONNX-сборках:
    ни аккаунта, ни токена, ни принятия условий.
    """
    engine = _engine()
    stage_pct("diarization", 0.05, "подготовка моделей")
    try:
        engine.ensure_models(engine.DIARIZATION_MODELS, log=log)
        def report(done, total, *_):
            # sherpa-onnx ждёт от колбэка int; вернуть None - уронить процесс.
            stage_pct("diarization", done / max(1, total))
            return 0

        wanted = speakers if speakers and speakers > 0 else NUM_SPEAKERS
        turns = engine.diarize(
            wav, threshold=DIARIZATION_THRESHOLD,
            num_speakers=wanted, progress=report,
        )

        # Движок отдаёт на голос меньше, чем просят.
        #
        # Замерено на двух разных записях: просим 3 - получаем 2, просим 4 -
        # получаем 3, просим 5 - получаем 4. Почему так, из библиотеки не
        # видно: привязка нативная, заглянуть внутрь нечем.
        #
        # Поэтому не поправка вслепую, а проверка результата: посчитали, и
        # если голосов недобрали - просим на один больше. Так исправление
        # переживёт починку библиотеки, а не сломается от неё.
        if wanted and wanted > 0:
            for extra in (1, 2):
                if len({t["speaker"] for t in turns}) >= wanted:
                    break
                log(f"    голосов вышло меньше заданного, повторяю с {wanted + extra}")
                turns = engine.diarize(
                    wav, threshold=DIARIZATION_THRESHOLD,
                    num_speakers=wanted + extra, progress=report,
                )
    except Exception as exc:
        raise DiarizationError(
            "Не удалось разделить запись на спикеров.",
            f"{type(exc).__name__}: {str(exc)[:200]}",
        ) from exc

    speakers = sorted({item["speaker"] for item in turns})
    log(f"    выделено голосов: {len(speakers)}")
    stage_pct("diarization", 1.0)
    return turns


def join_adjacent(turns: list, gap: float = TURN_JOIN_GAP,
                  floor: float = TURN_MIN) -> list:
    """Собрать разорванную речь одного голоса обратно во фразы.

    Сегментация режет по паузам дыхания, и одна реплика приходит четырьмя
    кусками по секунде. В стенограмме это оборванные фразы, а в образцах
    голоса - обрывки, по которым ни человек не узнает говорящего, ни модель
    не построит надёжный отпечаток.

    Склеиваем подряд идущие отрезки одного голоса, если между ними тишина
    короче `gap`. Куски короче `floor` после этого выбрасываем: фразы в них
    всё равно нет.
    """
    if not turns:
        return turns

    ordered = sorted(turns, key=lambda t: (t["start"], t["end"]))
    joined: list = [dict(ordered[0])]
    for turn in ordered[1:]:
        last = joined[-1]
        if turn["speaker"] == last["speaker"] and turn["start"] - last["end"] <= gap:
            last["end"] = max(last["end"], turn["end"])
        else:
            joined.append(dict(turn))

    kept = [t for t in joined if t["end"] - t["start"] >= floor]
    if len(kept) != len(turns):
        log(f"    отрезков после склейки: {len(kept)} (было {len(turns)})")
    return kept or joined


def merge_split_voices(wav: Path, turns: list, threshold: float = MERGE_THRESHOLD) -> list:
    """Слить голоса, которые на самом деле принадлежат одному человеку.

    Диаризация регулярно дробит человека на несколько голосов: он отходит от
    микрофона, меняет громкость, говорит после паузы. Подбирать под это один
    глобальный порог кластеризации бесполезно - на реальной записи он
    перескакивает нужное число участников: 0.50 даёт четыре голоса, 0.58 уже
    два, а трёх не даёт вовсе.

    Поэтому решаем задачу там, где есть данные: считаем голосовой отпечаток
    каждого выделенного голоса по нескольким его отрезкам и сливаем те, что
    похожи сильнее порога узнавания.
    """
    np = _np()
    by_speaker: dict = {}
    for turn in turns:
        by_speaker.setdefault(turn["speaker"], []).append(turn)
    if len(by_speaker) < 2:
        return turns

    prints: dict = {}
    for speaker, segments in by_speaker.items():
        total = sum(x["end"] - x["start"] for x in segments)
        if total < MERGE_MIN_SPEECH:
            # Мало речи - отпечаток недостоверен, объединять опасно.
            continue
        # Самые длинные отрезки: на коротких отпечаток неустойчив.
        longest = sorted(segments, key=lambda s: s["end"] - s["start"], reverse=True)[:3]
        vectors = []
        for segment in longest:
            start = float(segment["start"])
            end = min(float(segment["end"]), start + 8.0)
            if end - start < MIN_EMBED_SECONDS:
                continue
            try:
                vectors.append(embedding_from_wav(wav, start, end))
            except PipelineError:
                continue
        if vectors:
            prints[speaker] = np.mean(np.stack(vectors), axis=0)

    names = sorted(prints)
    parent = {name: name for name in names}

    def root(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    merged = []
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            score = cosine(prints[a], prints[b])
            if score >= threshold:
                ra, rb = root(a), root(b)
                if ra != rb:
                    parent[max(ra, rb)] = min(ra, rb)
                    merged.append((a, b, score))

    if not merged:
        return turns

    for a, b, score in merged:
        log(f"    {b} и {a} - один человек (близость {score:.2f})")
    log(f"    голосов после объединения: {len({root(n) for n in names})}")
    log("    остальные оставлены раздельно: склеенных людей уже не разделить")

    return [{**turn,
             "speaker": root(turn["speaker"]) if turn["speaker"] in parent else turn["speaker"]}
            for turn in turns]


def assign_speakers(utterances: list[Utterance], turns: list[dict[str, Any]]) -> None:
    """Разбить фразы на сменах голоса по меткам слов; сомнения оставить явными."""
    from speech_alignment import align_utterances
    utterances[:] = align_utterances(utterances, turns)


# --------------------------------------------------------------------------
# Профили спикеров
# --------------------------------------------------------------------------


def profiles_meta_path(profiles_dir: Path) -> Path:
    return profiles_dir / "profiles.json"


def load_profiles(profiles_dir: Path) -> dict[str, dict[str, Any]]:
    path = profiles_meta_path(profiles_dir)
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"Файл профилей повреждён и будет проигнорирован: {exc}")
        return {}
    return data if isinstance(data, dict) else {}


def save_profiles(profiles_dir: Path, profiles: dict[str, Any]) -> None:
    profiles_dir.mkdir(parents=True, exist_ok=True)
    path = profiles_meta_path(profiles_dir)
    tmp = path.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(profiles, handle, ensure_ascii=False, indent=2)
    tmp.replace(path)


def safe_key(value: str) -> str:
    key = "".join(ch if ch.isalnum() or ch in "_-" else "_" for ch in value).strip("_")
    return key or "speaker"


def resolve_profile_file(profiles_dir: Path, value: str) -> Path:
    """Привести profile_file к пути ВНУТРИ каталога профилей.

    SEC-03: раньше значение из profiles.json подставлялось в np.load() как
    есть, поэтому любая правка JSON заставляла приложение прочитать
    произвольный файл на диске. Теперь путь всегда разрешается относительно
    каталога профилей, а выход за его пределы отвергается.
    """
    root = profiles_dir.resolve()
    candidate = Path(value).expanduser()
    candidate = candidate if candidate.is_absolute() else root / candidate
    candidate = candidate.resolve()
    if root != candidate and root not in candidate.parents:
        # Профили, перенесённые с другой машины, хранят абсолютные пути вида
        # /Users/<чужой пользователь>/whisper-work/... Забирать файл оттуда
        # нельзя, но сам отпечаток обычно лежит рядом с profiles.json.
        migrated = (root / Path(value).name).resolve()
        if migrated.is_file() and (root == migrated or root in migrated.parents):
            return migrated
        raise SecurityError(
            "Профиль спикера ссылается на файл за пределами каталога профилей.",
            f"{candidate}",
        )
    return candidate


def embeddings_dir(profiles_dir: Path) -> Path:
    path = profiles_dir / "embeddings"
    path.mkdir(parents=True, exist_ok=True)
    return path


def samples_dir(profiles_dir: Path, key: str) -> Path:
    path = profiles_dir / "samples" / safe_key(key)
    path.mkdir(parents=True, exist_ok=True)
    return path


def embedding_from_wav(wav: Path, start=None, end=None):
    """Отпечаток голоса. 256 чисел, модель WeSpeaker VoxCeleb ResNet34-LM."""
    engine = _engine()
    try:
        return engine.embed(wav, start, end)
    except Exception as exc:
        raise DiarizationError(
            "Не удалось построить голосовой отпечаток фрагмента.",
            f"{type(exc).__name__}: {str(exc)[:200]}",
        ) from exc


def embedding_id() -> str:
    """Метка набора отпечатков. Меняется вместе с моделью."""
    try:
        return _engine().EMBEDDING_ID
    except Exception:  # noqa: BLE001 - без движка метка просто неизвестна
        return "unknown"


def cosine(a, b) -> float:
    np = _np()
    a = np.asarray(a, dtype="float32").reshape(-1)
    b = np.asarray(b, dtype="float32").reshape(-1)
    if a.size == 0 or b.size == 0 or a.size != b.size:
        return 0.0
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denom == 0.0:
        return 0.0
    return float(np.dot(a, b) / denom)


def load_known_embeddings(profiles_dir: Path) -> dict[str, Any]:
    np = _np()
    known: dict[str, Any] = {}
    for key, info in load_profiles(profiles_dir).items():
        reference = str(info.get("profile_file", "")).strip()
        if not reference:
            continue
        try:
            path = resolve_profile_file(profiles_dir, reference)
        except SecurityError as exc:
            warn(f"Профиль «{key}» пропущен: {exc}")
            continue
        if not path.is_file():
            continue
        if info.get("embedding_id", "") != embedding_id():
            continue  # отпечаток от другой модели; будет пересобран из образцов
        try:
            # allow_pickle=False: .npy не должен уметь исполнять код при загрузке.
            known[key] = np.load(path, allow_pickle=False)
        except Exception as exc:
            warn(f"Не удалось прочитать отпечаток профиля «{key}»: {exc}")
    return known


def rebuild_embedding(profiles_dir: Path, key: str) -> bool:
    """Пересобрать отпечаток человека по всем его WAV-образцам."""
    np = _np()
    folder = samples_dir(profiles_dir, key)
    samples = sorted(folder.glob("*.wav"))
    if not samples:
        return False

    vectors = []
    for sample in samples:
        length = wav_duration(sample)
        if length < MIN_EMBED_SECONDS:
            continue
        try:
            vectors.append(embedding_from_wav(sample))
        except PipelineError as exc:
            warn(f"Образец {sample.name} пропущен: {exc}")

    if not vectors:
        return False

    mean = np.mean(np.stack(vectors), axis=0).astype("float32")
    target = embeddings_dir(profiles_dir) / f"{safe_key(key)}.npy"
    np.save(target, mean, allow_pickle=False)

    profiles = load_profiles(profiles_dir)
    if key in profiles:
        profiles[key]["profile_file"] = str(target.relative_to(profiles_dir))
        profiles[key]["samples"] = len(samples)
        profiles[key]["embedding_update_pending"] = False
        profiles[key]["embedding_id"] = embedding_id()
        profiles[key]["embedding_dimensions"] = int(mean.shape[0])
        profiles[key]["updated_at"] = datetime.now().isoformat(timespec="seconds")
        save_profiles(profiles_dir, profiles)
    return True


def refresh_pending_profiles(profiles_dir: Path) -> None:
    """Досчитать отпечатки для профилей, помеченных GUI как «ожидает пересчёта».

    speaker_service при привязке голоса к человеку только копирует WAV и
    ставит флаг embedding_update_pending, потому что сам не работает с
    моделями голоса. Ядро закрывает этот цикл: без пересчёта привязанные голоса
    никогда не начали бы опознаваться автоматически.
    """
    profiles = load_profiles(profiles_dir)
    current = embedding_id()
    # Профиль пересобирается в двух случаях: интерфейс привязал новый голос,
    # либо сменилась модель отпечатков - векторы разных моделей несравнимы,
    # и старые молча перестали бы узнавать людей.
    pending = [
        key for key, info in profiles.items()
        if info.get("embedding_update_pending")
        or info.get("embedding_id", "") != current
    ]
    if not pending:
        return
    log(f"    пересчёт голосовых отпечатков: {len(pending)}")
    for key in pending:
        try:
            if rebuild_embedding(profiles_dir, key):
                log(f"      обновлён профиль: {profiles[key].get('name', key)}")
        except PipelineError as exc:
            warn(f"Профиль «{key}» не пересчитан: {exc}")


def save_speaker_profile(
    profiles_dir: Union[Path, str],
    wav_path: Union[Path, str],
    name: str,
    position: str = "",
    company: str = "",
) -> tuple[str, str]:
    """Зарегистрировать человека по WAV-образцу.

    Контракт с GUI (speaker_service.create_person_record): функция
    вызывается динамически и должна вернуть кортеж, первый элемент
    которого - отображаемое имя, найденное потом в list_speakers().
    """
    profiles_dir = Path(profiles_dir).expanduser().resolve()
    wav_path = Path(wav_path).expanduser().resolve()

    name = (name or "").strip()
    if not name:
        raise ValueError("ФИО обязательно")
    if not wav_path.is_file():
        raise FileNotFoundError("WAV-файл не найден")

    profiles_dir.mkdir(parents=True, exist_ok=True)
    profiles = load_profiles(profiles_dir)

    base = safe_key(name)
    key = base
    index = 2
    while key in profiles:
        key = f"{base}_{index}"
        index += 1

    target = samples_dir(profiles_dir, key) / f"{uuid.uuid4().hex}.wav"
    shutil.copy2(wav_path, target)

    now = datetime.now().isoformat(timespec="seconds")
    profiles[key] = {
        "name": name,
        "position": (position or "").strip(),
        "company": (company or "").strip(),
        "profile_file": "",
        "samples": 1,
        "created_at": now,
        "updated_at": now,
        "embedding_update_pending": True,
    }
    save_profiles(profiles_dir, profiles)

    # Отпечаток считаем сразу, если движок доступен. Если нет - профиль
    # останется с флагом pending и будет достроен при следующей обработке,
    # поэтому GUI не должен падать из-за отсутствующих моделей.
    try:
        rebuild_embedding(profiles_dir, key)
    except Exception as exc:  # noqa: BLE001 - GUI не должен падать из-за моделей
        warn(f"Отпечаток будет построен позже: {exc}")

    return name, key


def identify_speakers(
    wav: Path, turns: list[dict[str, Any]], profiles_dir: Path
) -> list[SpeakerMatch]:
    """Сопоставить голоса из диаризации с зарегистрированными людьми."""
    profiles = load_profiles(profiles_dir)
    known = load_known_embeddings(profiles_dir)
    log(f"    в базе профилей: {len(profiles)}, с отпечатком: {len(known)}")

    by_speaker: dict[str, list[dict[str, Any]]] = {}
    for turn in turns:
        by_speaker.setdefault(turn["speaker"], []).append(turn)

    matches: list[SpeakerMatch] = []
    for index, (speaker, segments) in enumerate(sorted(by_speaker.items())):
        segments = sorted(segments, key=lambda item: item["start"])
        total = sum(item["end"] - item["start"] for item in segments)

        # TD-09: границы образца считаем ВНУТРИ выбранного сегмента, а не по
        # последнему сегменту спикера, иначе в образец попадала чужая речь.
        longest = max(segments, key=lambda item: item["end"] - item["start"])
        seg_start, seg_end = float(longest["start"]), float(longest["end"])
        sample_end = min(seg_end, seg_start + SNIPPET_SECONDS)

        match = SpeakerMatch(
            speaker_id=speaker,
            total_speech=total,
            best_segment=(seg_start, sample_end),
        )

        if sample_end - seg_start < MIN_EMBED_SECONDS:
            warn(f"Голос {speaker} слишком короткий для опознания ({total:.1f} с речи).")
            matches.append(match)
            continue

        try:
            vector = embedding_from_wav(wav, seg_start, sample_end)
        except PipelineError as exc:
            warn(f"Голос {speaker} не опознан: {exc}")
            matches.append(match)
            continue

        scores = sorted(
            ((cosine(vector, ref), key) for key, ref in known.items()), reverse=True
        )
        best_score, best_key = scores[0] if scores else (0.0, "")
        runner_up = scores[1][0] if len(scores) > 1 else 0.0
        margin = best_score - runner_up

        match.similarity = best_score
        if best_key and best_score >= VOICE_THRESHOLD and (
            len(scores) == 1 or margin >= VOICE_MARGIN
        ):
            name = str(profiles.get(best_key, {}).get("name", best_key))
            samples = int(profiles.get(best_key, {}).get("samples") or 1)
            if samples < MIN_PROFILE_SAMPLES:
                match.voice_guess = name
                log(f"    {speaker} -> похож на {name} ({best_score:.2f}), но у карточки "
                    f"образцов: {samples} - только предлагаем")
            else:
                match.profile_key = best_key
                match.name = name
                log(f"    {speaker} -> {match.name} (близость {best_score:.2f})")
        elif best_key and best_score >= VOICE_THRESHOLD:
            # Похож сразу на двоих - честнее отдать пользователю, чем гадать.
            log(f"    {speaker} -> неоднозначно: {best_score:.2f} против {runner_up:.2f}")
        else:
            log(f"    {speaker} -> новый голос (лучшая близость {best_score:.2f})")

        matches.append(match)
        stage_pct("identify", (index + 1) / max(1, len(by_speaker)))

    return matches


def write_wav_excerpt(src: Path, dst: Path, spans: list) -> float:
    """Склеить несколько отрезков одного голоса в один образец.

    Одного куска не хватает: после сегментации самый длинный отрезок нередко
    короче двух секунд, а по такому обрывку голос не узнать ни на слух, ни по
    отпечатку. Берём несколько лучших кусков подряд, разделяя их короткой
    тишиной, чтобы слышно было, что это разные реплики.
    """
    dst.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(src), "rb") as source:
        rate = source.getframerate()
        width = source.getsampwidth()
        channels = source.getnchannels()
        total = source.getnframes()

        pieces: list = []
        gap = b"\x00" * (int(rate * 0.25) * width * channels)
        collected = 0
        for start, end in spans:
            first = max(0, int(start * rate))
            last = min(total, int(end * rate))
            if last <= first:
                continue
            source.setpos(first)
            if pieces:
                pieces.append(gap)
            pieces.append(source.readframes(last - first))
            collected += last - first

    if not collected:
        return 0.0

    with wave.open(str(dst), "wb") as out:
        out.setnchannels(channels)
        out.setsampwidth(width)
        out.setframerate(rate)
        out.writeframes(b"".join(pieces))
    return collected / float(rate)


def split_voice(result_dir: Path, speaker_id: str, into: int) -> int:
    """Разделить один голос на несколько человек.

    Диаризация склеивает людей: похожие голоса, один микрофон на комнату,
    короткие реплики. Обратная сторона слияния, которое делает
    merge_split_voices, и там честно написано, что склеенных уже не
    разделить, — автоматически не разделить, а по указанию человека можно:
    он слышит, что говорили двое, и знает, сколько их было.

    Считаем отпечаток каждого отрезка этого голоса и раскладываем отрезки на
    заданное число групп ближайшим объединением. Число групп берётся у
    человека, а не подбирается: подобранное на реальной записи перескакивает
    нужное значение, ради этого и существует эта команда.
    """
    result_dir = Path(result_dir).expanduser().resolve()
    extra_dir = result_dir / EXTRA_DIR_NAME
    transcript_path = result_dir / TRANSCRIPT_JSON
    turns_path = extra_dir / "diarization.json"
    if not transcript_path.is_file() or not turns_path.is_file():
        raise PipelineError("Не найдена встреча", "Нет стенограммы или разметки голосов.")
    if into < 2:
        raise PipelineError("Делить не на что", "Укажите хотя бы двух человек.")

    data = json.loads(transcript_path.read_text(encoding="utf-8"))
    meta = data if isinstance(data, dict) else {}
    utterances = meta.get("utterances") if meta else data
    turns = json.loads(turns_path.read_text(encoding="utf-8"))
    mine = [t for t in turns if t.get("speaker") == speaker_id]
    if not mine:
        raise PipelineError("Голос не найден", f"В разметке встречи нет «{speaker_id}».")

    stage_start("diarization")
    wav, temporary = _speech_wav(result_dir, meta)
    try:
        # Отрезки короче секунды дают неустойчивый отпечаток: их не
        # раскладываем, а раздаём в конце ближайшей по времени группе.
        usable, vectors = [], []
        for turn in mine:
            start = float(turn["start"])
            end = min(float(turn["end"]), start + 8.0)
            if end - start < MIN_EMBED_SECONDS:
                continue
            try:
                vectors.append(embedding_from_wav(wav, start, end))
            except PipelineError:
                continue
            usable.append(turn)
            stage_pct("diarization", len(usable) / max(1, len(mine)))
        if len(usable) < into:
            raise PipelineError(
                "Слишком мало речи",
                f"Отрезков длиннее {MIN_EMBED_SECONDS:g} с всего {len(usable)}, "
                f"а групп нужно {into}.")

        groups = _cluster_into(vectors, into)
        names = [f"{speaker_id}_{i + 1}" for i in range(into)]
        assigned = {id(turn): names[groups[i]] for i, turn in enumerate(usable)}
        # Короткие отрезки идут туда же, куда ближайший по времени разобранный.
        for turn in mine:
            if id(turn) in assigned:
                continue
            near = min(usable, key=lambda x: abs(float(x["start"]) - float(turn["start"])))
            assigned[id(turn)] = assigned[id(near)]

        for turn in mine:
            turn["speaker"] = assigned[id(turn)]
        spans: dict = {}
        for turn in mine:
            spans.setdefault(turn["speaker"], []).append((float(turn["start"]), float(turn["end"])))

        # Реплика достаётся тому, чьи отрезки перекрывают её сильнее прочих.
        for item in utterances if isinstance(utterances, list) else []:
            if not isinstance(item, dict) or item.get("speaker_id") != speaker_id:
                continue
            start, end = float(item.get("start", 0)), float(item.get("end", 0))
            best, best_overlap = names[0], -1.0
            for name, ranges in spans.items():
                overlap = sum(max(0.0, min(end, b) - max(start, a)) for a, b in ranges)
                if overlap > best_overlap:
                    best, best_overlap = name, overlap
            item["speaker_id"] = best
            item["speaker_name"] = ""
        if isinstance(meta.get("speakers"), list):
            meta["speakers"] = sorted({
                (u.get("speaker_name") or u.get("speaker_id") or "Неизвестный")
                for u in utterances})

        turns_path.write_text(json.dumps(turns, ensure_ascii=False, indent=2), encoding="utf-8")
        for path in (transcript_path, extra_dir / TRANSCRIPT_JSON):
            if path.is_file():
                write_json(path, data)
        _resplit_records(extra_dir, wav, speaker_id, names, spans)
    finally:
        if temporary and wav.exists():
            wav.unlink(missing_ok=True)

    log(f"    {speaker_id} разделён на {into}: {', '.join(names)}")
    stage_pct("diarization", 1.0)
    return 0


def _speech_wav(result_dir: Path, meta: dict):
    """Рабочий WAV встречи: сохранённый рядом или добытый из исходной записи."""
    kept = result_dir / EXTRA_DIR_NAME / "work" / "audio_16k.wav"
    if kept.is_file():
        return kept, False
    source = Path(str(meta.get("source_path") or ""))
    if not source.is_file():
        raise PipelineError(
            "Нет исходной записи",
            "Рабочий файл не сохранён, а исходную запись найти не удалось: "
            f"«{source}». Верните файл на место или включите «хранить рабочий WAV».")
    target = Path(tempfile.mkdtemp(prefix="slavator-split-")) / "audio_16k.wav"
    decode_to_wav16k(source, target)
    return target, True


def _cluster_into(vectors: list, into: int) -> list:
    """Ближайшее объединение отрезков в заданное число групп.

    Своё, а не из sklearn: зависимость ради двадцати строк на десятках
    отрезков не окупается, а среднее по группе — то же average linkage.
    """
    np = _np()
    groups = [[i] for i in range(len(vectors))]
    centres = [v for v in vectors]
    while len(groups) > into:
        best, pair = -2.0, (0, 1)
        for i in range(len(groups)):
            for j in range(i + 1, len(groups)):
                score = cosine(centres[i], centres[j])
                if score > best:
                    best, pair = score, (i, j)
        i, j = pair
        groups[i] = groups[i] + groups[j]
        centres[i] = np.mean(np.stack([vectors[k] for k in groups[i]]), axis=0)
        del groups[j], centres[j]
    label = [0] * len(vectors)
    for g, members in enumerate(groups):
        for index in members:
            label[index] = g

    # Ближайшее объединение легко оставляет группу из одного отрезка: пока
    # оно сливает похожих, всё сходится в один ком, а «второй человек»
    # оказывается случайным выбросом. Несколько проходов перераспределения
    # выравнивают группы: каждый отрезок уходит к ближайшему центру, центры
    # пересчитываются заново.
    for _ in range(12):
        centres = []
        for g in range(into):
            members = [vectors[i] for i, tag in enumerate(label) if tag == g]
            centres.append(np.mean(np.stack(members), axis=0) if members else None)
        moved = False
        for i, vector in enumerate(vectors):
            best, score = label[i], -2.0
            for g, centre in enumerate(centres):
                if centre is None:
                    continue
                value = cosine(vector, centre)
                if value > score:
                    best, score = g, value
            if best != label[i]:
                label[i], moved = best, True
        if not moved:
            break

    # Крупные группы идут первыми: «_1» должен быть тем, кто говорил больше.
    sizes = [label.count(g) for g in range(into)]
    order = sorted(range(into), key=lambda g: sizes[g], reverse=True)
    place = {g: i for i, g in enumerate(order)}
    return [place[tag] for tag in label]


def _resplit_records(extra_dir: Path, wav: Path, speaker_id: str, names: list, spans: dict) -> None:
    """Переписать всё, что помнило старый голос: узнавание, образцы, имена."""
    recognition = read_json_list(extra_dir / "speaker_recognition.json")
    recognition = [r for r in recognition if r.get("speaker_id") != speaker_id]
    unknown = read_json_list(extra_dir / "unknown_speakers.json")
    unknown = [r for r in unknown if r.get("speaker_id") != speaker_id]

    unknown_dir = extra_dir / UNKNOWN_DIR_NAME
    for stale in unknown_dir.glob(f"{speaker_id}*.wav"):
        stale.unlink(missing_ok=True)

    for name in names:
        ranges = sorted(spans.get(name, []), key=lambda x: x[1] - x[0], reverse=True)
        chosen, collected = [], 0.0
        for span in ranges:
            if collected >= SAMPLE_TARGET:
                break
            chosen.append(span)
            collected += span[1] - span[0]
        chosen.sort()
        total = sum(b - a for a, b in spans.get(name, []))
        recognition.append({"speaker_id": name, "profile_key": "", "name": "",
                            "similarity": 0.0, "total_speech": round(total, 2),
                            "best_segment": list(chosen[0]) if chosen else []})
        if not chosen:
            continue
        length = write_wav_excerpt(wav, unknown_dir / f"{name}.wav", chosen)
        if length <= 0:
            continue
        unknown.append({"speaker_id": name, "wav": f"{name}.wav", "suggested_name": "",
                        "suggested_confidence": 0, "duration": round(length, 2),
                        "total_speech": round(total, 2), "best_similarity": 0.0})

    write_json(extra_dir / "speaker_recognition.json", recognition)
    write_json(extra_dir / "unknown_speakers.json", unknown)

    # Имя и привязка относились к слитому голосу; для новых они неизвестны.
    for file in ("speaker_names.json", "speaker_links.json"):
        path = extra_dir / file
        if not path.is_file():
            continue
        try:
            table = json.loads(path.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            continue
        if isinstance(table, dict) and table.pop(speaker_id, None) is not None:
            write_json(path, table)


def read_json_list(path: Path) -> list:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return []
    return value if isinstance(value, list) else []


def export_unknown_voices(
    wav: Path, matches: list[SpeakerMatch], unknown_dir: Path,
    hints: Optional[dict] = None, turns: Optional[list] = None,
) -> list[dict[str, Any]]:
    """Сохранить WAV-образцы неопознанных голосов для экрана «Новые голоса».

    Если по контексту удалось предположить имя, оно попадает в название
    файла: интерфейс показывает именно его, поэтому пользователю остаётся
    подтвердить догадку, а не вспоминать голос с нуля.
    """
    unknown_dir.mkdir(parents=True, exist_ok=True)
    hints = hints or {}
    exported: list[dict[str, Any]] = []

    # Отрезки по голосам - чтобы собрать образец из нескольких кусков.
    by_speaker: dict = {}
    for turn in turns or []:
        by_speaker.setdefault(turn["speaker"], []).append(
            (turn["start"], turn["end"]))

    skipped = 0
    for match in matches:
        if match.known or not match.best_segment:
            continue
        # Голоса, набравшие за всю запись считаные секунды, к опознанию не
        # предлагаем: отпечаток по ним недостоверен, а список из шестидесяти
        # карточек разобрать невозможно.
        if match.total_speech < UNKNOWN_MIN_SPEECH:
            skipped += 1
            continue

        spans = sorted(by_speaker.get(match.speaker_id, []),
                       key=lambda x: x[1] - x[0], reverse=True)
        chosen, collected = [], 0.0
        for span in spans:
            if collected >= SAMPLE_TARGET:
                break
            chosen.append(span)
            collected += span[1] - span[0]
        if not chosen:
            chosen = [match.best_segment]
        # В образце куски идут в том же порядке, что и в записи.
        chosen.sort()

        hint = hints.get(match.speaker_id)
        if hint and not hint.get("applied"):
            safe = re.sub(r"[^\w\s.-]", "", hint["name"]).strip()
            target = unknown_dir / f"{match.speaker_id} — возможно, {safe}.wav"
        elif match.voice_guess:
            # Своя пометка, а не «возможно»: интерфейс должен сказать, что
            # имя определено по голосу, а не по разговору, — это разные
            # степени доверия, и путать их значит вводить в заблуждение.
            safe = re.sub(r"[^\w\s.-]", "", match.voice_guess).strip()
            target = unknown_dir / f"{match.speaker_id} — по голосу, {safe}.wav"
        else:
            target = unknown_dir / f"{match.speaker_id}.wav"
        length = write_wav_excerpt(wav, target, chosen)
        if length <= 0:
            continue
        exported.append(
            {
                "speaker_id": match.speaker_id,
                "wav": target.name,
                "suggested_name": (hints.get(match.speaker_id) or {}).get("name", "")
                                  or match.voice_guess,
                "suggested_confidence": (hints.get(match.speaker_id) or {}).get("confidence", 0),
                "duration": round(length, 2),
                "total_speech": round(match.total_speech, 2),
                "best_similarity": round(match.similarity, 3),
            }
        )

    if skipped:
        log(f"    пропущено мимолётных голосов (меньше {UNKNOWN_MIN_SPEECH:.0f} с речи): {skipped}")
    if exported:
        log(f"    сохранено образцов новых голосов: {len(exported)}")
    return exported


# --------------------------------------------------------------------------
# Ollama
# --------------------------------------------------------------------------


def _http_json(url: str, payload: Optional[dict] = None, timeout: int = 30) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST" if data else "GET",
    )
    # Local model traffic must not depend on a VPN/system proxy after reboot.
    if urllib.parse.urlparse(url).hostname in {"localhost", "127.0.0.1", "::1"}:
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        response_context = opener.open(request, timeout=timeout)
    else:
        response_context = urllib.request.urlopen(request, timeout=timeout)
    with response_context as response:
        return json.loads(response.read().decode("utf-8"))


def ollama_health() -> tuple[bool, str]:
    """Проверить, что на порту действительно Ollama.

    SEC-01: раньше приложение считало 127.0.0.1:11434 доверенным по факту
    открытого порта и сразу отправляло туда полную стенограмму встречи.
    Теперь сначала подтверждаем, что сервис отвечает как Ollama, и только
    после этого передаём ему данные.
    """
    try:
        version = _http_json(f"{OLLAMA_HOST}/api/version", timeout=5)
    except urllib.error.URLError as exc:
        return False, f"сервис не отвечает на {OLLAMA_HOST} ({exc.reason})"
    except (json.JSONDecodeError, OSError) as exc:
        return False, f"неожиданный ответ от {OLLAMA_HOST} ({exc})"

    if not isinstance(version, dict) or "version" not in version:
        return False, (
            f"на {OLLAMA_HOST} отвечает какой-то другой сервис - "
            "стенограмма ему передана не будет"
        )

    try:
        tags = _http_json(f"{OLLAMA_HOST}/api/tags", timeout=10)
    except Exception as exc:  # noqa: BLE001
        return False, f"не удалось получить список моделей ({exc})"

    models = {str(item.get("name", "")) for item in tags.get("models", [])}
    if not ollama_has_model(models):
        available = ", ".join(sorted(models)[:5]) or "нет моделей"
        return False, (
            f"модель «{OLLAMA_MODEL}» не установлена (доступно: {available}). "
            f"Выполните: ollama pull {OLLAMA_MODEL}"
        )
    return True, str(version.get("version", ""))


OLLAMA_MAC_APP = Path("/Applications/Ollama.app")


def ollama_binary():
    """Найти Ollama, где бы её ни поставили.

    Одного PATH мало: окно программы, запущенное из Finder или из меню
    «Пуск», получает урезанный PATH — без /opt/homebrew/bin и без
    %LOCALAPPDATA%. Ollama, поставленная из Homebrew или winget, при такой
    проверке «исчезала», и установщик предлагал скачать её заново, хотя она
    уже стояла на машине. Поэтому смотрим и в известные места установки.
    """
    found = shutil.which("ollama")
    if found:
        return Path(found)

    candidates = [
        OLLAMA_MAC_APP / "Contents" / "Resources" / "ollama",
        Path("/opt/homebrew/bin/ollama"),
        Path("/usr/local/bin/ollama"),
        Path("/usr/bin/ollama"),
    ]
    for base in (os.environ.get("LOCALAPPDATA"), os.environ.get("ProgramFiles")):
        if base:
            candidates.append(Path(base) / "Programs" / "Ollama" / "ollama.exe")
            candidates.append(Path(base) / "Ollama" / "ollama.exe")

    for candidate in candidates:
        try:
            if candidate.is_file():
                return candidate
        except OSError:
            continue
    return None


def ollama_running(timeout: int = 3) -> bool:
    """Сервер отвечает на своём порту."""
    try:
        _http_json(f"{OLLAMA_HOST}/api/version", timeout=timeout)
        return True
    except Exception:  # noqa: BLE001 - любая неудача значит «не отвечает»
        return False


def ollama_serve(wait_seconds: int = 30) -> bool:
    """Поднять Ollama и дождаться, пока она ответит.

    На маке предпочитаем приложение: с ним появляется значок в строке меню, и
    дальше система поднимает сервер сама. Если приложения нет, запускаем
    «ollama serve» отдельным сеансом, отвязанным от нашего процесса: иначе
    сервер умрёт вместе с обработкой, посреди работы.
    """
    # Starting a server is explicit repair, never a remote-host fallback.
    if OLLAMA_HOST.rstrip("/") != "http://127.0.0.1:11434":
        return False
    if ollama_running():
        return True
    binary = ollama_binary()
    if binary is None:
        return False

    detach = {"creationflags": 0x08000000} if os.name == "nt" else {"start_new_session": True}
    try:
        subprocess.Popen([str(binary), "serve"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         env={**os.environ, "OLLAMA_HOST": "127.0.0.1:11434"}, **detach)
    except OSError:
        return False

    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if ollama_running():
            return True
        time.sleep(1)
    return False


def ollama_models() -> set:
    """Имена установленных моделей. Пустое множество и когда моделей нет, и
    когда сервер молчит: для вызывающего разница невелика."""
    try:
        tags = _http_json(f"{OLLAMA_HOST}/api/tags", timeout=10)
    except Exception:  # noqa: BLE001
        return set()
    return {str(item.get("name", "")) for item in tags.get("models", [])}


def ollama_has_model(names=None) -> bool:
    known = ollama_models() if names is None else names
    return OLLAMA_MODEL in known or (":" not in OLLAMA_MODEL and OLLAMA_MODEL + ":latest" in known)


def ollama_pull(model: str = "", base: float = 45.0, scale: float = 0.5) -> bool:
    """Скачать языковую модель, показывая, сколько уже пришло.

    Тянем по протоколу самой Ollama, а не командой «ollama pull»: так прогресс
    приходит строками JSON и виден в окне программы, а не в чужой консоли,
    которую человек не открывал.
    """
    name = model or OLLAMA_MODEL
    request = urllib.request.Request(
        f"{OLLAMA_HOST}/api/pull",
        data=json.dumps({"model": name, "stream": True}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST")

    log(f"    Загружаю языковую модель {name}; точный объём покажет Ollama")
    shown = -5
    try:
        with urllib.request.urlopen(request, timeout=OLLAMA_TIMEOUT) as response:
            for raw in response:
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if item.get("error"):
                    warn(f"Ollama не отдала модель: {item['error']}")
                    return False
                total = int(item.get("total") or 0)
                done = int(item.get("completed") or 0)
                if total:
                    pct = int(done * 100 / total)
                    if pct >= shown + 5:
                        shown = pct
                        progress("llm", base + pct * scale,
                                 f"{pct}% из {total // (1024 * 1024)} МБ")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        warn(f"Не удалось загрузить модель: {exc}")
        return False
    return ollama_has_model()


def ollama_chat(system: str, user: str, json_mode: bool = True,
                timeout: Optional[int] = None) -> str:
    payload = {
        "model": OLLAMA_MODEL,
        "stream": False,
        # Размышления вслух выключены. Замер на короткой правке текста:
        # с ними 24,7 с, без них 2,2 с — цена десятикратная, а качество
        # добирается строгими указаниями в задании. С включёнными
        # размышлениями сверка терминов на стенограмме в 120 реплик
        # не укладывалась в отведённое время и валила весь прогон.
        "think": THINK_ALOUD,
        "keep_alive": "10m",
        "options": {"num_ctx": OLLAMA_NUM_CTX, "temperature": 0.2},
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    if json_mode:
        payload["format"] = "json"
    try:
        response = _http_json(f"{OLLAMA_HOST}/api/chat", payload,
                              timeout=timeout or OLLAMA_TIMEOUT)
    # OSError покрывает и URLError, и TimeoutError: истечение времени
    # приходит именно как TimeoutError и раньше проскакивало мимо перехвата,
    # роняя весь прогон вместо того, чтобы пропустить необязательный шаг.
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise LLMError("Ollama перестала отвечать во время анализа.",
                       f"{type(exc).__name__}: {exc}") from exc
    return str(response.get("message", {}).get("content", "")).strip()


def parse_json_response(raw: str, retries: int = 1) -> dict:
    """Разобрать JSON от модели, при необходимости попросив её починить ответ.

    Возвращённый v20 механизм repair: локальные модели регулярно добавляют
    пояснения вокруг JSON или обрывают структуру.
    """
    candidate = raw.strip()
    fenced = re.search(r"```(?:json)?\s*(.+?)```", candidate, re.S)
    if fenced:
        candidate = fenced.group(1).strip()

    first, last = candidate.find("{"), candidate.rfind("}")
    if first != -1 and last > first:
        candidate = candidate[first : last + 1]

    try:
        parsed = json.loads(candidate)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass

    if retries > 0:
        warn("Модель вернула некорректный JSON, запрашиваю исправленный ответ.")
        repaired = ollama_chat(
            "Ты исправляешь некорректный JSON. Верни ТОЛЬКО валидный JSON-объект, "
            "без комментариев и текста вокруг.",
            f"Исправь этот JSON:\n\n{raw[:6000]}",
        )
        return parse_json_response(repaired, retries - 1)

    raise LLMError(
        "Модель не вернула корректный результат анализа.",
        f"Первые 300 символов ответа: {raw[:300]}",
    )


NORMALIZE_SYSTEM = (
    "Ты корректор стенограмм рабочих встреч на русском языке. "
    "Ты исправляешь ТОЛЬКО неверно распознанные термины, аббревиатуры и "
    "англицизмы. Отвечай ТОЛЬКО валидным JSON."
)

NORMALIZE_TEMPLATE = """Ниже строки стенограммы, каждая с номером.
Распознаватель речи мог исказить термины, аббревиатуры и англоязычные слова.

Словарь правильных терминов этой команды:
{glossary}

Верни JSON: {{"lines": [{{"i": номер, "text": "исправленная строка"}}]}}

Строгие правила:
- включай в ответ ТОЛЬКО строки, которые действительно исправил;
- меняй исключительно написание терминов, аббревиатур и англицизмов;
- НЕ переписывай формулировки, НЕ сокращай, НЕ добавляй ничего от себя;
- если сомневаешься - не трогай строку.

Строки:
{lines}"""


def normalize_terminology(utterances: list, glossary: list,
                          budget_seconds: float = NORMALIZE_BUDGET) -> int:
    """Выправить термины и аббревиатуры по словарю команды.

    Распознаватель не знает «ЦОК», «МП Учителя» или «CJM» и пишет их на слух.
    Проход по словарю через локальную модель чинит это единообразно и не
    зависит от того, какой ASR-движок выбран.
    """
    if not glossary or not utterances:
        return 0

    import difflib

    numbered = [(index, item) for index, item in enumerate(utterances)]
    budget = max(2000, int((OLLAMA_NUM_CTX - 1200) * 3 * 0.5))

    # Заранее считаем, сколько будет обращений к модели: без этого шаг не
    # умел показывать прогресс и на длинной записи выглядел зависшим.
    total_batches, size_probe = 1, 0
    for _, item in numbered:
        line_size = len(item.text) + 8
        if size_probe + line_size > budget and size_probe:
            total_batches += 1
            size_probe = 0
        size_probe += line_size

    started_at = time.time()
    fixed = 0
    batch: list = []
    size = 0
    done_batches = 0
    given_up = False

    def flush(batch: list) -> int:
        nonlocal done_batches, given_up
        if not batch or given_up:
            return 0

        # Общий предел на весь шаг. Он необязательный: аббревиатуры уже
        # выправлены детерминированным проходом по словарю. Зато сюда ядро
        # однажды встало намертво - ждало ответа, которого не пришло, - и
        # обработка стояла двадцать минут без единого признака жизни.
        if time.time() - started_at > budget_seconds:
            warn("Сверка терминов прервана по времени: остальное оставлено как есть.")
            given_up = True
            return 0

        done_batches += 1
        stage_pct("summary", 0.05 + 0.25 * done_batches / max(1, total_batches),
                  f"сверка терминов, {done_batches} из {total_batches}")
        payload = "\n".join(f"{i}. {item.text}" for i, item in batch)
        try:
            raw = ollama_chat(
                NORMALIZE_SYSTEM,
                NORMALIZE_TEMPLATE.format(glossary="\n".join(glossary), lines=payload),
                timeout=NORMALIZE_REQUEST_TIMEOUT,
            )
            answer = parse_json_response(raw, retries=0)
        except (LLMError, PipelineError) as exc:
            warn(f"Нормализация терминов пропущена для части стенограммы: {exc}")
            return 0

        by_index = {index: item for index, item in batch}
        changed = 0
        for entry in answer.get("lines", []) or []:
            if not isinstance(entry, dict):
                continue
            try:
                index = int(entry.get("i"))
            except (TypeError, ValueError):
                continue
            item = by_index.get(index)
            text = str(entry.get("text", "")).strip()
            if item is None or not text or text == item.text:
                continue
            # Защита от переписывания смысла: правка терминов не может
            # изменить строку до неузнаваемости.
            ratio = difflib.SequenceMatcher(None, item.text, text).ratio()
            if ratio < 0.6 or len(text) > len(item.text) * 1.5 + 10:
                continue
            item.text = text
            changed += 1
        return changed

    for index, item in numbered:
        line_size = len(item.text) + 8
        if size + line_size > budget and batch:
            fixed += flush(batch)
            batch, size = [], 0
        batch.append((index, item))
        size += line_size
    fixed += flush(batch)

    if fixed:
        log(f"    выправлено строк по словарю: {fixed}")
    return fixed


NAMES_SYSTEM = (
    "Ты анализируешь стенограмму рабочей встречи на русском языке. "
    "Голоса пока обозначены как SPEAKER_00, SPEAKER_01 и так далее. "
    "Твоя задача - понять, как зовут этих людей, опираясь ТОЛЬКО на текст. "
    "Отвечай ТОЛЬКО валидным JSON."
)

NAMES_TEMPLATE = """Определи, как зовут участников встречи.

Опирайся на:
- прямые обращения («Ирина, что по бэклогу?» - значит отвечающий Ирина);
- самопредставления («Меня зовут Павел», «Павел Орлов, отдел аналитики»);
- упоминания в третьем лице («Ольга покажет макет»);
- подписи ролей («я как аналитик подготовила...»).

Верни JSON:
{{"speakers": [{{"id": "SPEAKER_01", "name": "Имя или Имя Фамилия",
                "confidence": 0.0-1.0, "evidence": "точная цитата из стенограммы"}}]}}

Строгие правила:
- имя ОБЯЗАНО встречаться в тексте стенограммы дословно;
- НЕ придумывай и НЕ угадывай имена, которых в тексте нет;
- если про голос ничего не понятно - не включай его в ответ;
- confidence 0.9+ только при самопредставлении или явном обращении;
- подпись перед двоеточием в стенограмме - НЕ доказательство: имя должно
  прозвучать в самих словах участников;
- уже названных по имени участников (не SPEAKER_XX) в ответ не включай.

Неопознанные голоса: {unknown}

Стенограмма:
{transcript}"""


def infer_speaker_names(utterances: list, extra_dir: Path) -> dict:
    """Понять по контексту, как зовут неопознанных участников.

    Каждое имя проверяется на присутствие в стенограмме: локальная модель
    охотно придумывает правдоподобные имена, и без этой проверки в профили
    спикеров попадали бы выдуманные люди.
    """
    unknown = sorted({item.speaker_id for item in utterances
                      if item.speaker_id and not item.speaker_name
                      and not item.speaker_id.startswith("UNASSIGNED_")})
    if not unknown:
        return {}

    text = transcript_as_text(utterances)
    # Имена почти всегда звучат в начале встречи, но берём и хвост: часть
    # участников подключается позже и представляется по ходу.
    budget = max(3000, int((OLLAMA_NUM_CTX - 1500) * 3 * 0.6))
    if len(text) > budget:
        head = text[: int(budget * 0.7)]
        tail = text[-int(budget * 0.3):]
        text = head + "\n\n[...пропущена середина встречи...]\n\n" + tail

    try:
        # Ограничение по времени обязательно: шаг необязательный, а стоит он
        # посреди обработки. Зависший запрос здесь останавливает всё.
        raw = ollama_chat(
            NAMES_SYSTEM,
            NAMES_TEMPLATE.format(unknown=", ".join(unknown), transcript=text),
            timeout=NAMES_REQUEST_TIMEOUT,
        )
        answer = parse_json_response(raw, retries=1)
    except PipelineError as exc:
        warn(f"Определение имён по контексту пропущено: {exc}")
        return {}

    # Проверяем по сказанному, без подписей голосов. В стенограмме для
    # модели уже опознанные голоса подписаны именами, и проверка по ней
    # пропускала любое такое имя: «Мигалин Сергей: большой экран...» — имя
    # «встречается в тексте», хотя вслух его никто не произносил. Модель брала
    # подпись за доказательство и раздавала то же имя соседнему голосу, а
    # ошибка сличения подтверждала сама себя под видом подсказки по разговору.
    haystack = _normalized(" ".join(item.text for item in utterances))
    hints: dict = {}
    for entry in answer.get("speakers", []) or []:
        if not isinstance(entry, dict):
            continue
        speaker_id = str(entry.get("id", "")).strip()
        name = str(entry.get("name", "")).strip()
        if speaker_id not in unknown or not name:
            continue
        try:
            confidence = float(entry.get("confidence", 0))
        except (TypeError, ValueError):
            confidence = 0.0

        # Защита от выдуманных имён: хотя бы одна часть имени обязана
        # реально звучать в стенограмме.
        parts = [p for p in _normalized(name).split() if len(p) > 2]
        if not parts or not any(part in haystack for part in parts):
            warn(f"Имя «{name}» отклонено: в стенограмме оно не встречается.")
            continue

        hints[speaker_id] = {
            "name": name,
            "confidence": round(confidence, 2),
            "evidence": str(entry.get("evidence", "")).strip()[:300],
            "applied": confidence >= NAME_CONFIDENCE,
        }

    if hints:
        write_json(extra_dir / "speaker_name_hints.json", hints)
        for speaker_id, hint in sorted(hints.items()):
            mark = "принято" if hint["applied"] else "предложено"
            log(f"    {speaker_id} -> {hint['name']} ({hint['confidence']:.2f}, {mark})")
    else:
        log("    имён по контексту определить не удалось")
    return hints


# --------------------------------------------------------------------------
# Анализ встречи
# --------------------------------------------------------------------------

MAP_SYSTEM = (
    "Ты - ассистент, который разбирает стенограммы рабочих встреч на русском языке. "
    "Перед каждой репликой указано имя говорящего. Отвечай ТОЛЬКО валидным JSON."
)

MAP_TEMPLATE = """Это фрагмент {index} из {total} стенограммы встречи.

Верни JSON строго такой структуры:
{{
  "topics": ["обсуждавшиеся темы"],
  "decisions": ["принятые решения"],
  "todos": [{{"task": "что сделать", "owner": "кто именно, из имён в стенограмме", "due": "срок или пустая строка"}}],
  "risks": ["риски и проблемы"],
  "questions": ["открытые вопросы без ответа"]
}}

Правила:
- owner бери ТОЛЬКО из имён говорящих в стенограмме; если исполнитель не назван, ставь "".
- не выдумывай факты, которых нет в тексте;
- пустой список лучше, чем придуманный пункт.
{roster}
Фрагмент стенограммы:
{chunk}"""

REDUCE_SYSTEM = (
    "Ты сводишь частичные разборы одной встречи в итоговый протокол на русском языке. "
    "Отвечай ТОЛЬКО валидным JSON."
)

REDUCE_TEMPLATE = """Ниже - разборы последовательных фрагментов одной встречи.
Объедини их, убрав дубли и противоречия.

Верни JSON строго такой структуры:
{{
  "title": "короткое название встречи",
  "summary": "связное резюме встречи, 5-10 предложений",
  "participants": ["имена участников из стенограммы"],
  "topics": ["темы"],
  "decisions": ["решения"],
  "todos": [{{"task": "...", "owner": "...", "due": "..."}}],
  "risks": ["риски"],
  "questions": ["открытые вопросы"]
}}
{roster}
Разборы фрагментов:
{parts}"""


ROSTER_TEMPLATE = """
Кто есть кто на встрече:
{people}

Это справка о людях, а не содержание разговора: фактов и поручений из неё не
берите. Должности нужны, чтобы верно понять, кто за что отвечает и к кому
относится сказанное.
"""


def speaker_roster(labels: Iterable[str], profiles_dir: Path = DEFAULT_PROFILES_DIR,
                   me: Optional[dict[str, str]] = None) -> dict[str, str]:
    """Должность и компания тех, кто говорил на этой встрече.

    Берём из карточек людей: должность отвечает на вопрос, кому поручение по
    силам и чьё слово в спорной строке решающее, — без неё модель раздаёт
    задачи по тому, кто последним говорил.

    Владелец программы попадает сюда даже без голосовой карточки: он
    вписывает себя в настройках, и приходит отдельно, в `me`.
    """
    cards: dict[str, str] = {}
    for info in load_profiles(profiles_dir).values():
        name = str(info.get("name", "")).strip()
        role = ", ".join(x for x in (str(info.get("position", "")).strip(),
                                     str(info.get("company", "")).strip()) if x)
        if name and role:
            cards[name.casefold()] = role
    if me:
        # Настройки свежее карточки: человек правит их чаще, чем заводит голос.
        name = str(me.get("name", "")).strip()
        role = ", ".join(x for x in (str(me.get("position", "")).strip(),
                                     str(me.get("company", "")).strip()) if x)
        if name and role:
            cards[name.casefold()] = role

    known: dict[str, str] = {}
    for label in labels:
        name = str(label).strip()
        role = cards.get(name.casefold(), "")
        if name and role and name not in known:
            known[name] = role
    return known


def roster_block(roles: dict[str, str]) -> str:
    """Справка о людях для промпта. Пусто, если про людей ничего не известно."""
    if not roles:
        return ""
    people = "\n".join(f"- {name} — {role}" for name, role in sorted(roles.items()))
    return ROSTER_TEMPLATE.format(people=people)


def transcript_as_text(utterances: Sequence[Utterance]) -> str:
    """Стенограмма С МЕТКАМИ СПИКЕРОВ.

    TD-01: прежняя версия отдавала в LLM голый текст без имён, из-за чего
    модель физически не могла определить владельца поручения - при том что
    summary обязан этого владельца назвать.
    """
    lines = []
    for item in utterances:
        stamp = time.strftime("%H:%M:%S", time.gmtime(max(0, item.start)))
        lines.append(f"[{stamp}] {item.label}: {item.text}")
    return "\n".join(lines)


def chunk_transcript(text: str, num_ctx: int) -> list[str]:
    """Порезать стенограмму под контекст модели.

    TD-03: раньше вся стенограмма уходила одним промптом при num_ctx=8192,
    и на длинных встречах модель просто не видела конец разговора.
    Оценка: для русского примерно 3 символа на токен, треть окна оставляем
    под инструкцию и ответ.
    """
    budget = max(2000, int((num_ctx - 1200) * 3 * 0.66))
    lines = text.split("\n")

    chunks: list[str] = []
    current: list[str] = []
    size = 0
    for line in lines:
        if size + len(line) + 1 > budget and current:
            chunks.append("\n".join(current))
            current, size = [], 0
        current.append(line)
        size += len(line) + 1
    if current:
        chunks.append("\n".join(current))
    return chunks or [text]


def _merge_unique(target: list[str], items: Iterable[Any]) -> None:
    seen = {_normalized(str(value)) for value in target}
    for value in items:
        text = str(value).strip()
        key = _normalized(text)
        if text and key not in seen:
            seen.add(key)
            target.append(text)


def analyze_meeting(utterances: list[Utterance], extra_dir: Path,
                    profiles_dir: Path = DEFAULT_PROFILES_DIR,
                    me: Optional[dict[str, str]] = None) -> dict[str, Any]:
    text = transcript_as_text(utterances)
    chunks = chunk_transcript(text, OLLAMA_NUM_CTX)
    log(f"    фрагментов для анализа: {len(chunks)} (num_ctx={OLLAMA_NUM_CTX})")

    roles = speaker_roster(sorted({item.label for item in utterances}), profiles_dir, me)
    roster = roster_block(roles)
    if roles:
        log(f"    известны должности: {len(roles)} из {len({item.label for item in utterances})}")

    partials: list[dict[str, Any]] = []
    for index, chunk in enumerate(chunks, start=1):
        stage_pct("summary", (index - 1) / (len(chunks) + 1), f"фрагмент {index} из {len(chunks)}")
        raw = ollama_chat(
            MAP_SYSTEM,
            MAP_TEMPLATE.format(index=index, total=len(chunks), chunk=chunk,
                                roster=roster),
        )
        partials.append(parse_json_response(raw))

    write_json(extra_dir / "initial_analysis.json", partials)

    if len(partials) == 1:
        stage_pct("summary", 0.6, "итоговое резюме")
    else:
        stage_pct("summary", len(chunks) / (len(chunks) + 1), "сведение фрагментов")
    raw = ollama_chat(
        REDUCE_SYSTEM,
        REDUCE_TEMPLATE.format(parts=json.dumps(partials, ensure_ascii=False, indent=2),
                               roster=roster),
    )
    final = parse_json_response(raw)
    speakers = sorted({item.label for item in utterances})
    analysis: dict[str, Any] = {
        "title": str(final.get("title", "")).strip(),
        "summary": str(final.get("summary", "")).strip(),
        "participants": [str(v).strip() for v in final.get("participants", []) if str(v).strip()]
        or speakers,
        "topics": [],
        "decisions": [],
        "risks": [],
        "questions": [],
        "todos": [],
        # Должности участников: их печатает документ, чтобы протокол читался
        # без вопроса «а кто это».
        "roles": roles,
    }
    for key in ("topics", "decisions", "risks", "questions"):
        _merge_unique(analysis[key], final.get(key, []))
        for partial in partials:
            _merge_unique(analysis[key], partial.get(key, []))

    seen_tasks: set[str] = set()
    for source in [final] + partials:
        for todo in source.get("todos", []) or []:
            if not isinstance(todo, dict):
                continue
            task = str(todo.get("task", "")).strip()
            if not task:
                continue
            key = _normalized(task)
            if key in seen_tasks:
                continue
            seen_tasks.add(key)
            analysis["todos"].append(
                {
                    "task": task,
                    "owner": str(todo.get("owner", "")).strip(),
                    "due": str(todo.get("due", "")).strip(),
                }
            )

    if not analysis["summary"]:
        raise LLMError("Модель не сформировала резюме встречи.")

    log(
        f"    решений: {len(analysis['decisions'])}, "
        f"поручений: {len(analysis['todos'])}, "
        f"рисков: {len(analysis['risks'])}"
    )
    stage_pct("summary", 1.0)
    return analysis


# --------------------------------------------------------------------------
# Документы
# --------------------------------------------------------------------------


def _docx():
    try:
        import docx  # noqa: F401
    except ImportError as exc:
        raise DependencyError(
            "Не установлен python-docx.", "pip install python-docx"
        ) from exc
    return __import__("docx")


def write_transcript_docx(path: Path, utterances: list[Utterance], title: str) -> None:
    docx = _docx()
    document = docx.Document()
    document.add_heading(title or "Стенограмма встречи", level=0)
    document.add_paragraph(datetime.now().strftime("Обработано: %d.%m.%Y %H:%M"))

    current = None
    for item in utterances:
        if item.label != current:
            current = item.label
            heading = document.add_paragraph()
            run = heading.add_run(current)
            run.bold = True
        stamp = time.strftime("%H:%M:%S", time.gmtime(max(0, item.start)))
        document.add_paragraph(f"[{stamp}] {item.text}")

    document.save(str(path))


def write_summary_docx(path: Path, analysis: dict[str, Any], warnings: list[str]) -> None:
    docx = _docx()
    document = docx.Document()
    document.add_heading(analysis.get("title") or "Итоги встречи", level=0)
    document.add_paragraph(datetime.now().strftime("Обработано: %d.%m.%Y %H:%M"))

    participants = analysis.get("participants") or []
    roles = analysis.get("roles") or {}
    if participants:
        document.add_heading("Участники", level=1)
        # Со списком должностей — по строке на человека: перечисление через
        # запятую с должностями читается как каша.
        if roles:
            lookup = {str(name).casefold(): role for name, role in roles.items()}
            for name in participants:
                role = lookup.get(str(name).strip().casefold(), "")
                document.add_paragraph(f"{name} — {role}" if role else str(name),
                                       style="List Bullet")
        else:
            document.add_paragraph(", ".join(participants))

    document.add_heading("Резюме", level=1)
    document.add_paragraph(analysis.get("summary", ""))

    sections = [
        ("Обсуждавшиеся темы", "topics"),
        ("Принятые решения", "decisions"),
        ("Риски и проблемы", "risks"),
        ("Открытые вопросы", "questions"),
    ]
    for heading, key in sections:
        values = analysis.get(key) or []
        if not values:
            continue
        document.add_heading(heading, level=1)
        for value in values:
            document.add_paragraph(str(value), style="List Bullet")

    todos = analysis.get("todos") or []
    if todos:
        document.add_heading("Поручения", level=1)
        table = document.add_table(rows=1, cols=3)
        table.style = "Table Grid"
        header = table.rows[0].cells
        header[0].text = "Задача"
        header[1].text = "Исполнитель"
        header[2].text = "Срок"
        for todo in todos:
            row = table.add_row().cells
            row[0].text = str(todo.get("task", ""))
            row[1].text = str(todo.get("owner", "")) or "не назначен"
            row[2].text = str(todo.get("due", "")) or "-"

    if warnings:
        document.add_heading("Замечания к обработке", level=1)
        for message in warnings:
            document.add_paragraph(str(message), style="List Bullet")

    document.save(str(path))


def write_mindmap(path: Path, analysis: dict[str, Any]) -> None:
    lines = [f"# {analysis.get('title') or 'Встреча'}", ""]

    def block(title: str, values: Sequence[Any]) -> None:
        if not values:
            return
        lines.append(f"## {title}")
        for value in values:
            lines.append(f"- {value}")
        lines.append("")

    block("Участники", analysis.get("participants") or [])
    block("Темы", analysis.get("topics") or [])
    block("Решения", analysis.get("decisions") or [])

    todos = analysis.get("todos") or []
    if todos:
        lines.append("## Поручения")
        for todo in todos:
            owner = str(todo.get("owner", "")).strip() or "не назначен"
            due = str(todo.get("due", "")).strip()
            suffix = f" (срок: {due})" if due else ""
            lines.append(f"- {todo.get('task', '')} — {owner}{suffix}")
        lines.append("")

    block("Риски", analysis.get("risks") or [])
    block("Открытые вопросы", analysis.get("questions") or [])

    path.write_text("\n".join(lines), encoding="utf-8")


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)


# --------------------------------------------------------------------------
# Подготовка каталогов
# --------------------------------------------------------------------------


def prepare_paths(source: Path, out_root: Optional[Path] = None) -> RunPaths:
    """Создать структуру результата, не уничтожая прошлые прогоны.

    SEC-04: прежняя clean_result_dir() вычищала существующий каталог, то есть
    повторная обработка того же файла молча удаляла предыдущую стенограмму,
    резюме и образцы голосов. Теперь прошлый результат переименовывается в
    <stem>_<таймстамп>_result: данные сохраняются и остаются видимыми в GUI,
    который ищет каталоги по маске *_result.
    """
    # По умолчанию результат ложится рядом с исходником - так удобнее из
    # командной строки. Приложение передаёт свою папку: иначе стенограмма
    # окажется там, откуда взяли файл, и в списке записей её не будет.
    parent = out_root if out_root is not None else source.parent
    parent.mkdir(parents=True, exist_ok=True)
    out_dir = parent / f"{source.stem}_result"
    archived_from = None

    if out_dir.exists() and any(out_dir.iterdir()):
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        archive = parent / f"{source.stem}_{stamp}_result"
        out_dir.rename(archive)
        archived_from = archive
        log(f"    прошлый результат сохранён как: {archive.name}")

    extra_dir = out_dir / EXTRA_DIR_NAME
    unknown_dir = extra_dir / UNKNOWN_DIR_NAME
    work_dir = extra_dir / "work"
    for folder in (out_dir, extra_dir, unknown_dir, work_dir):
        folder.mkdir(parents=True, exist_ok=True)

    return RunPaths(
        source=source,
        out_dir=out_dir,
        extra_dir=extra_dir,
        unknown_dir=unknown_dir,
        work_dir=work_dir,
        wav=work_dir / "audio_16k.wav",
        archived_from=archived_from,
    )


# --------------------------------------------------------------------------
# Пайплайн
# --------------------------------------------------------------------------


def run_pipeline(
    source: Path,
    profiles_dir: Path = DEFAULT_PROFILES_DIR,
    with_diarization: bool = True,
    with_summary: bool = True,
    keep_audio: bool = False,
    voice_track: Optional[Path] = None,
    voice_name: str = "Вы",
    voice_position: str = "",
    voice_company: str = "",
    out_root: Optional[Path] = None,
    with_llm: bool = True,
    speakers: int = 0,
    group_projects: bool = False,
) -> RunState:
    started = time.time()

    stage_start("prepare")
    if not source.is_file():
        raise InputError(f"Файл не найден: {source}")
    profiles_dir.mkdir(parents=True, exist_ok=True)
    paths = prepare_paths(source, out_root)
    state = RunState(paths=paths)
    log(f"    исходный файл: {source.name}")
    log(f"    каталог результата: {paths.out_dir}")
    if with_diarization:
        refresh_pending_profiles(profiles_dir)

    stage_start("audio")
    state.duration = decode_to_wav16k(source, paths.wav)
    log(f"    длительность: {state.duration / 60:.1f} мин")

    stage_start("asr")
    utterances = transcribe(paths.wav, state.duration)
    write_json(
        paths.extra_dir / "whisper.json",
        [asdict(item) for item in utterances],
    )

    # Своя дорожка разбирается отдельно: она заведомо принадлежит одному
    # человеку, поэтому опознавать её голос не нужно. Заодно это снимает
    # главную беду записи звонка - один и тот же звук, пойманный дважды:
    # микрофоном из динамиков и системным захватом.
    own: list = []
    if voice_track and voice_track.is_file():
        log(f"    отдельная дорожка: {voice_track.name}")
        own_wav = paths.work_dir / "voice_16k.wav"
        decode_to_wav16k(voice_track, own_wav)
        for item in transcribe(own_wav, 0.0):
            item.speaker_id = "OWN"
            item.speaker_name = voice_name
            own.append(item)
        log(f"    ваших реплик: {len(own)}")

    # Meeting ASR is finished. Keeping its cached model through diarization
    # and the LLM step wastes memory on 8-GB office machines.
    global _whisper_model
    _whisper_model = None
    if ASR_ENGINE.startswith("giga"):
        _engine().release_asr()
    import gc
    gc.collect()

    stage_start("quality")
    utterances, warnings = quality_gate(utterances, state.duration)
    state.warnings = warnings

    glossary = load_glossary()
    if glossary:
        # Здесь только детерминированный проход: он мгновенный, узнаёт
        # аббревиатуры по тому, как их произносят («си джей эм» -> CJM), и не
        # трогает падежи.
        #
        # Второй проход, языковой моделью, перенесён в сборку резюме. Он
        # делает десятки обращений подряд и однажды встал намертво посреди
        # обработки: ядро двадцать минут ждало ответа, которого не пришло.
        # Расшифровке он не нужен, а необязательный шаг не вправе держать
        # обязательный.
        stage_pct("quality", 0.4, "восстановление терминов")
        fixed = _local("glossary_fix").repair(utterances, glossary)
        if fixed:
            log(f"    восстановлено терминов по словарю: {fixed}")

    turns: list[dict[str, Any]] = []
    if with_diarization:
        stage_start("diarization")
        if speakers and speakers > 0:
            log(f"    участников задано: {speakers}")
        turns = diarize(paths.wav, speakers)
        turns = join_adjacent(turns)
        turns = merge_split_voices(paths.wav, turns)
        write_json(paths.extra_dir / "diarization.json", turns)
    else:
        log("Разделение на спикеров пропущено (--no-diarization)")

    assign_speakers(utterances, turns)
    # A phrase may split at a speaker change. Word timings retain original ASR
    # tokens, so apply deterministic terminology repair to the final pieces.
    if glossary:
        _local("glossary_fix").repair(utterances, glossary)

    hints: dict = {}
    names: dict = {}
    if with_diarization and turns:
        stage_start("identify")
        state.matches = identify_speakers(paths.wav, turns, profiles_dir)
        names.update({m.speaker_id: m.name for m in state.matches if m.known})
        for item in utterances:
            item.speaker_name = ("Голос не определён" if item.speaker_id.startswith("UNASSIGNED_")
                                 else names.get(item.speaker_id, ""))

        # Имена определяем ДО выгрузки образцов: подсказка попадает в имя
        # WAV-файла и сразу видна пользователю в разделе «Новые голоса».
        #
        # От резюме это не зависит. Раньше зависело, и с выключенным резюме
        # пропадала одна из главных вещей - подсказка, кто говорит.
        if with_llm and INFER_NAMES:
            stage_start("names")
            hints = infer_speaker_names(utterances, paths.extra_dir)
            state.name_hints = hints
            for item in utterances:
                hint = hints.get(item.speaker_id)
                if not item.speaker_name and hint and hint.get("applied"):
                    item.speaker_name = hint["name"]
            names.update({k: v["name"] for k, v in hints.items() if v.get("applied")})

        unknown = export_unknown_voices(
            paths.wav, state.matches, paths.unknown_dir, hints, turns
        )
        write_json(
            paths.extra_dir / "speaker_recognition.json",
            [asdict(match) for match in state.matches],
        )
        write_json(paths.extra_dir / "unknown_speakers.json", unknown)
        write_json(paths.extra_dir / "speaker_names.json", names)
    else:
        log("Опознание голосов пропущено")

    if own:
        before = len(own)
        own = drop_echo(own, utterances)
        if before != len(own):
            log(f"    отброшено эхо динамиков с микрофона: {before - len(own)}")
        utterances = sorted(utterances + own, key=lambda x: x.start)
        log(f"    в стенограмме реплик: {len(utterances)}")

        # Свои реплики нужно добавить и в диаризацию, иначе на голосовой
        # ленте вас не видно: она рисуется по diarization.json, а он
        # описывает только дорожку с собеседниками.
        if with_diarization:
            turns = sorted(turns + [
                {"start": item.start, "end": item.end, "speaker": "OWN"}
                for item in own
            ], key=lambda t: t["start"])
            write_json(paths.extra_dir / "diarization.json", turns)
            names["OWN"] = voice_name
            write_json(paths.extra_dir / "speaker_names.json", names)
            log(f"    ваши реплики добавлены на ленту: {len(own)}")

    stage_start("transcript")
    state.utterances = utterances
    transcript = {
        "version": APP_VERSION,
        "source": source.name,
        # Полный путь нужен интерфейсу: результат может лежать в отдельной
        # папке, и тогда рядом с ним исходной записи нет, а фрагменты реплик
        # проигрываются именно из неё.
        "source_path": str(source),
        "duration": round(state.duration, 2),
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "warnings": warnings,
        "speakers": sorted({item.label for item in utterances}),
        "utterances": [asdict(item) for item in utterances],
    }
    write_json(paths.out_dir / TRANSCRIPT_JSON, transcript)
    write_json(paths.extra_dir / TRANSCRIPT_JSON, transcript)

    if with_summary:
        stage_start("summary")
        try:
            state.analysis = analyze_meeting(
                utterances, paths.extra_dir, profiles_dir,
                {"name": voice_name, "position": voice_position, "company": voice_company})
        except LLMError as exc:
            # Стенограмма и разделение по голосам уже готовы. Ронять прогон
            # из-за необязательной части - значит выбросить сделанную работу.
            # На очень коротких записях модели просто не из чего собирать
            # резюме, и это нормально.
            warn(f"Резюме не собрано: {exc}")
            state.warnings.append("Резюме встречи не удалось собрать")
            with_summary = False
            state.analysis = {
                "title": source.stem,
                "summary": "",
                "participants": sorted({item.label for item in utterances}),
            }
    else:
        log("Анализ встречи пропущен (--no-summary)")
        state.analysis = {
            "title": source.stem,
            "summary": "",
            "participants": sorted({item.label for item in utterances}),
        }

    stage_start("documents")
    title = state.analysis.get("title") or source.stem
    write_transcript_docx(paths.out_dir / TRANSCRIPT_DOCX, utterances, title)
    if with_summary:
        write_summary_docx(paths.out_dir / SUMMARY_DOCX, state.analysis, warnings)
        write_mindmap(paths.out_dir / MINDMAP_MD, state.analysis)
        write_json(paths.extra_dir / "final_analysis.json", state.analysis)

    if not keep_audio:
        # Рабочий WAV удаляем: это самый объёмный и самый чувствительный
        # артефакт (SEC-05). Образцы новых голосов остаются - они нужны GUI.
        try:
            paths.wav.unlink(missing_ok=True)
            paths.work_dir.rmdir()
        except OSError:
            pass

    # Проект и тип встречи. Считаем по резюме, поэтому только когда оно есть
    # и когда человек попросил раскладывать: лишний запрос к модели стоит
    # десятки секунд, а без резюме относить встречу всё равно не к чему.
    result_dir = paths.out_dir
    if with_summary and group_projects:
        log("")
        log("Определяю проект встречи")
        card = classify_meeting(state.analysis, load_projects())
        write_json(paths.out_dir / MEETING_JSON, card)
        if card.get("needs_review"):
            reason = "проекта нет в списке" if card.get("project") else "не хватает данных"
            log(f"    проект не определён: {reason} — встреча ждёт уточнения")
        else:
            result_dir = move_to_project(paths.out_dir, card["project"])
            log(f"    {card['project']} · {card['type']}")

    elapsed = time.time() - started
    progress("documents", 100, "готово")
    log("")
    log(f"Готово за {elapsed / 60:.1f} мин.")
    log(f"Результат: {result_dir}")
    unknown_count = sum(1 for m in state.matches if not m.known)
    if unknown_count:
        log(f"Новых голосов, требующих определения: {unknown_count}")
    return state


def summarize_existing(result_dir: Path, group_projects: bool = False,
                       me: Optional[dict[str, str]] = None) -> int:
    """Собрать резюме по уже готовой стенограмме.

    Анализ вынесен из основного прогона: он самый долгий и единственный,
    кому нужна языковая модель. Расшифровка и разделение по голосам ценны
    сами по себе, и ждать ради них ещё несколько минут незачем. Резюме
    делается потом, по кнопке, и только для тех встреч, где оно нужно.
    """
    result_dir = Path(result_dir).expanduser().resolve()
    transcript = result_dir / TRANSCRIPT_JSON
    if not transcript.is_file():
        raise InputError(f"Нет стенограммы: {transcript}")

    data = json.loads(transcript.read_text(encoding="utf-8"))
    fields = set(Utterance.__dataclass_fields__)
    utterances = [
        Utterance(**{k: v for k, v in row.items() if k in fields})
        for row in data.get("utterances", [])
    ]
    if not utterances:
        raise InputError("Стенограмма пуста — резюме собирать не из чего.")

    extra_dir = result_dir / EXTRA_DIR_NAME
    extra_dir.mkdir(parents=True, exist_ok=True)

    log(f"Резюме для: {result_dir.name}")
    log(f"    реплик в стенограмме: {len(utterances)}")

    preflight(need_llm=True, need_diarization=False)

    stage_start("summary")

    # Сверка терминов моделью идёт здесь, вместе с анализом: это работа той же
    # языковой модели, и делается она по запросу, а не в каждом прогоне.
    glossary = load_glossary()
    if glossary and NORMALIZE_TERMS:
        if normalize_terminology(utterances, glossary):
            data["utterances"] = [asdict(item) for item in utterances]
            write_json(transcript, data)
            write_json(extra_dir / TRANSCRIPT_JSON, data)

    analysis = analyze_meeting(utterances, extra_dir, DEFAULT_PROFILES_DIR, me)

    stage_start("documents")
    warnings = list(data.get("warnings", []))
    title = analysis.get("title") or result_dir.name.removesuffix("_result")
    write_summary_docx(result_dir / SUMMARY_DOCX, analysis, warnings)
    write_mindmap(result_dir / MINDMAP_MD, analysis)
    write_json(extra_dir / "final_analysis.json", analysis)
    # Заголовок стенограммы до анализа был техническим - именем файла.
    # Теперь известно настоящее название встречи, и документ стоит обновить.
    write_transcript_docx(result_dir / TRANSCRIPT_DOCX, utterances, title)

    # Резюме собирают по кнопке, и это единственный момент, когда о встрече
    # известно достаточно, чтобы отнести её к проекту.
    final_dir = result_dir
    if group_projects:
        log("")
        log("Определяю проект встречи")
        card = classify_meeting(analysis, load_projects())
        write_json(result_dir / MEETING_JSON, card)
        if card.get("needs_review"):
            log("    проект не определён — встреча ждёт уточнения")
        else:
            final_dir = move_to_project(result_dir, card["project"])
            log(f"    {card['project']} · {card['type']}")

    progress("documents", 100, "готово")
    log("")
    log(f"Резюме готово: {final_dir / SUMMARY_DOCX}")
    return 0


def enroll(name: str, samples, position: str, company: str, profiles_dir: Path) -> int:
    """Завести человека по нескольким образцам голоса.

    Один человек на встрече часто разбивается диаризацией на несколько
    голосов - из-за смены громкости, микрофона или пауз. Объединять их в
    один профиль нужно обязательно: иначе профиль строится по обрывку и
    человек перестаёт узнаваться.

    Если человек с таким именем уже есть, образцы добавляются к нему, и
    отпечаток пересчитывается по всем накопленным записям сразу.
    """
    name = (name or "").strip()
    if not name:
        raise InputError("Не указано имя человека.")

    files = [Path(x).expanduser().resolve() for x in samples]
    missing = [f for f in files if not f.is_file()]
    if missing:
        raise InputError("Не найдены образцы: " + ", ".join(m.name for m in missing))
    if not files:
        raise InputError("Не передано ни одного образца голоса.")

    profiles_dir.mkdir(parents=True, exist_ok=True)
    profiles = load_profiles(profiles_dir)

    key = next((k for k, info in profiles.items()
                if str(info.get("name", "")).strip() == name), "")
    if key:
        log(f"Дополняю профиль: {name}")
    else:
        base = safe_key(name)
        key, index = base, 2
        while key in profiles:
            key = f"{base}_{index}"
            index += 1
        now = datetime.now().isoformat(timespec="seconds")
        profiles[key] = {
            "name": name, "position": position.strip(), "company": company.strip(),
            "profile_file": "", "samples": 0,
            "created_at": now, "updated_at": now,
        }
        save_profiles(profiles_dir, profiles)
        log(f"Создаю профиль: {name}")

    folder = samples_dir(profiles_dir, key)
    for source in files:
        shutil.copy2(source, folder / f"{uuid.uuid4().hex}.wav")
    log(f"    добавлено образцов: {len(files)}")

    if not rebuild_embedding(profiles_dir, key):
        raise DiarizationError(
            "Не удалось построить голосовой отпечаток.",
            "Возможно, все образцы короче секунды.")

    total = len(sorted(folder.glob("*.wav")))
    from speaker_links import link_sample
    for source in files:
        link_sample(source, key)
    log(f"Готово. Всего образцов у человека: {total}")
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


# --------------------------------------------------------------------------
# Готовность окружения и дозагрузка
#
# Одно место, которое знает, чего не хватает и что из этого можно дозагрузить
# на месте. Интерфейсы — маковский на Swift и виндовый на Python — только
# показывают список и нажимают кнопку: решение принимается здесь, чтобы на
# разных системах оно не разъезжалось.
# --------------------------------------------------------------------------

LLM_SIZE_MB = 5200
WHISPER_SIZE_MB = 1500


def cached_whisper_path():
    """Resolve installed weights offline; reuse this exact path when loading."""
    local = Path(WHISPER_MODEL).expanduser()
    if local.is_dir():
        return str(local) if all((local / name).is_file() and (local / name).stat().st_size > 0
                   for name in ("model.bin", "config.json", "tokenizer.json")) else None
    try:
        # Resolves the installed faster-whisper model mapping and cache refs;
        # local_files_only forbids downloads, unlike mere folder existence.
        from faster_whisper.utils import download_model
        cached = Path(download_model(WHISPER_MODEL, local_files_only=True))
        return str(cached) if all((cached / name).is_file() and (cached / name).stat().st_size > 0
                   for name in ("model.bin", "config.json", "tokenizer.json")) else None
    except Exception:
        return None


def whisper_cached() -> bool:
    return ASR_ENGINE.startswith("giga") or cached_whisper_path() is not None


def _speech_models():
    """Какие onnx-модели нужны, каких нет и сколько недостающие весят."""
    try:
        engine = _engine()
        names = list(engine.DIARIZATION_MODELS) + ["vad"]
        if ASR_ENGINE.startswith("giga"):
            names += list(engine.ASR_MODELS_CTC)
        absent = list(engine.missing(names))
        return names, absent, sum(engine.MODELS[n]["size_mb"] for n in absent)
    except Exception:  # noqa: BLE001 - без библиотек модуль может не подняться
        return [], ["не удалось проверить модели"], 0


def document_packages_missing() -> list:
    from importlib.metadata import version, PackageNotFoundError
    missing = []
    for package, minimum in [("pypdf", (6, 18)), ("python-docx", (1, 1))]:
        try:
            installed = tuple(int(part) for part in version(package).split(".")[:2])
            if installed < minimum:
                missing.append(package)
        except (PackageNotFoundError, ValueError):
            missing.append(package)
    return missing


def readiness() -> dict:
    """Что на месте, чего нет и что из этого дозагружается кнопкой."""
    items = []

    packages = packages_missing()
    items.append({
        "key": "packages",
        "title": "Библиотеки распознавания",
        "state": "ok" if not packages else "missing",
        "detail": ", ".join(packages),
        "size_mb": 0,
        # Библиотеки ставит установщик: ему нужны интернет, компилятор и
        # права, которых у окна программы нет.
        "fixable": False,
    })

    document_packages = document_packages_missing()
    items.append({
        "key": "documents", "title": "Чтение PDF и Word",
        "state": "missing" if document_packages else "ok",
        "detail": ", ".join(document_packages), "size_mb": 0, "fixable": False,
    })

    _, absent, size = ([], ["сначала восстановите библиотеки"], 0) if packages else _speech_models()
    items.append({
        "key": "speech",
        "title": "Модели разделения голосов",
        "state": "ok" if not absent else "missing",
        "detail": ", ".join(absent),
        "size_mb": size,
        "fixable": True,
    })

    asr_ready = not packages and whisper_cached()
    items.append({
        "key": "asr",
        "title": f"Модель распознавания речи ({WHISPER_MODEL})",
        "state": "ok" if asr_ready else ("unknown" if packages else "missing"),
        "detail": "сначала восстановите библиотеки для проверки" if packages else "",
        "size_mb": WHISPER_SIZE_MB if not asr_ready and not packages else 0,
        "fixable": True,
    })

    binary = ollama_binary()
    local = OLLAMA_HOST.rstrip("/") == "http://127.0.0.1:11434"
    running = local and ollama_running()
    items.append({
        "key": "ollama",
        "title": "Ollama",
        "state": "ok" if running else ("stopped" if binary else "missing"),
        "detail": "" if running else ("установлена, но не запущена" if binary
                                      else "не установлена"),
        "size_mb": 0,
        # Скачать саму Ollama отсюда мы не беремся: это дело установщика, у
        # него есть права на /Applications. А запустить уже установленную —
        # можем, и именно этого не хватало чаще всего.
        "fixable": binary is not None,
    })

    # Пока сервер молчит, о моделях спрашивать некого — это «неизвестно», а не
    # «нет»: сказать «модели нет» и отправить человека качать пять гигабайт
    # заново было бы враньём.
    model_state = ("ok" if ollama_has_model() else "missing") if running else "unknown"
    items.append({
        "key": "llm",
        "title": f"Языковая модель {OLLAMA_MODEL}",
        "state": model_state,
        "detail": "" if model_state != "unknown" else "неизвестно, пока Ollama не запущена",
        "size_mb": LLM_SIZE_MB if model_state == "missing" else 0,
        "fixable": binary is not None,
    })

    incomplete = [item for item in items if item["state"] != "ok"]
    return {
        "version": APP_VERSION,
        "ok": not incomplete,
        "items": items,
        "missing": [item["key"] for item in incomplete],
        "can_repair": any(item["fixable"] for item in incomplete),
        "needs_setup": any(not item["fixable"] for item in incomplete),
        "size_mb": sum(item["size_mb"] for item in incomplete),
    }


def pull_model(name: str) -> int:
    """Скачать языковую модель по имени, подняв Ollama, если она не запущена.

    Отдельная команда, а не часть --repair: там дозагружается то, чего не
    хватает для работы, а здесь человек осознанно берёт другую модель —
    полегче или потяжелее, — и менять ради этого настройки заранее незачем.
    """
    name = (name or "").strip()
    if not name:
        log("ОШИБКА: не указано имя модели")
        return 2
    if OLLAMA_HOST.rstrip("/") != "http://127.0.0.1:11434":
        log("ОШИБКА: загрузка доступна только для локальной Ollama")
        log(f"  Сейчас указана {OLLAMA_HOST}")
        return 2

    progress("llm", 5, name)
    if not ollama_running():
        log("Запускаю Ollama")
        if not ollama_serve():
            log("")
            log("ОШИБКА: Ollama не запустилась")
            log("  Установите Ollama или запустите её вручную: ollama serve")
            return 1
    if name in ollama_models():
        log(f"Модель {name} уже установлена.")
        progress("llm", 100, "готово")
        return 0
    if not ollama_pull(name, base=5.0, scale=0.94):
        log("")
        log(f"ОШИБКА: не удалось скачать {name}")
        log("  Проверьте имя модели и связь с интернетом.")
        return 1
    progress("llm", 100, "готово")
    log(f"Модель {name} установлена.")
    return 0


def repair(allow_download: bool = False) -> int:
    """Дозагрузить недостающее и поднять то, что не запущено."""
    if OLLAMA_HOST.rstrip("/") != "http://127.0.0.1:11434":
        log("Восстановление доступно только для локальной Ollama: http://127.0.0.1:11434")
        return 2
    if not allow_download:
        log("Загрузка не разрешена. Используйте --repair --allow-download после явного согласия на интернет.")
        return 2
    report = readiness()
    if report["ok"]:
        log("Всё на месте — дозагружать нечего.")
        return 0
    if report["needs_setup"]:
        broken = next(item for item in report["items"]
                      if item["state"] != "ok" and not item["fixable"])
        log("")
        log(f"ОШИБКА: не хватает того, что ставит установщик: {broken['title']}")
        if broken["detail"]:
            log(f"  {broken['detail']}")
        log("  Подсказка: запустите установку заново кнопкой «Установить».")
        return 2

    states = {item["key"]: item for item in report["items"]}

    progress("models", 5, "")
    if states["speech"]["state"] != "ok":
        log("Догружаю модели разделения голосов")
        names, _, _ = _speech_models()
        try:
            _engine().ensure_models(names, log=log)
        except Exception as exc:  # noqa: BLE001
            warn(f"модели разделения голосов не догрузились: {exc}")

    progress("asr", 20, "")
    if states["asr"]["state"] != "ok":
        log(f"Догружаю модель распознавания речи (~{WHISPER_SIZE_MB} МБ)")
        try:
            whisper_model()
            log("    модель распознавания на месте")
        except Exception as exc:  # noqa: BLE001
            warn(f"модель распознавания не догрузилась: {exc}")

    progress("ollama", 40, "")
    if states["ollama"]["state"] != "ok":
        log("Запускаю Ollama")
        if ollama_serve():
            log("    Ollama запущена")
        else:
            warn("Ollama не запустилась. Резюме и определение имён будут пропущены.")

    progress("llm", 45, "")
    if ollama_running() and not ollama_has_model():
        ollama_pull()

    final = readiness()
    progress("llm", 100, "готово")
    log("")
    if final["ok"]:
        log("Всё на месте.")
        return 0
    log("Осталось незакрытым:")
    for item in final["items"]:
        if item["state"] != "ok":
            log(f"  - {item['title']}: {item['detail'] or 'нет на месте'}")
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="meeting_transcriber_v25_1.py",
        description="Локальная обработка записи встречи: расшифровка, спикеры, резюме.",
    )
    parser.add_argument("input", nargs="?", type=Path, help="видео- или аудиофайл встречи")
    parser.add_argument(
        "--profiles",
        type=Path,
        default=DEFAULT_PROFILES_DIR,
        help="каталог профилей спикеров",
    )
    parser.add_argument("--language", default=None, help="язык записи (ru, en, auto)")
    parser.add_argument("--no-diarization", action="store_true", help="без разделения на спикеров")
    parser.add_argument("--no-summary", action="store_true", help="без анализа через Ollama")
    parser.add_argument("--keep-audio", action="store_true", help="не удалять рабочий WAV")
    parser.add_argument("--my-voice", type=Path, default=None,
                        help="отдельная дорожка с вашим голосом (микрофон)")
    parser.add_argument("--my-name", default="Вы",
                        help="как подписывать реплики с вашей дорожки")
    parser.add_argument("--my-position", default="",
                        help="ваша должность: уходит в справку о людях для резюме")
    parser.add_argument("--my-company", default="",
                        help="ваша компания: уходит в справку о людях для резюме")
    parser.add_argument("--speakers", type=int, default=0,
                        help="сколько человек на встрече (0 - определить самой)")
    parser.add_argument("--out-dir", type=Path, default=None,
                        help="куда складывать результат (по умолчанию рядом с исходником)")
    parser.add_argument("--summarize", type=Path, default=None, metavar="КАТАЛОГ",
                        help="собрать резюме по готовой стенограмме в каталоге _result")
    parser.add_argument("--assign", type=Path, default=None, metavar="КАТАЛОГ",
                        help="отнести встречу к проекту из --project")
    parser.add_argument("--split-voice", type=Path, default=None, metavar="КАТАЛОГ",
                        help="разделить один голос встречи на нескольких человек")
    parser.add_argument("--voice", default="", help="какой голос делить, например SPEAKER_02")
    parser.add_argument("--into", type=int, default=2, help="на сколько человек делить")
    parser.add_argument("--clarify", type=Path, default=None, metavar="КАТАЛОГ",
                        help="переспросить модель с ответами из --answers")
    parser.add_argument("--project", default="", help="название проекта для --assign")
    parser.add_argument("--answers", default="", help="ответы человека для --clarify")
    parser.add_argument("--add-project", action="store_true",
                        help="с --assign: запомнить проект в списке")
    parser.add_argument("--group-by-project", action="store_true",
                        help="определить проект встречи и разложить по папкам")
    parser.add_argument("--check", action="store_true", help="только проверить окружение")
    parser.add_argument("--start-services", action="store_true", help="запустить установленную локальную Ollama без загрузок")
    parser.add_argument("--json", action="store_true",
                        help="с --check: выдать отчёт о готовности машинно")
    parser.add_argument("--allow-download", action="store_true", help="явно разрешить загрузки при --repair")
    parser.add_argument("--pull-model", default="", metavar="ИМЯ",
                        help="скачать языковую модель Ollama по имени")
    parser.add_argument("--repair", action="store_true",
                        help="дозагрузить недостающее и запустить Ollama")
    parser.add_argument("--enroll", metavar="ИМЯ",
                        help="завести человека или дополнить существующего")
    parser.add_argument("--samples", nargs="+", type=Path, default=[],
                        help="WAV-образцы голоса для --enroll")
    parser.add_argument("--position", default="", help="должность для --enroll")
    parser.add_argument("--company", default="", help="компания для --enroll")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    global WHISPER_LANGUAGE

    speak_utf8()
    args = build_parser().parse_args(argv)
    if args.language:
        WHISPER_LANGUAGE = args.language

    # Машинный отчёт печатается один и без спутников: интерфейсу иначе
    # пришлось бы выковыривать JSON из человеческого текста.
    if args.check and args.json:
        if args.start_services:
            ollama_serve(wait_seconds=15)
        print(json.dumps(readiness(), ensure_ascii=False))
        return 0

    log(f"Meeting Transcriber v{APP_VERSION}")

    if args.pull_model:
        return pull_model(args.pull_model)

    if args.repair:
        return repair(allow_download=args.allow_download)

    if args.check:
        try:
            llm_ready = preflight(need_llm=True, need_diarization=True)
        except DependencyError as exc:
            log(str(exc))
            if exc.hint:
                log(f"    {exc.hint}")
            return 1
        if llm_ready:
            log("Окружение готово: расшифровка, спикеры и резюме.")
        else:
            log("Окружение готово частично: расшифровка и спикеры работают, резюме - нет.")
        return 0

    if args.assign:
        if not args.project.strip():
            log("Укажите проект: --project «название»")
            return 2
        return assign_project(args.assign, args.project.strip(), args.add_project)

    if args.split_voice:
        try:
            return split_voice(args.split_voice, args.voice.strip(), args.into)
        except PipelineError as exc:
            log(f"ОШИБКА: {exc.user_message}")
            log(f"  {exc}")
            return 1

    if args.clarify:
        return clarify_project(args.clarify, args.answers)

    if args.summarize:
        try:
            return summarize_existing(
                args.summarize, args.group_by_project,
                {"name": args.my_name, "position": args.my_position,
                 "company": args.my_company})
        except PipelineError as exc:
            log("")
            log(f"ОШИБКА: {exc.user_message}")
            log(f"  {exc}")
            if exc.hint:
                log(f"  Подсказка: {exc.hint}")
            return 1

    if args.enroll:
        try:
            return enroll(args.enroll, args.samples, args.position, args.company,
                          args.profiles.expanduser().resolve())
        except PipelineError as exc:
            log(f"ОШИБКА: {exc}")
            if exc.hint:
                log(f"  {exc.hint}")
            return 1

    if args.input is None:
        build_parser().print_usage()
        log("Укажите файл записи.")
        return 2

    source = args.input.expanduser().resolve()
    paths: Optional[RunPaths] = None

    try:
        # Языковая модель нужна не только резюме: ею же определяются имена
        # участников и выправляются термины. Поэтому спрашиваем о ней всегда,
        # но её отсутствие валит только резюме.
        # Языковую модель проверяем всегда, даже когда резюме не просят: ею
        # же определяются имена участников и выправляются термины. Раньше при
        # --no-summary проверка пропускалась, и llm_ready оказывался True без
        # всяких оснований - обращения к неработающей Ollama шли вслепую.
        llm_ready = preflight(need_llm=True,
                              need_diarization=not args.no_diarization)
        state = run_pipeline(
            source,
            profiles_dir=args.profiles.expanduser().resolve(),
            with_diarization=not args.no_diarization,
            with_summary=(not args.no_summary) and llm_ready,
            with_llm=llm_ready,
            keep_audio=args.keep_audio,
            voice_track=args.my_voice.expanduser().resolve() if args.my_voice else None,
            voice_name=args.my_name,
            voice_position=args.my_position,
            voice_company=args.my_company,
            out_root=args.out_dir.expanduser().resolve() if args.out_dir else None,
            speakers=args.speakers,
            group_projects=args.group_by_project,
        )
        paths = state.paths
        return 0
    except PipelineError as exc:
        log("")
        log(f"ОШИБКА: {exc.user_message}")
        log(f"  {exc}")
        if exc.hint:
            log(f"  Подсказка: {exc.hint}")
        if paths is not None:
            (paths.extra_dir / "TEMP_PATH.txt").write_text(
                f"{paths.work_dir}\n", encoding="utf-8"
            )
        return 1
    except KeyboardInterrupt:
        log("")
        log("Обработка прервана пользователем.")
        return 130
    except Exception as exc:  # noqa: BLE001 - последний рубеж, чтобы GUI получил текст
        log("")
        log("ОШИБКА: непредвиденный сбой при обработке.")
        log(f"  {type(exc).__name__}: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
