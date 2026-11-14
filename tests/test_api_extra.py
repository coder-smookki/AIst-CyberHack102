"""Проверки дополнительных маршрутов: справочник и разбор правил, отклонение и комментарии замечаний, сведения об объекте."""
import io
import shutil
import socket
import sqlite3
import wave
import zipfile
from datetime import datetime, timedelta

import numpy as np
from openpyxl import load_workbook

import pytest
from fastapi.testclient import TestClient

from server import auth, db, migrate, site, sound, telemetry_api
from server import seed as seeding
from server.app import create_app
from server.inspections import report_extra, service
from server.models import Finding, Node
from server.reports import build_pdf, build_xlsx
from server.rules import explain_rule, load_rules
from server.seed import load_cards

SECRET = "x" * 48
PASSWORD = "demo12345"
CALM = {
    "rpm": 2950.0, "vib_rms": 1.0, "vib_1x": 0.8, "vib_2x": 0.3, "vib_hf": 0.1, "vib_axial": 0.45,
    "temp_bearing": 50.0, "temp_winding": 65.0, "current_a": 11.0, "current_b": 11.0, "current_c": 11.0,
    "current_unbalance": 0.5, "press_in": 1.5, "press_out": 4.6, "press_out_true": 4.6, "flow": 47.0, "power": 5.5,
    "efficiency": 73.8, "run_hours": 19195.0, "mode": 1.0,
}
HOT = {**CALM, "vib_hf": 3.2, "temp_bearing": 82.0}


class FakeDetector:
    """Подменный детектор: рамок на кадре нет."""

    def detect(self, frame):
        """Возвращает пустой список рамок."""
        return []


class FakePlayer:
    """Подмена проигрывателя телеметрии: заданные показания без трендов на заданный момент."""

    def __init__(self, readings):
        """Запоминает показания."""
        self.readings = dict(readings)
        self.cursor = datetime(2026, 11, 20, 12, 0)

    def snapshot(self, at=None):
        """Показания на момент курсора."""
        return dict(self.readings)

    def trend(self, code, hours=12, at=None):
        """Трендов нет."""
        return None

    def customer_label(self, kind, at=None):
        """Записей заказчика на этот момент нет: диагноз по уставкам считается моделью."""
        return None

    def parameters(self, at=None):
        """Описание параметров с уставками заказчика для вибрации и температур."""
        limits = {"vib_rms": (None, None), "vib_1x": (2.8, 4.5), "vib_2x": (1.8, 3.0), "vib_hf": (2.5, 5.0),
                  "temp_bearing": (75.0, 90.0), "temp_winding": (90.0, 110.0)}
        return [{"code": code, "name": code, "unit": "мм/с", "warn": warn, "alarm": alarm,
                 "direction": "high" if warn else None, "source": "model"} for code, (warn, alarm) in limits.items()]

    def window(self, code, hours=24, at=None):
        """Ряд значений параметра по часам: постоянное текущее значение."""
        return [(self.cursor - timedelta(hours=hours - index), self.readings.get(code, 0.0)) for index in range(hours + 1)]


def forget_caches():
    """Сбрасывает запомненные хэши паролей и счётчик неудачных входов."""
    seeding._demo_hash.cache_clear()
    auth._decoy_hash.cache_clear()
    auth._failures.clear()


@pytest.fixture(scope="module")
def seeded_database(tmp_path_factory):
    """Один раз создаёт базу с начальными данными; каждая проверка работает со своей копией."""
    path = tmp_path_factory.mktemp("extra") / "kst.db"
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("KST_DB", str(path))
        patch.setattr(auth, "SCRYPT_N", 2**10)
        forget_caches()
        db.init_db()
        with db.SessionLocal() as session:
            seeding.seed(session)
        db.engine.dispose()
        forget_caches()
    return path


@pytest.fixture
def readings():
    """Изменяемые показания подменной телеметрии N-101 (у других агрегатов телеметрии нет)."""
    return dict(CALM)


@pytest.fixture
def client(seeded_database, tmp_path, monkeypatch, readings):
    """Сервер на копии базы с подменной телеметрией."""
    shutil.copyfile(seeded_database, tmp_path / "kst.db")
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    monkeypatch.setenv("KST_SECRET", SECRET)
    monkeypatch.setattr(auth, "SCRYPT_N", 2**10)

    def player(equipment_id):
        """Телеметрия есть только у N-101."""
        if equipment_id != "N-101":
            raise KeyError(equipment_id)
        return FakePlayer(readings)

    monkeypatch.setattr(telemetry_api, "get_player", player)
    monkeypatch.setattr(service, "get_player", player)
    monkeypatch.setattr(report_extra, "get_player", player)
    forget_caches()
    with TestClient(create_app(FakeDetector())) as test_client:
        yield test_client
    service._live.clear()
    db.engine.dispose()
    forget_caches()


