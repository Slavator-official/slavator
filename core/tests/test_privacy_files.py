"""Synthetic data only. No user files or network services."""
import base64
import csv
import io
import json
import socket
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from unittest.mock import patch

import pytest
import privacy_files as pf


def mask(path, ner=False):
    source = pf.Source(path)
    entities = pf.detect(source, ner, lambda _: None)
    matcher = pf.Matcher(entities)
    return source, entities, source.export(matcher, lambda _: None)


def test_long_file_15001_rows_many_unique_ids_and_exact_structure(tmp_path):
    path = tmp_path / 'large.csv'
    lines = ['ФИО;СНИЛС;Телефон;Бюджет;Условие']
    for n in range(15001):
        lines.append(f'ИВАНОВ ИВАН ИВАНОВИЧ;{10000000000+n};+7 (999) {n//10000:03d}-{n//100%100:02d}-{n%100:02d};120000;не согласовал')
    original = '\r\n'.join(lines) + '\r\n'
    path.write_bytes(original.encode('utf-8-sig'))
    start = time.monotonic()
    with patch.object(socket.socket, 'connect', side_effect=AssertionError('Network forbidden')), patch.object(socket, 'getaddrinfo', side_effect=AssertionError('DNS forbidden')):
        source, entities, data = mask(path, ner=True)
    result = data.decode('utf-8-sig')
    rows = list(csv.reader(io.StringIO(result), delimiter=';'))
    assert len(rows) == 15002 and all(len(r) == 5 for r in rows)
    assert rows[0] == ['ФИО', 'СНИЛС', 'Телефон', 'Бюджет', 'Условие']
    assert len(entities) > 30000
    assert len(result.split('\r\n')) == len(original.split('\r\n'))
    assert 'ИВАНОВ' not in result and '10000015000' not in result and '+7 (999)' not in result
    assert all(row[-2:] == ['120000', 'не согласовал'] for row in rows[1:])
    assert path.read_bytes() == original.encode('utf-8-sig')
    assert source.characters > len(source.preview())
    print(f'15001 CSV rows, {len(entities)} entities: {time.monotonic()-start:.2f}s')


def test_excel_15001_rows_styles_hidden_sheets_and_numeric_identifiers(tmp_path):
    import openpyxl
    from openpyxl.styles import Font
    book = openpyxl.Workbook(); sheet = book.active
    sheet.append(['ФИО', 'СНИЛС', 'Телефон', 'Бюджет'])
    for n in range(15001):
        sheet.append(['Иванов Иван Иванович', 10000000000+n, f'8999{n:07d}', 120000])
    sheet['A1'].font = Font(bold=True)
    hidden = book.create_sheet('Скрытый'); hidden.sheet_state = 'hidden'
    hidden['A1'] = 'hidden@example.test'
    sheet['E1'] = '=SUM(D2:D3)'
    path = tmp_path / 'large.xlsx'; book.save(path)
    _, entities, output = mask(path)
    clean = openpyxl.load_workbook(io.BytesIO(output))
    assert clean.active.max_row == 15002 and clean.active.max_column == 5
    assert clean.active['A1'].font.bold
    assert [clean.active.cell(1, n).value for n in range(1, 5)] == ['ФИО', 'СНИЛС', 'Телефон', 'Бюджет']
    assert clean.active['D15002'].value == 120000
    assert clean.active['E1'].value == '=SUM(D2:D3)'
    assert clean.active['B15002'].value.startswith('[Документ ')
    assert clean['Скрытый']['A1'].value.startswith('[Почта ')
    with zipfile.ZipFile(io.BytesIO(output)) as archive:
        contents = b'\n'.join(archive.read(n) for n in archive.namelist())
    assert b'10000015000' not in contents and b'hidden@example.test' not in contents
    assert len(entities) > 30000


def test_docx_cross_run_names_tables_headers_and_hidden_data(tmp_path):
    from docx import Document
    doc = Document()
    p = doc.add_paragraph(); p.add_run('Иванов ').bold = True
    p.add_run('Иван Иванович, СНИЛС 123-456-789 00, +7 (999) 111-22-33; бюджет 120000.')
    table = doc.add_table(rows=1, cols=2)
    table.cell(0, 0).text = 'Срок'; table.cell(0, 1).text = '15 дней'
    doc.sections[0].header.paragraphs[0].text = 'secret@example.test'
    doc.core_properties.author = 'Private author'
    path = tmp_path / 'source.docx'; doc.save(path)
    _, _, output = mask(path)
    clean = Document(io.BytesIO(output))
    assert 'Иванов' not in clean.paragraphs[0].text
    assert '120000' in clean.paragraphs[0].text
    assert clean.paragraphs[0].runs[0].bold
    assert clean.tables[0].cell(0, 1).text == '15 дней'
    with zipfile.ZipFile(io.BytesIO(output)) as archive:
        contents = b'\n'.join(archive.read(n) for n in archive.namelist())
    for private in ['Иванов', 'secret@example.test', 'Private author', '123-456-789']:
        assert private.encode() not in contents


