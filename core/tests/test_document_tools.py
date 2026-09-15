import io
import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path
from unittest.mock import patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import document_tools as dt


def sample(text="Иван Иванов согласовал бюджет 120 000 рублей. Срок — 15 сентября."):
    return dt.document("Личный файл Иванова.docx", "DOCX", [("Текст Word", text)])


def test_letter_initials_landlines_address_oid_and_false_person():
    # Synthetic analogue of a failed official-letter extraction, not user PII.
    text = ("МИНИСТЕРСТВО ОБРАЗОВАНИЯ ОБЛАСТИ\n"
            "Садовая пер., д. 17, Примерск, 123456, тел. (4012) 111-222\n"
            "Факс (4012) 111-223\nРоссийской Федерации Иванова О. Ю. от 06.11.2025\n"
            "Министр [SIGNERSTAMP1] С.С. Семёнова\nН. Е. Петрова\n8-4012-111-224\n"
            "Идентификатор&#x20;\noid\n1 [Человек 1]\n[Телефон 1] [Почта 2] [Документ 1]\n"
            "Институт образования, методист\n242900001\n2 [Человек 2]\n360591\n"
            "Бюджет — 120 000 рублей. Скидка 10%. Срок — 15 сентября. Не согласовал.")
    value = sample(text)
    with patch.object(dt, "model_request", return_value=json.dumps({"entities": [
        {"kind": "PERSON", "variants": ["Федерации", "Российской Федерации"]},
        {"kind": "PERSON", "variants": ["[Человек 1]"]}
    ]})):
        result = dt.detect(value)
    for private in ("Садовая", "123456", "111-222", "111-223", "111-224", "Иванова", "Семёнова", "Петрова", "242900001", "360591"):
        assert private not in result["text"], private
    for meaningful in ("Российской Федерации", "06.11.2025", "120 000", "10%", "15 сентября", "Не согласовал", "[Человек 1]"):
        assert meaningful in result["text"]
    assert "&#x20;" not in result["text"]
    assert all(e["replacement"] != "[Человек 1]" for e in result["entities"] if e["kind"] == "PERSON")
    assert not any("Семёнова\nН. Е." in e["variants"] for e in result["entities"])


def test_large_documents_and_request_transport(tmp_path):
    text = "Условие и бюджет 120000 рублей.\n" * 20000 + "КОНЕЦ"
    path = tmp_path / "large.txt"
    path.write_text(text, encoding="utf-8")
    value = dt.read_document(path)
    assert dt.full_text(value) == text and value["characters"] > 200_000
    result = dt.detect(value, use_model=False)
    assert result["text"] == text
    # Payload above the former 2.5 MB limit is accepted without clipping.
    transport = json.dumps({"action": "apply", "document": value, "entities": []}, ensure_ascii=True)
    assert len(transport) > 2_500_000
    process = subprocess.run([sys.executable, str(Path(dt.__file__))], input=transport,
                             capture_output=True, text=True, timeout=30)
    assert process.returncode == 0, process.stdout
    assert json.loads(process.stdout)["text"] == text
    pdf = tmp_path / "many-pages.pdf"
    make_pdf(pdf, ("Useful page text.",) * 205)
    assert len(dt.read_document(pdf)["blocks"]) == 205


def test_too_many_entities_are_not_silently_dropped():
    values = [f"user{i}@example.test" for i in range(3001)]
    with pytest.raises(ValueError, match="3000"):
        dt.merge_entities(" ".join(values), [{"kind": "EMAIL", "variants": [v]} for v in values])


def minimal_word(path, body, extra=None):
    header = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("word/document.xml", header + body + "</w:body></w:document>")
        for name, text in (extra or {}).items():
            archive.writestr(name, text)


def make_pdf(path, pages=("Alice approved 120000 roubles.",), password=None):
    from pypdf import PdfWriter
    from pypdf.generic import DictionaryObject, NameObject, DecodedStreamObject
    writer = PdfWriter()
    for text in pages:
        page = writer.add_blank_page(width=600, height=800)
        if text:
            font = DictionaryObject({NameObject("/Type"): NameObject("/Font"),
                                     NameObject("/Subtype"): NameObject("/Type1"),
                                     NameObject("/BaseFont"): NameObject("/Helvetica")})
            page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"):
                DictionaryObject({NameObject("/F1"): writer._add_object(font)})})
            stream = DecodedStreamObject()
            stream.set_data(f"BT /F1 12 Tf 40 700 Td ({text}) Tj ET".encode("ascii"))
            page[NameObject("/Contents")] = writer._add_object(stream)
    if password:
        writer.encrypt(password)
    writer.write(path)


