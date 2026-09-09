"""Проверка контроллера Tk без дисплея, микрофона и моделей."""
from pathlib import Path
import queue
import sys
import threading
from types import SimpleNamespace

import pytest

pytest.importorskip("tkinter")
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "legacy" / "tk-версия"))
from meeting_transcriber_gui_v25_10 import UI


def test_double_click_starts_one_job_with_immutable_input(tmp_path):
    ready = threading.Event()
    captures = []

    def worker(path, settings):
        captures.append((path, settings))
        ready.set()

    selected = tmp_path / "initial.wav"
    job = SimpleNamespace(is_processing=False, selected_file=selected, settings={"results_dir": str(tmp_path)},
                          backend=SimpleNamespace(available=lambda: True), render=lambda: None, _run_backend=worker)
    UI.start_transcription(job)
    job.selected_file = tmp_path / "another.wav"
    job.settings["results_dir"] = "/changed"
    UI.start_transcription(job)
    assert ready.wait(timeout=2)
    assert captures == [(selected, {"results_dir": str(tmp_path)})]


def test_cancel_before_process_is_published_is_not_lost():
    terminated = []
    proc = SimpleNamespace(poll=lambda: None, terminate=lambda: terminated.append(True))
    job = SimpleNamespace(is_processing=True, cancel_requested=False, proc=None,
                          render=lambda: None, events=queue.Queue(), playback_proc=None,
                          title=lambda _: None, after=lambda *_: None, _poll=lambda: None)
    UI.cancel_processing(job)
    job.events.put(("started", proc))
    UI._poll(job)
    assert terminated == [True]
    assert job.is_processing
    job.events.put(("done", -15))
    UI._poll(job)
    assert not job.is_processing and job.proc is None
