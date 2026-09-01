from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/"meeting_transcriber_gui_v25_10.py"
TEXT=SRC.read_text(encoding="utf-8")
def test_no_reference_rendering():
    # Интерфейс рисуется кодом, а не картинками макетов. Единственная
    # разрешённая картинка - иконка приложения в боковом меню.
    for token in ("REF_overview","REF_speakers","REF_new_voices","REF_person","REF_records","REF_settings"):
        assert token not in TEXT
    assert TEXT.count("create_image") <= 1
def test_pages():
    for name in ("draw_overview","draw_speakers","draw_new_voices","draw_person","draw_records","draw_settings"):
        assert f"def {name}" in TEXT
def test_core_speaker_flows():
    for name in ("assign_voice_dialog","create_person_dialog","_person_edit_dialog","play_wav"):
        assert f"def {name}" in TEXT
def test_company_field():
    assert '"Компания"' in TEXT
def test_counter_and_navigation():
    assert "discover_unknown_voices()" in TEXT and 'self.show("new_voices")' in TEXT
def test_sidebar_visible_by_default():
    # Навигация видна сразу: прятать её за «гамбургером» на десктопе незачем.
    assert "self.sidebar_open = True" in TEXT
def test_backend_boundary():
    assert "BackendAdapter" in TEXT and "meeting_transcriber_v25_1.py" in TEXT


def test_single_source_file_selection():
    assert "self.selected_file is None" in TEXT
    assert "if self.selected_file is None:" in TEXT
    assert "Файл не выбран" not in TEXT
    assert "Начать транскрибацию" in TEXT

def test_playback_state_machine():
    for token in ("playback_proc", "playback_path", "playback_state", "toggle_wav_playback", "SIGSTOP", "SIGCONT"):
        assert token in TEXT

def test_records_are_width_constrained():
    assert "ratios = [0.31, 0.12, 0.17, 0.17, 0.12, 0.07, 0.04]" in TEXT
    assert "ellipsize" in TEXT

def test_unknown_section_is_conditional():
    assert "if unknown:" in TEXT

def test_exact_build_index():
    for f in ("install_v25_10.sh", "run_v25_10.sh", "validate_v25_10.sh", "meeting_transcriber_gui_v25_10.py"):
        assert (ROOT/f).is_file(), f


def test_resizable_desktop_window_contract():
    assert 'def _configure_native_window(self):' in TEXT
    assert 'self.overrideredirect(False)' in TEXT
    assert 'self.resizable(True, True)' in TEXT
    assert 'self.attributes("-fullscreen", False)' in TEXT
    assert 'self.state("normal")' in TEXT
    assert 'MacWindowStyle' in TEXT
    assert 'closeBox collapseBox zoomBox resizable' in TEXT
    assert 'def _verify_native_window(self):' in TEXT
    assert 'self.protocol("WM_DELETE_WINDOW", self._on_close)' in TEXT
    assert 'self._set_initial_window_geometry()' in TEXT
    assert 'self.geometry(f"{width}x{height}+{x}+{y}")' in TEXT

def test_single_button_source():
    assert 'def button(self, x, y, w, h, label, command' in TEXT
    assert 'if primary and h >= 34:' in TEXT and 'elif h <= 28:' in TEXT


def test_status_badge_does_not_consume_overflow_menu_column():
    assert 'status_w = min(72, max(48, w - 14))' in TEXT


def test_no_duplicate_primary_action_on_main():
    # На главной кнопки в шапке нет: там же лежит область выбора файла,
    # и две точки входа в одно действие только путают.
    assert 'self.page in ("records", "speakers", "new_voices")' in TEXT


def test_settings_controls_are_right_aligned():
    # Элементы управления держатся правого края карточки, а не фиксированной
    # координаты: иначе они разъезжаются при смене ширины окна.
    assert "control_x = r - 16 - control_w" in TEXT
    assert TEXT.count("self.toggle(r-58,") >= 2


def test_records_have_dedicated_overflow_column():
    assert "ratios = [0.31, 0.12, 0.17, 0.17, 0.12, 0.07, 0.04]" in TEXT
    assert "elif idx==6:" in TEXT


def test_shared_buttons_use_smooth_round_rect():
    assert 'def rounded_rect(' in TEXT
    assert 'self.rounded_rect(x, y, x+w, y+h, fill, outline, radius, 1)' in TEXT
    assert 'radius=10' in TEXT


def test_speaker_tabs_have_gap_around_counter():
    assert "badge_x = l + 184" in TEXT
    assert 'self.text(l+216,128,"Архив"' in TEXT
