from pathlib import Path
ROOT=Path(__file__).resolve().parent
REQUIRED=['install_v25_10.sh', 'run_v25_10.sh', 'validate_v25_10.sh', 'meeting_transcriber_gui_v25_10.py', 'README_v25_10.md', 'PACKAGE_MANIFEST_v25_10.txt', 'REGRESSION_CHECKLIST_v25_10.md']
for f in REQUIRED:
    assert (ROOT/f).is_file(), f"missing build file: {f}"
text=(ROOT/"meeting_transcriber_gui_v25_10.py").read_text(encoding="utf-8")
# Интерфейс рисуется кодом, а не картинками макетов. Исключение одно -
# иконка приложения в меню, она к макетам отношения не имеет.
for token in ("REF_overview","REF_speakers","REF_new_voices","REF_person","REF_records","REF_settings"):
    assert token not in text
assert text.count("create_image") <= 1, "картинки в интерфейсе: только иконка приложения"
for name in ("draw_overview","draw_speakers","draw_new_voices","draw_person","draw_records","draw_settings","assign_voice_dialog","create_person_dialog","_person_edit_dialog","play_wav","toggle_wav_playback"):
    assert f"def {name}" in text
assert '"Компания"' in text
assert "discover_unknown_voices()" in text and "if unknown:" in text
assert 'self.show("new_voices")' in text
assert "BackendAdapter" in text and "meeting_transcriber_v25_1.py" in text
print("Build contract: PASS")

assert "self.selected_file is None" in text
assert "Файл не выбран" not in text
assert "SIGSTOP" in text and "SIGCONT" in text
assert "ratios = [0.31, 0.12, 0.17, 0.17, 0.12, 0.07, 0.04]" in text
print("UX/layout contract: PASS")

assert 'def _configure_native_window(self):' in text
assert 'self.overrideredirect(False)' in text
assert 'self.resizable(True, True)' in text
assert 'self.attributes("-fullscreen", False)' in text
assert 'self.state("normal")' in text
assert 'MacWindowStyle' in text
assert 'closeBox collapseBox zoomBox resizable' in text
assert 'def _verify_native_window(self):' in text
assert 'self.protocol("WM_DELETE_WINDOW", self._on_close)' in text
assert 'self._set_initial_window_geometry()' in text
assert 'self.geometry(f"{width}x{height}+{x}+{y}")' in text
assert 'status_w = min(72, max(48, w - 14))' in text
assert 'return max(0.62, min(1.0, w / BASE_W, h / BASE_H))' in text
