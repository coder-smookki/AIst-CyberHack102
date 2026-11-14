"""Отчёт об осмотре в формате PDF: оборудование, кто и когда, три оценки по узлам, находки с основаниями.

Шрифт с кириллицей встраивается в файл: Arial из системной папки, а если его нет - DejaVu Sans из папок
поиска шрифтов. Без такого шрифта отчёт не формируется: русский текст превратился бы в пустые квадраты.
"""
import io
from functools import lru_cache
from pathlib import Path
from xml.sax.saxutils import escape

from reportlab import rl_config
from reportlab.lib.colors import HexColor, white
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFError, TTFont
from reportlab.platypus import Image, KeepTogether, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

from server.reports.xlsx import (
    BRAND,
    ESTIMATES_NOTE,
    RESOURCE_STATES,
    STATUS_COLORS,
    SYSTEM_NOTE,
    TEXT,
    actual_title,
    calculated_text,
    coverage_note,
    moment_text,
    normative_text,
    number_text,
    ok_tail,
    severity_text,
    source_title,
    summary_rows,
)

FONT = "KstSans"
FONT_BOLD = "KstSans-Bold"
SYSTEM_FONTS = Path("/System/Library/Fonts/Supplemental")
FONT_FILES = (("Arial.ttf", "Arial Bold.ttf"), ("DejaVuSans.ttf", "DejaVuSans-Bold.ttf"))
EXTRA_FONT_DIRS = ("/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/dejavu", "/usr/share/fonts/TTF")
CYRILLIC_SAMPLE = "Решение принимает инженер №"
MARGIN = 16 * mm
PAGE_WIDTH = A4[0] - 2 * MARGIN
PHOTO_WIDTH = 80 * mm
PHOTO_HEIGHT = 60 * mm
GRID = HexColor("#C9CDD6")
STRIPE = HexColor("#F4F5F8")
NO_FINDINGS = "Замечаний и дефектов не зафиксировано"
CELL_LIMIT = 1200
NO_FONT = ("Не найден шрифт с кириллицей (Arial или DejaVu Sans): отчёт PDF сформировать нельзя. "
           "Установите шрифт DejaVu Sans или сформируйте отчёт Excel")


def _font_dirs() -> list[Path]:
    """Папки, где ищутся файлы шрифтов: системная папка, папки поиска reportlab и обычные места DejaVu."""
    return [SYSTEM_FONTS, *(Path(folder) for folder in rl_config.TTFSearchPath), *(Path(folder) for folder in EXTRA_FONT_DIRS)]


def _registered(regular: Path, bold: Path | None) -> bool:
    """Встраивает пару шрифтов и проверяет, что в обычном начертании есть кириллица и знак номера."""
    try:
        face = TTFont(FONT, str(regular))
        if any(ord(symbol) not in face.face.charToGlyph for symbol in CYRILLIC_SAMPLE if symbol != " "):
            return False
        heavy = TTFont(FONT_BOLD, str(bold if bold else regular))
    except (TTFError, OSError):
        return False
    pdfmetrics.registerFont(face)
    pdfmetrics.registerFont(heavy)
    pdfmetrics.registerFontFamily(FONT, normal=FONT, bold=FONT_BOLD, italic=FONT, boldItalic=FONT_BOLD)
    return True


@lru_cache
def fonts() -> tuple[str, str]:
    """Находит и встраивает шрифт с кириллицей; возвращает названия обычного и полужирного начертаний.

    Если подходящего файла шрифта нет, сообщает об этом ошибкой с понятным текстом.
    """
    for regular_name, bold_name in FONT_FILES:
        for folder in _font_dirs():
            regular, bold = folder / regular_name, folder / bold_name
            if regular.is_file() and _registered(regular, bold if bold.is_file() else None):
                return FONT, FONT_BOLD
    raise RuntimeError(NO_FONT)


