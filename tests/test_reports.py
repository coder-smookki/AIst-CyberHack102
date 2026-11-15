"""Проверки отчётов об осмотре: содержание и кириллица в PDF и Excel, три раздельные оценки, находки с основаниями."""

import io
import shutil
import subprocess
from datetime import datetime

import pytest
from openpyxl import load_workbook
from PIL import Image
from reportlab.pdfbase import pdfmetrics
from reportlab.platypus import KeepTogether, Paragraph, Table
from sqlalchemy import select

from server import auth, db
from server import seed as seeding
from server.inspections import service
from server.models import User
from server.reports import build_pdf, build_story, build_xlsx
from server.reports import pdf as pdf_report
from server.reports.xlsx import coverage_note, date_text, duration_text, moment_text, number_text
from server.seed import seed

DECISION = "Решение принимает инженер"
OK_NOTE = "не является подтверждением исправности"
TRICKY_COMMENT = "Капли <b>у вала</b> & пятно 5 см; t < 40 °C </para>"
FORMULA_COMMENT = "=СУММ(A1:A9)"
READINGS = {
    "rpm": 2950.0,
    "vib_rms": 1.4,
    "vib_1x": 0.8,
    "vib_2x": 0.3,
    "vib_hf": 3.4,
    "vib_axial": 0.45,
    "temp_bearing": 82.0,
    "temp_winding": 65.0,
    "current_a": 11.0,
    "current_b": 11.0,
    "current_c": 11.0,
    "current_unbalance": 0.5,
    "press_in": 1.5,
    "press_out": 4.6,
    "press_out_true": 4.6,
    "flow": 47.0,
    "power": 5.5,
    "efficiency": 73.8,
    "run_hours": 19195.0,
    "mode": 1.0,
}


class FakePlayer:
    """Подмена проигрывателя телеметрии: рост вибрации и температуры подшипника на заданный момент."""

    cursor = datetime(2026, 11, 26, 9, 0)

    def snapshot(self, at=None):
        """Показания на момент курсора."""
        return dict(READINGS)

    def trend(self, code, hours=12, at=None):
        """Наклон параметра за час: растут высокочастотная вибрация и температура подшипника."""
        return {"vib_hf": 0.06, "temp_bearing": 0.6}.get(code)


def fake_player(equipment_id):
    """Подмена: телеметрия есть только у N-101."""
    if equipment_id != "N-101":
        raise KeyError(equipment_id)
    return FakePlayer()


def jpeg():
    """Стоп-кадр камеры в формате JPEG."""
    output = io.BytesIO()
    Image.effect_noise((640, 480), 60).convert("RGB").save(output, "JPEG")
    return output.getvalue()


def box(cls, conf, share):
    """Рамка детектора заданного класса, занимающая указанную долю кадра 1280 на 720."""
    side = (share * 1280 * 720) ** 0.5
    return {"cls": cls, "conf": conf, "x1": 50.0, "y1": 50.0, "x2": 50.0 + side, "y2": 50.0 + side}


@pytest.fixture(scope="module")
def reports(tmp_path_factory):
    """Проводит осмотр насоса Н-101 на временной базе и возвращает данные отчётов: идущего, завершённого и старого."""
    folder = tmp_path_factory.mktemp("reports")
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("KST_DB", str(folder / "kst.db"))
        patch.setattr(auth, "SCRYPT_N", 2**10)
        patch.setattr(service, "get_player", fake_player)
        seeding._demo_hash.cache_clear()
        db.init_db()
        with db.SessionLocal() as session:
            seed(session)
            engineer = session.scalar(select(User).where(User.email == "engineer@kst.demo"))
            inspection, _ = service.start_inspection(session, engineer, "N-101")
            tracker = service.tracker_for(session, inspection)
            for _ in range(6):
                tracker.observe([box("terminal_box", 0.9, 0.03), box("motor", 0.8, 0.2)], 1280, 720)
            tracker.observe([box("terminal_box_burnt", 0.86, 0.03)], 1280, 720)
            service.add_finding(session, inspection, engineer, kind="defect", node="terminal_box", sign="terminal_box_burnt")
            service.add_finding(
                session, inspection, engineer, kind="defect", node="seal", sign="leak", comment=TRICKY_COMMENT, frame=jpeg()
            )
            service.add_finding(session, inspection, engineer, kind="checked", node="flanges", comment=FORMULA_COMMENT)
            service.add_finding(session, inspection, engineer, kind="replacement", node="gauge", comment="Манометр заменён")
            service.add_finding(session, inspection, engineer, kind="maintenance", maintenance_code="TO-1")
            inspection = service.get_inspection(session, inspection.id)
            active = service.report_data(session, inspection)
            inspection = service.finish_inspection(session, inspection, engineer)
            finished = service.report_data(session, inspection)
            old = service.report_data(session, service.get_inspection(session, 1))
        service._live.clear()
        db.engine.dispose()
        seeding._demo_hash.cache_clear()
    return {"active": active, "finished": finished, "old": old}


