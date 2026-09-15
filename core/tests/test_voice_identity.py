"""Имя голосу — только с достаточной опорой.

Обе проверки родом из записи 15.09: голос Славы через наушники оказался ближе
к единственному образцу Мигалина, чем к шести своим, и 88% встречи подписали
чужим именем. А подсказка «по разговору» приняла эту подпись за доказательство
и раздала то же имя соседнему голосу.
"""
import json

import numpy as np

import meeting_transcriber_v25_1 as core


def _profiles(monkeypatch, samples):
    profiles = {"migalin": {"name": "Мигалин Сергей", "samples": samples},
                "slava": {"name": "Слава Живаев", "samples": 6}}
    monkeypatch.setattr(core, "load_profiles", lambda _: profiles)
    # Голос ровно как у Мигалина и заметно дальше от Славы — зазор проходит.
    monkeypatch.setattr(core, "load_known_embeddings", lambda _: {
        "migalin": np.array([1.0, 0.0]), "slava": np.array([0.6, 0.8])})
    monkeypatch.setattr(core, "embedding_from_wav", lambda *a, **k: np.array([1.0, 0.0]))
    monkeypatch.setattr(core, "VOICE_THRESHOLD", 0.80)


TURNS = [{"speaker": "SPEAKER_02", "start": 0.0, "end": 12.0}]


def test_single_sample_card_only_suggests(monkeypatch, tmp_path):
    _profiles(monkeypatch, samples=1)
    [match] = core.identify_speakers(tmp_path / "x.wav", TURNS, tmp_path)
    assert not match.known
    assert match.voice_guess == "Мигалин Сергей"


def test_card_with_enough_samples_names_voice(monkeypatch, tmp_path):
    _profiles(monkeypatch, samples=2)
    [match] = core.identify_speakers(tmp_path / "x.wav", TURNS, tmp_path)
    assert match.profile_key == "migalin"
    assert match.voice_guess == ""


def test_voice_guess_is_marked_in_sample_name(monkeypatch, tmp_path):
    monkeypatch.setattr(core, "write_wav_excerpt", lambda src, dst, spans: 10.0)
    match = core.SpeakerMatch(speaker_id="SPEAKER_02", total_speech=60.0,
                              best_segment=(0.0, 10.0), voice_guess="Мигалин Сергей")
    [row] = core.export_unknown_voices(tmp_path / "x.wav", [match], tmp_path / "new",
                                       turns=TURNS)
    # «по голосу», а не «возможно»: интерфейс обязан сказать, откуда имя.
    assert row["wav"] == "SPEAKER_02 — по голосу, Мигалин Сергей.wav"
    assert row["suggested_name"] == "Мигалин Сергей"


def _names(monkeypatch, tmp_path, answer, utterances):
    monkeypatch.setattr(core, "ollama_chat", lambda *a, **k: json.dumps(answer, ensure_ascii=False))
    return core.infer_speaker_names(utterances, tmp_path)


def test_speaker_label_is_not_evidence(monkeypatch, tmp_path):
    utterances = [
        core.Utterance(0, 5, "большой экран, где у нас тянется большой запрос",
                       speaker_id="SPEAKER_02", speaker_name="Мигалин Сергей"),
        core.Utterance(5, 9, "очень похожая страничка на наш", speaker_id="SPEAKER_01"),
    ]
    answer = {"speakers": [{"id": "SPEAKER_01", "name": "Мигалин Сергей", "confidence": 0.9,
                            "evidence": "Мигалин Сергей: большой экран"}]}
    assert _names(monkeypatch, tmp_path, answer, utterances) == {}


def test_spoken_name_is_still_accepted(monkeypatch, tmp_path):
    utterances = [
        core.Utterance(0, 5, "Сергей, покажи, пожалуйста, журнал", speaker_id="SPEAKER_00"),
        core.Utterance(5, 9, "да, сейчас открою", speaker_id="SPEAKER_01"),
    ]
    answer = {"speakers": [{"id": "SPEAKER_01", "name": "Сергей", "confidence": 0.9,
                            "evidence": "Сергей, покажи, пожалуйста, журнал"}]}
    hints = _names(monkeypatch, tmp_path, answer, utterances)
    assert hints["SPEAKER_01"]["name"] == "Сергей"