def headers(client, who):
    """Входит под демонстрационной учётной записью и возвращает заголовок авторизации."""
    response = client.post("/auth/login", json={"email": f"{who}@kst.demo", "password": PASSWORD})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


def start(client, auth_headers, equipment_id="N-101"):
    """Начинает осмотр и возвращает его номер."""
    response = client.post("/inspections", json={"equipment_id": equipment_id}, headers=auth_headers)
    assert response.status_code in (200, 201), response.text
    return response.json()["id"]


def defect(client, auth_headers, inspection_id, sign="leak", node="seal"):
    """Фиксирует дефект по признаку и возвращает запись."""
    response = client.post(f"/inspections/{inspection_id}/findings", headers=auth_headers,
                           data={"kind": "defect", "sign": sign, "node": node})
    assert response.status_code == 201, response.text
    return response.json()


def test_rules_catalogue_maps_every_rule(client):
    """Справочник отдаёт все правила файла, с признаками камеры, порогами датчиков и источником."""
    engineer = headers(client, "engineer")
    response = client.get("/rules", headers=engineer)
    assert response.status_code == 200
    items = {item["id"]: item for item in response.json()}
    assert set(items) == {rule["id"] for rule in load_rules()}
    r01 = items["R01"]
    assert r01["group"] == "customer" and r01["source"]["customer"] is True
    assert [sign["code"] for sign in r01["camera"]["signs"]] == ["leak"]
    assert r01["camera"]["text"] == "Влажное пятно, капли, блеск жидкости у вала"
    params = {(entry["param"], entry["op"], entry["value"]) for entry in r01["sensor"]["conditions"]}
    assert ("vib_hf", ">", 2.5) in params and ("temp_bearing", ">", 75) in params
    assert r01["status"]["status"] == "defect" and r01["severity"] == 3
    assert {variant["when"] for variant in r01["status"]["variants"]} == {"camera_only", "partial"}
    r04 = items["R04"]
    assert [sign["code"] for sign in r04["camera"]["manual_signs"]] == ["local_heating"]
    s04 = items["S04"]
    escalation = [entry for entry in s04["sensor"]["conditions"] if entry["escalation"]]
    assert escalation[0]["value"] == 90 and escalation[0]["unit"] == "°C"
    assert s04["source"]["thresholds"] is True
    assert items["V01"]["camera"]["any_defect_sign"] is True
    trend = next(entry for entry in r01["sensor"]["conditions"] if entry["kind"] == "trend")
    assert trend["unit"].endswith("/ч")
    assert client.get("/rules", headers=headers(client, "operator")).status_code == 200


def test_rules_need_view_permission(client):
    """Без входа справочник недоступен, администратору ИБ без прав просмотра - 403."""
    assert client.get("/rules").status_code == 401
    assert client.get("/rules", headers=headers(client, "security")).status_code == 403
    assert client.get("/equipment/N-101/rules/R01", headers=headers(client, "security")).status_code == 403


def test_rule_evaluation_by_sensors_only(client, readings):
    """Без осмотра правило R01 при росте вибрации и температуры выполнено частично: течь камерой не подтверждена."""
    readings.update(HOT)
    engineer = headers(client, "engineer")
    body = client.get("/equipment/N-101/rules/R01", headers=engineer).json()
    assert body["applies"] is True and body["status"] == "check"
    assert body["telemetry"] is True and body["at"] == "2026-11-20T12:00:00"
    assert body["node_id"] == "seal" and body["node_name"]
    camera, sensor = body["parts"]
    assert camera["source"] == "camera" and camera["state"] == "unknown"
    assert sensor["state"] == "met"
    leak = next(entry for entry in body["conditions"] if entry["kind"] == "sign")
    assert leak["missing"] is True and leak["met"] is False and leak["hints"]
    vib = next(entry for entry in body["conditions"] if entry["param"] == "vib_hf" and entry["kind"] == "threshold")
    assert vib["met"] is True and vib["value"] == "3.2 g" and vib["threshold"] == "> 2.5 g"
    trend = next(entry for entry in body["conditions"] if entry["kind"] == "trend")
    assert trend["missing"] is True
    assert body["evidence"] and body["recommendation"]
    assert "наведите камеру" in " ".join(body["missing"])