def story_fonts(flowables) -> set[str]:
    """Собирает названия шрифтов, которыми набран текст отчёта PDF, включая выделенные фрагменты."""
    names = set()
    for item in flowables:
        if isinstance(item, Paragraph):
            names.update(fragment.fontName for fragment in item.frags)
        elif isinstance(item, Table):
            for row in item._cellvalues:
                names.update(story_fonts(row))
        elif isinstance(item, KeepTogether):
            names.update(story_fonts(item._content))
    return names


def story_text(flowables) -> str:
    """Собирает весь текст отчёта PDF из его абзацев и таблиц."""
    parts = []
    for item in flowables:
        if isinstance(item, Paragraph):
            parts.append(item.getPlainText())
        elif isinstance(item, Table):
            parts.extend(story_text(row) for row in item._cellvalues)
        elif isinstance(item, KeepTogether):
            parts.append(story_text(item._content))
    return "\n".join(parts)


def sheet_rows(sheet) -> list[list]:
    """Все строки листа как списки значений."""
    return [list(row) for row in sheet.iter_rows(values_only=True)]


def sheet_text(sheet) -> str:
    """Весь текст листа одной строкой."""
    return "\n".join(str(value) for row in sheet_rows(sheet) for value in row if value is not None)


@pytest.fixture(scope="module")
def book(reports):
    """Книга Excel завершённого осмотра, прочитанная обратно из файла."""
    return load_workbook(io.BytesIO(build_xlsx(reports["finished"])))


def test_report_data_has_everything(reports):
    """Данные отчёта: оборудование, кто и когда, оценки по узлам, находки, проверки и работы, строка о решении."""
    data = reports["finished"]
    assert data["decision"] == DECISION and OK_NOTE in data["ok_note"]
    assert data["equipment"]["name"] == "Насос Н-101" and data["equipment"]["serial"] == "2786107-0142"
    assert data["inspection"]["user"]["name"] == "Алексей Смирнов" and data["inspection"]["status"] == "finished"
    assert data["telemetry_at"] == "2026-11-26T09:00:00" and data["estimates_on"] == "2026-11-26"
    assert data["overall"] == {"status": "defect", "title": "Обнаружены признаки возможного дефекта"}
    assert data["coverage"]["inspected"] == 5 and data["coverage"]["total"] == 7 and data["coverage"]["frames"] == 7
    assert len(data["nodes"]) == 8
    rules = {view["rule_id"] for view in data["findings"]}
    assert {"R01", "R04", "R08"} <= rules
    assert [view["kind"] for view in data["checked"]] == ["checked"]
    assert [view["kind"] for view in data["works"]] == ["replacement", "maintenance"]
    assert all(view["evidence"] and view["recommendation"] for view in data["findings"])
    assert sum(1 for view in data["findings"] if view["photo_file"]) == 1
    assert {entry["code"] for entry in data["maintenance"]} == {"TO-1", "TO-2", "TR"}


