import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from speaker_memory import Memory, EXTRA, normalize
from speaker_links import link_voice, link_sample


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


def meeting(root, name="one", rows=None, **fields):
    folder = root / (name + "_result")
    write(folder / "transcript.json", dict(source=name + ".wav", created_at="2026-09-07T10:00:00",
        utterances=rows if rows is not None else [quote("Нужно перенести запуск на пятницу")], **fields))
    return folder


def quote(text, speaker="SPEAKER_00", start=10, name=""):
    return dict(text=text,speaker_id=speaker,speaker_name=name,start=start,end=start+3)


@pytest.fixture
def memory(tmp_path):
    root = tmp_path / "results"
    root.mkdir()
    profiles = tmp_path / "profiles"
    write(profiles / "profiles.json", {"anna": {"name":"Анна"}, "anna2":{"name":"Анна"}})
    value = Memory(root, profiles, tmp_path / "index.sqlite")
    yield value
    value.close()


def test_real_schema_phrase_and_context(memory):
    meeting(memory.root, rows=[quote("Обсудим бюджет", start=1),quote("Ёлка, новый БЮДЖЕТ согласован!", speaker="SPEAKER_01",start=4),quote("Хорошо",start=8)])
    assert memory.sync() == []
    result = memory.search("елка новый бюджет")
    assert result["total"] == 1
    hit = result["hits"][0]
    assert hit["start"] == 4
    assert hit["title"] == "one"
    assert hit["text"] == "Ёлка, новый БЮДЖЕТ согласован!"
    assert len(memory.context(hit["id"])) == 3
    assert memory.search('" OR * ; DROP TABLE quotes; --')["total"] == 0


def test_identity_not_merged_by_name_or_diarization_id(memory):
    meeting(memory.root, "one", [quote("Да", name="Анна")])
    meeting(memory.root, "two", [quote("Нет", name="Анна")])
    memory.sync()
    people = memory.overview()["people"]
    assert len(people) == 2
    assert all(p["identity"] == "unconfirmed" and p["meetings"] == 1 for p in people)


def test_explicit_links_graph_and_profile_rename(memory):
    one = meeting(memory.root, "one", [quote("Да"),quote("Нет","SPEAKER_01")])
    two = meeting(memory.root, "two", [quote("Позже")])
    link_voice(one,"SPEAKER_00","anna")
    link_voice(one,"SPEAKER_01","anna2")
    link_voice(two,"SPEAKER_00","anna")
    memory.sync()
    overview = memory.overview()
    assert len(overview["people"]) == 2  # Same name, two distinct profile IDs.
    assert overview["edges"] == [{"a":"profile:anna","b":"profile:anna2","meetings":[str(one)]}]
    assert memory.search(person="profile:anna")["total"] == 2
    write(memory.profiles / "profiles.json", {"anna":{"name":"Анна Иванова"},"anna2":{"name":"Анна"}})
    memory.sync()
    assert all(h["name"] == "Анна Иванова" for h in memory.search(person="profile:anna")["hits"])


def test_manual_overrides_recognition(memory):
    folder = meeting(memory.root)
    write(folder/EXTRA/"speaker_recognition.json", [{"speaker_id":"SPEAKER_00","profile_key":"anna"}])
    memory.sync()
    assert memory.search()["hits"][0]["identity"] == "voice"
    link_voice(folder, "SPEAKER_00", "anna2")
    memory.sync()
    assert memory.search()["hits"][0]["person"] == "profile:anna2"
    assert memory.search()["hits"][0]["identity"] == "manual"


def test_sample_link_survives_removed_sample(memory):
    folder = meeting(memory.root)
    sample = folder / EXTRA / "Новые спикеры" / "SPEAKER_00 — возможно, Анна.wav"
    sample.parent.mkdir(parents=True)
    sample.touch()
    link_sample(sample,"anna")
    sample.unlink()
    memory.sync()
    assert memory.search()["hits"][0]["person"] == "profile:anna"


def test_windows_existing_assignments_imported(memory):
    meeting(memory.root)
    write(memory.profiles / "voice_assignments.json", {"one_result:SPEAKER_00.wav":"anna"})
    memory.sync()
    assert memory.search()["hits"][0]["person"] == "profile:anna"