def test_rule_evaluation_with_confirmed_mark(client, readings):
    """С номером осмотра учитывается подтверждённая инженером течь: правило R01 срабатывает полностью."""
    readings.update(HOT)
    engineer = headers(client, "engineer")
    inspection_id = start(client, engineer)
    defect(client, engineer, inspection_id)
    body = client.get(f"/equipment/N-101/rules/R01?inspection_id={inspection_id}", headers=engineer).json()
    assert body["status"] == "defect" and body["severity"] == 3
    assert body["confirmed_signs"] == [{"code": "leak", "title": "Течь, капли или влажное пятно"}]
    assert all(part["met"] for part in body["parts"])
    assert body["diagnosis"].startswith("Деградация уплотнения вала")
    assert any(line["source"] == "manual" and line["met"] for line in body["evidence"])


def test_rule_evaluation_not_fired_and_no_data(client):
    """Спокойные показания - условия не выполнены; агрегат без телеметрии - недостаточно данных."""
    engineer = headers(client, "engineer")
    calm = client.get("/equipment/N-101/rules/S04", headers=engineer).json()
    assert calm["status"] == "ok" and calm["diagnosis"] is None
    assert calm["conditions"][0]["value"] == "50 °C" and calm["conditions"][0]["met"] is False
    assert calm["escalation"]["met"] is False and calm["escalation"]["status"] == "defect"
    empty = client.get("/equipment/AMS-1/rules/S04", headers=engineer).json()
    assert empty["status"] == "unknown" and empty["telemetry"] is False
    assert empty["conditions"][0]["missing"] is True and empty["conditions"][0]["value"] == "нет данных"


def test_rule_evaluation_errors(client):
    """Неизвестный агрегат или правило - 404, осмотр другого агрегата - 422."""
    engineer = headers(client, "engineer")
    assert client.get("/equipment/NOPE/rules/R01", headers=engineer).status_code == 404
    assert client.get("/equipment/N-101/rules/R99", headers=engineer).status_code == 404
    other = start(client, engineer, "AMS-1")
    assert client.get(f"/equipment/N-101/rules/R01?inspection_id={other}", headers=engineer).status_code == 422


def test_explain_rule_not_applicable():
    """Правило для другого типа оборудования не применяется и находки не даёт, но условия разобраны."""
    card = {**next(entry for entry in load_cards() if entry["id"] == "N-101"), "type": "other_type"}
    result = explain_rule(card, HOT, {}, {}, {"leak"}, "R01")
    assert result["applies"] is False and result["status"] == "not_applicable" and result["findings"] == []
    assert result["conditions"]
    with pytest.raises(KeyError):
        explain_rule(card, {}, {}, {}, set(), "R99")


def test_reject_finding_excludes_it_everywhere(client, readings):
    """Отклонённая находка: кто и когда, причина; нет в диагнозе, на доске, в счётчике и в находках отчёта."""
    engineer, master = headers(client, "engineer"), headers(client, "master")
    inspection_id = start(client, engineer)
    finding = defect(client, engineer, inspection_id)
    before = client.get("/equipment/N-101", headers=engineer).json()["open_findings"]
    url = f"/inspections/findings/{finding['id']}/state"
    assert client.post(url, json={"state": "rejected", "comment": "блик"}, headers=engineer).status_code == 403
    assert client.post(url, json={"state": "rejected"}, headers=master).status_code == 422
    assert client.post(url, json={"state": "rejected", "comment": "  "}, headers=master).status_code == 422
    response = client.post(url, json={"state": "rejected", "comment": "Блик на корпусе, течи нет"}, headers=master)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["state"] == "rejected" and body["state_title"] == "Отклонено" and body["rejected"] is True
    assert body["rejected_by"]["name"] == "Марина Орлова" and body["rejected_at"]
    assert body["reject_reason"] == "Блик на корпусе, течи нет"
    assert body["notes"][-1]["kind"] == "rejected" and "Отклонено - Марина Орлова" in body["comment"]
    assert client.post(url, json={"state": "rejected", "comment": "ещё раз"}, headers=master).status_code == 200
    assert client.post(url, json={"state": "in_work"}, headers=master).status_code == 409
    board = client.get("/inspections/findings", headers=master).json()
    assert finding["id"] not in [item["id"] for item in board]
    rejected = client.get("/inspections/findings?state=rejected", headers=master).json()
    assert [item["id"] for item in rejected] == [finding["id"]]
    every = client.get("/inspections/findings?include_rejected=true", headers=master).json()
    assert finding["id"] in [item["id"] for item in every]
    assert client.get("/equipment/N-101", headers=engineer).json()["open_findings"] == before - 1
    diagnosis = client.get(f"/equipment/N-101/diagnosis?inspection_id={inspection_id}", headers=engineer).json()
    assert not any(line["source"] == "manual" for found in diagnosis["findings"] for line in found["evidence"])
    rule = client.get(f"/equipment/N-101/rules/R01?inspection_id={inspection_id}", headers=engineer).json()
    assert rule["confirmed_signs"] == []
    finished = client.post(f"/inspections/{inspection_id}/finish", headers=engineer).json()
    assert finished["summary"]["rejected"] == 1 and finished["summary"]["by_status"]["defect"] == 0
    assert not any(item["rule_id"] == "R01" and item["id"] != finding["id"] for item in finished["findings"])
    with db.SessionLocal() as session:
        data = service.report_data(session, service.get_inspection(session, inspection_id))
    assert finding["id"] not in [view["id"] for view in data["findings"]]
    assert [view["id"] for view in data["rejected"]] == [finding["id"]]
    xlsx = client.get(f"/inspections/{inspection_id}/report.xlsx", headers=engineer)
    assert xlsx.status_code == 200 and "Отклонено инженером".encode() in _unzipped(xlsx.content)
    assert client.get(f"/inspections/{inspection_id}/report.pdf", headers=engineer).status_code in (200, 503)


