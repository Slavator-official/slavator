import sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import meeting_transcriber_v25_1 as core


def test_exact_model_tag():
    with patch.object(core, "OLLAMA_MODEL", "qwen3:8b"):
        assert core.ollama_has_model({"qwen3:8b"})
        assert not core.ollama_has_model({"qwen3:8b-other"})
    with patch.object(core, "OLLAMA_MODEL", "qwen3"):
        assert core.ollama_has_model({"qwen3:latest"})
        assert not core.ollama_has_model({"qwen3:4b"})


def test_repair_requires_explicit_download_permission():
    with patch.object(core, "OLLAMA_HOST", "http://127.0.0.1:11434"), patch.object(core, "readiness", side_effect=AssertionError):
        assert core.repair() == 2


def test_remote_does_not_spawn_local_server():
    with patch.object(core, "OLLAMA_HOST", "https://remote.invalid"), patch.object(core.subprocess, "Popen", side_effect=AssertionError):
        assert core.ollama_serve() is False
        assert core.repair(allow_download=True) == 2


def test_missing_packages_never_report_asr_ready():
    with patch.object(core, "packages_missing", return_value=["faster-whisper"]), patch.object(core, "ollama_running", return_value=False), patch.object(core, "ollama_binary", return_value=None):
        report = core.readiness()
    states = {x["key"]: x["state"] for x in report["items"]}
    assert states["asr"] != "ok" and states["speech"] != "ok"


def test_partial_local_whisper_is_not_ready(tmp_path):
    with patch.object(core, "WHISPER_MODEL", str(tmp_path)), patch.object(core, "ASR_ENGINE", "whisper"):
        assert core.whisper_cached() is False
        for name in ("model.bin", "config.json", "tokenizer.json"):
            (tmp_path / name).write_text("fixture")
        assert core.whisper_cached() is True