def _styles() -> dict[str, ParagraphStyle]:
    """Стили абзацев отчёта: все на встроенном шрифте с кириллицей."""
    regular, bold = fonts()
    text = HexColor(f"#{TEXT}")
    brand = HexColor(f"#{BRAND}")
    base = ParagraphStyle("base", fontName=regular, fontSize=9, leading=12, textColor=text, splitLongWords=1)
    return {
        "base": base,
        "small": ParagraphStyle("small", parent=base, fontSize=8, leading=10.5),
        "cell": ParagraphStyle("cell", parent=base, fontSize=8, leading=10),
        "head": ParagraphStyle("head", parent=base, fontName=bold, fontSize=8, leading=10, textColor=white),
        "label": ParagraphStyle("label", parent=base, fontName=bold, fontSize=8.5, leading=11),
        "title": ParagraphStyle("title", parent=base, fontName=bold, fontSize=16, leading=20, textColor=brand, spaceAfter=6),
        "section": ParagraphStyle("section", parent=base, fontName=bold, fontSize=12, leading=15, textColor=brand,
                                  spaceBefore=12, spaceAfter=5),
        "finding": ParagraphStyle("finding", parent=base, fontName=bold, fontSize=10, leading=13, spaceBefore=8,
                                  spaceAfter=2),
        "decision": ParagraphStyle("decision", parent=base, fontName=bold, fontSize=13, leading=16, textColor=brand,
                                   spaceBefore=14, spaceAfter=4),
    }


def _markup(value) -> str:
    """Готовит произвольный текст к вставке в абзац: служебные знаки разметки экранируются, переводы строк сохраняются."""
    return escape("-" if value is None or value == "" else str(value)).replace("\n", "<br/>")


def _paragraph(value, style: ParagraphStyle) -> Paragraph:
    """Абзац из произвольного текста без разметки."""
    return Paragraph(_markup(value), style)


def _labelled(label: str, value, style: ParagraphStyle) -> Paragraph:
    """Абзац вида «Название: значение» с полужирным названием."""
    return Paragraph(f"<b>{_markup(label)}:</b> {_markup(value)}", style)


def _coloured(value: str, status: str) -> str:
    """Разметка текста статуса его цветом: зелёный, жёлтый, красный или серый."""
    return f'<font color="#{STATUS_COLORS.get(status, TEXT)}"><b>{_markup(value)}</b></font>'


def _cell(value, style: ParagraphStyle) -> Paragraph:
    """Ячейка таблицы: текст в одну строку с переносом по словам, слишком длинный текст обрезается.

    Строка таблицы не делится между страницами, поэтому ячейка не должна вырасти выше страницы.
    """
    text = "-" if value is None or value == "" else " ".join(str(value).split())
    if len(text) > CELL_LIMIT:
        text = text[:CELL_LIMIT].rstrip() + "... (полный текст - в отчёте Excel)"
    return _paragraph(text, style)


def _table(headers: list[str], rows: list[list], widths: list[float], styles: dict, striped: bool = True) -> Table:
    """Таблица с шапкой фирменного цвета; шапка повторяется на каждой странице, строки переносятся целиком."""
    data = [[Paragraph(_markup(title), styles["head"]) for title in headers]]
    for row in rows:
        data.append([cell if isinstance(cell, Paragraph) else _cell(cell, styles["cell"]) for cell in row])
    table = Table(data, colWidths=widths, repeatRows=1)
    commands = [
        ("BACKGROUND", (0, 0), (-1, 0), HexColor(f"#{BRAND}")),
        ("GRID", (0, 0), (-1, -1), 0.4, GRID),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 4), ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 3), ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]
    if striped:
        commands.append(("ROWBACKGROUNDS", (0, 1), (-1, -1), [white, STRIPE]))
    table.setStyle(TableStyle(commands))
    return table


def _summary(data: dict, styles: dict) -> list:
    """Шапка отчёта: оборудование, кто и когда провёл осмотр, итоговый статус."""
    rows = [[Paragraph(_markup(label), styles["label"]), _paragraph(value, styles["base"])]
            for label, value in summary_rows(data)]
    table = Table(rows, colWidths=[48 * mm, PAGE_WIDTH - 48 * mm])
    table.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"), ("LINEBELOW", (0, 0), (-1, -1), 0.3, GRID),
        ("LEFTPADDING", (0, 0), (-1, -1), 2), ("TOPPADDING", (0, 0), (-1, -1), 2), ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    overall = data["overall"]
    verdict = f"<b>Итог осмотра:</b> {_coloured(overall['title'], overall['status'])}"
    if overall["status"] == "ok":
        verdict += f" ({_markup(ok_tail(data))})"
    return [
        Paragraph(f"Отчёт об осмотре оборудования № {data['inspection']['id']}", styles["title"]),
        table, Spacer(1, 6), Paragraph(verdict, styles["base"]),
    ]