def _unzipped(content: bytes) -> bytes:
    """Склеивает содержимое всех файлов книги Excel для поиска текста."""
    with zipfile.ZipFile(io.BytesIO(content)) as book:
        return b"".join(book.read(name) for name in book.namelist())


def test_reject_after_finish_updates_summary(client, readings):
    """Отклонение находки завершённого осмотра пересчитывает счётчики и итог сводки."""
    engineer, master = headers(client, "engineer"), headers(client, "master")
    inspection_id = start(client, engineer)
    finding = defect(client, engineer, inspection_id, sign="corrosion", node="casing")
    finished = client.post(f"/inspections/{inspection_id}/finish", headers=engineer).json()
    assert finished["summary"]["status"] == "defect"
    client.post(f"/inspections/findings/{finding['id']}/state", json={"state": "rejected", "comment": "грязь"},
                headers=master)
    summary = client.get(f"/inspections/{inspection_id}", headers=engineer).json()["summary"]
    assert summary["rejected"] == 1 and summary["by_status"]["defect"] == 0 and summary["status"] == "ok"


def test_resolved_finding_cannot_be_rejected(client):
    """Устранённое замечание отклонить нельзя - 409; отклонить можно и из состояния «в работе»."""
    engineer, master = headers(client, "engineer"), headers(client, "master")
    inspection_id = start(client, engineer)
    first = defect(client, engineer, inspection_id)
    second = defect(client, engineer, inspection_id, sign="corrosion", node="casing")
    for state in ("in_work", "resolved"):
        assert client.post(f"/inspections/findings/{first['id']}/state", json={"state": state},
                           headers=master).status_code == 200
    assert client.post(f"/inspections/findings/{first['id']}/state", json={"state": "rejected", "comment": "нет"},
                       headers=master).status_code == 409
    client.post(f"/inspections/findings/{second['id']}/state", json={"state": "in_work"}, headers=master)
    moved = client.post(f"/inspections/findings/{second['id']}/state", json={"state": "rejected", "comment": "нет"},
                        headers=master)
    assert moved.status_code == 200 and moved.json()["state"] == "rejected"


def test_comment_on_finding(client):
    """Комментарий дописывается с автором и временем; без права просмотра и не автору - 403; пустой - 422."""
    engineer = headers(client, "engineer")
    inspection_id = start(client, engineer)
    finding = defect(client, engineer, inspection_id)
    url = f"/inspections/findings/{finding['id']}/comment"
    response = client.post(url, json={"text": "Капли раз в минуту"}, headers=engineer)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["notes"][-1]["text"] == "Капли раз в минуту" and body["notes"][-1]["user_name"] == "Алексей Смирнов"
    assert body["notes"][-1]["kind"] == "comment" and body["notes"][-1]["at"]
    assert "Комментарий - Алексей Смирнов" in body["comment"]
    again = client.post(url, json={"text": "Подтянут сальник"}, headers=headers(client, "operator")).json()
    assert len(again["notes"]) == 2 and again["comment"].count("\n") == 1
    assert client.post(url, json={"text": "x"}, headers=headers(client, "security")).status_code == 403
    assert client.post(url, json={"text": ""}, headers=engineer).status_code == 422
    assert client.post(url, json={"text": "   "}, headers=engineer).status_code == 422
    assert client.post("/inspections/findings/999999/comment", json={"text": "x"}, headers=engineer).status_code == 404


