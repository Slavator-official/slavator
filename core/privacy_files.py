"""Offline, format-preserving privacy workflow. No Ollama or network client.

Only previews cross the UI pipe; processing always rereads the complete source
and verifies its SHA-256. Export returns bytes, never writes a supplied path.
"""
from __future__ import annotations

import base64
import hashlib
import io
import re
import socket
import zipfile
from collections import Counter
from pathlib import Path
from lxml import etree as ET

MAX_BYTES = 100 * 1024 * 1024
MAX_CHARS = 25_000_000
MAX_ENTITIES = 250_000
PREVIEW = 30_000
W = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
WARNING = 'Поиск может пропустить данные. Проверьте копию; одинаковые метки означают одинаковый текст, не подтверждённую личность.'


def xml_root(raw):
    from document_tools import xml_root as validate_xml
    validate_xml(raw)
    # Preserve Office namespace prefixes referenced by mc:Ignorable etc.
    return ET.fromstring(raw, ET.XMLParser(resolve_entities=False, no_network=True))


def deny_network():
    def denied(*args, **kwargs):
        raise RuntimeError('Сеть отключена для обезличивания.')
    socket.socket.connect = denied
    socket.socket.connect_ex = denied
    socket.create_connection = denied
    socket.getaddrinfo = denied


def folded(text):
    # Keep offsets stable (unlike casefold, which can expand characters).
    return ''.join(c.lower() if len(c.lower()) == 1 else c for c in text)


def word(c):
    return c.isalnum() or c == '_'


class Matcher:
    def __init__(self, entities):
        import ahocorasick
        if not isinstance(entities, list) or len(entities) > MAX_ENTITIES:
            raise ValueError('Слишком много сущностей (предел 250 000).')
        self.index = ahocorasick.Automaton()
        self.enabled = False
        for entity in entities:
            if not entity.get('enabled', True):
                continue
            replacement = entity.get('replacement', '')
            if not isinstance(replacement, str) or not replacement.strip() or len(replacement) > 200:
                raise ValueError('Укажите непустую замену до 200 символов.')
            for value in entity.get('variants', [])[:30]:
                if not isinstance(value, str) or not 2 <= len(value) <= 500:
                    continue
                key = folded(value)
                if key not in self.index:
                    self.index.add_word(key, (len(value), replacement))
                    self.enabled = True
        if self.enabled:
            self.index.make_automaton()

    def spans(self, text):
        if not self.enabled:
            return []
        found = []
        for end, (length, replacement) in self.index.iter(folded(text)):
            start, stop = end - length + 1, end + 1
            if text[start].isalnum() and start and word(text[start - 1]):
                continue
            if text[end].isalnum() and stop < len(text) and word(text[stop]):
                continue
            found.append((start, stop, replacement))
        found.sort(key=lambda item: (item[0], -(item[1] - item[0])))
        accepted, cursor = [], 0
        for item in found:
            if item[0] >= cursor:
                accepted.append(item)
                cursor = item[1]
        return accepted

    def replace(self, text):
        pieces, cursor = [], 0
        spans = self.spans(text)
        for start, end, replacement in spans:
            pieces.extend((text[cursor:start], replacement))
            cursor = end
        pieces.append(text[cursor:])
        return ''.join(pieces), len(spans)


def decode_text(data):
    if data.startswith((b'\xff\xfe', b'\xfe\xff')):
        return data.decode('utf-16'), 'utf-16'
    for encoding in ('utf-8-sig' if data.startswith(b'\xef\xbb\xbf') else 'utf-8', 'cp1251'):
        try:
            return data.decode(encoding), encoding
        except UnicodeError:
            pass
    raise ValueError('Не удалось прочитать кодировку текста.')


