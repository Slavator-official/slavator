from speaker_service.service import SpeakerService

def make_service(tmp_path):
    return SpeakerService(profiles_dir=tmp_path/"profiles", results_root=tmp_path/"results")

def test_empty_service(tmp_path):
    service=make_service(tmp_path)
    assert service.list_speakers()==[]
    assert service.discover_unknown_voices()==[]

def test_create_person_fallback(tmp_path, monkeypatch):
    monkeypatch.delenv("MEETING_TRANSCRIBER_BACKEND", raising=False)
    service=make_service(tmp_path)
    wav=tmp_path/"sample.wav"; wav.write_bytes(b"RIFFfake")
    speaker=service.create_person_record("Иван Иванов","PM","",wav)
    assert speaker.name=="Иван Иванов"
    assert speaker.position=="PM"
    assert speaker.company==""
    assert speaker.samples==1

def test_company_can_be_empty_and_later_updated(tmp_path, monkeypatch):
    monkeypatch.delenv("MEETING_TRANSCRIBER_BACKEND", raising=False)
    service=make_service(tmp_path)
    wav=tmp_path/"sample.wav"; wav.write_bytes(b"RIFFfake")
    speaker=service.create_person_record("Анна Петрова","","",wav)
    updated=service.update_speaker(speaker.key,name="Анна Петрова",position="Lead",company="ООО Рога и Копыта")
    assert updated.company=="ООО Рога и Копыта"

def test_discover_and_assign_unknown_voice(tmp_path, monkeypatch):
    monkeypatch.delenv("MEETING_TRANSCRIBER_BACKEND", raising=False)
    service=make_service(tmp_path)
    wav=tmp_path/"sample.wav"; wav.write_bytes(b"RIFFfake")
    speaker=service.create_person_record("Иван Иванов","","",wav)
    folder=tmp_path/"results"/"meeting_result"/"доп файлы, на случай ошибки summary"/"Новые спикеры"
    folder.mkdir(parents=True)
    unknown=folder/"SPEAKER_02.wav"; unknown.write_bytes(b"RIFFunknown")
    voices=service.discover_unknown_voices()
    assert len(voices)==1
    target=service.assign_voice_to_existing(voices[0].voice_id,speaker.key)
    assert target.exists()
    assert service.discover_unknown_voices()==[]


def test_assign_marks_embedding_update_pending(tmp_path, monkeypatch):
    monkeypatch.delenv("MEETING_TRANSCRIBER_BACKEND", raising=False)
    service=make_service(tmp_path)
    wav=tmp_path/"sample.wav"; wav.write_bytes(b"RIFFfake")
    speaker=service.create_person_record("Петр Иванов","","",wav)
    folder=tmp_path/"results"/"meeting_result"/"доп файлы, на случай ошибки summary"/"Новые спикеры"
    folder.mkdir(parents=True)
    unknown=folder/"SPEAKER_01.wav"; unknown.write_bytes(b"RIFFunknown")
    voice=service.discover_unknown_voices()[0]
    service.assign_voice_to_existing(voice.voice_id,speaker.key)
    updated=service.get_speaker(speaker.key)
    assert updated.samples == 2
    meta=service._profiles()[speaker.key]
    assert meta["embedding_update_pending"] is True
