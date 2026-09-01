from pathlib import Path
from speaker_service.backend import BackendAdapter

def test_backend_unavailable(tmp_path):
    adapter=BackendAdapter(tmp_path/"missing.py",Path("/usr/bin/python"))
    assert adapter.available() is False