OLD_FINDINGS = """
CREATE TABLE findings (id INTEGER NOT NULL, inspection_id INTEGER NOT NULL, equipment_id VARCHAR(32) NOT NULL,
    node_code VARCHAR(64), source VARCHAR(16) NOT NULL, rule_id VARCHAR(16), status VARCHAR(16) NOT NULL, severity INTEGER,
    title VARCHAR(200) NOT NULL, diagnosis TEXT, recommendation TEXT, confidence FLOAT, evidence JSON, comment TEXT,
    photo_path VARCHAR(300), state VARCHAR(16) NOT NULL, created_at DATETIME NOT NULL, PRIMARY KEY (id),
    CONSTRAINT ck_findings_state CHECK (state IN ('open', 'in_work', 'resolved')),
    CONSTRAINT ck_findings_severity CHECK (severity IS NULL OR severity BETWEEN 0 AND 3),
    FOREIGN KEY(inspection_id) REFERENCES inspections (id), FOREIGN KEY(equipment_id) REFERENCES equipment (id));
"""


def test_old_findings_table_is_migrated(seeded_database, tmp_path, monkeypatch):
    """Таблица находок прежнего вида пересобирается на месте: строки сохраняются, отклонение становится возможным."""
    path = tmp_path / "old.db"
    shutil.copyfile(seeded_database, path)
    with sqlite3.connect(path) as connection:
        rows = connection.execute("SELECT id, inspection_id, equipment_id, node_code, source, rule_id, status, severity, "
                                  "title, diagnosis, recommendation, confidence, evidence, comment, photo_path, state, "
                                  "created_at FROM findings").fetchall()
        connection.execute("DROP TABLE findings")
        connection.executescript(OLD_FINDINGS)
        connection.executemany(f"INSERT INTO findings VALUES ({', '.join('?' * 17)})", rows)
        assert migrate.findings_need_upgrade(connection)
    monkeypatch.setenv("KST_DB", str(path))
    try:
        db.init_db()
        with sqlite3.connect(path) as connection:
            assert not migrate.findings_need_upgrade(connection)
            assert connection.execute("SELECT count(*) FROM findings").fetchone()[0] == len(rows)
            assert connection.execute("PRAGMA foreign_key_check").fetchall() == []
            indexes = {row[1] for row in connection.execute("PRAGMA index_list(findings)")}
            assert {"ix_findings_inspection_id", "ix_findings_equipment_state"} <= indexes
        with db.SessionLocal() as session:
            if rows:
                found = session.get(Finding, rows[0][0])
                found.state, found.rejected_at = "rejected", datetime(2026, 11, 14, 12, 0)
                session.commit()
        assert migrate.upgrade(str(path)) is False
    finally:
        db.engine.dispose()


def test_site_defaults_and_shift(client, monkeypatch):
    """Сведения об объекте: название по умолчанию, имя сервера из переменной или имя машины, смена по времени."""
    monkeypatch.delenv("KST_SITE_NAME", raising=False)
    monkeypatch.setenv("KST_SERVER_NAME", "kst-server-01")
    monkeypatch.setenv("KST_TIMEZONE", "Europe/Moscow")
    assert client.get("/site").status_code == 401
    body = client.get("/site", headers=headers(client, "operator")).json()
    assert body["name"] == "Насосная станция № 2" and body["server_name"] == "kst-server-01"
    assert body["timezone"] == "Europe/Moscow" and body["shift"] in ("08:00-20:00", "20:00-08:00")
    monkeypatch.delenv("KST_SERVER_NAME")
    monkeypatch.setenv("KST_SITE_NAME", "Насосная станция № 5")
    body = client.get("/site", headers=headers(client, "security")).json()
    assert body["server_name"] == socket.gethostname() and body["name"] == "Насосная станция № 5"


@pytest.mark.parametrize(("clock", "code", "start"), [
    ("2026-11-14T08:00", "day", "2026-11-14T08:00"),
    ("2026-11-14T19:59", "day", "2026-11-14T08:00"),
    ("2026-11-14T20:00", "night", "2026-11-14T20:00"),
    ("2026-11-15T07:59", "night", "2026-11-14T20:00"),
])
def test_shift_boundaries(clock, code, start, monkeypatch):
    """Дневная смена 08:00-20:00, ночная 20:00-08:00; ночная после полуночи начинается накануне."""
    monkeypatch.setenv("KST_TIMEZONE", "Europe/Moscow")
    info = site.site_info(datetime.fromisoformat(clock))
    assert info["shift_code"] == code and info["shift_start"] == start
    assert info["shift"] == ("08:00-20:00" if code == "day" else "20:00-08:00")


SHAFT_HZ = CALM["rpm"] / 60.0


def wav(samples, rate=16000, width=2, channels=1) -> bytes:
    """Запись WAV из отсчётов в диапазоне -1..1."""
    output = io.BytesIO()
    with wave.open(output, "wb") as target:
        target.setnchannels(channels)
        target.setsampwidth(width)
        target.setframerate(rate)
        if width == 2:
            target.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())
        else:
            target.writeframes(((np.clip(samples, -1, 1) + 1) * 127).astype("u1").tobytes())
    return output.getvalue()