def test_xlsx_sheets_and_russian_text(reports, book):
    """Книга Excel содержит листы с русскими названиями, а ячейки - русский текст об оборудовании и осмотре."""
    assert book.sheetnames == [
        "Осмотр",
        "Оценки по узлам",
        "Находки",
        "Основания",
        "Проверки и работы",
        "Регламент",
        "Обход узлов",
        "Датчики",
        "Рекомендации",
    ]
    summary = dict((row[0], row[1]) for row in sheet_rows(book["Осмотр"]) if row[0])
    assert book["Осмотр"]["A1"].value == f"Отчёт об осмотре оборудования № {reports['finished']['inspection']['id']}"
    assert summary["Оборудование"] == "Насос Н-101 (N-101)"
    assert summary["Место установки"] == "Насосная станция, зал 2"
    assert summary["Осмотр провёл"] == "Алексей Смирнов, инженер"
    assert summary["Наработка агрегата"] == "19 195 ч"
    assert summary["Состояние осмотра"] == "Завершён"
    assert summary["Полнота обхода"] == "осмотрено 5 из 7 узлов (71 %), кадров обработано: 7"
    assert summary["Показания датчиков на момент"] == "26.11.2026 09:00"
    assert summary["Итог осмотра"] == "Обнаружены признаки возможного дефекта"
    assert DECISION in summary
    for name in ("Осмотр", "Оценки по узлам", "Находки"):
        assert DECISION in sheet_text(book[name]), name
    assert OK_NOTE in sheet_text(book["Осмотр"])


def test_xlsx_three_estimates_are_separate_columns(reports, book):
    """Норматив, расчётный остаток и фактическое состояние стоят в отдельных столбцах и не смешаны."""
    rows = sheet_rows(book["Оценки по узлам"])
    header = rows[0]
    normative, calculated, actual = (
        header.index(title) for title in ("Нормативный срок службы", "Расчётный остаточный ресурс", "Фактическое состояние")
    )
    assert len({normative, calculated, actual}) == 3
    by_name = {row[0]: row for row in rows[1:9]}
    assert set(by_name) == {node["name"] for node in reports["finished"]["nodes"]}
    seal = by_name["Торцевое уплотнение"]
    assert seal[normative].startswith("Норматив: 15000 ч. Источник: Регламент производителя")
    assert seal[calculated].startswith("Срок приближается: израсходовано") and "Оценка расчётная" in seal[calculated]
    assert seal[actual] == "Обнаружены признаки возможного дефекта"
    assert seal[header.index("Состояние расчёта")] == "срок приближается"
    assert seal[header.index("Остаток, ч")] == 1805 and seal[header.index("Израсходовано, %")] == 88.0
    motor = by_name["Электродвигатель"]
    assert motor[normative] == "Норматив не задан"
    assert motor[calculated].startswith("Недостаточно данных для оценки")
    assert motor[header.index("Состояние расчёта")] == "недостаточно данных"
    assert motor[header.index("Осмотр при обходе")] == "Осмотрен камерой, кадров: 6"
    flanges = by_name["Фланцевые соединения"]
    assert flanges[actual] == f"Видимых проблем не обнаружено ({OK_NOTE})"
    assert flanges[header.index("Причины")] == "Проверено инженером: замечаний нет"
    assert flanges[header.index("Осмотр при обходе")] == "Отмечен инженером вручную"
    gauge = by_name["Манометр на нагнетании"]
    assert gauge[normative].startswith("Норматив: 2 года") and gauge[header.index("Прогноз даты")] == "25.11.2028"
    for row in rows[1:9]:
        assert "Норматив" in row[normative] and "Норматив" not in row[calculated] and "Норматив" not in row[actual]
    assert "Три оценки приводятся раздельно" in sheet_text(book["Оценки по узлам"])


def test_xlsx_findings_with_evidence(reports, book):
    """Каждая находка записана с диагнозом и рекомендацией, каждое её условие - отдельной строкой оснований."""
    rows = sheet_rows(book["Находки"])
    header = rows[0]
    findings = reports["finished"]["findings"]
    by_rule = {row[header.index("Правило")]: row for row in rows[1 : 1 + len(findings)]}
    assert set(by_rule) == {view["rule_id"] for view in findings}
    leak = by_rule["R01"]
    assert leak[header.index("Узел")] == "Торцевое уплотнение"
    assert leak[header.index("Статус")] == "Обнаружены признаки возможного дефекта"
    assert "уплотнени" in leak[header.index("Диагноз")] and len(leak[header.index("Рекомендация")]) > 20
    assert leak[header.index("Комментарий")] == TRICKY_COMMENT
    assert leak[header.index("Снимок")] == "есть" and leak[header.index("Устранение")] == "Открыто"
    assert isinstance(leak[header.index("Время")], datetime)
    burnt = by_rule["R04"]
    assert burnt[header.index("Источник")] == "Инженер"
    assert burnt[header.index("Осталось проверить")] != "-"
    evidence = sheet_rows(book["Основания"])
    assert evidence[0] == ["№ находки", "Находка", "Источник", "Условие", "Значение", "Уставка", "Итог"]
    assert len(evidence) - 1 == sum(len(view["evidence"]) for view in findings)
    bearing = [row for row in evidence[1:] if row[3] == "Температура подшипника" and row[5] == "> 75 °C"]
    assert bearing and all(row[2] == "Датчики" and row[4] == "82 °C" and row[6] == "выполнено" for row in bearing)
    assert {row[6] for row in evidence[1:]} == {"выполнено", "не выполнено"}
    assert {"Камера", "Датчики", "Инженер"} <= {row[2] for row in evidence[1:]}