def test_incremental_update_delete_and_bad_write_preserved(memory):
    folder = meeting(memory.root)
    memory.sync()
    first = memory.search()["hits"][0]["id"]
    memory.sync()
    assert memory.search()["hits"][0]["id"] == first
    (folder/"transcript.json").write_text('{"utterances":',encoding="utf-8")
    assert len(memory.sync()) == 1
    assert memory.search()["total"] == 1
    meeting(memory.root,rows=[quote("Уже согласовали")])
    memory.sync()
    assert memory.search("перенести")["total"] == 0
    assert memory.search("согласовали")["total"] == 1
    (folder/"transcript.json").unlink()
    memory.sync()
    assert memory.search()["total"] == 0
    assert memory.db.execute("SELECT count(*) FROM words").fetchone()[0] == 0


def test_missing_root_does_not_erase_index(memory):
    meeting(memory.root)
    memory.sync()
    memory.root = memory.root / "missing"
    with pytest.raises(FileNotFoundError):
        memory.sync()
    assert memory.search()["total"] == 1


@pytest.mark.parametrize("rows", [[quote("invalid", start=-1)], [dict(text="bad",start=2,end=1)], [dict(text="bad",start=float("nan"),end=2)]])
def test_invalid_timing_not_indexed(memory, rows):
    meeting(memory.root,rows=rows)
    assert len(memory.sync()) == 1
    assert memory.overview()["quotes"] == 0


def test_long_utterance_keeps_all_text(memory):
    text = " ".join("слово" + str(n) for n in range(1700))
    meeting(memory.root,rows=[quote(text)])
    memory.sync()
    hits = memory.search(limit=100)["hits"]
    assert len(hits) > 1
    assert " ".join(h["text"] for h in hits) == text
    assert memory.search("слово1699")["total"] == 1


def test_pagination_filters(memory):
    one = meeting(memory.root,rows=[quote(str(i), start=i) for i in range(65)])
    meeting(memory.root,"two")
    memory.sync()
    a = memory.search(meeting=str(one),limit=30)
    b = memory.search(meeting=str(one),offset=30,limit=30)
    assert a["total"] == 65
    assert len(set(h["id"] for h in a["hits"] + b["hits"])) == 60


def test_same_voice_sentence_join_cross_segment_phrase(memory):
    meeting(memory.root, rows=[quote("Запуск",start=1),quote("переносим на пятницу",start=4),quote("Согласен",speaker="SPEAKER_01",start=9)])
    memory.sync()
    hit = memory.search("запуск переносим")["hits"][0]
    assert hit["text"] == "Запуск переносим на пятницу"
    assert hit["start"] == 1 and hit["end"] == 7
    assert len(memory.context(hit["id"])) == 2


def test_filler_is_context_only_but_meaningful_short_replies_remain(memory):
    folder = meeting(memory.root, rows=[quote("Как", "UNASSIGNED_0", start=0),
        quote("Обсудим API", start=3), quote("Ну вот", "UNASSIGNED_1", start=7),
        quote("Да", start=11), quote("Нет", start=21), quote("CJM", start=31),
        quote("буду", "UNASSIGNED_2", start=41), quote("Все.", "UNASSIGNED_3", start=51)])
    original = (folder / "transcript.json").read_bytes()
    memory.sync()
    hits = memory.search()["hits"]
    assert [h["text"] for h in hits] == ["Обсудим API", "Да", "Нет", "CJM"]
    assert memory.search("как")["total"] == 0
    assert [h["text"] for h in memory.context(hits[0]["id"])][:3] == ["Как", "Обсудим API", "Ну вот"]
    assert memory.overview()["hidden_fragments"] == 4
    assert (folder / "transcript.json").read_bytes() == original
    model = FakeEmbedder()
    memory.build_vectors(model)
    assert model.count == 4


def test_archived_versions_do_not_reintroduce_unconfirmed_people(memory):
    meeting(memory.root, "call_20260908_101010", [quote("Старая запись")])
    current = meeting(memory.root, "call", [quote("Актуальная запись")])
    link_voice(current, "SPEAKER_00", "anna")
    memory.sync()
    overview = memory.overview()
    assert len(overview["meetings"]) == 1
    assert [p["id"] for p in overview["people"]] == ["profile:anna"]
    assert memory.search("Старая")["total"] == 0


