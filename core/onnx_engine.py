"""Речевой движок Славатора на sherpa-onnx.

Заменяет связку pyannote + torch. Причина не в качестве, а в том, что модели
pyannote закрыты гейтом: каждому пользователю пришлось бы заводить аккаунт на
HuggingFace, создавать токен и принимать условия двух моделей. Для программы,
которую передают коллеге одним файлом, это неприемлемо.

Здесь всё открытое и без регистрации:

    распознавание речи   GigaAM v3 (ONNX-сборка NeMo CTC), опционально
    разделение голосов   pyannote-segmentation-3.0, конвертированная в ONNX
    отпечаток голоса     WeSpeaker VoxCeleb ResNet34-LM, 256 измерений
    детектор речи        Silero VAD

Побочный выигрыш: уходит torch, и установка сокращается примерно с 3 ГБ до
250 МБ.

Модуль не импортирует sherpa_onnx на верхнем уровне: главное окно подгружает
ядро только ради работы с профилями, и платить за это загрузкой движка не
должно.
"""
import os
import shutil
import tarfile
import urllib.error
import urllib.request
import wave
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SAMPLE_RATE = 16000
EMBEDDING_DIM = 256

# Как называется набор отпечатков. Пишется в profiles.json: если движок
# сменился, старые векторы несопоставимы и профили нужно пересобрать.
EMBEDDING_ID = "sherpa-wespeaker-voxceleb-resnet34-LM"

MODELS_DIR = Path(
    os.environ.get("MEETING_TRANSCRIBER_MODELS", str(Path.home() / "whisper-work" / "models"))
).expanduser()

_GH = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
_HF = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16/resolve/main"

# Каждая запись: куда положить -> откуда взять. Архивы распаковываются.
MODELS: Dict[str, Dict[str, Any]] = {
    "segmentation": {
        "check": "sherpa-onnx-pyannote-segmentation-3-0/model.onnx",
        "url": f"{_GH}/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
        "archive": True,
        "size_mb": 7,
        "title": "разделение голосов",
    },
    "embedding": {
        "check": "wespeaker_en_voxceleb_resnet34_LM.onnx",
        "url": f"{_GH}/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx",
        "size_mb": 26,
        "title": "отпечатки голосов",
    },
    "vad": {
        "check": "silero_vad.onnx",
        "url": f"{_GH}/asr-models/silero_vad.onnx",
        "size_mb": 1,
        "title": "детектор речи",
    },
    # CTC-сборка, а не трансдьюсер: у трансдьюсерной версии в decoder.onnx
    # нет метаданных vocab_size, и sherpa-onnx её не принимает.
    "asr_ctc": {
        "check": "gigaam-v3-ctc/model.int8.onnx",
        "url": f"{_HF}/model.int8.onnx",
        "size_mb": 215,
        "title": "распознавание речи (GigaAM)",
    },
    "asr_ctc_tokens": {
        "check": "gigaam-v3-ctc/tokens.txt",
        "url": f"{_HF}/tokens.txt",
        "size_mb": 1,
        "title": "словарь распознавателя",
    },
}

DIARIZATION_MODELS = ("segmentation", "embedding")
ASR_MODELS_CTC = ("asr_ctc", "asr_ctc_tokens")


class EngineError(Exception):
    """Ошибка движка с текстом, пригодным для показа пользователю."""


def _sherpa():
    try:
        import sherpa_onnx
    except ImportError as exc:
        raise EngineError(
            "Не установлен sherpa-onnx. Выполните: pip install sherpa-onnx"
        ) from exc
    return sherpa_onnx


# --------------------------------------------------------------------------
# Модели
# --------------------------------------------------------------------------


def model_path(name: str) -> Path:
    return MODELS_DIR / MODELS[name]["check"]


def missing(names) -> List[str]:
    return [n for n in names if not model_path(n).exists()]


