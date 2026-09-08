import json
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from speaker_memory import Memory
from meeting_chat import recall
from test_speaker_memory import meeting, quote, write
from speaker_links import link_voice


def fixture(tmp_path):
    root = tmp_path / "results"
    root.mkdir()
    profiles = tmp_path / "profiles"
    write(profiles / "profiles.json", {"me": {"name": "Валера"}, "other": {"name": "Саша"}})
    folder = meeting(root, rows=[quote("Согласуем бюджет в пятницу"), quote("Бюджет уже утвержден", "SPEAKER_01", 20)])
    link_voice(folder, "SPEAKER_00", "me")
    link_voice(folder, "SPEAKER_01", "other")
    memory = Memory(root, profiles, tmp_path / "memory.sqlite")
    memory.sync()
    return memory


def test_self_requires_explicit_profile(tmp_path):
    memory = fixture(tmp_path)
    try:
        result = recall(memory, "Вспомни, когда я говорил про бюджет", generate=False)
        assert result["needs_profile"] and not result["sources"]
    finally:
        memory.close()


def test_self_sources_and_graph_disabled(tmp_path):
    memory = fixture(tmp_path)
    try:
        with patch("speaker_memory.Embedder.version", side_effect=OSError):
            result = recall(memory, "Вспомни, когда я говорил про бюджет", "me", generate=False)
        assert len(result["sources"]) == 1
        assert result["sources"][0]["person"] == "profile:me"
        assert result["sources"][0]["start"] == 10
        with patch("speaker_memory.itertools.combinations", side_effect=AssertionError("must skip graph")):
            overview = memory.overview(build_graph=False)
        assert not overview["edges"] and len(overview["people"]) == 2
    finally:
        memory.close()


def test_no_hits_does_not_ask_llm(tmp_path):
    memory = fixture(tmp_path)
    try:
        with patch("speaker_memory.Embedder.version", side_effect=OSError), patch("speaker_memory.Embedder.request", side_effect=AssertionError):
            result = recall(memory, "термоядерный реактор")
        assert not result["sources"] and "не нашёл" in result["text"]
    finally:
        memory.close()


def test_invalid_citations_use_quotes(tmp_path):
    memory = fixture(tmp_path)
    try:
        with patch("speaker_memory.Embedder.version", side_effect=OSError), patch("speaker_memory.Embedder.request", return_value={"message": {"content": "Вы обещали миллиард [99]"}}):
            result = recall(memory, "бюджет")
        assert not result["generated"]
        assert "миллиард" not in result["text"]
        assert result["sources"]
    finally:
        memory.close()


def test_local_transport_ignores_remote_configuration(tmp_path, monkeypatch):
    memory = fixture(tmp_path)
    monkeypatch.setenv("MEETING_TRANSCRIBER_OLLAMA_HOST", "https://outside.invalid")
    monkeypatch.setenv("HTTPS_PROXY", "https://proxy.invalid")
    try:
        import speaker_memory
        assert speaker_memory.HOST == "http://127.0.0.1:11434"
        calls = []
        def request(self, endpoint, body=None, timeout=60):
            calls.append((endpoint, body))
            return {"message": {"content": "Валера обсуждал бюджет [1]."}}
        with patch("speaker_memory.Embedder.version", side_effect=OSError), patch("speaker_memory.Embedder.request", request):
            result = recall(memory, "бюджет")
        assert result["generated"]
        assert calls[0][0] == "/api/chat"
        assert calls[0][1]["keep_alive"] == 0
    finally:
        memory.close()