def _nodes(data: dict, styles: dict) -> list:
    """Раздел «Оценки по узлам»: норматив, расчётный остаток и фактическое состояние - в трёх отдельных столбцах."""
    rows = []
    for node in data["nodes"]:
        actual = node["actual"]
        state = _coloured(actual_title(node, ok_tail(data)), actual["status"])
        reasons = "<br/>".join(f"- {_markup(reason)}" for reason in actual["reasons"])
        name = f"<b>{_markup(node['name'])}</b><br/>{_markup(coverage_note(data.get('coverage'), node['code']))}"
        rows.append([
            Paragraph(name, styles["cell"]), normative_text(node), calculated_text(node),
            Paragraph(f"{state}<br/>{reasons}" if reasons else state, styles["cell"]),
        ])
    headers = ["Узел и осмотр камерой", "1. Нормативный срок службы", "2. Расчётный остаточный ресурс",
               "3. Фактическое состояние"]
    return [
        Paragraph("Оценки по узлам", styles["section"]),
        _paragraph(ESTIMATES_NOTE, styles["small"]), Spacer(1, 4),
        _table(headers, rows, [34 * mm, 40 * mm, 48 * mm, PAGE_WIDTH - 122 * mm], styles),
        Spacer(1, 3), _paragraph(data["basis"], styles["small"]),
    ]


def _photo(path: str | None, styles: dict) -> list:
    """Стоп-кадр камеры к находке, вписанный в отведённое место; нечитаемый файл пропускается."""
    if not path:
        return []
    try:
        width, height = ImageReader(path).getSize()
    except (OSError, ValueError):
        return []
    scale = min(PHOTO_WIDTH / width, PHOTO_HEIGHT / height)
    picture = Image(path, width=width * scale, height=height * scale)
    picture.hAlign = "LEFT"
    return [Spacer(1, 3), KeepTogether([_paragraph("Стоп-кадр камеры:", styles["label"]), Spacer(1, 2), picture])]


def _finding(view: dict, styles: dict) -> list:
    """Одна находка: статус, диагноз, рекомендация, основания по условиям, что осталось проверить, снимок."""
    confidence = "-" if view["confidence"] is None else number_text(view["confidence"], 2)
    origin = "записано автоматически по результатам диагностики" if view["automatic"] else "зафиксировано инженером"
    facts = (f"Узел: {view['node_name']}. Критичность: {severity_text(view)}. Источник: {view['source_title']}. "
             f"Правило: {view['rule_id'] or '-'}. Уверенность: {confidence}. Время: {moment_text(view['created_at'])}. "
             f"Устранение: {view['state_title']}. Запись: {origin}.")
    head = [
        Paragraph(f"№ {view['id']}. {_markup(view['title'])} - {_coloured(view['status_title'], view['status'])}",
                  styles["finding"]),
        _paragraph(facts, styles["small"]),
    ]
    body = [
        _labelled("Диагноз", view["diagnosis"], styles["base"]),
        _labelled("Рекомендация", view["recommendation"], styles["base"]),
    ]
    if view["evidence"]:
        rows = [[source_title(line.get("source")), line.get("what"), line.get("value"), line.get("threshold") or "-",
                 "выполнено" if line.get("met") else "не выполнено"] for line in view["evidence"]]
        body += [Spacer(1, 3), _paragraph("Основания:", styles["label"]), Spacer(1, 2),
                 _table(["Источник", "Условие", "Значение", "Уставка", "Итог"], rows,
                        [20 * mm, 62 * mm, 44 * mm, 28 * mm, PAGE_WIDTH - 154 * mm], styles, striped=False)]
    if view["missing"]:
        body.append(_labelled("Осталось проверить", "; ".join(view["missing"]), styles["base"]))
    if view["comment"]:
        body.append(_labelled("Комментарий", view["comment"], styles["base"]))
    return [KeepTogether(head), *body, *_photo(view.get("photo_file"), styles)]