def ensure_models(names, log=print) -> None:
    """Догрузить недостающие модели. Уже имеющиеся не трогаются."""
    todo = missing(names)
    if not todo:
        return

    total = sum(MODELS[n]["size_mb"] for n in todo)
    log(f"    Нужно загрузить моделей: {len(todo)} (~{total} МБ)")
    MODELS_DIR.mkdir(parents=True, exist_ok=True)

    for name in todo:
        spec = MODELS[name]
        target = model_path(name)
        target.parent.mkdir(parents=True, exist_ok=True)
        log(f"    Загружаю: {spec['title']} (~{spec['size_mb']} МБ)")

        tmp = MODELS_DIR / f".{name}.part"
        try:
            with urllib.request.urlopen(spec["url"], timeout=120) as response, \
                 tmp.open("wb") as handle:
                shutil.copyfileobj(response, handle)
        except (urllib.error.URLError, OSError) as exc:
            tmp.unlink(missing_ok=True)
            raise EngineError(
                f"Не удалось загрузить модель «{spec['title']}». "
                "Проверьте подключение к интернету."
            ) from exc

        if spec.get("archive"):
            with tarfile.open(tmp, "r:bz2") as archive:
                # Архив приходит из сети: не разрешаем именам выйти
                # за MODELS_DIR или создать опасные ссылки.
                archive.extractall(MODELS_DIR, filter="data")
            tmp.unlink(missing_ok=True)
        else:
            tmp.replace(target)

        if not target.exists():
            raise EngineError(f"Модель «{spec['title']}» загрузилась не полностью.")
    log("    Модели на месте")


# --------------------------------------------------------------------------
# Чтение звука
# --------------------------------------------------------------------------


def read_wav(path: Path, start: Optional[float] = None, end: Optional[float] = None):
    """Прочитать WAV 16 кГц mono в float32 [-1, 1]."""
    import numpy as np

    with wave.open(str(path), "rb") as handle:
        rate = handle.getframerate()
        channels = handle.getnchannels()
        total = handle.getnframes()

        first = 0 if start is None else max(0, int(start * rate))
        last = total if end is None else min(total, int(end * rate))
        if last <= first:
            return np.zeros(0, dtype="float32"), rate

        handle.setpos(first)
        raw = handle.readframes(last - first)

    audio = np.frombuffer(raw, dtype=np.int16).astype("float32") / 32768.0
    if channels > 1:
        audio = audio.reshape(-1, channels).mean(axis=1)
    return audio, rate


# --------------------------------------------------------------------------
# Разделение по голосам
# --------------------------------------------------------------------------

_diarizer = None
_diarizer_key: Tuple = ()


def diarize(
    wav: Path,
    threshold: float = 0.33,
    num_speakers: int = -1,
    min_on: float = 0.3,
    min_off: float = 0.5,
    progress=None,
) -> List[Dict[str, Any]]:
    """Разделить запись по голосам.

    threshold подобран на эталонной записи: 0.33 разделяет говорящих там, где
    0.5 склеивает их в одного. Значение вынесено в настройки, потому что
    оптимум зависит от качества записи и числа участников.

    num_speakers > 0 — когда пользователь точно знает, сколько человек было:
    так надёжнее любого порога.
    """
    global _diarizer, _diarizer_key

    s = _sherpa()
    ensure_models(DIARIZATION_MODELS)

    key = (threshold, num_speakers, min_on, min_off)
    if _diarizer is None or _diarizer_key != key:
        config = s.OfflineSpeakerDiarizationConfig(
            segmentation=s.OfflineSpeakerSegmentationModelConfig(
                pyannote=s.OfflineSpeakerSegmentationPyannoteModelConfig(
                    model=str(model_path("segmentation"))
                ),
            ),
            embedding=s.SpeakerEmbeddingExtractorConfig(
                model=str(model_path("embedding"))
            ),
            clustering=s.FastClusteringConfig(
                num_clusters=int(num_speakers) if num_speakers and num_speakers > 0 else -1,
                threshold=float(threshold),
            ),
            min_duration_on=min_on,
            min_duration_off=min_off,
        )
        if not config.validate():
            raise EngineError("Некорректная конфигурация разделения по голосам.")
        _diarizer = s.OfflineSpeakerDiarization(config)
        _diarizer_key = key

    audio, rate = read_wav(wav)
    if rate != _diarizer.sample_rate:
        raise EngineError(
            f"Ожидается частота {_diarizer.sample_rate} Гц, а в файле {rate} Гц."
        )
    if audio.size == 0:
        return []

    if progress is not None:
        result = _diarizer.process(audio, callback=progress).sort_by_start_time()
    else:
        result = _diarizer.process(audio).sort_by_start_time()

    return [
        {"start": float(r.start), "end": float(r.end), "speaker": f"SPEAKER_{r.speaker:02d}"}
        for r in result
    ]