def test_xlsx_works_schedule_and_formula_safety(book):
    """Работы и регламент записаны по-русски; комментарий, похожий на формулу, остаётся текстом."""
    works = book["Проверки и работы"]
    rows = sheet_rows(works)
    assert [row[2] for row in rows[1:]] == [
        "Проверено, замечаний нет",
        "Выполнена замена узла",
        "Выполнено техническое обслуживание: ТО-1",
    ]
    assert [row[1] for row in rows[1:]] == ["Фланцевые соединения", "Манометр на нагнетании", "Агрегат в целом"]
    assert works["D2"].value == FORMULA_COMMENT and works["D2"].data_type == "s"
    assert works["A2"].is_date and works["A2"].number_format == "DD.MM.YYYY HH:MM"
    schedule = sheet_rows(book["Регламент"])
    assert [row[0] for row in schedule[1:]] == ["ТО-1", "ТО-2", "Ревизия"]
    assert schedule[1][3] == 0 and schedule[1][6] == "в норме"


def test_pdf_is_real_document_with_embedded_font(reports):
    """PDF - настоящий документ: несколько страниц, встроенный шрифт TrueType, снимок находки, нетривиальный размер."""
    content = build_pdf(reports["finished"])
    assert content.startswith(b"%PDF-") and content.rstrip().endswith(b"%%EOF")
    assert len(content) > 40_000
    assert b"/FontFile2" in content
    assert content.count(b"/Type /Page\n") + content.count(b"/Type /Page ") >= 3
    assert b"/Subtype /Image" in content
    without_photo = {
        **reports["finished"],
        "findings": [{**view, "photo_file": None} for view in reports["finished"]["findings"]],
    }
    assert b"/Subtype /Image" not in build_pdf(without_photo)


def test_pdf_story_contains_report_content(reports):
    """В PDF есть оборудование, кто и когда, три оценки под своими заголовками, находки с основаниями и строка о решении."""
    data = reports["finished"]
    text = story_text(build_story(data))
    for expected in (
        f"Отчёт об осмотре оборудования № {data['inspection']['id']}",
        "Насос Н-101 (N-101)",
        "Алексей Смирнов, инженер",
        "26.11.2026 09:00",
        "1. Нормативный срок службы",
        "2. Расчётный остаточный ресурс",
        "3. Фактическое состояние",
        "Три оценки приводятся раздельно",
        "Норматив: 15000 ч",
        "Оценка расчётная",
        "Недостаточно данных для оценки",
        f"Видимых проблем не обнаружено ({OK_NOTE})",
        "Обнаружены признаки возможного дефекта",
        "Диагноз:",
        "Рекомендация:",
        "Основания:",
        "Температура подшипника",
        "> 75 °C",
        "Осталось проверить:",
        TRICKY_COMMENT,
        "Стоп-кадр камеры:",
        "Проверки и работы",
        FORMULA_COMMENT,
        "Регламент обслуживания",
        DECISION,
        "Оценки сохранены на момент завершения осмотра",
        "записано автоматически по результатам диагностики",
    ):
        assert expected in text, expected
    assert text.rstrip().endswith(f"Статус «Видимых проблем не обнаружено» {OK_NOTE}")
    for view in data["findings"]:
        assert view["title"] in text and view["diagnosis"] in text and view["recommendation"] in text
        for line in view["evidence"]:
            assert line["what"] in text and line["value"] in text


