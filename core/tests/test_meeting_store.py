import json
from pathlib import Path

import pytest

from meeting_store import active_results, list_deleted, trash_meeting, restore_meeting, TRASH


def result(root, name):
    path = root / (name + "_result")
    path.mkdir(parents=True)
    (path / "transcript.json").write_text('{"utterances":[]}', encoding="utf-8")
    return path


def test_current_canonical_beats_recently_edited_archive(tmp_path):
    current = result(tmp_path, "call")
    archive = result(tmp_path, "call_20260908_101010")
    assert active_results(tmp_path) == [current]
    # A lone archived version remains recoverable/visible if no current exists.
    current.rename(tmp_path / "unfinished")
    assert active_results(tmp_path) == [archive]


def test_delete_all_versions_restore_and_preserve_original(tmp_path):
    current = result(tmp_path, "call")
    archive = result(tmp_path, "call_20260908_101010")
    other = result(tmp_path, "other")
    original = tmp_path / "call.wav"
    original.write_bytes(b"original")
    deleted = trash_meeting(tmp_path, current)
    assert deleted["count"] == 2
    assert active_results(tmp_path) == [other]
    assert original.read_bytes() == b"original"
    assert list_deleted(tmp_path) == [deleted]
    assert restore_meeting(tmp_path, deleted["id"]) == 2
    assert current.exists() and archive.exists()
    assert list_deleted(tmp_path) == []
    with pytest.raises(ValueError):
        restore_meeting(tmp_path, deleted["id"])


def test_restore_never_overwrites_existing_result(tmp_path):
    current = result(tmp_path, "call")
    deleted = trash_meeting(tmp_path, current)
    result(tmp_path, "call")
    with pytest.raises(ValueError, match="Ничего не перезаписано"):
        restore_meeting(tmp_path, deleted["id"])
    assert len(list_deleted(tmp_path)) == 1
    assert current.exists()


def test_outside_root_and_symlink_rejected(tmp_path):
    root = tmp_path / "results"
    root.mkdir()
    outside = result(tmp_path, "outside")
    with pytest.raises(ValueError):
        trash_meeting(root, outside)
    link = root / "link_result"
    try:
        link.symlink_to(outside, target_is_directory=True)
    except OSError:
        pytest.skip("Symlinks unavailable for this Windows user")
    assert active_results(root) == []
    with pytest.raises(ValueError):
        trash_meeting(root, link)
    assert outside.exists()


def test_invalid_restore_token_and_manifest_path_rejected(tmp_path):
    current = result(tmp_path, "call")
    deleted = trash_meeting(tmp_path, current)
    with pytest.raises(ValueError):
        restore_meeting(tmp_path, "../call_result")
    receipt = tmp_path / TRASH / deleted["id"] / "receipt.json"
    receipt.write_text(json.dumps({"folders":["../outside_result"]}))
    with pytest.raises(ValueError):
        restore_meeting(tmp_path, deleted["id"])


def test_failed_move_rolls_back_completed_moves(tmp_path, monkeypatch):
    current = result(tmp_path, "call")
    archive = result(tmp_path, "call_20260908_101010")
    rename = Path.rename

    def fail_archive(self, target):
        if self == archive:
            raise PermissionError("test")
        return rename(self, target)

    monkeypatch.setattr(Path, "rename", fail_archive)
    with pytest.raises(PermissionError):
        trash_meeting(tmp_path, current)
    assert current.exists() and archive.exists()
    assert list_deleted(tmp_path) == []


def test_interrupted_move_stays_recoverable(tmp_path):
    current = result(tmp_path, "call")
    archive = result(tmp_path, "call_20260908_101010")
    deleted = trash_meeting(tmp_path, current)
    # Simulate interruption after only one of two directories was moved.
    (tmp_path / TRASH / deleted["id"] / archive.name).rename(archive)
    assert list_deleted(tmp_path)[0]["count"] == 1
    assert restore_meeting(tmp_path, deleted["id"]) == 1
    assert current.exists() and archive.exists()


def test_worker_delete_and_restore_contract(tmp_path):
    import subprocess
    import sys
    root = tmp_path / "results"
    current = result(root, "call")
    result(root, "call_20260908_101010")
    profiles = tmp_path / "profiles"
    profiles.mkdir()
    (profiles / "profiles.json").write_text("{}")
    script = Path(__file__).resolve().parents[1] / "speaker_memory.py"

    def request(payload):
        proc = subprocess.run([sys.executable, "-B", str(script), "--root", str(root),
                               "--profiles", str(profiles), "--db", str(tmp_path / "memory.sqlite")],
                              input=json.dumps(payload), text=True, capture_output=True, check=True)
        return json.loads(proc.stdout.splitlines()[-1])

    assert len(request({"action":"catalog"})["overview"]["meetings"]) == 1
    deleted = request({"action":"delete_meeting", "meeting":str(current)})
    assert deleted["overview"]["meetings"] == [] and deleted["deleted"][0]["count"] == 2
    restored = request({"action":"restore_meeting", "token":deleted["deleted"][0]["id"]})
    assert len(restored["overview"]["meetings"]) == 1 and restored["deleted"] == []