# --------------------------------------------------------------------------
# Отпечатки голосов
# --------------------------------------------------------------------------

_extractor = None


def extractor():
    global _extractor
    if _extractor is None:
        s = _sherpa()
        ensure_models(("embedding",))
        _extractor = s.SpeakerEmbeddingExtractor(
            s.SpeakerEmbeddingExtractorConfig(model=str(model_path("embedding")))
        )
    return _extractor


def embed(wav: Path, start: Optional[float] = None, end: Optional[float] = None):
    """Отпечаток голоса на участке записи. Вектор из 256 чисел."""
    import numpy as np

    audio, rate = read_wav(wav, start, end)
    if audio.size < rate * 0.5:
        raise EngineError("Фрагмент слишком короткий для отпечатка голоса.")

    engine = extractor()
    stream = engine.create_stream()
    stream.accept_waveform(sample_rate=rate, waveform=audio)
    stream.input_finished()
    return np.asarray(engine.compute(stream), dtype="float32").reshape(-1)


# --------------------------------------------------------------------------
# Распознавание речи
# --------------------------------------------------------------------------

_recognizer = None


def release_asr():
    global _recognizer
    _recognizer = None


def recognizer():
    """Распознаватель GigaAM v3 (CTC).

    Словарь модели - 34 строчных кириллических символа, поэтому латиница,
    цифры и пунктуация в вывод не попадают. Для встреч с англицизмами нужен
    faster-whisper; здесь это осознанный размен на скорость и точность
    на чистом русском.
    """
    global _recognizer
    if _recognizer is None:
        s = _sherpa()
        ensure_models(ASR_MODELS_CTC)
        base = MODELS_DIR / "gigaam-v3-ctc"
        try:
            _recognizer = s.OfflineRecognizer.from_nemo_ctc(
                model=str(base / "model.int8.onnx"),
                tokens=str(base / "tokens.txt"),
                num_threads=max(2, (os.cpu_count() or 4) - 2),
                sample_rate=SAMPLE_RATE,
                feature_dim=64,
            )
        except Exception as exc:
            raise EngineError(f"Не удалось загрузить распознаватель: {exc}") from exc
    return _recognizer


def speech_segments(wav: Path, min_silence: float = 0.5, max_chunk: float = 25.0):
    """Нарезать запись на куски с речью через Silero VAD."""
    s = _sherpa()
    ensure_models(("vad",))

    config = s.VadModelConfig()
    config.silero_vad.model = str(model_path("vad"))
    config.silero_vad.min_silence_duration = min_silence
    config.silero_vad.max_speech_duration = max_chunk
    config.sample_rate = SAMPLE_RATE

    vad = s.VoiceActivityDetector(config, buffer_size_in_seconds=100)
    audio, _ = read_wav(wav)

    window = 512
    segments = []
    for offset in range(0, len(audio), window):
        vad.accept_waveform(audio[offset:offset + window])
        while not vad.empty():
            piece = vad.front
            start = piece.start / SAMPLE_RATE
            segments.append((start, start + len(piece.samples) / SAMPLE_RATE, piece.samples))
            vad.pop()
    vad.flush()
    while not vad.empty():
        piece = vad.front
        start = piece.start / SAMPLE_RATE
        segments.append((start, start + len(piece.samples) / SAMPLE_RATE, piece.samples))
        vad.pop()
    return segments


def transcribe_ctc(wav: Path, progress=None) -> List[Dict[str, Any]]:
    """Расшифровать запись целиком. Возвращает участки со временем и текстом."""
    engine = recognizer()
    chunks = speech_segments(wav)
    if not chunks:
        return []

    total = chunks[-1][1] or 1.0
    out = []
    for index, (start, end, samples) in enumerate(chunks):
        stream = engine.create_stream()
        stream.accept_waveform(SAMPLE_RATE, samples)
        engine.decode_stream(stream)
        text = (stream.result.text or "").strip()
        if text:
            out.append({"start": start, "end": end, "text": text})
        if progress is not None:
            progress(end / total, index + 1, len(chunks))
    return out
