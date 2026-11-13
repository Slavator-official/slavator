import io
import tarfile
import urllib.error

import pytest

import onnx_engine as engine


@pytest.mark.parametrize("cause, expected", [
    (urllib.error.HTTPError("https://example.org/model", 403, "Forbidden", {}, None), "403"),
    (urllib.error.URLError("CERTIFICATE_VERIFY_FAILED"), "CERTIFICATE_VERIFY_FAILED"),
    (PermissionError("Permission denied"), "Permission denied"),
    (TimeoutError("timed out"), "время ожидания"),
])
def test_download_failure_preserves_reason(tmp_path, monkeypatch, cause, expected):
    monkeypatch.setattr(engine, "MODELS_DIR", tmp_path)
    def fail(*args, **kwargs):
        raise cause
    monkeypatch.setattr(engine.urllib.request, "urlopen", fail)
    with pytest.raises(engine.EngineError) as caught:
        engine.ensure_models(["segmentation"], log=lambda _: None)
    assert expected in str(caught.value)
    assert not (tmp_path / ".segmentation.part").exists()


def test_empty_model_is_missing(tmp_path, monkeypatch):
    monkeypatch.setattr(engine, "MODELS_DIR", tmp_path)
    path = engine.model_path("segmentation")
    path.parent.mkdir(parents=True)
    path.touch()
    assert engine.missing(["segmentation"]) == ["segmentation"]


@pytest.mark.parametrize("archive", [False, True])
def test_download_installs_model_and_skips_it_on_retry(tmp_path, monkeypatch, archive):
    source = tmp_path / "source"
    content = b"model fixture"
    if archive:
        with tarfile.open(source, "w:bz2") as handle:
            item = tarfile.TarInfo("model.onnx")
            item.size = len(content)
            handle.addfile(item, io.BytesIO(content))
    else:
        source.write_bytes(content)
    monkeypatch.setattr(engine, "MODELS_DIR", tmp_path / "models")
    monkeypatch.setitem(engine.MODELS, "fixture", dict(
        check="model.onnx", url=source.as_uri(), archive=archive, size_mb=1, title="тест"))
    engine.ensure_models(["fixture"])
    assert engine.model_path("fixture").read_bytes() == content
    assert not (engine.MODELS_DIR / ".fixture.part").exists()
    source.unlink()
    engine.ensure_models(["fixture"])  # Уже установленная модель не скачивается заново.