def test_confirmed_profiles_sort_before_all_unconfirmed_voices(memory):
    meeting(memory.root, "noise", [quote("Реплика", "SPEAKER_" + str(i), start=i*10) for i in range(15)])
    current = meeting(memory.root, "named", [quote("Именованная реплика")])
    link_voice(current, "SPEAKER_00", "anna")
    memory.sync()
    assert memory.overview()["people"][0]["id"] == "profile:anna"


def test_deleted_meeting_removes_search_graph_and_vectors_then_restores(memory):
    from meeting_store import trash_meeting, restore_meeting
    folder = meeting(memory.root)
    memory.sync()
    memory.build_vectors(FakeEmbedder())
    deleted = trash_meeting(memory.root, folder)
    memory.sync()
    assert memory.search()["total"] == 0
    assert memory.overview()["people"] == []
    assert memory.db.execute("SELECT count(*) FROM vectors").fetchone()[0] == 0
    restore_meeting(memory.root, deleted["id"])
    memory.sync()
    assert memory.search()["total"] == 1


class FakeEmbedder:
    revision = "model-v1"
    count = 0
    def version(self):
        return self.revision
    def embed(self, texts, query=False):
        self.count += len(texts)
        return [[1.,0.] if "запуск" in t or query else [0.,1.] for t in texts]


def test_vectors_incremental_model_change_and_semantic_no_word_overlap(memory):
    meeting(memory.root,rows=[quote("запуск отложен"),quote("чай остыл", start=20)])
    memory.sync()
    model = FakeEmbedder()
    memory.build_vectors(model)
    assert model.count == 2
    memory.build_vectors(model)
    assert model.count == 2
    result = memory.search("перенос релиза",mode="semantic",embedder=model)
    assert result["total"] == 1 and result["hits"][0]["text"] == "запуск отложен"
    model.revision = "model-v2"
    result = memory.search("перенос релиза",mode="semantic",embedder=model)
    assert result["total"] == 0 and result["notice"]
    memory.build_vectors(model)
    assert memory.search("перенос релиза",mode="semantic",embedder=model)["total"] == 1


def test_semantic_outage_truthful_lexical_fallback(memory):
    meeting(memory.root)
    memory.sync()
    class Offline:
        def version(self):
            raise ConnectionError("offline")
    result = memory.search("запуск",mode="semantic",embedder=Offline())
    assert result["total"] == 1 and "только совпадения слов" in result["notice"]


def test_transaction_rolls_back_partial_insert(memory):
    meeting(memory.root)
    memory.sync()
    memory.db.execute("""CREATE TRIGGER reject_bad BEFORE INSERT ON quotes
        WHEN new.text='bad' BEGIN SELECT RAISE(ABORT,'test'); END""")
    meeting(memory.root,rows=[quote("first"),quote("bad")])
    import sqlite3
    with pytest.raises(sqlite3.IntegrityError):
        memory.sync()
    assert memory.search("запуск")["total"] == 1


@pytest.mark.skipif(__import__("os").environ.get("SLAVATOR_TEST_OLLAMA") != "1", reason="Opt-in local Ollama integration")
def test_real_russian_semantic_retrieval(memory):
    from speaker_memory import Embedder
    sentences = [
        "Выкладку новой версии отложим до следующей недели: разработчики не успевают закончить работу.",
        "Сократим расходы на рекламу, чтобы сэкономить деньги компании.",
        "Нужно нанять двух программистов, нашей команде не хватает людей.",
        "Клиенты жалуются на медленные ответы службы поддержки.",
    ]
    meeting(memory.root, rows=[quote(text,start=i*90) for i,text in enumerate(sentences)])
    memory.sync()
    model = Embedder()
    memory.build_vectors(model)
    queries = ["перенос сроков релиза", "уменьшение маркетингового бюджета", "расширение штата сотрудников", "плохой сервис для пользователей"]
    for query, expected in zip(queries, sentences):
        result = memory.search(query,mode="semantic",embedder=model)
        assert result["hits"] and result["hits"][0]["text"] == expected, (query,result)