def tone(freq, seconds=6.0, rate=16000, amplitude=0.3, noise=0.01, seed=1):
    """Синус заданной частоты с небольшим шумом."""
    moments = np.arange(int(rate * seconds)) / rate
    return amplitude * np.sin(2 * np.pi * freq * moments) + noise * np.random.default_rng(seed).standard_normal(moments.size)


def knocks(seconds=6.0, rate=16000, period=0.1):
    """Тихий шум с короткими ударами через равные промежутки - стук."""
    samples = 0.01 * np.random.default_rng(2).standard_normal(int(rate * seconds))
    samples[::int(rate * period)] += 0.9
    return samples


def white(seconds=6.0, rate=16000, amplitude=0.2):
    """Белый шум - широкополосный, с большой долей энергии выше 2 кГц."""
    return amplitude * np.random.default_rng(3).standard_normal(int(rate * seconds))


def upload(client, auth_headers, inspection_id, data, normal=False):
    """Отправляет запись звука осмотра."""
    return client.post(f"/inspections/{inspection_id}/sound", headers=auth_headers,
                       files={"audio": ("rec.wav", data, "audio/wav")}, data={"normal": str(normal).lower()})


def test_sound_analysis_of_synthetic_signals():
    """Тон на 2x частоты вращения, стук и белый шум дают свои признаки-кандидаты с пояснением."""
    samples, rate = sound.read_wav(wav(tone(2 * SHAFT_HZ)))
    measures = sound.analyse(samples, rate, rpm=CALM["rpm"])
    assert measures["peaks"][0]["match"] == "2x" and abs(measures["peaks"][0]["freq_hz"] - 2 * SHAFT_HZ) < 1.0
    assert measures["kurtosis"] < 2 and measures["crest_factor"] < 2
    texts = [entry["text"] for entry in sound.candidates(measures, sound.baseline_level(None, [measures["level_dbfs"]]))]
    assert texts == [f"Тональная составляющая {round(2 * SHAFT_HZ)} Гц ≈ 2× частоты вращения"]
    measures = sound.analyse(*sound.read_wav(wav(knocks())), rpm=CALM["rpm"])
    signs = {entry["sign"] for entry in sound.candidates(measures, sound.baseline_level(None, [measures["level_dbfs"]]))}
    assert "noise_impulsive" in signs and measures["crest_factor"] > 6 and measures["kurtosis"] > 6
    measures = sound.analyse(*sound.read_wav(wav(white())))
    found = sound.candidates(measures, sound.baseline_level(None, [measures["level_dbfs"]]))
    assert [entry["sign"] for entry in found] == ["cavitation_noise"] and measures["hf_flatness"] > 0.5
    shares = {band["code"]: band["share"] for band in measures["bands"]}
    assert abs(sum(shares.values()) - 1.0) < 0.01 and shares["high"] > 0.6
    louder = sound.candidates(measures, sound.baseline_level(None, [measures["level_dbfs"] - 8.0]))
    assert louder[0]["text"] == "Повышенный шум относительно прошлых осмотров +8 дБ"
    default = sound.baseline_level("inline_centrifugal_pump", [])
    assert default["source"] == "model_default" and default["dbfs"] == -32.0
    stereo = sound.read_wav(wav(np.repeat(tone(100.0), 2), channels=2))
    assert stereo[1] == 16000 and stereo[0].size == 96000


@pytest.mark.parametrize(("data", "text"), [
    (b"not a wav file", "не является записью WAV"),
    (wav(tone(100.0), width=1), "16 бит"),
    (wav(tone(100.0, seconds=1.0)), "Длительность"),
    (wav(tone(100.0, rate=8000), rate=8000), "Частота дискретизации"),
    (wav(np.zeros(32000)), None),
])
def test_sound_rejects_bad_records(data, text):
    """Не WAV, не 16 бит, короче 2 с, частота ниже 16 кГц и тишина отклоняются с понятным текстом."""
    with pytest.raises(sound.SoundError) as error:
        sound.analyse(*sound.read_wav(data))
    if text:
        assert text in str(error.value)


