"""Makes small sample files for the build server to have the app convert: a Word document, a PowerPoint
deck, an Excel workbook and an EPUB. Run with python-docx, python-pptx and openpyxl installed:

    python tools/make_samples.py samples
"""
import os
import struct
import sys
import zipfile
import zlib

out = sys.argv[1] if len(sys.argv) > 1 else 'samples'
os.makedirs(out, exist_ok=True)


def png(path, width=320, height=180):
    """A picture of coloured bands, written without any library."""
    rows = b''
    for y in range(height):
        row = b'\x00'
        for x in range(width):
            band = (x * 6) // width
            row += bytes(((40 + band * 35) % 256, (120 + y) % 256, (200 - band * 20) % 256))
        rows += row

    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF)

    head = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', head) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


picture = os.path.join(out, 'bands.png')
png(picture)

KOREAN = ('경사 하강법은 손실 함수의 기울기를 따라 매개변수를 조금씩 옮겨 가며 최솟값을 찾는 방법이다. '
          '학습률이 너무 크면 발산하고 너무 작으면 수렴이 느리다. ')
ENGLISH = ('Gradient descent moves the parameters a little at a time along the slope of the loss, '
           'looking for its lowest point. Too large a step diverges; too small a step crawls. ')


def word():
    from docx import Document
    from docx.shared import Inches
    doc = Document()
    doc.add_heading('3주차 강의 노트: 최적화', 0)
    for part in range(1, 7):
        doc.add_heading(f'{part}. 경사 하강법의 {part}번째 이야기', level=1)
        for n in range(4):
            doc.add_paragraph(f'({part}-{n + 1}) ' + KOREAN * 2 + ENGLISH * 2)
        if part == 2:
            table = doc.add_table(rows=1, cols=3)
            table.style = 'Table Grid'
            for cell, text in zip(table.rows[0].cells, ('방법', '학습률', '비고')):
                cell.text = text
            for row in (('SGD', '0.1', '기본'), ('Momentum', '0.05', '관성'), ('Adam', '0.001', '적응형')):
                for cell, text in zip(table.add_row().cells, row):
                    cell.text = text
        if part == 3:
            doc.add_picture(picture, width=Inches(4))
            doc.add_paragraph('그림 1. 띠 무늬')
        if part == 4:
            for item in ('첫째 항목', '둘째 항목', '셋째 항목'):
                doc.add_paragraph(item, style='List Bullet')
    doc.save(os.path.join(out, 'word.docx'))


def slides():
    from pptx import Presentation
    from pptx.util import Inches, Pt
    deck = Presentation()
    deck.slide_width = Inches(13.333)
    deck.slide_height = Inches(7.5)
    first = deck.slides.add_slide(deck.slide_layouts[0])
    first.shapes.title.text = '최적화 개요'
    first.placeholders[1].text = '3주차 · 경사 하강법'
    for n in range(1, 5):
        slide = deck.slides.add_slide(deck.slide_layouts[1])
        slide.shapes.title.text = f'슬라이드 {n + 1}: 학습률'
        body = slide.placeholders[1].text_frame
        body.text = '학습률이 크면 발산한다'
        for line in ('학습률이 작으면 느리다', 'Momentum은 관성을 더한다', f'Adam은 적응형이다 ({n})'):
            body.add_paragraph().text = line
        if n == 2:
            slide.shapes.add_picture(picture, Inches(8), Inches(3), width=Inches(4))
        if n == 3:
            box = slide.shapes.add_textbox(Inches(7), Inches(5.5), Inches(5), Inches(1))
            box.text_frame.text = '오른쪽 아래 글상자'
            box.text_frame.paragraphs[0].runs[0].font.size = Pt(28)
    deck.save(os.path.join(out, 'slides.pptx'))


def sheet():
    from openpyxl import Workbook
    book = Workbook()
    first = book.active
    first.title = '성적'
    first.append(['학번', '이름', '중간', '기말', '과제', '출석', '합계', '등급'])
    for n in range(1, 71):
        first.append([2026000 + n, f'학생{n}', 50 + n % 40, 45 + (n * 7) % 50, 80 + n % 20, 10, f'=C{n + 1}+D{n + 1}+E{n + 1}+F{n + 1}', 'A' if n % 3 == 0 else 'B'])
    second = book.create_sheet('넓은 표')
    second.append([f'열 {c}' for c in range(1, 19)])
    for r in range(1, 13):
        second.append([r * c for c in range(1, 19)])
    book.save(os.path.join(out, 'sheet.xlsx'))


def epub():
    path = os.path.join(out, 'book.epub')
    chapters = []
    for n in range(1, 4):
        body = ''.join(f'<p>({n}-{k}) {KOREAN * 3}{ENGLISH * 2}</p>' for k in range(1, 14))
        extra = '<p><img src="../images/bands.png" alt="bands"/></p>' if n == 2 else ''
        link = '<p><a href="ch1.xhtml">첫 장으로</a></p>' if n == 3 else ''
        chapters.append(
            '<?xml version="1.0" encoding="utf-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml"><head>'
            f'<title>{n}장</title><link rel="stylesheet" type="text/css" href="../style.css"/></head><body>'
            f'<h1>{n}장. 경사 하강법 이야기 {n}</h1>{extra}{body}{link}</body></html>')
    manifest = ''.join(f'<item id="c{n}" href="text/ch{n}.xhtml" media-type="application/xhtml+xml"/>' for n in range(1, 4))
    spine = ''.join(f'<itemref idref="c{n}"/>' for n in range(1, 4))
    package = (
        '<?xml version="1.0" encoding="utf-8"?>\n<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">sample-book</dc:identifier>'
        '<dc:title>견본 책</dc:title><dc:language>ko</dc:language></metadata>'
        f'<manifest>{manifest}<item id="css" href="style.css" media-type="text/css"/>'
        '<item id="img" href="images/bands.png" media-type="image/png"/></manifest>'
        f'<spine>{spine}</spine></package>')
    container = (
        '<?xml version="1.0"?>\n<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
        z.writestr('META-INF/container.xml', container, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/content.opf', package, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr('OEBPS/style.css', 'h1{font-size:1.5em;margin:1em 0;} p{text-indent:1em;margin:0 0 0.6em;}', compress_type=zipfile.ZIP_DEFLATED)
        for n, text in enumerate(chapters, 1):
            z.writestr(f'OEBPS/text/ch{n}.xhtml', text, compress_type=zipfile.ZIP_DEFLATED)
        z.write(picture, 'OEBPS/images/bands.png', compress_type=zipfile.ZIP_DEFLATED)


for make in (epub, word, slides, sheet):
    try:
        make()
        print('made', make.__name__)
    except Exception as error:  # a sample that cannot be made is not worth losing the others for
        print('could not make', make.__name__, error)
os.remove(picture)