def _findings(data: dict, styles: dict) -> list:
    """Раздел «Находки»: каждая находка с основаниями и рекомендацией."""
    story = [Paragraph("Находки", styles["section"])]
    if not data["findings"]:
        story.append(_paragraph(NO_FINDINGS, styles["base"]))
    for view in data["findings"]:
        story.extend(_finding(view, styles))
    return story


def _works(data: dict, styles: dict) -> list:
    """Раздел «Проверки и работы»: узлы, проверенные без замечаний, обслуживание и замены в ходе осмотра."""
    views = [*data["checked"], *data["works"]]
    if not views:
        return []
    rows = [[moment_text(view["created_at"]), view["node_name"], view["title"], view["comment"] or "-"] for view in views]
    return [Paragraph("Проверки и работы", styles["section"]),
            _table(["Время", "Узел", "Запись", "Комментарий"], rows,
                   [28 * mm, 42 * mm, 50 * mm, PAGE_WIDTH - 120 * mm], styles)]


def _maintenance(data: dict, styles: dict) -> list:
    """Раздел «Регламент обслуживания»: наработка после последнего обслуживания против интервала."""
    if not data["maintenance"]:
        return []
    rows = [[entry.get("name"), entry.get("work") or "-", number_text(entry.get("interval_hours")),
             number_text(entry.get("since_hours")), number_text(entry.get("used_percent"), 1),
             number_text(entry.get("remaining_hours")), RESOURCE_STATES.get(entry.get("state"), "-")]
            for entry in data["maintenance"]]
    headers = ["Вид", "Состав работ", "Интервал, ч", "После ТО, ч", "Израсходовано, %", "Остаток, ч", "Состояние"]
    return [Paragraph("Регламент обслуживания", styles["section"]),
            _table(headers, rows, [15 * mm, PAGE_WIDTH - 133 * mm, 20 * mm, 22 * mm, 30 * mm, 19 * mm, 27 * mm], styles)]


def _closing(data: dict, styles: dict) -> list:
    """Заключительная часть: кто принимает решение и оговорки к статусам."""
    return [KeepTogether([
        Paragraph(_markup(data["decision"]), styles["decision"]),
        _paragraph(SYSTEM_NOTE, styles["small"]),
        _paragraph(data["ok_note"], styles["small"]),
    ])]


def build_story(data: dict) -> list:
    """Собирает содержимое отчёта по разделам в порядке их появления на страницах."""
    styles = _styles()
    return [*_summary(data, styles), *_nodes(data, styles), *_findings(data, styles), *_works(data, styles),
            *_maintenance(data, styles), *_closing(data, styles)]


def build_pdf(data: dict) -> bytes:
    """Собирает отчёт об осмотре в формате PDF со встроенным шрифтом и возвращает содержимое файла."""
    regular, _ = fonts()
    number = data["inspection"]["id"]
    footer = f"КСТ Визор - отчёт об осмотре № {number} - {data['equipment']['name']}"

    def decorate(canvas, document) -> None:
        """Рисует внизу страницы название отчёта и номер страницы."""
        canvas.saveState()
        canvas.setFont(regular, 7.5)
        canvas.setFillColor(HexColor("#6B7280"))
        canvas.drawString(MARGIN, 9 * mm, footer[:110])
        canvas.drawRightString(A4[0] - MARGIN, 9 * mm, f"Страница {document.page}")
        canvas.restoreState()

    output = io.BytesIO()
    document = SimpleDocTemplate(output, pagesize=A4, leftMargin=MARGIN, rightMargin=MARGIN, topMargin=MARGIN,
                                 bottomMargin=MARGIN, title=f"Отчёт об осмотре № {number}", author="КСТ Визор",
                                 subject=data["equipment"]["name"])
    document.build(build_story(data), onFirstPage=decorate, onLaterPages=decorate)
    return output.getvalue()