class Source:
    def __init__(self, filename, expected=None, data=None):
        self.path = Path(filename).expanduser().resolve(strict=True)
        if not self.path.is_file() or self.path.stat().st_size > MAX_BYTES:
            raise ValueError('Выберите файл до 100 МБ.')
        self.data = self.path.read_bytes() if data is None else data
        self.digest = hashlib.sha256(self.data).hexdigest()
        if expected and self.digest != expected:
            raise ValueError('Исходник изменился. Откройте его и выполните поиск заново.')
        self.ext = self.path.suffix.lower()
        self.units = []
        self.hints = []
        self.warnings = [WARNING]
        if self.ext in {'.txt', '.md', '.csv', '.tsv'}:
            self.text, self.encoding = decode_text(self.data)
            self.units = [self.text]
            if self.ext in {'.csv', '.tsv'}:
                self.csv_hints()
        elif self.ext in {'.docx', '.xlsx'}:
            with zipfile.ZipFile(io.BytesIO(self.data)) as archive:
                infos = archive.infolist()
                if len(infos) > 20000 or len({i.filename for i in infos}) != len(infos):
                    raise ValueError('Некорректный или слишком сложный архив Office.')
                if sum(i.file_size for i in infos) > 300 * 1024 * 1024:
                    raise ValueError('Распакованный Office превышает 300 МБ.')
                for info in infos:
                    if info.filename.endswith('.xml'):
                        xml_root(archive.read(info))
            if self.ext == '.docx':
                self.load_word()
            else:
                self.load_excel()
        elif self.ext == '.pdf':
            self.load_pdf()
        else:
            raise ValueError('Поддерживаются XLSX, CSV, TSV, DOCX, PDF, TXT и MD. Старые XLS/DOC сохраните в XLSX/DOCX.')
        total = sum(len(s) for s in self.units)
        if not total or total > MAX_CHARS:
            raise ValueError('Нужен читаемый текст объёмом до 25 миллионов символов. Ничего не обрезано.')
        self.characters = total

    def csv_hints(self):
        import csv
        try:
            dialect = csv.Sniffer().sniff(self.text[:8192], delimiters=',;\t|')
            rows = csv.reader(io.StringIO(self.text, newline=''), dialect)
            headers = next(rows)
            for row in rows:
                for header, cell in zip(headers, row):
                    kind = header_kind(header)
                    if kind and cell.strip():
                        self.hints.append((kind, cell.strip()))
        except (csv.Error, StopIteration):
            self.warnings.append('Заголовки CSV не распознаны; весь текст проверяется общими правилами и локальным распознавателем имён.')

    def load_excel(self):
        import openpyxl
        self.book = openpyxl.load_workbook(io.BytesIO(self.data), keep_links=False)
        self.warnings.append('Excel: сохраняются листы, ячейки, стили и обычные формулы. Комментарии, ссылки, рисунки, диаграммы и свойства файла удаляются. Формула с персональными данными заменяется текстом.')
        cells = 0
        for sheet in self.book:
            if sheet.max_row * sheet.max_column > 2_000_000:
                raise ValueError('Лист превышает 2 миллиона ячеек. Удалите пустое форматирование за пределами таблицы.')
            self.units.append(sheet.title)
            headers = {}
            for row in sheet:
                values = []
                for cell in row:
                    cells += 1
                    if cells > 3_000_000:
                        raise ValueError('Книга превышает 3 миллиона ячеек.')
                    value = '' if cell.value is None else str(cell.value)
                    values.append(value)
                    kind = header_kind(value)
                    if cell.row <= 10 and kind:
                        headers[cell.column] = kind
                    elif cell.column in headers and value:
                        self.hints.append((headers[cell.column], value))
                self.units.append('\t'.join(values))

    def load_word(self):
        self.parts = {}
        with zipfile.ZipFile(io.BytesIO(self.data)) as archive:
            for name in archive.namelist():
                if name.startswith('word/') and name.endswith('.xml'):
                    root = xml_root(archive.read(name))
                    self.parts[name] = root
                    for paragraph in root.iter(W + 'p'):
                        self.units.append(''.join(node.text or '' for node in paragraph.iter() if node.tag in {W + 't', W + 'delText', W + 'instrText'}))
        self.warnings.append('Word: сохраняются абзацы, таблицы и оформление текста. Изображения, вложения, комментарии, история исправлений, поля, ссылки и метаданные удаляются; вставки принимаются.')

    def load_pdf(self):
        import pymupdf
        self.pdf = pymupdf.open(stream=self.data, filetype='pdf')
        if self.pdf.is_encrypted:
            raise ValueError('Сохраните PDF без пароля.')
        if len(self.pdf) > 2000:
            raise ValueError('В PDF более 2000 страниц.')
        for number, page in enumerate(self.pdf, 1):
            # Fail closed: text-layer checks cannot inspect faces, signatures,
            # screenshots or scanned text. Never certify an unchecked image.
            if page.get_images() or page.get_image_info():
                raise ValueError(f'На странице {number} PDF есть изображения. Этот режим принимает текстовые PDF без сканов и картинок; используйте текстовый исходник.')
            self.units.append(page.get_text())
        self.warnings.append('PDF: найденный текст физически удаляется с чёрными прямоугольниками; размер и число страниц сохраняются. Поля форм, аннотации, вложения, ссылки и метаданные удаляются. Векторные надписи не распознаются как текст — проверьте визуально.')

    def preview(self):
        # Avoid constructing another full copy for a UI preview.
        parts, left = [], PREVIEW
        for text in self.units:
            if left <= 0:
                break
            parts.append(text[:left]); left -= len(parts[-1]) + 1
        return '\n'.join(parts)

    def document(self):
        return dict(title=self.path.name, format=self.ext[1:].upper(), characters=self.characters,
                    sourceHash=self.digest, warnings=self.warnings,
                    blocks=[dict(id='1', locator='Предпросмотр начала; обрабатывается весь файл', text=self.preview(), separator='')])

    def export(self, matcher, progress):
        if self.ext in {'.txt', '.md', '.csv', '.tsv'}:
            result, _ = matcher.replace(self.text)
            # Exact delimiter / newline / quoting preservation. Replacement
            # labels contain no separator or quote characters by default.
            if self.ext in {'.csv', '.tsv'}:
                for _, _, replacement in matcher.spans(self.text):
                    if any(c in replacement for c in '\r\n\t,;|"'):
                        raise ValueError('Для CSV/TSV подписи замен не должны содержать разделители, кавычки или переносы строк.')
            try:
                return result.encode(self.encoding)
            except UnicodeError:
                raise ValueError('Подпись замены не представима в кодировке исходника. Используйте другие символы.') from None
        if self.ext == '.xlsx':
            from openpyxl.packaging.core import DocumentProperties
            for sheet in self.book:
                title = matcher.replace(sheet.title)[0]
                if title != sheet.title:
                    # Renaming can invalidate formulas and named ranges.
                    raise ValueError('Персональные данные в имени листа. Переименуйте лист в исходной копии и повторите поиск.')
                sheet._images = []; sheet._charts = []
                for row in sheet:
                    for cell in row:
                        cell.comment = None; cell.hyperlink = None
                        if cell.value is not None:
                            value = str(cell.value)
                            changed, count = matcher.replace(value)
                            if count:
                                cell.value = changed
                                cell.data_type = 's'
                sheet.HeaderFooter = type(sheet.HeaderFooter)()
            self.book.properties = DocumentProperties(creator='', lastModifiedBy='')
            self.book.custom_doc_props.props = []
            self.book.defined_names.clear()
            output = io.BytesIO(); self.book.save(output)
            return scrub_office(output.getvalue(), matcher)
        if self.ext == '.docx':
            for root in self.parts.values():
                # Strip potentially hidden or executable content, keeping the
                # surrounding paragraph/table/style structure intact.
                for parent in root.iter():
                    for child in list(parent):
                        if child.tag in {W + n for n in ('del', 'moveFrom', 'drawing', 'pict', 'object', 'instrText', 'fldChar', 'commentRangeStart', 'commentRangeEnd', 'commentReference')}:
                            parent.remove(child)
                for paragraph in root.iter(W + 'p'):
                    nodes = list(paragraph.iter(W + 't'))
                    replace_nodes(nodes, matcher)
            return scrub_office(self.data, matcher, self.parts)
        if self.ext == '.pdf':
            import pymupdf
            for number, page in enumerate(self.pdf, 1):
                progress(f'Удаляю данные: страница {number} из {len(self.pdf)}…')
                raw = page.get_text('rawdict')
                chars, positions = [], []
                for block in raw['blocks']:
                    for line in block.get('lines', []):
                        for span in line.get('spans', []):
                            for char in span.get('chars', []):
                                chars.append(char['c']); positions.append(char['bbox'])
                        chars.append('\n'); positions.append(None)
                for start, end, _ in matcher.spans(''.join(chars)):
                    for rect in positions[start:end]:
                        if rect:
                            page.add_redact_annot(pymupdf.Rect(rect), fill=(0, 0, 0))
                page.apply_redactions(images=0, graphics=0, text=0)
                for widget in list(page.widgets() or []):
                    page.delete_widget(widget)
                for annot in list(page.annots() or []):
                    page.delete_annot(annot)
            self.pdf.scrub()
            self.pdf.set_toc([])
            result = self.pdf.tobytes(garbage=4, deflate=True, clean=True)
            check = pymupdf.open(stream=result, filetype='pdf')
            if any(matcher.spans(page.get_text()) for page in check):
                raise ValueError('Проверка PDF обнаружила оставшийся выбранный текст. Копия не выдана.')
            return result
        raise ValueError('Неподдерживаемый формат.')


