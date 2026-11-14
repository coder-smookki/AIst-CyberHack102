"""Отчёт об осмотре в формате Excel и общие для обоих форматов текстовые представления значений.

Книга состоит из листов: осмотр, оценки по узлам (три оценки в отдельных столбцах), находки, основания,
проверки и работы, регламент обслуживания. Текст из комментариев пишется как текст, а не как формула.
"""
import io
from datetime import date, datetime

from openpyxl import Workbook
from openpyxl.cell.cell import ILLEGAL_CHARACTERS_RE
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

BRAND = "135AA6"
TEXT = "313132"
NOT_APPLICABLE = "Не применяется"
STATUS_COLORS = {"ok": "2E7D4F", "check": "B7791F", "defect": "C53030", "unknown": "6B7280"}
RESOURCE_STATES = {
    "ok": "в норме",
    "approaching": "срок приближается",
    "due": "срок наступил",
    "insufficient_data": "недостаточно данных",
}
ESTIMATES_NOTE = ("Три оценки приводятся раздельно и не сводятся в одну: нормативный срок службы - по документам, "
                  "расчётный остаточный ресурс - по наработке и календарному сроку, фактическое состояние - "
                  "по камере, датчикам и отметкам инженера.")
SYSTEM_NOTE = "Статусы и оценки в отчёте - подсказка системы; оценка ресурса расчётная."
MOMENT_FORMAT = "DD.MM.YYYY HH:MM"


def moment_text(value: str | None) -> str:
    """Записывает момент времени из ISO-строки в виде ДД.ММ.ГГГГ ЧЧ:ММ; пустое значение - прочерк."""
    return datetime.fromisoformat(value).strftime("%d.%m.%Y %H:%M") if value else "-"


def date_text(value: str | None) -> str:
    """Записывает дату из ISO-строки в виде ДД.ММ.ГГГГ; пустое значение - прочерк."""
    return date.fromisoformat(value[:10]).strftime("%d.%m.%Y") if value else "-"


def number_text(value, digits: int = 0) -> str:
    """Записывает число по-русски: разряды через неразрывный пробел, дробная часть через запятую."""
    if value is None:
        return "-"
    return f"{value:,.{digits}f}".replace(",", "\u00a0").replace(".", ",")


def duration_text(seconds: int | None) -> str:
    """Записывает длительность осмотра в часах, минутах и секундах."""
    if seconds is None:
        return "-"
    hours, rest = divmod(int(seconds), 3600)
    minutes, tail = divmod(rest, 60)
    if hours:
        return f"{hours} ч {minutes:02d} мин"
    if minutes:
        return f"{minutes} мин {tail:02d} с"
    return f"{tail} с"


def normative_text(row: dict) -> str:
    """Нормативный срок службы узла вместе с документом-источником."""
    normative = row.get("normative")
    if not normative:
        return NOT_APPLICABLE
    source = normative.get("source")
    return f"{normative['text']}. Источник: {source}" if source else normative["text"]


def calculated_text(row: dict) -> str:
    """Расчётный остаточный ресурс узла или явное «недостаточно данных»."""
    calculated = row.get("calculated")
    return calculated["text"] if calculated else NOT_APPLICABLE


def actual_title(row: dict, ok_note: str) -> str:
    """Категория фактического состояния; к «видимых проблем не обнаружено» всегда добавляется оговорка."""
    actual = row["actual"]
    return f"{actual['title']} ({ok_note})" if actual["status"] == "ok" else actual["title"]


def coverage_text(coverage: dict | None) -> str:
    """Полнота обхода одной строкой."""
    if not coverage:
        return "Не сохранялась"
    return (f"осмотрено {coverage['inspected']} из {coverage['total']} узлов ({coverage['percent']} %), "
            f"кадров обработано: {coverage['frames']}")


def coverage_note(coverage: dict | None, code: str) -> str:
    """Как узел осмотрен при обходе: камерой, отметкой инженера или не осмотрен."""
    node = ((coverage or {}).get("nodes") or {}).get(code)
    if not node:
        return "Сведений об обходе нет"
    if node.get("manual"):
        return "Отмечен инженером вручную"
    if node.get("inspected"):
        return f"Осмотрен камерой, кадров: {node.get('seen', 0)}"
    if not node.get("trackable"):
        return "Камерой не распознаётся"
    if node.get("seen"):
        return f"Осмотр камерой не завершён, кадров: {node['seen']}"
    return "Камерой не осмотрен"


def ok_tail(data: dict) -> str:
    """Оговорка к зелёному статусу без повторения названия статуса."""
    return data["ok_note"].split("» ", 1)[-1]


def source_title(source: str | None) -> str:
    """Название источника основания по-русски."""
    return {"camera": "Камера", "sensor": "Датчики", "resource": "Ресурс", "manual": "Инженер"}.get(source, source or "-")


def severity_text(view: dict) -> str:
    """Критичность находки числом и словами."""
    if not view.get("severity"):
        return "-"
    return f"{view['severity']} - {view['severity_title']}" if view.get("severity_title") else str(view["severity"])