def test_pdf_redaction_removes_underlying_text_and_preserves_pages(tmp_path):
    import pymupdf
    doc = pymupdf.open(); page = doc.new_page()
    page.insert_text((30, 50), 'Email: private@example.test Phone: +7 (999) 111-22-33')
    page.insert_text((30, 90), 'Budget 120000. Deadline 15 days.')
    doc.new_page().insert_text((30, 50), 'Second page')
    doc.set_metadata({'author': 'secret author'})
    path = tmp_path / 'source.pdf'; doc.save(path)
    _, _, output = mask(path)
    clean = pymupdf.open(stream=output, filetype='pdf')
    text = ''.join(p.get_text() for p in clean)
    assert len(clean) == 2 and clean[0].rect == doc[0].rect
    assert 'private@example.test' not in text and '111-22-33' not in text
    assert '120000' in text and 'Second page' in text
    assert not clean.metadata['author']


def test_scanned_pdf_fails_closed(tmp_path):
    import pymupdf
    doc = pymupdf.open(); page = doc.new_page()
    pix = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 30, 30), False)
    page.insert_image(pymupdf.Rect(0, 0, 30, 30), pixmap=pix)
    path = tmp_path / 'scan.pdf'; doc.save(path)
    with pytest.raises(ValueError, match='изображения'):
        pf.Source(path)


def test_txt_preserves_whitespace_crlf_encoding_and_detects_multiple_values(tmp_path):
    text = '  Иванов Иван Иванович; СНИЛС 12345678900; ИНН 123456789012; телефон 89991112233; a@example.test\r\n\r\nне согласовал 120000 рублей.\r\n'
    path = tmp_path / 'source.txt'; path.write_bytes(text.encode('cp1251'))
    _, _, data = mask(path)
    clean = data.decode('cp1251')
    assert clean.startswith('  ') and clean.endswith('\r\n') and '\r\n\r\n' in clean
    for private in ['Иванов', '12345678900', '123456789012', '89991112233', 'a@example.test']:
        assert private not in clean
    assert 'не согласовал 120000 рублей.' in clean


def test_ner_offline_without_ollama(tmp_path):
    path = tmp_path / 'ner.txt'; path.write_text('Мария встретилась с Анной в Москве.', encoding='utf-8')
    with patch.object(socket.socket, 'connect', side_effect=AssertionError('Network forbidden')), patch.object(socket, 'getaddrinfo', side_effect=AssertionError('DNS forbidden')):
        source, entities, data = mask(path, ner=True)
    assert 'Мария' not in data.decode() and 'Анной' not in data.decode()
    assert any(e['origin'] == 'Локальная NER' for e in entities)


def test_hash_changed_source_cancelled_and_source_never_written(tmp_path):
    path = tmp_path / 'source.txt'; path.write_text('original')
    digest = pf.Source(path).digest
    path.write_text('modified')
    with pytest.raises(ValueError, match='изменился'):
        pf.Source(path, digest)


def test_worker_protocol_native_export_and_no_network(tmp_path):
    path = tmp_path / 'source.txt'; path.write_text('private@example.test\n')
    worker = Path(pf.__file__).with_name('document_tools.py')
    request = {'action': 'privacy_detect', 'path': str(path), 'source_hash': pf.Source(path).digest, 'use_model': False}
    proc = subprocess.run([sys.executable, '-B', str(worker)], input=json.dumps(request), text=True, capture_output=True, timeout=30)
    assert proc.returncode == 0, proc.stdout
    result = json.loads(proc.stdout.splitlines()[-1])
    request.update(action='privacy_export', entities=result['entities'])
    proc = subprocess.run([sys.executable, '-B', str(worker)], input=json.dumps(request), text=True, capture_output=True, timeout=30)
    assert proc.returncode == 0, proc.stdout
    assert 'private@example.test' not in base64.b64decode(json.loads(proc.stdout)['data']).decode()
    assert path.read_text() == 'private@example.test\n'


def test_matcher_boundaries_overlap_disabled_repeated_labels():
    entities = [dict(variants=['Анна'], replacement='[Человек 1]'),
                dict(variants=['Анна Иванова'], replacement='[Человек 2]'),
                dict(variants=['Анналы'], replacement='removed', enabled=False)]
    assert pf.Matcher(entities).replace('Анна Иванова и Анна. Анналы.')[0] == '[Человек 2] и [Человек 1]. Анналы.'


@pytest.mark.parametrize('snils', ['12345678900', '123-456-789 00', '123-456-789-00', '123-456-78900', '123 456 789 00', '123–456–789–00'])
@pytest.mark.parametrize('phone', ['+7 (999) 111-22-33', '89991112233', '9991112233'])
def test_snils_email_phone_and_full_name_in_the_same_line(tmp_path, snils, phone):
    path = tmp_path / 'one-line.txt'
    original = f'Иванов Иван Иванович; {snils}; TEST.person+tag@example.test; {phone}; бюджет 120000, не согласовал.\n'
    path.write_text(original, encoding='utf-8')
    source, entities, result = mask(path)
    text = result.decode('utf-8')
    for private in ['Иванов', snils, 'TEST.person+tag@example.test', phone]:
        assert private not in text
    assert text.count(';') == original.count(';') and text.endswith('бюджет 120000, не согласовал.\n')
    assert path.read_text() == original