def replace_nodes(nodes, matcher):
    text = ''.join(node.text or '' for node in nodes)
    spans = matcher.spans(text)
    # Apply from right to left, distributing a cross-run replacement into its
    # first run. Unaffected run formatting is retained.
    offsets, cursor = [], 0
    for node in nodes:
        offsets.append((cursor, cursor + len(node.text or ''), node))
        cursor += len(node.text or '')
    for start, end, replacement in reversed(spans):
        first = True
        for low, high, node in offsets:
            if low < end and high > start:
                value = node.text or ''
                a, b = max(start - low, 0), min(end - low, high - low)
                node.text = value[:a] + (replacement if first else '') + value[b:]
                first = False


def scrub_office(data, matcher, parts=None):
    """Repack, excluding metadata, caches, external links and binary payloads."""
    output = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(data)) as source, zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as dest:
        removed = {n for n in source.namelist() if n.startswith(('docProps/', 'customXml/', 'word/media/', 'word/embeddings/', 'word/comments', 'xl/externalLinks/', 'xl/comments', 'xl/drawings/', 'xl/media/', 'xl/pivot', 'xl/persons', 'xl/printerSettings/'))}
        for name in source.namelist():
            if name in removed:
                continue
            raw = source.read(name)
            if name.endswith(('.xml', '.rels')):
                root = (parts or {}).get(name)
                if root is None:
                    root = xml_root(raw)
                for parent in root.iter():
                    for child in list(parent):
                        target = child.get('Target', '')
                        part = child.get('PartName', '').lstrip('/')
                        if child.get('TargetMode') == 'External' or part in removed or any(t in target for t in ('comments', 'docProps', 'customXml', 'media/', 'embeddings/', 'externalLinks/', 'pivot', 'printerSettings/')):
                            parent.remove(child)
                for element in root.iter():
                    if element.text:
                        element.text = matcher.replace(element.text)[0]
                    for key, value in list(element.attrib.items()):
                        if key.split('}')[-1] in {'author', 'initials', 'date'}:
                            element.attrib[key] = ''
                        elif key.split('}')[-1] in {'descr', 'title', 'name'}:
                            element.attrib[key] = matcher.replace(value)[0]
                raw = ET.tostring(root, encoding='utf-8', xml_declaration=True)
            elif name not in {'mimetype'}:
                # Only Office XML parts are needed for text / table documents.
                continue
            dest.writestr(name, raw)
    return output.getvalue()