def test_sound_endpoint_stores_record_and_candidates(client):
    """Запись звука сохраняется с анализом и файлом; кандидаты не становятся замечаниями; норма задаёт уровень."""
    engineer = headers(client, "engineer")
    inspection_id = start(client, engineer)
    quiet = upload(client, engineer, inspection_id, wav(tone(2 * SHAFT_HZ, amplitude=0.005, noise=0.0005)), normal=True)
    assert quiet.status_code == 201, quiet.text
    first = quiet.json()
    assert first["normal"] is True and first["baseline"]["source"] == "model_default"
    assert first["rpm"] == CALM["rpm"] and first["rpm_source"] == "telemetry"
    assert any(entry["sign"] == "noise_tonal" for entry in first["candidates"])
    assert first["audio_url"] == f"/inspections/sound/{first['id']}/audio" and len(first["spectrum"]) > 50
    loud = upload(client, engineer, inspection_id, wav(knocks())).json()
    assert loud["baseline"]["source"] == "recordings" and loud["baseline"]["delta_db"] > 6
    signs = {entry["sign"] for entry in loud["candidates"]}
    assert {"noise_high", "noise_impulsive"} <= signs
    assert loud["candidates"][0]["confirm"]["kind"] == "defect"
    listed = client.get(f"/inspections/{inspection_id}/sound", headers=engineer).json()
    assert [entry["id"] for entry in listed] == [first["id"], loud["id"]]
    audio = client.get(first["audio_url"], headers=engineer)
    assert audio.status_code == 200 and audio.content[:4] == b"RIFF"
    assert client.get(f"/inspections/{inspection_id}", headers=engineer).json()["findings"] == []
    assert upload(client, engineer, inspection_id, b"junk").status_code == 422
    assert upload(client, headers(client, "operator"), inspection_id, wav(white())).status_code == 403
    confirmed = client.post(f"/inspections/{inspection_id}/findings", headers=engineer,
                            data={"kind": "defect", "sign": "noise_impulsive"})
    assert confirmed.status_code == 201, confirmed.text
    assert confirmed.json()["rule_id"] == "N01" and confirmed.json()["status"] == "check"
    rule = client.get(f"/equipment/N-101/rules/N01?inspection_id={inspection_id}", headers=engineer).json()
    assert rule["status"] == "check" and rule["parts"][0]["source_title"] == "Звук"
    finished = client.post(f"/inspections/{inspection_id}/finish", headers=engineer).json()
    assert finished["summary"]["sound"]["id"] == loud["id"]
    assert upload(client, engineer, inspection_id, wav(white())).status_code == 409


def test_new_equipment_types_and_rules(client):
    """Шкаф управления и трансформатор есть в реестре с узлами, нормативами и своими правилами."""
    engineer = headers(client, "engineer")
    cabinet = client.get("/equipment/SHU-3", headers=engineer).json()
    assert cabinet["type"] == "control_cabinet" and cabinet["serial"] == "2408-0317" and cabinet["demo"] is True
    assert {node["id"] for node in cabinet["nodes"]} == {"door_seal", "terminals", "contactors", "breakers", "indicators",
                                                         "cable_entries", "vent_filter"}
    transformer = client.get("/equipment/TR-1", headers=engineer).json()
    assert transformer["model"] == "ТМ-400/10-У1" and len(transformer["nodes"]) == 7
    assert all(node["source"] and (node["norm_hours"] or node["norm_years"]) for node in transformer["nodes"])
    catalogue = {item["id"]: item for item in client.get("/rules", headers=engineer).json()}
    assert catalogue["T01"]["applies_to"] == ["power_transformer"] and catalogue["T01"]["source"]["demo"] is True
    assert [sign["code"] for sign in catalogue["N01"]["sound"]["signs"]] == ["noise_high", "noise_impulsive", "noise_tonal"]
    other = client.get("/equipment/TR-1/rules/R01", headers=engineer).json()
    assert other["applies"] is False and other["status"] == "not_applicable"
    oil = client.get("/equipment/TR-1/rules/T02", headers=engineer).json()
    assert oil["applies"] is True and oil["status"] == "unknown" and oil["conditions"][0]["param"] == "temp_oil"
    inspection_id = start(client, engineer, "SHU-3")
    burnt = defect(client, engineer, inspection_id, sign="terminal_burn", node="terminals")
    assert burnt["rule_id"] == "C02" and burnt["status"] == "defect" and burnt["severity"] == 2
    leak_id = start(client, engineer, "TR-1")
    leak = defect(client, engineer, leak_id, sign="oil_leak", node="tank")
    assert leak["rule_id"] == "T01" and leak["status"] == "defect"


