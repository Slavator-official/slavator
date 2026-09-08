from __future__ import annotations
import json
import os
import shutil
import unicodedata
import subprocess
import uuid
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any

def _same_person(left: str, right: str) -> bool:
    """Одно ли это имя.

    Сравнение снисходительное: регистр, лишние пробелы, «ё» против «е» и
    потерянный надстрочный знак у «й» не должны заводить второго человека -
    ровно на этих различиях профили и задвоились.
    """
    def key(value: str) -> str:
        value = unicodedata.normalize("NFC", value).casefold()
        value = value.replace("ё", "е").replace("й", "и")
        return " ".join(value.replace("_", " ").split())
    return key(left) == key(right)


class Speaker:
    key: str
    name: str
    position: str = ""
    company: str = ""
    samples: int = 0
    profile_file: str = ""
    created_at: str = ""
    updated_at: str = ""

@dataclass
@dataclass
class UnknownVoice:
    voice_id: str
    wav_path: str
    source_result: str
    speaker_id: str = ""
    duration: float = 0.0

class SpeakerService:
    """Local speaker-management boundary; AI pipeline stays outside this service."""

    def __init__(self, profiles_dir: Path | None = None, results_root: Path | None = None):
        self.profiles_dir = Path(
            profiles_dir or Path.home() / "whisper-work" / "speaker_profiles"
        ).expanduser().resolve()
        self.results_root = Path(
            results_root or Path.home() / "Downloads"
        ).expanduser().resolve()
        self.profiles_dir.mkdir(parents=True, exist_ok=True)
        self.samples_dir = self.profiles_dir / "samples"
        self.samples_dir.mkdir(parents=True, exist_ok=True)
        self.meta_path = self.profiles_dir / "profiles.json"
        self.assignments_path = self.profiles_dir / "voice_assignments.json"

    def _load_json(self, path: Path, default: Any):
        if not path.exists():
            return default
        try:
            with path.open("r", encoding="utf-8") as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError):
            # Битый файл метаданных не должен ронять весь GUI.
            return default

    def _save_json(self, path: Path, value: Any):
        tmp = path.with_suffix(path.suffix + ".tmp")
        with tmp.open("w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False, indent=2)
        tmp.replace(path)

    def _profiles(self) -> dict[str, dict]:
        data = self._load_json(self.meta_path, {})
        return data if isinstance(data, dict) else {}

    def _assignments(self) -> dict[str, str]:
        data = self._load_json(self.assignments_path, {})
        return data if isinstance(data, dict) else {}

    def list_speakers(self) -> list[Speaker]:
        result = []
        for key, info in self._profiles().items():
            result.append(Speaker(
                key=key,
                name=str(info.get("name", key)),
                position=str(info.get("position", "")),
                company=str(info.get("company", "")),
                samples=int(info.get("samples", 0) or 0),
                profile_file=str(info.get("profile_file", "")),
                created_at=str(info.get("created_at", "")),
                updated_at=str(info.get("updated_at", "")),
            ))
        return sorted(result, key=lambda x: x.name.lower())

    def get_speaker(self, key: str) -> Speaker | None:
        return next((x for x in self.list_speakers() if x.key == key), None)

    def update_speaker(self, key: str, *, name: str, position: str, company: str) -> Speaker:
        profiles = self._profiles()
        if key not in profiles:
            raise KeyError("Спикер не найден")
        if not name.strip():
            raise ValueError("ФИО обязательно")
        profiles[key]["name"] = name.strip()
        profiles[key]["position"] = position.strip()
        profiles[key]["company"] = company.strip()
        self._save_json(self.meta_path, profiles)
        return self.get_speaker(key)

    def discover_unknown_voices(self) -> list[UnknownVoice]:
        assignments = self._assignments()
        found = []
        if not self.results_root.exists():
            return found
        for result_dir in self.results_root.glob("*_result"):
            if not result_dir.is_dir():
                continue
            folders = [
                result_dir / "доп файлы, на случай ошибки summary" / "Новые спикеры",
                result_dir / "доп файлы, на случай ошибки summary" / "Новые голоса",
            ]
            for folder in folders:
                if not folder.exists():
                    continue
                for wav in sorted(folder.glob("*.wav")):
                    voice_id = f"{result_dir.name}:{wav.name}"
                    if voice_id in assignments:
                        continue
                    found.append(UnknownVoice(
                        voice_id=voice_id,
                        wav_path=str(wav),
                        source_result=str(result_dir),
                        speaker_id=wav.stem,
                        duration=self._wav_duration(wav),
                    ))
        return found

    @staticmethod
    def _wav_duration(path: Path) -> float:
        try:
            with wave.open(str(path), "rb") as source:
                rate = source.getframerate()
                return source.getnframes() / float(rate) if rate else 0.0
        except (OSError, wave.Error):
            pass
        try:
            out = subprocess.check_output(
                ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                 "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
                text=True, stderr=subprocess.DEVNULL, timeout=5,
            )
            return max(0.0, float(out.strip()))
        except Exception:
            return 0.0

    def assign_voice_to_existing(self, voice_id: str, speaker_key: str) -> Path:
        voice = next((x for x in self.discover_unknown_voices() if x.voice_id == voice_id), None)
        if voice is None:
            raise FileNotFoundError("Новый голос не найден")
        speaker = self.get_speaker(speaker_key)
        if speaker is None:
            raise KeyError("Спикер не найден")
        safe_key = "".join(c if c.isalnum() or c in "_-" else "_" for c in speaker_key)
        target_dir = self.samples_dir / safe_key
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / f"{uuid.uuid4().hex}.wav"
        shutil.copy2(voice.wav_path, target)
        assignments = self._assignments()
        assignments[voice_id] = speaker_key
        self._save_json(self.assignments_path, assignments)

        # The sample is now part of the person's local voice-sample archive.
        # The existing v25.1 backend does not expose an "append embedding" API,
        # so we deliberately do not fabricate or overwrite the embedding here.
        # Mark the profile as having a pending sample; the recognition adapter
        # can rebuild/merge embeddings without coupling this service to pyannote.
        profiles = self._profiles()
        if speaker_key in profiles:
            profiles[speaker_key]["samples"] = int(profiles[speaker_key].get("samples", 0) or 0) + 1
            profiles[speaker_key]["embedding_update_pending"] = True
            self._save_json(self.meta_path, profiles)
        return target

    def create_person_record(self, name: str, position: str, company: str, wav_path: Path) -> Speaker:
        name = name.strip()
        if not name:
            raise ValueError("ФИО обязательно")
        wav_path = Path(wav_path).expanduser().resolve()
        if not wav_path.is_file():
            raise FileNotFoundError("WAV-файл не найден")

        key_base = "".join(c if c.isalnum() or c in "_-" else "_" for c in name).strip("_") or "speaker"
        profiles = self._profiles()

        # Один человек - одна запись.
        #
        # Ключ раньше делали двумя разными правилами: одно оставляло «й»,
        # другое роняло надстрочный знак и превращало его в «и». Так у
        # «Мигалин Сергей» появились ключи Мигалин_Сергей и Мигалин_Сергеи —
        # два профиля на одного человека, между которыми делятся образцы
        # голоса. Опознание от этого только хуже: половина отпечатков в одной
        # записи, половина в другой.
        #
        # Правило генерации ключа с тех пор одно, но само по себе оно не
        # спасает: имя, введённое чуть иначе, снова даст новый ключ. Поэтому
        # сравниваем по имени, а не по ключу.
        same = [existing for existing, row in profiles.items()
                if _same_person(str(row.get("name", "")), name)]
        if same:
            raise ValueError(
                f"«{name}» уже есть в списке людей. "
                "Добавьте новый образец голоса этому человеку, а не заводите второго."
            )

        key = key_base
        n = 2
        while key in profiles:
            key = f"{key_base}_{n}"
            n += 1

        backend = os.environ.get("MEETING_TRANSCRIBER_BACKEND")
        if backend:
            backend_path = Path(backend).expanduser().resolve()
            if backend_path.is_file():
                import importlib.util
                spec = importlib.util.spec_from_file_location("_mt_backend", backend_path)
                module = importlib.util.module_from_spec(spec)
                assert spec and spec.loader
                spec.loader.exec_module(module)
                fn = getattr(module, "save_speaker_profile", None)
                if callable(fn):
                    display, _ = fn(self.profiles_dir, wav_path, name, position, company)
                    for sp in self.list_speakers():
                        if sp.name == display:
                            return sp

        target_dir = self.samples_dir / key
        target_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(wav_path, target_dir / f"{uuid.uuid4().hex}.wav")
        profiles[key] = {
            "name": name,
            "position": position.strip(),
            "company": company.strip(),
            "profile_file": "",
            "samples": 1,
        }
        self._save_json(self.meta_path, profiles)
        return self.get_speaker(key)
