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


def test_stopped_ollama_does_not_claim_a_model_download():
    with patch.object(core, "document_packages_missing", return_value=[]), \
            patch.object(core, "packages_missing", return_value=[]), \
            patch.object(core, "_speech_models", return_value=([], [], 0)), \
            patch.object(core, "whisper_cached", return_value=True), \
            patch.object(core, "ollama_running", return_value=False), \
            patch.object(core, "ollama_binary", return_value=Path("/installed/ollama")):
        report = core.readiness()
    states = {x["key"]: x for x in report["items"]}
    assert states["ollama"]["state"] == "stopped"
    assert states["llm"]["state"] == "unknown" and report["size_mb"] == 0
    assert states["asr"]["state"] == "ok"


def test_start_services_only_starts_installed_server(capsys):
    with patch.object(core, "ollama_serve", return_value=True) as start, \
            patch.object(core, "readiness", return_value={"ok": True}), \
            patch.object(core, "ollama_pull", side_effect=AssertionError("no download")), \
            patch.object(core, "whisper_model", side_effect=AssertionError("no download")):
        assert core.main(["--check", "--json", "--start-services"]) == 0
        start.assert_called_once_with(wait_seconds=15)
    assert '"ok": true' in capsys.readouterr().out


def test_whisper_loads_from_installed_path_without_hub_request(tmp_path):
    import types
    from unittest.mock import Mock
    constructor = Mock(return_value="loaded")
    with patch.object(core, "_whisper_model", None), \
            patch.object(core, "cached_whisper_path", return_value=str(tmp_path)), \
            patch.dict(sys.modules, {"faster_whisper": types.SimpleNamespace(WhisperModel=constructor)}):
        assert core.whisper_model() == "loaded"
    assert constructor.call_args.args[0] == str(tmp_path)


def test_loopback_health_bypasses_proxies():
    from unittest.mock import MagicMock
    opener = MagicMock()
    opener.open.return_value.__enter__.return_value.read.return_value = b'{"version":"test"}'
    with patch.object(core.urllib.request, "build_opener", return_value=opener) as build, \
            patch.object(core.urllib.request, "urlopen", side_effect=AssertionError("proxy path")):
        assert core._http_json("http://127.0.0.1:11434/api/version") == {"version": "test"}
    assert build.call_args.args[0].proxies == {}


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


def test_document_dependencies_are_reported_separately_from_speech():
    with patch.object(core, "document_packages_missing", return_value=["pypdf"]), \
            patch.object(core, "packages_missing", return_value=[]), \
            patch.object(core, "_speech_models", return_value=([], [], 0)), \
            patch.object(core, "whisper_cached", return_value=True), \
            patch.object(core, "ollama_running", return_value=False), \
            patch.object(core, "ollama_binary", return_value=None):
        report = core.readiness()
    states = {x["key"]: x["state"] for x in report["items"]}
    assert states["documents"] == "missing" and states["asr"] == "ok"
    assert report["needs_setup"]
