from pathlib import Path


def test_overview_source_contract():
    src = Path(__file__).resolve().parent / 'meeting_transcriber_gui_v25_10.py'
    text = src.read_text(encoding='utf-8')
    assert text.count('self.selected_file') >= 4
    assert 'Файл не выбран' not in text
    assert 'Начать транскрибацию' in text


def test_layout_contract_has_no_fixed_record_offsets():
    src = Path(__file__).resolve().parent / 'meeting_transcriber_gui_v25_10.py'
    text = src.read_text(encoding='utf-8')
    assert 'x+310' not in text
    assert 'x+398' not in text
    assert 'x+505' not in text
    assert 'x+650' not in text


def test_playback_uses_pause_resume_signals():
    src = Path(__file__).resolve().parent / 'meeting_transcriber_gui_v25_10.py'
    text = src.read_text(encoding='utf-8')
    assert 'signal.SIGSTOP' in text
    assert 'signal.SIGCONT' in text
    assert 'self.playback_state = "paused"' in text
    assert 'self.playback_state = "playing"' in text
    assert 'self.playback_state = "stopped"' in text
