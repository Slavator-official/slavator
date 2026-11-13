from types import SimpleNamespace
from unittest.mock import Mock
from pathlib import Path
import subprocess
import sys

import pytest

from setup_runtime import complete_setup


@pytest.mark.parametrize("missing, code, ready", [
    ([], 0, True), (["speech"], 2, False), (["asr"], 2, False),
    (["packages"], 2, False), (["ollama", "llm"], 1, True),
])
def test_setup_only_claims_success_after_readiness_check(tmp_path, capsys, missing, code, ready):
    marker = tmp_path / ".ready"
    marker.write_text("old installation")
    def repair(**kwargs):
        assert kwargs == {"allow_download": True}
        assert not marker.exists()
        return 1 if missing else 0
    report = {"items": [dict(key=key, state="missing" if key in missing else "ok",
                            title=key, detail="нет на месте")
                        for key in ("packages", "speech", "asr", "ollama", "llm")]}
    core = SimpleNamespace(repair=Mock(side_effect=repair), readiness=Mock(return_value=report))
    assert complete_setup(core, tmp_path) == code
    assert marker.exists() is ready
    assert ("Готово. Славатор установлен" in capsys.readouterr().out) is (code == 0)
    core.repair.assert_called_once()
    core.readiness.assert_called_once()


def test_interrupted_setup_does_not_keep_success_marker(tmp_path):
    (tmp_path / ".ready").write_text("old installation")
    core = SimpleNamespace(repair=Mock(side_effect=RuntimeError("disk full")))
    with pytest.raises(RuntimeError):
        complete_setup(core, tmp_path)
    assert not (tmp_path / ".ready").exists()


def test_cli_failure_is_not_confused_with_optional_ollama(tmp_path):
    script = tmp_path / "setup_runtime.py"
    script.write_bytes(Path(__file__).parents[1].joinpath("setup_runtime.py").read_bytes())
    result = subprocess.run([sys.executable, "-I", "-B", str(script)], capture_output=True, text=True)
    assert result.returncode == 2
    assert "Установка не завершена" in result.stdout
    assert "Готово. Славатор установлен" not in result.stdout
