import json
import sys
from pathlib import Path

import pytest
import app_config
from speaker_service.backend import BackendAdapter


@pytest.fixture
def settings_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("MEETING_TRANSCRIBER_APP_SUPPORT", str(tmp_path))
    return tmp_path


def test_old_settings_and_foreign_fields_survive_save(settings_dir):
    path = settings_dir / "settings.json"
    path.write_text(json.dumps({"theme": "light", "results_dir": "/custom",
                                "dictation_model": "large-v3-turbo", "future": {"flag": True}}))
    assert app_config.load()["results_dir"] == "/custom"
    app_config.update(theme="dark")
    stored = json.loads(path.read_text())
    assert stored["dictation_model"] == "large-v3-turbo"
    assert stored["future"] == {"flag": True}
    assert not list(settings_dir.glob(".settings-*"))


def test_invalid_field_does_not_reset_valid_fields(settings_dir):
    (settings_dir / "settings.json").write_text(json.dumps({
        "theme": "light", "results_dir": "", "dictation_enabled": "false", "my_name": "Алексей",
    }))
    result = app_config.load()
    assert result["theme"] == "light"
    assert result["my_name"] == "Алексей"
    assert result["dictation_enabled"] is False
    assert result["results_dir"] == str(app_config.default_results_dir())


@pytest.mark.parametrize("content", ["{broken", "[]", "null", '"string"'])
def test_invalid_settings_are_recoverable(settings_dir, content):
    (settings_dir / "settings.json").write_text(content)
    assert app_config.load()["theme"] == "dark"


def test_windows_bom_and_quoted_paths(settings_dir):
    path = settings_dir / "config.env"
    path.write_text('\ufeff# comment\n KEY = "C:\\Мои файлы\\a=b"\nSINGLE=\'value\'\nEMPTY=\n', encoding="utf-8")
    assert app_config.read_env(path) == {"KEY": "C:\\Мои файлы\\a=b", "SINGLE": "value", "EMPTY": ""}


def test_model_precedence_and_host_alias(settings_dir, monkeypatch):
    monkeypatch.delenv("MEETING_TRANSCRIBER_LLM", raising=False)
    monkeypatch.delenv("MEETING_TRANSCRIBER_OLLAMA_HOST", raising=False)
    monkeypatch.delenv("MEETING_TRANSCRIBER_OLLAMA", raising=False)
    (settings_dir / "config.env").write_text('MEETING_TRANSCRIBER_LLM="configured"\nMEETING_TRANSCRIBER_OLLAMA="http://localhost:11434/"')
    assert app_config.environment()["MEETING_TRANSCRIBER_LLM"] == "configured"
    assert app_config.load()["llm_model"] == "configured"
    app_config.update(llm_model="selected")
    env = app_config.environment()
    assert env["MEETING_TRANSCRIBER_LLM"] == "selected"
    assert env["MEETING_TRANSCRIBER_OLLAMA_HOST"] == env["MEETING_TRANSCRIBER_OLLAMA"] == "http://localhost:11434"
    monkeypatch.setenv("MEETING_TRANSCRIBER_LLM", "explicit")
    assert app_config.environment()["MEETING_TRANSCRIBER_LLM"] == "explicit"


def test_asr_model_precedence_and_cpu_default(settings_dir, monkeypatch):
    monkeypatch.delenv("MEETING_TRANSCRIBER_WHISPER_MODEL",raising=False)
    assert app_config.environment()["MEETING_TRANSCRIBER_WHISPER_MODEL"] == "small"
    (settings_dir/"config.env").write_text("MEETING_TRANSCRIBER_WHISPER_MODEL=large-v3")
    assert app_config.load()["asr_model"] == "large-v3"
    app_config.update(asr_model="small")
    assert app_config.environment()["MEETING_TRANSCRIBER_WHISPER_MODEL"] == "small"
    monkeypatch.setenv("MEETING_TRANSCRIBER_WHISPER_MODEL","base")
    assert app_config.environment()["MEETING_TRANSCRIBER_WHISPER_MODEL"] == "base"


