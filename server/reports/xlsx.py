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
STATUS_COLORS = {"ok": "2E7D4F", "check": "B7791F", "defect": "C53030", "unknown": "6B7280", "incomplete": "6B7280"}
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
LEVEL_TITLES = {"ok": "в норме", "warn": "предупреждение", "alarm": "тревога"}
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


def uninspected_text(data: dict) -> str:
    """Перечень узлов, оставшихся без осмотра, через запятую; пустая строка, если таких нет."""
    return ", ".join(node["name"] for node in data.get("uninspected") or ())


def verdict_text(data: dict) -> str:
    """Текст итога осмотра для отчётов: оговорка к «видимых проблем не обнаружено», список неосмотренных узлов."""
    overall = data["overall"]
    if overall["status"] == "ok":
        return f"{overall['title']} ({ok_tail(data)})"
    if overall["status"] == "incomplete" and uninspected_text(data):
        return f"{overall['title']}: не осмотрены - {uninspected_text(data)}"
    return overall["title"]


def models_text(data: dict) -> str:
    """Отпечаток набора моделей: каким набором получены находки осмотра и какой работает сейчас."""
    models = data.get("models") or {}
    current, found = models.get("current"), list(models.get("findings") or [])
    if not current and not found:
        return "-"
    if not found or found == [current]:
        return f"{current or found[0]}" + ("" if found else " (находок с отпечатком нет, указан текущий)")
    return f"в находках {', '.join(found)}; сейчас {current}"


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
        ("Опознание агрегата", (data.get("identified") or {}).get("title") or "Не указано"),
        ("Режим", equipment["mode_title"]),
        ("Наработка агрегата", f"{number_text(equipment['run_hours'])} ч"),
        ("Ввод в эксплуатацию", date_text(equipment.get("commissioned"))),
        ("Осмотр провёл", f"{user.get('name', '-')}, {user.get('role_title', '-')}"),
        ("Начало осмотра", moment_text(inspection["started_at"])),
        ("Окончание осмотра", moment_text(inspection["finished_at"])),
        ("Длительность", duration_text(inspection["duration_s"])),
        ("Состояние осмотра", inspection["status_title"]),
        ("Полнота обхода", coverage_text(data.get("coverage"))),
        *([("Неосмотренные узлы", uninspected_text(data))] if uninspected_text(data) else []),
        ("Показания датчиков на момент", moment_text(data.get("telemetry_at")) if data.get("telemetry_at")
         else "телеметрии по агрегату нет"),
        ("Оценки рассчитаны на дату", date_text(data.get("estimates_on"))),
        ("Отчёт сформирован", moment_text(data["generated_at"])),
        ("Отпечаток набора моделей", models_text(data)),
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
    _put(sheet, row, 2, verdict_text(data), bold=True, color=STATUS_COLORS[overall["status"]])
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


def rejected_rows(data: dict) -> list[list]:
    """Строки списка «Отклонено инженером»: номер, узел, находка, кто и когда отклонил, причина."""
    rows = []
    for view in data.get("rejected") or []:
        who = (view.get("rejected_by") or {}).get("name") or "-"
        rows.append([view["id"], view["node_name"], view["title"], who, moment_text(view.get("rejected_at")),
                     view.get("reject_reason") or "-"])
    return rows