def test_report_has_new_sections(client):
    """Отчёт: способ опознания, обход узлов, датчики с рядами, звук, рекомендации, подписи; PDF и Excel собираются."""
    engineer, master = headers(client, "engineer"), headers(client, "master")
    response = client.post("/inspections", json={"equipment_id": "N-101", "identified_by": "nameplate"}, headers=engineer)
    inspection_id = response.json()["id"]
    assert response.json()["identified_by"] == "nameplate" and response.json()["identified_title"] == "По шильдику"
    upload(client, engineer, inspection_id, wav(tone(2 * SHAFT_HZ)))
    kept = defect(client, engineer, inspection_id)
    false = defect(client, engineer, inspection_id, sign="corrosion", node="casing")
    client.post(f"/inspections/findings/{false['id']}/state", json={"state": "rejected", "comment": "тень"}, headers=master)
    client.post(f"/inspections/{inspection_id}/finish", headers=engineer)
    with db.SessionLocal() as session:
        data = service.report_data(session, service.get_inspection(session, inspection_id))
    assert data["identified"] == {"code": "nameplate", "title": "По шильдику"}
    assert {row["code"] for row in data["walk"]} >= {"seal", "casing"}
    assert next(row for row in data["walk"] if row["code"] == "seal")["inspected"] is True
    assert data["sensors"]["available"] is True and len(data["sensors"]["series"]["24h"]["codes"]["vib_hf"]) == 25
    assert data["sensors"]["current"][0]["code"] == "vib_rms"
    assert data["sound"][0]["peaks"][0]["match"] == "2x"
    assert data["recommendations"][0]["finding_id"] == kept["id"]
    assert data["next_maintenance"]["name"] and [entry["role"] for entry in data["signatures"]] == ["Инженер", "Мастер"]
    assert data["signatures"][1]["name"] == "Марина Орлова"
    assert [view["id"] for view in data["rejected"]] == [false["id"]]
    pdf = build_pdf(data)
    assert pdf.startswith(b"%PDF") and len(pdf) > 20000
    book = load_workbook(io.BytesIO(build_xlsx(data)))
    assert {"Обход узлов", "Датчики", "Звук", "Рекомендации", "Отклонено инженером"} <= set(book.sheetnames)
    summary = {row[0].value: row[1].value for row in book["Осмотр"].iter_rows() if row[0].value}
    assert summary["Опознание агрегата"] == "По шильдику"
    sound_text = " ".join(str(cell.value) for row in book["Звук"].iter_rows() for cell in row if cell.value)
    assert "2× частоты вращения" in sound_text
    empty = dict(data, sensors={"available": False, "reason": "Для этого оборудования нет телеметрии"}, sound=[])
    assert build_pdf(empty).startswith(b"%PDF")


def test_seed_refreshes_detector_classes(seeded_database, tmp_path, monkeypatch):
    """Повторное наполнение базы возвращает узлу перечень классов детектора из карточки, остальное не трогает."""
    path = tmp_path / "kst.db"
    shutil.copyfile(seeded_database, path)
    monkeypatch.setenv("KST_DB", str(path))
    try:
        db.init_db()
        with db.SessionLocal() as session:
            node = session.query(Node).filter_by(equipment_id="N-101", code="seal").one()
            node.data = {**node.data, "classes": ["something_else"]}
            node.hours = 123.0
            session.commit()
            seeding.seed(session)
            session.refresh(node)
            assert node.data["classes"] == ["leak"] and node.hours == 123.0
    finally:
        db.engine.dispose()


def test_live_panel_sources(client):
    """Панель видит в реальном времени: вход по биометрии в журнале безопасности, решения и звук в журнале событий."""
    login = client.post("/auth/login", json={"email": "engineer@kst.demo", "password": PASSWORD}).json()
    again = client.post("/auth/refresh", json={"refresh_token": login["refresh_token"], "biometric": True})
    assert again.status_code == 200, again.text
    plain = client.post("/auth/refresh", json={"refresh_token": again.json()["refresh_token"]})
    assert plain.status_code == 200
    log = client.get("/admin/security-log?limit=20", headers=headers(client, "security")).json()
    biometric = [row for row in log if row["event"] == "login_biometric"]
    assert len(biometric) == 1 and biometric[0]["title"] == "Вход по биометрии"
    engineer, master = headers(client, "engineer"), headers(client, "master")
    inspection_id = start(client, engineer)
    upload(client, engineer, inspection_id, wav(tone(2 * SHAFT_HZ)))
    finding = defect(client, engineer, inspection_id)
    client.post(f"/inspections/findings/{finding['id']}/state", json={"state": "rejected", "comment": "блик"}, headers=master)
    events = client.get("/webadmin/events?limit=50", headers=headers(client, "admin")).json()
    titles = [row["title"] for row in events]
    assert any(title.startswith(f"Находка отклонена · № {finding['id']}") for title in titles)
    assert any(row["kind"] == "sound" and f"осмотр № {inspection_id}" in row["title"] for row in events)
    assert [row["at"] for row in events] == sorted((row["at"] for row in events), reverse=True)
    recent = client.get("/inspections/sound/recent?limit=5", headers=master).json()
    assert recent[0]["inspection_id"] == inspection_id and recent[0]["candidates"]
    assert client.get("/inspections/sound/recent", headers=headers(client, "security")).status_code == 403
