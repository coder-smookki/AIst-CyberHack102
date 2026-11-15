"""Отпечаток набора моделей в находках, отчётах, /health и /webadmin; состояние каналов в /health без путей."""

import io
import json
from pathlib import Path

from openpyxl import load_workbook

from server import db, fingerprint, health
from server.inspections import service
from server.reports import build_story, build_xlsx
from test_api_extra import client, defect, headers, readings, seeded_database, start
from test_reports import sheet_text, story_text

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / "models"


def _entries(path: Path) -> list[dict]:
    """Записи моделей описания: список или поле models."""
    document = json.loads(path.read_text(encoding="utf-8"))
    return document.get("models", []) if isinstance(document, dict) else document


def _copy_models(target: Path) -> Path:
    """Копирует записи моделей описания; вместо больших весов кладёт маленькие файлы с тем же именем."""
    target.mkdir()
    entries = _entries(MODELS / "models.json")
    (target / "models.json").write_text(json.dumps(entries, ensure_ascii=False), encoding="utf-8")
    for entry in entries:
        (target / entry["file"]).write_bytes(entry["file"].encode())
    return target


def test_fingerprint_follows_files_and_thresholds(tmp_path):
    """Отпечаток меняется от весов и порогов, но не от пояснительных полей описания; считает все модели списка."""
    folder = _copy_models(tmp_path / "m")
    first = fingerprint.compute(folder)
    listed = [entry["file"] for entry in _entries(folder / "models.json")]
    assert [model["file"] for model in first["models"]] == listed and all(model["present"] for model in first["models"])
    assert len(first["fingerprint"]) == 12 and first == {**fingerprint.compute(folder), "computed_at": first["computed_at"]}
    document = json.loads((folder / "models.json").read_text(encoding="utf-8"))
    document[0]["limits"] = "другая заметка"
    (folder / "models.json").write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
    assert fingerprint.compute(folder)["fingerprint"] == first["fingerprint"]
    document[0]["conf_check"] = 0.3
    (folder / "models.json").write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
    changed = fingerprint.compute(folder)["fingerprint"]
    assert changed != first["fingerprint"]
    (folder / listed[0]).write_bytes(b"new weights")
    assert fingerprint.compute(folder)["fingerprint"] not in (first["fingerprint"], changed)
    document.append({"file": "third.onnx", "role": "extra", "conf_check": 0.4})
    (folder / "models.json").write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
    third = fingerprint.compute(folder)
    assert third["models"][-1] == {"file": "third.onnx", "sha256": None, "present": False}


def test_fingerprint_without_manifest(tmp_path):
    """Без описания моделей отпечаток считается по файлу модели по умолчанию и не падает."""
    result = fingerprint.compute(tmp_path)
    assert result["manifest"] is False and result["models"] == [{"file": "detector.onnx", "sha256": None, "present": False}]


def test_health_reports_channels_without_paths(client):
    """/health: база, каждая модель, распознавание текста, телеметрия и звук; путей на диске в ответе нет."""
    body = client.get("/health").json()
    channels = body["channels"]
    assert set(channels) == {"database", "models", "ocr", "telemetry", "sound"}
    assert channels["database"]["state"] == "ok" and channels["sound"]["state"] == "ok"
    assert [row["file"] for row in channels["models"]] == [model["file"] for model in fingerprint.current()["models"]]
    assert all(row["state"] in ("ok", "missing", "error") for row in channels["models"])
    assert channels["ocr"]["state"] in ("ok", "missing") and channels["telemetry"]["state"] in ("ok", "missing")
    assert body["models_fingerprint"] == fingerprint.short() and body["ok"] is True
    text = json.dumps(body, ensure_ascii=False)
    assert str(ROOT) not in text and "/Users/" not in text and "site-packages" not in text and "\\\\" not in text


def test_health_marks_missing_parts(monkeypatch):
    """Нет файла модели, моделей распознавания текста и баз заказчика - каналы сообщают «missing»."""
    monkeypatch.setattr(fingerprint, "current", lambda: {"models": [{"file": "x.onnx", "sha256": None, "present": False}]})
    monkeypatch.setattr(health.loader, "CUSTOMER_DIR", Path("/nonexistent-kst"))

    def no_ocr():
        """Файлов моделей распознавания текста нет."""
        raise FileNotFoundError("нет")

    monkeypatch.setattr(health.import_module("cv.nameplate"), "ocr_model_paths", no_ocr)
    channels = health.channels(object(), "error")
    assert channels["database"]["state"] == "error"
    assert channels["models"][0]["state"] == "missing" and channels["models"][0]["file"] == "x.onnx"
    assert channels["ocr"]["state"] == "missing" and channels["telemetry"]["state"] == "missing"
    assert "nonexistent" not in json.dumps(channels, ensure_ascii=False)


def test_fingerprint_stored_in_findings_and_reports(client):
    """Каждая новая находка хранит отпечаток моделей; отчёты PDF и Excel его печатают; веб-панель его показывает."""
    engineer = headers(client, "engineer")
    inspection_id = start(client, engineer)
    found = defect(client, engineer, inspection_id, sign="corrosion", node="casing")
    assert found["models_fingerprint"] == fingerprint.short()
    assert found["evidence"][0]["models"] == fingerprint.short()
    finished = client.post(f"/inspections/{inspection_id}/finish", headers=engineer).json()
    assert all(item["models_fingerprint"] == fingerprint.short() for item in finished["findings"])
    with db.SessionLocal() as session:
        data = service.report_data(session, service.get_inspection(session, inspection_id))
    assert data["models"] == {"current": fingerprint.short(), "findings": [fingerprint.short()]}
    book = load_workbook(io.BytesIO(build_xlsx(data)))
    assert "Отпечаток набора моделей" in sheet_text(book.worksheets[0]) and fingerprint.short() in sheet_text(book.worksheets[0])
    pdf_text = story_text(build_story(data))
    assert "Отпечаток набора моделей" in pdf_text and fingerprint.short() in pdf_text
    admin = headers(client, "admin")
    info = client.get("/webadmin/models", headers=admin).json()
    assert info["fingerprint"]["fingerprint"] == fingerprint.short()
    assert str(ROOT) not in json.dumps(info["fingerprint"], ensure_ascii=False)