def test_docx_body_tables_headers_notes_not_comments_or_deletions(tmp_path):
    path = tmp_path / "input.docx"
    w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    minimal_word(path,
        '<w:p><w:r><w:t>Иван </w:t></w:r><w:r><w:t>Иванов</w:t></w:r>'
        '<w:del><w:r><w:delText>удалённый секрет</w:delText></w:r></w:del>'
        '<w:ins><w:r><w:t> согласовал</w:t></w:r></w:ins></w:p>'
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Бюджет</w:t></w:r></w:p></w:tc>'
        '<w:tc><w:p><w:r><w:t>120000</w:t></w:r></w:p></w:tc></w:tr></w:tbl>',
        {"word/header1.xml": f'<w:hdr {w}><w:p><w:r><w:t>Отдел продаж</w:t></w:r></w:p></w:hdr>',
         "word/footnotes.xml": f'<w:footnotes {w}><w:footnote><w:p><w:r><w:t>Важная сноска</w:t></w:r></w:p></w:footnote></w:footnotes>',
         "word/comments.xml": "secret comment", "word/media/image1.png": "private picture",
         "docProps/core.xml": "secret author"})
    original = path.read_bytes()
    result = dt.read_document(path)
    text = dt.full_text(result)
    assert "Иван Иванов согласовал" in text
    assert "Бюджет\t120000" in text and "Важная сноска" in text and "Отдел продаж" in text
    assert "удалённый секрет" not in text and "secret" not in text
    assert any("исправления" in w for w in result["warnings"])
    assert any("Изображения" in w for w in result["warnings"])
    assert path.read_bytes() == original


def test_docx_rejects_xml_entities_and_bomb(tmp_path):
    path = tmp_path / "bad.docx"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("word/document.xml", '<!DOCTYPE x [<!ENTITY x SYSTEM "file:///etc/passwd">]><x>&x;</x>')
    with pytest.raises(ValueError, match="XML"):
        dt.read_document(path)
    info = zipfile.ZipInfo("word/document.xml"); info.file_size = 129 * 1024 * 1024
    with patch.object(zipfile.ZipFile, "infolist", return_value=[info]), pytest.raises(ValueError, match="128 МБ"):
        dt.read_document(path)


def test_pdf_pages_partial_scans_and_password(tmp_path):
    path = tmp_path / "sample.pdf"
    make_pdf(path, ("Alice approved 120000 roubles.", "", "The deadline is Friday."))
    result = dt.read_document(path)
    assert [b["locator"] for b in result["blocks"]] == ["Страница 1", "Страница 3"]
    assert "120000" in dt.full_text(result)
    assert any("страницах: 2" in w for w in result["warnings"])
    make_pdf(path, ("",))
    with pytest.raises(ValueError, match="OCR"):
        dt.read_document(path)
    make_pdf(path, password="not-for-tests")
    with pytest.raises(ValueError, match="паролем"):
        dt.read_document(path)


def test_text_limits_do_not_silently_truncate(tmp_path):
    path = tmp_path / "readme.txt"
    text = ("Строка и условие. " * 300) + "КОНЕЦ"
    path.write_text(text, encoding="utf-8")
    result = dt.read_document(path)
    assert len(result["blocks"]) > 1
    assert dt.full_text(result) == text
    with pytest.raises(ValueError, match="2 000 000"):
        sample("x" * (dt.MAX_TEXT + 1))
    path = tmp_path / "macro.docm"
    path.write_text("do not execute")
    with pytest.raises(ValueError, match="Поддерживаются"):
        dt.read_document(path)


def test_exact_replacements_keep_conditions_numbers_and_identity():
    text = "Иван Иванов не согласовал бюджет 120 000. Иванов подпишет до 15 сентября, если ООО «Ромашка» даст скидку 10%."
    entities = dt.merge_entities(text, [
        {"kind": "PERSON", "variants": ["Иван Иванов", "Иванов", "Несуществующий человек"]},
        {"kind": "ORG", "variants": ["ООО «Ромашка»"]}])
    result = dt.apply_replacements(text, entities)
    assert result["text"] == "[Человек 1] не согласовал бюджет 120 000. [Человек 1] подпишет до 15 сентября, если [Компания 1] даст скидку 10%."
    assert result["count"] == 3
    assert "Несуществующий человек" not in str(entities)


