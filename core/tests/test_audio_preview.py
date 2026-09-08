from pathlib import Path
import wave

import pytest

from audio_preview import decode_slice


def test_pcm_slice_duration_and_no_overwrite(tmp_path):
    pytest.importorskip("av")
    source = tmp_path / "source.wav"
    with wave.open(str(source),"wb") as out:
        out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
        out.writeframes(b"\0\0"*16000*4)
    target = tmp_path / "preview.wav"
    duration = decode_slice(source,target,1,2.25)
    assert abs(duration-1.25) < .003
    with pytest.raises(FileExistsError):
        decode_slice(source,target,1,2)
    assert source.stat().st_size == 44+16000*4*2


def test_preview_rejects_network_and_bad_times(tmp_path):
    pytest.importorskip("av")
    with pytest.raises(ValueError):
        decode_slice(Path("https://example.invalid/audio"),tmp_path/"out.wav")
    source = tmp_path/"source.wav"
    source.touch()
    with pytest.raises(ValueError):
        decode_slice(source,tmp_path/"out.wav",3,1)
