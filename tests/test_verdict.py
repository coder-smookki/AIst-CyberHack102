"""Итог осмотра при неполном обходе: «Осмотр неполный» со списком неосмотренных узлов в сводке и отчётах."""
import io

from openpyxl import load_workbook

from server import db
from server.inspections import service
from server.reports import build_story, build_xlsx
from test_api_extra import client, defect, headers, readings, seeded_database, start
from test_reports import sheet_text, story_text


def _finish(client, auth_headers, inspection_id):
    """Завершает осмотр и возвращает ответ сервера."""
    response = client.post(f"/inspections/{inspection_id}/finish", headers=auth_headers)
    assert response.status_code == 200, response.text
    return response.json()


def _report(inspection_id):
    """Данные отчёта, страницы PDF в виде текста и текст первого листа Excel."""
    with db.SessionLocal() as session:
        data = service.report_data(session, service.get_inspection(session, inspection_id))
    book = load_workbook(io.BytesIO(build_xlsx(data)))
    return data, story_text(build_story(data)), sheet_text(book.worksheets[0])


def test_verdict_rules():
    """Дефект и проверка важнее неполного обхода; без неосмотренных узлов итог не меняется."""
    missing = [{"code": "seal", "name": "Уплотнение", "actual": {"status": "unknown"}}]
    seen = [{"code": "seal", "name": "Уплотнение", "actual": {"status": "ok"}}]
    assert service.verdict("ok", missing) == "incomplete"
    assert service.verdict("unknown", missing) == "incomplete"
    assert service.verdict(None, missing) == "incomplete"
    assert service.verdict("check", missing) == "check"
    assert service.verdict("defect", missing) == "defect"
    assert service.verdict("ok", seen) == "ok"
    assert service.uninspected_nodes(missing) == [{"code": "seal", "name": "Уплотнение"}]
    assert service.STATUS_TITLES["incomplete"] == "Осмотр неполный"


def test_unwalked_inspection_is_incomplete(client):
    """Осмотр без обхода и без находок - «Осмотр неполный», а не «видимых проблем не обнаружено»."""
    engineer = headers(client, "engineer")
    inspection_id = start(client, engineer)
    summary = _finish(client, engineer, inspection_id)["summary"]
    assert summary["status"] == "incomplete" and summary["status_title"] == "Осмотр неполный"
    unknown = [row for row in summary["nodes"] if row["actual"]["status"] == "unknown"]
    assert unknown and summary["uninspected"] == [{"code": row["code"], "name": row["name"]} for row in unknown]
    again = client.get(f"/inspections/{inspection_id}", headers=engineer).json()["summary"]
    assert again["status"] == "incomplete" and again["uninspected"] == summary["uninspected"]
    data, pdf_text, xlsx_text = _report(inspection_id)
    assert data["overall"] == {"status": "incomplete", "title": "Осмотр неполный"}
    assert data["uninspected"] == summary["uninspected"]
    first = summary["uninspected"][0]["name"]
    assert "Осмотр неполный: не осмотрены" in pdf_text and first in pdf_text
    assert "Осмотр неполный: не осмотрены" in xlsx_text and "Неосмотренные узлы" in xlsx_text
    assert "Видимых проблем не обнаружено (" not in xlsx_text.split("Итог осмотра", 1)[1].split("\n", 2)[1]


def test_defect_takes_precedence_over_incomplete(client):
    """Признак дефекта остаётся итогом осмотра, а неосмотренные узлы всё равно перечислены."""
    engineer = headers(client, "engineer")
    inspection_id = start(client, engineer)
    defect(client, engineer, inspection_id, sign="corrosion", node="casing")
    summary = _finish(client, engineer, inspection_id)["summary"]
    assert summary["status"] == "defect" and summary["status_title"] == "Обнаружены признаки возможного дефекта"
    assert summary["uninspected"] and "casing" not in [node["code"] for node in summary["uninspected"]]
    data, _, _ = _report(inspection_id)
    assert data["overall"]["status"] == "defect" and data["uninspected"] == summary["uninspected"]


def test_fully_walked_inspection_is_not_incomplete(client):
    """Когда инженер отметил каждый узел, итог - «видимых проблем не обнаружено» с оговоркой, список пуст."""
    engineer = headers(client, "engineer")
    inspection_id = start(client, engineer)
    nodes = client.get("/equipment/N-101", headers=engineer).json()["nodes"]
    for node in nodes:
        response = client.post(f"/inspections/{inspection_id}/findings", headers=engineer,
                               data={"kind": "checked", "node": node["id"]})
        assert response.status_code == 201, response.text
    summary = _finish(client, engineer, inspection_id)["summary"]
    assert summary["uninspected"] == [] and summary["status"] == "ok"
    data, _, xlsx_text = _report(inspection_id)
    assert data["overall"]["status"] == "ok" and data["uninspected"] == []
    assert "Неосмотренные узлы" not in xlsx_text


def test_old_summary_without_list_is_reported_incomplete(client):
    """Отчёт по осмотру, завершённому до этой доработки, выводит неполный обход из сохранённых оценок узлов."""
    engineer = headers(client, "engineer")
    inspection_id = start(client, engineer)
    _finish(client, engineer, inspection_id)
    with db.SessionLocal() as session:
        inspection = service.get_inspection(session, inspection_id)
        old = {key: value for key, value in inspection.summary.items() if key not in ("status_title", "uninspected")}
        inspection.summary = {**old, "status": "ok"}
        session.commit()
    data, _, _ = _report(inspection_id)
    assert data["overall"]["status"] == "incomplete" and data["uninspected"]