def test_overlap_boundaries_and_literal_regex_characters():
    text = "Анна и Анналы: anna@example.test; +7 (999) 123-45-67. A+B не равно AAB."
    entities = dt.merge_entities(text, dt.automatic_entities(text) + [
        {"kind": "PERSON", "variants": ["Анна", "anna"]},
        {"kind": "OTHER", "variants": ["A+B"]}])
    result = dt.apply_replacements(text, entities)["text"]
    assert "Анналы" in result and "AAB" in result
    assert "anna@example.test" not in result and "+7 (999) 123-45-67" not in result
    assert "[Почта 1]" in result and "[Телефон 1]" in result
    assert "A+B" not in result


def test_rules_detect_ids_but_preserve_normal_dates_and_budgets():
    text = ("Бюджет 120 000 рублей, срок 15.09.2026. ИНН 1234567890, "
            "СНИЛС 123-456-789 00; дата рождения: 01.02.1990; карта 4111 1111 1111 1111.")
    result = dt.apply_replacements(text, dt.merge_entities(text, dt.automatic_entities(text)))["text"]
    assert "120 000" in result and "15.09.2026" in result
    for raw in ["1234567890", "123-456-789 00", "01.02.1990", "4111 1111 1111 1111"]:
        assert raw not in result


def test_detection_invalid_model_spans_are_not_applied():
    value = sample()
    with patch.object(dt, "model_request", return_value=json.dumps({"entities": [
        {"kind": "PERSON", "variants": ["Иван Иванов", "Сергей Секретов"]},
        {"kind": "BOGUS", "variants": ["120 000"]}]})):
        result = dt.detect(value)
    assert result["model_complete"] and result["checked"] == 1
    assert len(result["entities"]) == 1 and "Сергей" not in str(result)
    assert "120 000" in result["text"] and "Иван Иванов" not in result["text"]


def test_model_failure_keeps_rules_and_honest_incomplete_status():
    with patch.object(dt, "model_request", side_effect=TimeoutError):
        result = dt.detect(sample("Иван: ivan@example.test"))
    assert not result["model_complete"] and result["checked"] == 0
    assert "[Почта 1]" in result["text"] and "Иван" in result["text"]
    assert any("могут быть пропущены" in w for w in result["warnings"])


def test_model_cannot_mask_money_percent_or_deadline_with_wrong_category():
    text = "Иван согласовал бюджет 120000 рублей, скидку 10%, срок 15 дней."
    wrong = [{"kind": "ID", "variants": ["120000", "120000 рублей", "15 дней"]},
             {"kind": "ORG", "variants": ["10%"]},
             {"kind": "OTHER", "variants": ["согласовал"]},
             {"kind": "PERSON", "variants": ["Иван"]}]
    filtered = dt.filter_model_candidates(text, wrong)
    result = dt.apply_replacements(text, dt.merge_entities(text, filtered))["text"]
    assert result == "[Человек 1] согласовал бюджет 120000 рублей, скидку 10%, срок 15 дней."


def test_rules_and_export_do_not_call_model_or_include_source_metadata(tmp_path):
    value = sample("Иван Иванов: ivan@example.test, бюджет 500.")
    with patch.object(dt.Embedder, "request", side_effect=AssertionError("no network")):
        result = dt.detect(value, use_model=False)
        entities = dt.merge_entities(dt.full_text(value), [
            {"kind": "PERSON", "variants": ["Иван Иванов"]},
            {"kind": "EMAIL", "variants": ["ivan@example.test"]}])
        clean = dt.apply_replacements(dt.full_text(value), entities)["text"]
        data = dt.docx_bytes(clean)
    assert not result["model_complete"]
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        assert not any(n.startswith("word/media/") or n == "word/comments.xml" for n in archive.namelist())
        xml = "\n".join(archive.read(n).decode("utf-8", errors="replace") for n in archive.namelist() if n.endswith(".xml"))
        for secret in ["Иван Иванов", "ivan@example.test", value["title"]]:
            assert secret not in xml
        assert "[Человек 1]" in xml and "бюджет 500" in xml


class FakeLocal:
    def __init__(self, entry=None, info=None):
        self.calls = []
        self.entry = entry or {"name": "qwen3:8b", "size": 5_000_000_000}
        self.info = info if info is not None else {"details": {"format": "gguf"}, "model_info": {"general.architecture": "qwen3"}}

    def request(self, endpoint, body=None, timeout=None):
        self.calls.append((endpoint, body))
        return {"models": [self.entry]} if endpoint == "/api/tags" else self.info