@pytest.mark.parametrize("platform", ["win32", "darwin", "linux"])
def test_platform_support_directory(platform, tmp_path, monkeypatch):
    monkeypatch.delenv("MEETING_TRANSCRIBER_APP_SUPPORT", raising=False)
    monkeypatch.setattr(sys, "platform", platform)
    monkeypatch.setenv("APPDATA", str(tmp_path / "roaming"))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    expected = {"win32": tmp_path / "roaming" / "Славатор",
                "linux": tmp_path / "xdg" / "Славатор",
                "darwin": Path.home() / "Library" / "Application Support" / "Славатор"}
    assert app_config.support_dir() == expected[platform]


def test_adapter_reads_real_utf8_subprocess_and_passes_settings(settings_dir):
    script = settings_dir / "fake_backend.py"
    script.write_text("import os,sys\nprint('Готово — встреча')\nprint(os.environ['MEETING_TRANSCRIBER_LLM'])\nprint('--keep-audio' in sys.argv)", encoding="utf-8")
    adapter = BackendAdapter(script, Path(sys.executable))
    proc = adapter.start_transcription(settings_dir / "record.wav", keep_audio=True,
                                      settings={"llm_model": "review-test"},
                                      env={"MEETING_TRANSCRIBER_LLM": "review-test"})
    stdout, _ = proc.communicate(timeout=10)
    assert proc.returncode == 0
    assert stdout.splitlines() == ["Готово — встреча", "review-test", "True"]


def test_both_desktop_palettes_read_the_same_tokens():
    desktop = Path(__file__).resolve().parents[2] / "legacy" / "tk-версия"
    sys.path.insert(0, str(desktop))
    import ui_theme
    for name in ("light", "dark"):
        assert ui_theme.palette(name)["BG"] == "#" + app_config.CONTRACT["themes"][name]["bg"]
        assert len(ui_theme.speaker_palette(name)) == 10


@pytest.fixture
def model_server():
    import http.server
    import threading

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/moved":
                self.send_response(302)
                self.send_header("Location", "http://example.invalid/api/tags")
                self.end_headers()
                return
            body = b'{"models": []}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()


def test_model_requests_ignore_environment_proxy(model_server, monkeypatch):
    import urllib.request
    monkeypatch.setenv("http_proxy", "http://127.0.0.1:9")
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:9")
    # Для 127.0.0.1 urllib и сам обходит прокси; удалённая Ollama — нет.
    monkeypatch.setattr(urllib.request, "proxy_bypass", lambda host: False)
    with pytest.raises(OSError):
        urllib.request.urlopen(model_server + "/api/tags", timeout=5)
    assert app_config.model_json(model_server + "/api/tags", timeout=5) == {"models": []}


def test_model_requests_refuse_redirects(model_server):
    import urllib.error
    with pytest.raises(urllib.error.URLError, match="перенаправление"):
        app_config.model_json(model_server + "/moved", timeout=5)


def test_both_host_variables_are_read(monkeypatch):
    monkeypatch.delenv("MEETING_TRANSCRIBER_OLLAMA_HOST", raising=False)
    monkeypatch.setenv("MEETING_TRANSCRIBER_OLLAMA", "http://10.0.0.5:11434/")
    assert app_config.ollama_host() == "http://10.0.0.5:11434"
    monkeypatch.delenv("MEETING_TRANSCRIBER_OLLAMA")
    assert app_config.ollama_host() == app_config.LOCAL_OLLAMA


def test_model_clients_do_not_bypass_the_guarded_opener():
    core = Path(__file__).resolve().parents[1]
    for name in ("dictation_worker.py", "meeting_transcriber_v25_1.py", "speaker_memory.py", "meeting_chat.py"):
        assert "urlopen(" not in (core / name).read_text(encoding="utf-8"), name