def sound_rows(record: dict) -> list[tuple[str, str]]:
    """Показатели записи звука строками «название - значение» для отчётов PDF и Excel."""
    baseline = record.get("baseline") or {}
    peaks = "; ".join(f"{number_text(peak['freq_hz'], 1)} Гц (+{number_text(peak['prominence_db'], 0)} дБ"
                      + (f", {peak['match_title']})" if peak.get("match_title") else ")")
                      for peak in record.get("peaks") or []) or "нет"
    bands = "; ".join(f"{band['title']}: {number_text(band['share'] * 100, 0)} %" for band in record.get("bands") or [])
    rows = [
        ("Длительность, частота", f"{number_text(record.get('duration_s'), 1)} с, {number_text(record.get('sample_rate'))} Гц"),
        ("Уровень", f"{number_text(record.get('level_dbfs'), 1)} дБ от полной шкалы"),
        ("Норма уровня", f"{number_text(baseline.get('dbfs'), 1)} дБ - {baseline.get('title', '-')}"),
        ("Отличие от нормы", f"{number_text(baseline.get('delta_db'), 1)} дБ"),
        ("Коэффициент амплитуды", number_text(record.get("crest_factor"), 2)),
        ("Эксцесс (импульсность)", number_text(record.get("kurtosis"), 2)),
        ("Спектральный центроид", f"{number_text(record.get('centroid_hz'))} Гц"),
        ("Энергия по полосам", bands),
        ("Частота вращения", f"{number_text(record.get('shaft_hz'), 2)} Гц" if record.get("shaft_hz") else "не известна"),
        ("Тональные пики", peaks),
    ]
    return rows


def _rejected_sheet(sheet, data: dict) -> None:
    """Лист «Отклонено инженером»: находки, признанные ложными; в итог и счётчики они не входят."""
    _table(sheet, [("№", 6), ("Узел", 26), ("Находка", 40), ("Отклонил", 24), ("Когда", 17), ("Причина", 60)],
           rejected_rows(data))


def _maintenance_sheet(sheet, data: dict) -> None:
    """Лист «Регламент»: наработка после последнего обслуживания против интервала."""
    rows = [[entry.get("name"), entry.get("work") or "-", entry.get("interval_hours"), entry.get("since_hours"),
             entry.get("used_percent"), entry.get("remaining_hours"), RESOURCE_STATES.get(entry.get("state"), "-")]
            for entry in data["maintenance"]]
    _table(sheet, [("Вид обслуживания", 20), ("Состав работ", 70), ("Интервал, ч", 13), ("После последнего, ч", 20),
                   ("Израсходовано, %", 17), ("Остаток, ч", 12), ("Состояние", 22)], rows)


def _walk_sheet(sheet, data: dict) -> None:
    """Лист «Обход узлов»: осмотрен ли каждый узел и его фактический статус."""
    rows = [[node["name"], node["code"], "осмотрен" if node["inspected"] else "не осмотрен", node.get("title") or node["status"]]
            for node in data.get("walk") or []]
    _table(sheet, [("Узел", 34), ("Код", 16), ("Осмотр", 14), ("Статус", 44)], rows)


def _sensors_sheet(sheet, data: dict) -> None:
    """Лист «Датчики»: текущие значения с уставками, правила по датчикам и ряды за 24 ч и 7 сут."""
    sensors = data.get("sensors") or {}
    if not sensors.get("available"):
        _put(sheet, 1, 1, sensors.get("reason") or "Телеметрии по агрегату нет")
        return
    rows = [[entry["name"], entry["unit"], entry["value"], entry["warn"], entry["alarm"],
             LEVEL_TITLES.get(entry["level"], "-")] for entry in sensors["current"]]
    last = _table(sheet, [("Параметр", 34), ("Единица", 10), (f"Значение на {moment_text(sensors['at'])}", 22),
                          ("Предупреждение", 16), ("Тревога", 12), ("Уровень", 16)], rows)
    rules = [[rule["rule_id"], rule["title"], rule["status"], "; ".join(
        f"{line['what']}: {line['value']} (уставка {line['threshold'] or '-'})" for line in rule["evidence"] if line["met"])]
        for rule in sensors["rules"]]
    last = _table(sheet, [("Правило", 34), ("Название", 10), ("Статус", 22), ("Основания", 16)], rules, last + 1)
    codes = [code for code in sensors["meta"]]
    for key in ("24h", "7d"):
        window = sensors["series"][key]
        series = window["codes"]
        stamps = [point["t"] for point in series[codes[0]]] if codes else []
        table = [[_moment(stamp), *[series[code][index]["v"] if index < len(series[code]) else None for code in codes]]
                 for index, stamp in enumerate(stamps)]
        _put(sheet, last + 1, 1, f"Ряды за {window['title']}", bold=True, color=BRAND)
        last = _table(sheet, [("Время", 34), *[(sensors["meta"][code]["name"], 18) for code in codes]], table, last + 2)
    sheet.freeze_panes = None