def header_kind(value):
    value = value.strip().lower().replace('ё', 'е')
    if re.fullmatch(r'(фио|ф\.и\.о\.?|фамилия|имя|отчество|фамилия имя отчество)', value):
        return 'PERSON'
    if re.fullmatch(r'(снилс|инн|паспорт|номер паспорта|серия паспорта|полис|омс)', value):
        return 'ID'
    if re.fullmatch(r'(телефон|номер телефона|мобильный|моб\.? телефон|phone)', value):
        return 'PHONE'
    if re.fullmatch(r'(email|e-mail|почта|электронная почта)', value):
        return 'EMAIL'
    if re.fullmatch(r'(адрес|адрес регистрации|адрес проживания)', value):
        return 'ADDRESS'
    if re.fullmatch(r'(дата рождения|д\.р\.)', value):
        return 'BIRTHDATE'
    return None


def detect(source, use_ner, progress):
    from document_tools import automatic_entities, KINDS, invalid_person
    entities, known, counts = [], {}, Counter()
    def add(kind, value, origin):
        value = value.strip()
        if '\t' in value:
            # Excel writers operate per cell; mask the pieces rather than
            # retaining an unreplaceable multi-cell match.
            for piece in value.split('\t'):
                if piece.strip():
                    add(kind, piece, origin)
            return
        key = folded(value)
        if not 2 <= len(value) <= 500 or key in known or re.fullmatch(r'\[[^\]]+ \d+\]', value):
            return
        if len(entities) >= MAX_ENTITIES:
            raise ValueError('Найдено более 250 000 сущностей; разделите файл.')
        counts[kind] += 1
        known[key] = True
        entities.append(dict(id=str(len(entities) + 1), kind=kind, variants=[value],
                             replacement=f'[{KINDS[kind]} {counts[kind]}]', enabled=True, origin=origin))
    for unit in source.units:
        for kind, label in KINDS.items():
            for number in re.findall(r'\[' + re.escape(label) + r' (\d+)\]', unit):
                counts[kind] = max(counts[kind], int(number))
    # Individual column values are not grouped into a single person's identity.
    for kind, value in source.hints:
        add(kind, value, 'Заголовок колонки')
    ner = segmenter = None
    if use_ner:
        from natasha import Doc, Segmenter, NewsEmbedding, NewsNERTagger
        segmenter, ner = Segmenter(), NewsNERTagger(NewsEmbedding())
    # Bounded chunks, overlapping at boundaries. No language-model request;
    # weights ship in the installed Python packages.
    text = '\n'.join(source.units)
    chunks = range(0, len(text), 6000)
    for index, start in enumerate(chunks, 1):
        part = text[max(0, start - 300):start + 6300]
        progress(f'Проверяю весь файл офлайн: {index} из {len(chunks)} частей…')
        # Row boundaries are semantic: never join the last column heading
        # with a name from the following row into a fictitious person.
        for line in part.splitlines():
            for candidate in automatic_entities(line):
                for value in candidate['variants']:
                    add(candidate['kind'], value, 'Правило')
        # All-uppercase and non-standard surnames, full names on one line.
        for match in re.finditer(r'(?i)\b[а-яё][а-яё-]+[ \t]+[а-яё][а-яё-]+[ \t]+[а-яё][а-яё-]*(?:ович|евич|ич|овна|евна|ична)\b', part):
            if not invalid_person(match.group()):
                add('PERSON', match.group(), 'ФИО')
        for match in re.finditer(r'(?<!\w)\d{11}(?!\w)', part):
            add('ID', match.group(), '11-значный идентификатор')
        for match in re.finditer(r'(?<!\w)(?:\d{3}[- –—]\d{3}[- –—]\d{3}[ –—-]?\d{2}|\d{9}[ -]\d{2}|\d{4}[ ]\d{6})(?!\w)', part):
            add('ID', match.group(), 'СНИЛС / паспорт')
        for match in re.finditer(r'(?<!\w)9\d{9}(?!\w)', part):
            add('PHONE', match.group(), 'Мобильный телефон')
        for match in re.finditer(r'(?i)(?:паспорт|снилс|инн|полис|омс)\s*[:№=]?\s*(\d[\d -]{5,22}\d)', part):
            add('ID', match.group(1), 'Документ')
        if ner:
            doc = Doc(part); doc.segment(segmenter); doc.tag_ner(ner)
            for span in doc.spans:
                kind = {'PER': 'PERSON', 'LOC': 'ADDRESS', 'ORG': 'ORG'}.get(span.type)
                if kind and '\n' not in span.text and '\r' not in span.text and not (kind == 'PERSON' and invalid_person(span.text)):
                    add(kind, span.text, 'Локальная NER')
    return entities


def handle(request, progress):
    deny_network()
    if request['action'] != 'privacy_read' and not re.fullmatch(r'[0-9a-f]{64}', request.get('source_hash', '')):
        raise ValueError('Откройте исходник заново для проверки его целостности.')
    source = Source(request['path'], request.get('source_hash'))
    action = request['action']
    if action == 'privacy_read':
        return {'document': source.document()}
    if action == 'privacy_detect':
        entities = detect(source, request.get('use_model', True), progress)
    else:
        entities = request.get('entities', [])
    matcher = Matcher(entities)
    if action == 'privacy_export':
        result = source.export(matcher, progress)
        # Fail rather than hand over a copy where a selected cross-run or
        # cross-paragraph match could not be removed by the format writer.
        check = Source(request['path'], data=result)
        if matcher.spans('\n'.join(check.units)):
            raise ValueError('В итоговом файле остались выбранные фрагменты. Проверьте пересекающиеся замены; копия не сохранена.')
        return {'data': base64.b64encode(result).decode('ascii')}
    count = sum(len(matcher.spans(unit)) for unit in source.units)
    return dict(text=matcher.replace(source.preview())[0], entities=entities, count=count,
                warnings=source.warnings, checked=source.characters, total=source.characters,
                model_complete=True)