def test_local_weight_check_accepts_real_model_metadata():
    client = FakeLocal()
    dt.require_local_weights(client, "qwen3:8b")
    assert [p for p, _ in client.calls] == ["/api/tags", "/api/show"]


@pytest.mark.parametrize("name,entry,info", [
    ("qwen3:cloud", None, None),
    ("https://outside/model", None, None),
    ("qwen3:8", None, None),
    ("qwen3:8b", {"name": "qwen3:8b", "size": 200}, None),
    ("qwen3:8b", {"name": "qwen3:8b", "size": 5_000_000_000, "remote_host": "https://ollama.com"}, None),
    ("qwen3:8b", None, {"remote_model": "some-cloud-model"}),
    ("qwen3:8b", None, {"details": {"format": "gguf"}}),
])
def test_cloud_unknown_or_incomplete_weights_rejected_before_content(name, entry, info):
    client = FakeLocal(entry, info)
    with pytest.raises(ValueError):
        dt.require_local_weights(client, name)
    assert all(p != "/api/chat" for p, _ in client.calls)


def test_model_request_ignores_remote_and_proxy_settings(monkeypatch):
    monkeypatch.setenv("MEETING_TRANSCRIBER_OLLAMA_HOST", "https://outside.invalid")
    monkeypatch.setenv("HTTPS_PROXY", "https://proxy.invalid")
    client = FakeLocal()
    original = client.request
    def request(endpoint, body=None, timeout=None):
        if endpoint == "/api/chat":
            client.calls.append((endpoint, body))
            return {"message": {"content": "ok"}}
        return original(endpoint, body, timeout)
    client.request = request
    with patch.object(dt, "Embedder", return_value=client):
        assert dt.model_request([{"role": "user", "content": "private"}], model="qwen3:8b") == "ok"
    assert len(client.calls) == 3
    assert client.calls[-1][1]["model"] == "qwen3:8b"
    assert "outside" not in str(client.calls) and "proxy" not in str(client.calls)


def test_document_answer_has_actual_sources_and_rejects_bogus_citations():
    value = sample()
    with patch.object(dt, "model_request", return_value="Бюджет 120 000 [1]."):
        result = dt.answer(value, "Какой бюджет?")
    assert "120 000" in result["text"] and result["citations"][0]["text"] == value["blocks"][0]["text"]
    with patch.object(dt, "model_request", return_value="Миллиард [99]."):
        result = dt.answer(value, "Какой бюджет?")
    assert "Миллиард" not in result["text"] and result["citations"]


def test_no_matches_does_not_ask_llm_and_long_quote_includes_hit():
    with patch.object(dt, "model_request", side_effect=AssertionError):
        result = dt.answer(sample("обычные слова " * 1000), "термоядерный реактор")
    assert not result["citations"]
    value = sample(("обычные слова " * 180 + "уникальныйбюджет 500 рублей. ") * 5)
    sources = dt.select_sources(value, "уникальныйбюджет")
    assert "уникальныйбюджет" in sources[0]["text"] and sources[0]["shortened"]


def test_long_summary_discloses_sampling():
    value = dt.document("Long", "PDF", [(f"Страница {i}", f"Условие {i} " * 150) for i in range(10)])
    with patch.object(dt, "model_request", return_value="Есть условия [1]."):
        result = dt.answer(value, "Краткое содержание")
    assert len(result["citations"]) == 6 and "не полный разбор" in result["notice"]


def test_cli_reads_file_without_dumping_text_to_diagnostics(tmp_path):
    path = tmp_path / "private.txt"
    path.write_text("Иван Иванов согласовал бюджет 500.", encoding="utf-8")
    result = subprocess.run([sys.executable, "-B", str(Path(dt.__file__))],
                            input=json.dumps({"action": "read", "path": str(path)}),
                            text=True, capture_output=True, timeout=10)
    assert result.returncode == 0 and not result.stderr
    reply = json.loads(result.stdout)
    assert reply["event"] == "result" and reply["document"]["title"] == "private.txt"


@pytest.mark.skipif(os.environ.get("SLAVATOR_TEST_OLLAMA") != "1", reason="optional installed local model")
def test_actual_local_document_model():
    value = sample("Иван Иванов согласовал бюджет 120000 рублей. Телефон: +7 (999) 123-45-67.")
    result = dt.detect(value)
    assert result["model_complete"], result["warnings"]
    assert "Иван Иванов" not in result["text"] and "+7 (999) 123-45-67" not in result["text"]
    assert "120000" in result["text"]
