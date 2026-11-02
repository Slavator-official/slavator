"""Исправление имени должно пережить пересборку документов и снятие привязки."""
import json
import pytest
import meeting_transcriber_v25_1 as core


@pytest.mark.parametrize('name,key,expected', [('Новое имя', '', 'Новое имя'), ('', '', ''), ('Карточка', 'new', 'Имя из карточки')])
def test_rename_updates_both_transcripts_and_document(tmp_path, monkeypatch, name, key, expected):
    extra = tmp_path / core.EXTRA_DIR_NAME
    extra.mkdir()
    data = {'speakers': ['Старое имя', 'Другой'], 'utterances': [
        dict(start=0, end=2, text='Первая реплика', speaker_id='A', speaker_name='Старое имя'),
        dict(start=2, end=4, text='Вторая реплика', speaker_id='B', speaker_name='Другой')]}
    for path in (tmp_path / core.TRANSCRIPT_JSON, extra / core.TRANSCRIPT_JSON):
        path.write_text(json.dumps(data))
    (extra / 'speaker_links.json').write_text(json.dumps({'A': 'old'}))
    (extra / 'speaker_names.json').write_text(json.dumps({'A': 'Старое имя'}))
    (extra / 'speaker_recognition.json').write_text(json.dumps([{'speaker_id': 'A', 'profile_key': 'old', 'name': 'Старое имя'}]))
    monkeypatch.setattr(core, 'load_profiles', lambda _: {'old': {'name': 'Старое имя'}, 'new': {'name': 'Имя из карточки'}})
    documents = []
    monkeypatch.setattr(core, 'write_transcript_docx', lambda path, rows, title: documents.append(rows))
    assert core.rename_voice(tmp_path, 'A', name, key) == 0
    for path in (tmp_path / core.TRANSCRIPT_JSON, extra / core.TRANSCRIPT_JSON):
        updated = json.loads(path.read_text())
        assert updated['utterances'][0]['speaker_name'] == expected
        assert updated['utterances'][1] == data['utterances'][1]
        assert updated['speakers'] == sorted([expected or 'A', 'Другой'])
    assert documents[0][0].speaker_name == expected
    assert documents[0][0].text == 'Первая реплика'
    links = json.loads((extra / 'speaker_links.json').read_text())
    assert links.get('A', '') == key
    if not key:
        assert json.loads((extra / 'speaker_recognition.json').read_text())[0]['profile_key'] == ''
