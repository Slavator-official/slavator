from pathlib import Path
import tempfile
from PIL import ImageGrab
from meeting_transcriber_gui_v25_10 import UI
from speaker_service.service import UnknownVoice, Speaker

app = UI()
app.geometry('1280x800')
app.update_idletasks(); app.update()

# Deterministic visual fixture: no backend or real user data required.
tmp = Path(tempfile.gettempdir()) / 'Meeting_Transcriber_v25_10_visual_fixture'
tmp.mkdir(exist_ok=True)
sample = tmp / 'Встреча с командой.mp4'
sample.write_bytes(b'0' * 1024 * 1024)
wav = tmp / 'SPEAKER_00.wav'
wav.write_bytes(b'RIFF' + b'0' * 256)
voice = UnknownVoice('fixture:SPEAKER_00.wav', str(wav), 'fixture_result', duration=10.0)

class FixtureService:
    def __init__(self): self.assigned=False
    def list_speakers(self): return [Speaker('ivan','Иванов Иван Иванович','Руководитель проекта','ООО «Рога и Копыта»',12)]
    def discover_unknown_voices(self): return [] if self.assigned else [voice, UnknownVoice('fixture:SPEAKER_02.wav', str(wav), 'fixture_result', duration=10.0)]
    def get_speaker(self,key): return self.list_speakers()[0]

app.speakers = FixtureService()

def fixture_records():
    return [
        ('FamiliarAdvertisementsOfferUnderGround_2026-08-18T15_02_35.944Z','МП Учителя','Техническая','21.05.2025, 14:32','6','Готово',None),
        ('Обсуждение требований','УБ ЦОК','Со стейкхолдерами','20.05.2025, 10:15','4','Готово',None),
        ('Планирование релиза','МП Учителя','Техническая','19.05.2025, 16:40','5','Готово',None),
    ]
app.recent_records = fixture_records

for name, selected in [('overview_empty', False), ('overview_selected', True)]:
    app.selected_file = sample if selected else None
    app.show('overview'); app.update_idletasks(); app.update()
    ImageGrab.grab().save(f'/mnt/data/UI_RENDER_{name}_v25_10.png')

app.selected_file = None
app.show('overview'); app.update_idletasks(); app.update()
ImageGrab.grab().save('/mnt/data/UI_RENDER_overview_v25_10.png')

app.show('speakers'); app.update_idletasks(); app.update()
ImageGrab.grab().save('/mnt/data/UI_RENDER_speakers_v25_10.png')

app.show('records'); app.update_idletasks(); app.update()
ImageGrab.grab().save('/mnt/data/UI_RENDER_records_v25_10.png')

app.destroy()