def summary_rows(data: dict) -> list[tuple[str, str]]:
    """Строки «название - значение» об оборудовании и осмотре: общая часть отчётов PDF и Excel."""
    equipment, inspection = data["equipment"], data["inspection"]
    user = inspection.get("user") or {}
    return [
        ("Оборудование", f"{equipment['name']} ({equipment['id']})"),
        ("Модель", equipment["model"]),
        ("Серийный номер", equipment["serial"]),
        ("Производитель", equipment.get("manufacturer") or "-"),
        ("Место установки", equipment["location"]),
        ("Режим", equipment["mode_title"]),
        ("Наработка агрегата", f"{number_text(equipment['run_hours'])} ч"),
        ("Ввод в эксплуатацию", date_text(equipment.get("commissioned"))),
        ("Осмотр провёл", f"{user.get('name', '-')}, {user.get('role_title', '-')}"),
        ("Начало осмотра", moment_text(inspection["started_at"])),
        ("Окончание осмотра", moment_text(inspection["finished_at"])),
        ("Длительность", duration_text(inspection["duration_s"])),
        ("Состояние осмотра", inspection["status_title"]),
        ("Полнота обхода", coverage_text(data.get("coverage"))),
        ("Показания датчиков на момент", moment_text(data.get("telemetry_at")) if data.get("telemetry_at")
         else "телеметрии по агрегату нет"),
        ("Оценки рассчитаны на дату", date_text(data.get("estimates_on"))),
        ("Отчёт сформирован", moment_text(data["generated_at"])),
    ]


def _clean(value):
    """Готовит значение к записи в ячейку: убирает недопустимые управляющие символы из текста."""
    if isinstance(value, str):
        return ILLEGAL_CHARACTERS_RE.sub("", value)
    return value


def _put(sheet, row: int, column: int, value, bold: bool = False, color: str = TEXT, moment: bool = False):
    """Записывает значение в ячейку; строка, начинающаяся со знака формулы, остаётся текстом."""
    cell = sheet.cell(row=row, column=column, value=_clean(value))
    if isinstance(value, str):
        cell.data_type = "s"
    if moment:
        cell.number_format = MOMENT_FORMAT
    cell.font = Font(name="Arial", size=10, bold=bold, color=color)
    cell.alignment = Alignment(wrap_text=True, vertical="top")
    return cell


