import os
import subprocess
import sys
import wave
from pathlib import Path

from speaker_service.backend import BackendAdapter
from speaker_service.service import SpeakerService


ROOT = Path(__file__).resolve().parents[2]


def test_windows_launcher_diagnoses_checkout(tmp_path):
    env = {**os.environ, "MEETING_TRANSCRIBER_APP_SUPPORT": str(tmp_path)}
    result = subprocess.run(
        [sys.executable, str(ROOT / "windows" / "slavator.py"), "--diagnose"],
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert "status=ok" in result.stdout


def test_backend_adapter_builds_windows_safe_arguments(tmp_path, monkeypatch):
    backend = tmp_path / "backend.py"
    backend.write_text("print('ok')", encoding="utf-8")
    captured = {}

    class Process:
        pass

    def fake_popen(command, **kwargs):
        captured["command"] = command
        captured["kwargs"] = kwargs
        return Process()

    monkeypatch.setattr(subprocess, "Popen", fake_popen)
    adapter = BackendAdapter(backend, Path(sys.executable))
    adapter.start_transcription(
        tmp_path / "встреча.wav",
        out_dir=tmp_path / "results",
        no_summary=True,
        speakers=4,
    )
    command = captured["command"]
    assert "--no-summary" in command
    assert command[command.index("--out-dir") + 1] == str(tmp_path / "results")
    assert command[command.index("--speakers") + 1] == "4"


def test_corrupt_profiles_do_not_crash_service(tmp_path):
    profiles = tmp_path / "profiles"
    service = SpeakerService(profiles_dir=profiles, results_root=tmp_path / "results")
    service.meta_path.write_text("{broken", encoding="utf-8")
    assert service.list_speakers() == []


def test_wav_duration_does_not_require_ffprobe(tmp_path):
    wav = tmp_path / "sample.wav"
    with wave.open(str(wav), "wb") as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(16000)
        target.writeframes(b"\0\0" * 16000)
    assert SpeakerService._wav_duration(wav) == 1.0