def test_pdf_font_has_every_character_of_the_report(reports):
    """Во встроенном шрифте есть все знаки текста отчёта - кириллица не превратится в пустые квадраты."""
    regular, bold = pdf_report.fonts()
    story = build_story(reports["finished"])
    text = story_text(story)
    assert any("а" <= symbol <= "я" for symbol in text)
    assert story_fonts(story) == {regular, bold}
    for name in (regular, bold):
        glyphs = pdfmetrics.getFont(name).face.charToGlyph
        missing = {symbol for symbol in text if not symbol.isspace() and ord(symbol) not in glyphs}
        assert not missing, (name, missing)


def test_pdf_text_is_readable_cyrillic(reports, tmp_path):
    """Текст, извлечённый из готового PDF сторонней программой, читается по-русски."""
    if shutil.which("pdftotext") is None:
        pytest.skip("программа pdftotext не установлена")
    path = tmp_path / "report.pdf"
    path.write_bytes(build_pdf(reports["finished"]))
    result = subprocess.run(["pdftotext", "-enc", "UTF-8", str(path), "-"], capture_output=True, check=True, timeout=15)
    text = " ".join(result.stdout.decode("utf-8").split())
    for expected in (
        "Отчёт об осмотре оборудования",
        "Насос Н-101",
        "Алексей Смирнов",
        "Нормативный срок",
        "Расчётный остаточный",
        "Фактическое состояние",
        "Основания",
        "Рекомендация",
        DECISION,
        "Капли <b>у вала</b> & пятно 5 см; t < 40 °C </para>",
        "КСТ Визор - отчёт об осмотре",
        "Страница 2",
    ):
        assert expected in text, expected


def test_reports_of_active_and_old_inspections(reports):
    """Отчёт строится и по идущему осмотру, и по старому, где оценки не сохранялись; основание оценок названо."""
    active, old = reports["active"], reports["old"]
    assert active["basis"] == "Осмотр не завершён: оценки рассчитаны на момент формирования отчёта"
    assert active["inspection"]["finished_at"] is None and active["inspection"]["duration_s"] is None
    assert old["basis"].startswith("Оценки ресурса рассчитаны на дату формирования отчёта")
    assert old["coverage"] is None and old["telemetry_at"] is None
    assert old["inspection"]["user"]["name"] and old["inspection"]["duration_s"] > 0
    for data in (active, old):
        pdf = build_pdf(data)
        assert pdf.startswith(b"%PDF-") and len(pdf) > 20_000
        text = story_text(build_story(data))
        assert DECISION in text and data["basis"] in text and "1. Нормативный срок службы" in text
        workbook = load_workbook(io.BytesIO(build_xlsx(data)))
        assert DECISION in sheet_text(workbook["Осмотр"]) and data["basis"] in sheet_text(workbook["Оценки по узлам"])
    assert "Идёт" in story_text(build_story(active))
    old_book = load_workbook(io.BytesIO(build_xlsx(old)))
    summary = dict((row[0], row[1]) for row in sheet_rows(old_book["Осмотр"]) if row[0])
    assert summary["Полнота обхода"] == "Не сохранялась"
    assert summary["Показания датчиков на момент"] == "телеметрии по агрегату нет"
    assert "Коррозия на корпусе насоса" in sheet_text(old_book["Находки"])


def test_node_skipped_on_walk_is_not_reported_as_fine(reports, book):
    """Узел, который камера распознаёт, но его не осмотрели при обходе и не отметили, не считается исправным на вид.

    Датчики по нему в норме, но категория остаётся «не осмотрен»; осмотренные камерой и отмеченные инженером узлы - зелёные.
    """
    for data in (reports["finished"], reports["active"]):
        actual = {node["code"]: node["actual"] for node in data["nodes"]}
        for code in ("coupling", "casing"):
            assert actual[code]["status"] == "unknown", code
            assert actual[code]["reasons"][0] == service.NOT_WALKED
            assert "Датчики: отклонений по правилам не выявлено" in actual[code]["reasons"]
            assert service.CAMERA_MISSED not in actual[code]["reasons"]
        assert actual["motor"]["status"] == "ok" and actual["flanges"]["status"] == "ok"
        assert actual["gauge"]["status"] == "ok"
    saved = {node["code"]: node["actual"]["status"] for node in reports["finished"]["nodes"]}
    assert saved["coupling"] == "unknown"
    rows = sheet_rows(book["Оценки по узлам"])
    column = rows[0].index("Фактическое состояние")
    by_name = {row[0]: row for row in rows[1:9]}
    assert by_name["Муфта и защита муфты"][column] == "Узел не осмотрен / недостаточно данных"
    assert by_name["Электродвигатель"][column] == f"Видимых проблем не обнаружено ({OK_NOTE})"