def _table(sheet, headers: list[tuple[str, int]], rows: list[list], first_row: int = 1) -> int:
    """Пишет таблицу с шапкой фирменного цвета и возвращает номер строки после неё."""
    for column, (title, width) in enumerate(headers, start=1):
        cell = _put(sheet, first_row, column, title, bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", start_color=BRAND)
        sheet.column_dimensions[get_column_letter(column)].width = width
    for offset, values in enumerate(rows, start=1):
        for column, value in enumerate(values, start=1):
            _put(sheet, first_row + offset, column, value, moment=isinstance(value, datetime))
    sheet.freeze_panes = sheet.cell(row=first_row + 1, column=1)
    return first_row + len(rows) + 1


def _moment(value: str | None):
    """Превращает ISO-строку во время для ячейки; пустое значение остаётся пустым."""
    return datetime.fromisoformat(value) if value else None


def _summary_sheet(sheet, data: dict) -> None:
    """Лист «Осмотр»: оборудование, кто и когда, итог и строка о том, кто принимает решение."""
    sheet.title = "Осмотр"
    sheet.column_dimensions["A"].width = 34
    sheet.column_dimensions["B"].width = 90
    _put(sheet, 1, 1, f"Отчёт об осмотре оборудования № {data['inspection']['id']}", bold=True, color=BRAND).font = Font(
        name="Arial", size=14, bold=True, color=BRAND)
    row = 3
    for label, value in summary_rows(data):
        _put(sheet, row, 1, label, bold=True)
        _put(sheet, row, 2, value)
        row += 1
    overall = data["overall"]
    _put(sheet, row, 1, "Итог осмотра", bold=True)
    title = f"{overall['title']} ({ok_tail(data)})" if overall["status"] == "ok" else overall["title"]
    _put(sheet, row, 2, title, bold=True, color=STATUS_COLORS[overall["status"]])
    _put(sheet, row + 2, 1, data["decision"], bold=True, color=BRAND)
    _put(sheet, row + 2, 2, SYSTEM_NOTE)
    _put(sheet, row + 3, 2, data["ok_note"])
    _put(sheet, row + 4, 2, data["basis"])


def _nodes_sheet(sheet, data: dict) -> None:
    """Лист «Оценки по узлам»: норматив, расчётный остаток и фактическое состояние в отдельных столбцах."""
    headers = [("Узел", 28), ("Код узла", 16), ("Нормативный срок службы", 44), ("Расчётный остаточный ресурс", 52),
               ("Состояние расчёта", 20), ("Израсходовано, %", 16), ("Остаток, ч", 12), ("Остаток, сут", 12),
               ("Прогноз даты", 14), ("Фактическое состояние", 40), ("Причины", 60), ("Осмотр при обходе", 30)]
    rows = []
    for node in data["nodes"]:
        calculated = node.get("calculated") or {}
        rows.append([
            node["name"], node["code"], normative_text(node), calculated_text(node),
            RESOURCE_STATES.get(calculated.get("state"), NOT_APPLICABLE), calculated.get("used_percent"),
            calculated.get("remaining_hours"), calculated.get("remaining_days"),
            date_text(calculated.get("forecast_date")), actual_title(node, ok_tail(data)),
            "; ".join(node["actual"]["reasons"]), coverage_note(data.get("coverage"), node["code"]),
        ])
    last = _table(sheet, headers, rows)
    for offset, node in enumerate(data["nodes"], start=2):
        sheet.cell(row=offset, column=10).font = Font(name="Arial", size=10, bold=True,
                                                      color=STATUS_COLORS[node["actual"]["status"]])
    _put(sheet, last + 1, 1, ESTIMATES_NOTE)
    _put(sheet, last + 2, 1, data["basis"])
    _put(sheet, last + 3, 1, data["decision"], bold=True, color=BRAND)


def _findings_sheets(findings_sheet, evidence_sheet, data: dict) -> None:
    """Листы «Находки» и «Основания»: каждая находка с диагнозом и рекомендацией, каждое условие - отдельной строкой."""
    headers = [("№", 6), ("Время", 17), ("Узел", 26), ("Статус", 30), ("Критичность", 26), ("Находка", 36),
               ("Диагноз", 60), ("Рекомендация", 60), ("Источник", 12), ("Правило", 10), ("Уверенность", 13),
               ("Осталось проверить", 44), ("Комментарий", 40), ("Устранение", 14), ("Снимок", 10)]
    rows, evidence = [], []
    for view in data["findings"]:
        rows.append([
            view["id"], _moment(view["created_at"]), view["node_name"], view["status_title"], severity_text(view),
            view["title"], view["diagnosis"] or "-", view["recommendation"] or "-", view["source_title"],
            view["rule_id"] or "-", view["confidence"], "; ".join(view["missing"]) or "-", view["comment"] or "-",
            view["state_title"], "есть" if view["has_photo"] else "нет",
        ])
        for line in view["evidence"]:
            evidence.append([view["id"], view["title"], source_title(line.get("source")), line.get("what"),
                             line.get("value"), line.get("threshold") or "-",
                             "выполнено" if line.get("met") else "не выполнено"])
    last = _table(findings_sheet, headers, rows)
    for offset, view in enumerate(data["findings"], start=2):
        findings_sheet.cell(row=offset, column=4).font = Font(name="Arial", size=10, bold=True,
                                                              color=STATUS_COLORS.get(view["status"], TEXT))
    if not rows:
        _put(findings_sheet, last, 1, "Замечаний и дефектов не зафиксировано")
        last += 1
    _put(findings_sheet, last + 1, 1, data["decision"], bold=True, color=BRAND)
    _table(evidence_sheet, [("№ находки", 11), ("Находка", 36), ("Источник", 12), ("Условие", 52), ("Значение", 40),
                            ("Уставка", 22), ("Итог", 16)], evidence)


def _works_sheet(sheet, data: dict) -> None:
    """Лист «Проверки и работы»: узлы, проверенные без замечаний, обслуживание и замены в ходе осмотра."""
    rows = [[_moment(view["created_at"]), view["node_name"], view["title"], view["comment"] or "-"]
            for view in [*data["checked"], *data["works"]]]
    _table(sheet, [("Время", 17), ("Узел", 30), ("Запись", 46), ("Комментарий", 60)], rows)


def _maintenance_sheet(sheet, data: dict) -> None:
    """Лист «Регламент»: наработка после последнего обслуживания против интервала."""
    rows = [[entry.get("name"), entry.get("work") or "-", entry.get("interval_hours"), entry.get("since_hours"),
             entry.get("used_percent"), entry.get("remaining_hours"), RESOURCE_STATES.get(entry.get("state"), "-")]
            for entry in data["maintenance"]]
    _table(sheet, [("Вид обслуживания", 20), ("Состав работ", 70), ("Интервал, ч", 13), ("После последнего, ч", 20),
                   ("Израсходовано, %", 17), ("Остаток, ч", 12), ("Состояние", 22)], rows)


def build_xlsx(data: dict) -> bytes:
    """Собирает книгу Excel с отчётом об осмотре и возвращает её содержимое."""
    book = Workbook()
    _summary_sheet(book.active, data)
    _nodes_sheet(book.create_sheet("Оценки по узлам"), data)
    _findings_sheets(book.create_sheet("Находки"), book.create_sheet("Основания"), data)
    _works_sheet(book.create_sheet("Проверки и работы"), data)
    if data["maintenance"]:
        _maintenance_sheet(book.create_sheet("Регламент"), data)
    book.properties.title = f"Отчёт об осмотре № {data['inspection']['id']}"
    book.properties.creator = "КСТ Визор"
    output = io.BytesIO()
    book.save(output)
    return output.getvalue()
