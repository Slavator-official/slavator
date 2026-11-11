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
    assert app_config.load()["theme"] == "light"


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