def _sound_sheet(sheet, data: dict) -> None:
    """Лист «Звук»: показатели каждой записи, кандидаты и спектр последней записи."""
    records = data.get("sound") or []
    row = 1
    for record in records:
        _put(sheet, row, 1, f"Запись № {record['id']} от {moment_text(record['created_at'])}"
                            + (" (норма)" if record.get("normal") else ""), bold=True, color=BRAND)
        row += 1
        for label, value in sound_rows(record):
            _put(sheet, row, 1, label, bold=True)
            _put(sheet, row, 2, value)
            row += 1
        for entry in record.get("candidates") or []:
            _put(sheet, row, 1, "Кандидат", bold=True)
            _put(sheet, row, 2, entry["text"])
            row += 1
        row += 1
    sheet.column_dimensions["A"].width = 30
    sheet.column_dimensions["B"].width = 90
    if records:
        _put(sheet, row, 1, records[-1].get("note") or "")
        spectrum = [[point["f"], point["db"]] for point in records[-1].get("spectrum") or []]
        _table(sheet, [("Частота, Гц", 30), ("Уровень, дБ", 90)], spectrum, row + 2)
        sheet.freeze_panes = None


def _advice_sheet(sheet, data: dict) -> None:
    """Лист «Рекомендации»: рекомендации по подтверждённым находкам, ближайшее обслуживание и подписи."""
    rows = [[item["finding_id"], item["node_name"], item["title"], item["text"]] for item in data.get("recommendations") or []]
    last = _table(sheet, [("№ замечания", 12), ("Узел", 28), ("Находка", 36), ("Рекомендация", 80)], rows)
    upcoming = data.get("next_maintenance")
    if upcoming:
        when = (f"остаток {number_text(upcoming['remaining_hours'])} ч" if upcoming.get("remaining_hours") is not None
                else f"прогноз {date_text(upcoming.get('forecast_date'))}")
        _put(sheet, last + 1, 1, "Ближайшее обслуживание", bold=True)
        _put(sheet, last + 1, 4, f"{upcoming['name']} - {when}. {upcoming.get('work') or ''}")
    row = last + 3
    for entry in data.get("signatures") or []:
        _put(sheet, row, 1, entry["role"], bold=True)
        _put(sheet, row, 2, entry.get("name") or "")
        _put(sheet, row, 3, "подпись ____________")
        row += 1
    sheet.freeze_panes = None


def build_xlsx(data: dict) -> bytes:
    """Собирает книгу Excel с отчётом об осмотре и возвращает её содержимое."""
    book = Workbook()
    _summary_sheet(book.active, data)
    _nodes_sheet(book.create_sheet("Оценки по узлам"), data)
    _findings_sheets(book.create_sheet("Находки"), book.create_sheet("Основания"), data)
    _works_sheet(book.create_sheet("Проверки и работы"), data)
    if data.get("rejected"):
        _rejected_sheet(book.create_sheet("Отклонено инженером"), data)
    if data["maintenance"]:
        _maintenance_sheet(book.create_sheet("Регламент"), data)
    if data.get("walk"):
        _walk_sheet(book.create_sheet("Обход узлов"), data)
    if data.get("sensors"):
        _sensors_sheet(book.create_sheet("Датчики"), data)
    if data.get("sound"):
        _sound_sheet(book.create_sheet("Звук"), data)
    if "recommendations" in data:
        _advice_sheet(book.create_sheet("Рекомендации"), data)
    book.properties.title = f"Отчёт об осмотре № {data['inspection']['id']}"
    book.properties.creator = "КСТ Визор"
    output = io.BytesIO()
    book.save(output)
    return output.getvalue()