def test_report_without_findings_says_so(reports):
    """Если замечаний нет, отчёт прямо сообщает об этом, а строка о решении остаётся."""
    empty = {**reports["finished"], "findings": [], "checked": [], "works": [], "maintenance": []}
    text = story_text(build_story(empty))
    assert "Замечаний и дефектов не зафиксировано" in text and DECISION in text
    assert "Проверки и работы" not in text and "Регламент обслуживания" not in text
    workbook = load_workbook(io.BytesIO(build_xlsx(empty)))
    assert "Регламент" not in workbook.sheetnames
    assert "Замечаний и дефектов не зафиксировано" in sheet_text(workbook["Находки"])
    assert build_pdf(empty).startswith(b"%PDF-")


def test_pdf_survives_very_long_comments(reports):
    """Очень длинный многострочный комментарий не ломает PDF: в таблице он обрезается, в находке переносится на страницы."""
    data = reports["finished"]
    long_comment = "\n".join(f"Строка замечания номер {number}" for number in range(400))
    first = {**data["findings"][0], "comment": long_comment}
    heavy = {
        **data,
        "findings": [first, *data["findings"][1:]],
        "checked": [{**view, "comment": long_comment} for view in data["checked"]],
    }
    content = build_pdf(heavy)
    assert content.startswith(b"%PDF-") and len(content) > len(build_pdf(data))
    text = story_text(build_story(heavy))
    assert "Строка замечания номер 399" in text and "полный текст - в отчёте Excel" in text
    workbook = load_workbook(io.BytesIO(build_xlsx(heavy)))
    assert workbook["Проверки и работы"]["D2"].value == long_comment


def test_pdf_refuses_without_cyrillic_font(reports, tmp_path, monkeypatch):
    """Без шрифта с кириллицей PDF не формируется, ошибка объясняет причину по-русски."""
    monkeypatch.setattr(pdf_report, "_font_dirs", lambda: [tmp_path])
    pdf_report.fonts.cache_clear()
    try:
        with pytest.raises(RuntimeError, match="шрифт с кириллицей"):
            build_pdf(reports["finished"])
    finally:
        pdf_report.fonts.cache_clear()
    monkeypatch.undo()
    assert build_pdf(reports["old"]).startswith(b"%PDF-")


def test_text_helpers():
    """Числа, даты, длительность и сведения об обходе записываются по-русски; пустые значения - прочерком."""
    assert number_text(19190) == "19 190" and number_text(0.857, 2) == "0,86" and number_text(None) == "-"
    assert moment_text("2026-11-14T02:05:09") == "14.11.2026 02:05" and moment_text(None) == "-"
    assert date_text("2027-02-04") == "04.02.2027" and date_text(None) == "-"
    assert duration_text(None) == "-" and duration_text(42) == "42 с"
    assert duration_text(605) == "10 мин 05 с" and duration_text(3725) == "1 ч 02 мин"
    coverage = {
        "nodes": {
            "a": {"manual": True, "inspected": True, "seen": 0, "trackable": True},
            "b": {"manual": False, "inspected": True, "seen": 7, "trackable": True},
            "c": {"manual": False, "inspected": False, "seen": 2, "trackable": True},
            "d": {"manual": False, "inspected": False, "seen": 0, "trackable": True},
            "e": {"manual": False, "inspected": False, "seen": 0, "trackable": False},
        }
    }
    assert [coverage_note(coverage, code) for code in "abcde"] == [
        "Отмечен инженером вручную",
        "Осмотрен камерой, кадров: 7",
        "Осмотр камерой не завершён, кадров: 2",
        "Камерой не осмотрен",
        "Камерой не распознаётся",
    ]
    assert coverage_note(None, "a") == "Сведений об обходе нет" and coverage_note(coverage, "z") == "Сведений об обходе нет"
