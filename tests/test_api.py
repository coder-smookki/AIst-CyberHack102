"""Сквозные проверки сервера: вход, шильдик, карточка, телеметрия, осмотр по WebSocket, отчёты и помощник.

Детектор, распознаватель текста и чтение манометра подменяются, поэтому проверки идут без файлов моделей.
"""
import io
import json
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image
from starlette.websockets import WebSocketDisconnect

from server import auth, db, recognition
from server import seed as seeding
from server.app import create_app
from server.inspections import service
from server.models import User
from server.telemetry import TelemetryDataError, get_player

FRAME_W, FRAME_H = 640, 480
PASSWORD = "demo12345"
PLATE_LINES = [{"text": "НАСОС IL 65/160-5,5/2", "score": 0.93}, {"text": "Зав. № 2786107-0142", "score": 0.91}]


def jpeg(size=(FRAME_W, FRAME_H), color=(90, 120, 150)) -> bytes:
    """Кадр камеры в формате JPEG."""
    output = io.BytesIO()
    Image.new("RGB", size, color).save(output, "JPEG")
    return output.getvalue()


def box(cls, conf=0.8, share=0.05):
    """Рамка детектора заданного класса, занимающая указанную долю площади кадра."""
    side = (share * FRAME_W * FRAME_H) ** 0.5
    return {"cls": cls, "conf": conf, "x1": 20.0, "y1": 20.0, "x2": 20.0 + side, "y2": 20.0 + side}


class FakeDetector:
    """Подменный детектор: на каждый кадр возвращает заранее заданные рамки и считает вызовы."""

    def __init__(self):
        """Начинает с пустого списка рамок."""
        self.boxes = []
        self.calls = 0

    def detect(self, frame):
        """Возвращает заданные рамки; размер кадра проверяется, чтобы убедиться, что кадр декодирован."""
        assert frame.shape[:2] == (FRAME_H, FRAME_W)
        self.calls += 1
        return [dict(item) for item in self.boxes]


def customer_data_available() -> bool:
    """Проверяет, что базы заказчика на месте и телеметрия N-101 строится."""
    try:
        get_player("N-101")
    except (KeyError, TelemetryDataError):
        return False
    return True


needs_telemetry = pytest.mark.skipif(not customer_data_available(), reason="нет баз заказчика в data/customer")


@pytest.fixture(scope="module")
def server(tmp_path_factory):
    """Сервер на временной базе с подменным детектором; курсор телеметрии восстанавливается после проверок."""
    path = tmp_path_factory.mktemp("api") / "kst.db"
    player = get_player("N-101") if customer_data_available() else None
    cursor = player.cursor if player else None
    detector = FakeDetector()
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("KST_DB", str(path))
        patch.setenv("KST_SECRET", "s" * 48)
        patch.setattr(auth, "SCRYPT_N", 2**10)
        seeding._demo_hash.cache_clear()
        with TestClient(create_app(detector)) as client:
            with db.SessionLocal() as session:
                session.add(User(email="second@kst.demo", name="Пётр Иванов", role="engineer",
                                 password_hash=auth.hash_password(PASSWORD)))
                session.commit()
            yield client, detector
        service._live.clear()
        seeding._demo_hash.cache_clear()
        db.engine.dispose()
    if player:
        player.set_cursor(cursor)


def login(client, email):
    """Входит под указанной почтой и возвращает заголовок авторизации и токен доступа."""
    response = client.post("/auth/login", json={"email": email, "password": PASSWORD})
    assert response.status_code == 200, response.text
    token = response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}, token


def closed_with(socket) -> tuple[dict, int]:
    """Читает сообщение о закрытии и код закрытия соединения сервером."""
    message = socket.receive_json()
    with pytest.raises(WebSocketDisconnect) as closed:
        socket.receive_json()
    return message, closed.value.code


def test_health_without_login(server):
    """Проверка готовности отвечает без входа: база доступна, три агрегата, детектор готов."""
    client, _ = server
    body = client.get("/health").json()
    assert body["ok"] is True and body["database"] == "ok" and body["equipment"] == 3
    assert body["detector"]["ready"] is True


def test_docs_are_disabled_and_panel_is_served(server):
    """Страницы документации отключены (они тянут файлы из интернета), пульт раздаётся по /panel/."""
    client, _ = server
    assert client.get("/docs").status_code == 404 and client.get("/redoc").status_code == 404
    moved = client.get("/panel", follow_redirects=False)
    assert moved.status_code in (302, 307) and moved.headers["location"] == "/panel/"
    page = client.get("/panel/")
    assert page.status_code == 200 and "text/html" in page.headers["content-type"]
    assert client.get("/panel/panel.js").status_code == 200
    assert client.get("/", follow_redirects=False).headers["location"] == "/panel/"


def test_routes_require_login(server):
    """Данные оборудования, телеметрия, осмотры, помощник и распознавание закрыты без токена."""
    client, _ = server
    for method, url in (("get", "/equipment"), ("get", "/equipment/N-101/telemetry"), ("get", "/inspections"),
                        ("post", "/assistant/ask"), ("post", "/recognize/nameplate"), ("post", "/recognize/gauge")):
        assert getattr(client, method)(url).status_code == 401, url


@needs_telemetry
def test_inspection_end_to_end(server, monkeypatch):
    """Полный путь инженера: шильдик, карточка, телеметрия сценария, осмотр с кадрами, запись, итог, отчёты, помощник."""
    client, detector = server
    engineer, token = login(client, "engineer@kst.demo")
    master, _ = login(client, "master@kst.demo")

    monkeypatch.setattr(recognition, "read_text", lambda frame: PLATE_LINES)
    plate = client.post("/recognize/nameplate", headers=engineer, files={"frame": ("plate.jpg", jpeg(), "image/jpeg")})
    assert plate.status_code == 200, plate.text
    plate = plate.json()
    assert plate["found"] is True and plate["match"]["equipment_id"] == "N-101" and plate["match"]["by"] == "serial"
    assert plate["fields"]["serial"] == "2786107-0142"

    unit = client.get("/equipment/N-101", headers=engineer).json()
    assert unit["serial"] == "2786107-0142" and {node["id"] for node in unit["nodes"]} >= {"seal", "motor", "casing"}

    assert client.post("/equipment/N-101/scenarios/bearing_wear", headers=engineer).status_code == 403
    chosen = client.post("/equipment/N-101/scenarios/bearing_wear", headers=master)
    assert chosen.status_code == 200 and chosen.json()["at"] == "2026-11-27T19:00:00"

    telemetry = client.get("/equipment/N-101/telemetry", headers=engineer).json()
    assert telemetry["available"] is True and telemetry["at"] == "2026-11-27T19:00:00"
    levels = {entry["code"]: entry for entry in telemetry["parameters"]}
    assert levels["vib_hf"]["level"] == "alarm" and levels["vib_hf"]["source"] == "customer"
    assert levels["temp_bearing"]["level"] == "alarm"
    assert telemetry["labels"]["vibration"] == {"text": "Тревога: Дефект подшипника", "source": "customer"}

    chart = client.get("/equipment/N-101/telemetry/vib_hf?hours=24", headers=engineer).json()
    assert len(chart["points"]) == 24 and chart["points"][-1]["v"] == levels["vib_hf"]["value"]

    sensors = client.get("/equipment/N-101/diagnosis", headers=engineer).json()
    assert sensors["status"] == "defect"
    by_rule = {found["rule_id"]: found for found in sensors["findings"]}
    assert {"R08", "R01"} <= set(by_rule)
    assert by_rule["R01"]["status"] == "check" and by_rule["R01"]["missing"]
    assert any(item["source"] == "sensor" and item["met"] for item in by_rule["R08"]["evidence"])
    assert sensors["nodes"]["casing"]["status"] == "unknown"

    route = client.get("/equipment/N-101/route", headers=engineer).json()
    assert route[0]["group"] in ("previous_finding", "sensor")
    assert {entry["code"] for entry in route} == {node["id"] for node in unit["nodes"]}

    started = client.post("/inspections", headers=engineer, json={"equipment_id": "N-101"})
    assert started.status_code == 201, started.text
    inspection_id = started.json()["id"]

    with client.websocket_connect(f"/ws/inspect/{inspection_id}?token={token}") as socket:
        first = socket.receive_json()
        assert first["type"] == "state" and first["coverage"]["inspected"] == 0 and first["boxes"] == []
        assert first["diagnosis_changed"] is True
        assert "R01" in {found["rule_id"] for found in first["findings"]}

        detector.boxes = [box("motor", 0.9, 0.05)]
        replies = []
        for _ in range(3):
            socket.send_bytes(jpeg())
            replies.append(socket.receive_json())
        assert replies[-1]["type"] == "frame" and replies[-1]["w"] == FRAME_W and replies[-1]["h"] == FRAME_H
        assert replies[-1]["boxes"][0] == {**box("motor", 0.9, 0.05), "status": "ok", "node": "motor"}
        assert replies[-1]["coverage"]["nodes"]["motor"]["inspected"] is True
        assert replies[-1]["diagnosis_changed"] is False
        assert replies[-1]["nodes"]["motor"]["status"] == "ok"
        assert replies[-1]["nodes"]["casing"]["status"] == "unknown"

        detector.boxes = [box("leak", 0.82, 0.03), box("pump_casing", 0.3, 0.2)]
        socket.send_bytes(jpeg())
        leak = socket.receive_json()
        statuses = {item["cls"]: (item["status"], item["node"]) for item in leak["boxes"]}
        assert statuses == {"leak": ("defect", "seal"), "pump_casing": ("unsure", "casing")}
        assert leak["diagnosis_changed"] is True
        r01 = next(found for found in leak["findings"] if found["rule_id"] == "R01")
        assert r01["status"] == "defect"
        assert any(item["source"] == "camera" and item["met"] for item in r01["evidence"])

        socket.send_text("ping")
        assert socket.receive_json() == {"type": "pong"}
        socket.send_text("что-то ещё")
        assert socket.receive_json()["status"] == 415
        socket.send_bytes(b"not a jpeg")
        assert socket.receive_json() == {"type": "error", "status": 415, "detail": "Кадр должен быть в формате JPEG"}
        socket.send_text("state")
        again = socket.receive_json()
        assert again["type"] == "state" and again["diagnosis_changed"] is False

    other, other_token = login(client, "second@kst.demo")
    with client.websocket_connect(f"/ws/inspect/{inspection_id}?token={other_token}") as socket:
        message, code = closed_with(socket)
        assert code == 4403 and message["type"] == "closed"

    with client.websocket_connect(f"/ws/inspect/{inspection_id}?token={token}") as socket:
        resumed = socket.receive_json()
        assert resumed["coverage"]["nodes"]["motor"]["inspected"] is True
        assert resumed["coverage"]["visual"]["leak"] == 0.82

    live = client.get(f"/equipment/N-101/diagnosis?inspection_id={inspection_id}", headers=engineer).json()
    assert next(found for found in live["findings"] if found["rule_id"] == "R01")["status"] == "defect"
    assert live["nodes"]["motor"]["status"] == "ok" and live["nodes"]["casing"]["status"] == "unknown"

    gauge = {"ok": True, "value": 6.2, "reason": None, "angle_deg": 32.4, "contrast": 90.0}
    monkeypatch.setattr(recognition, "read_gauge", lambda frame, scale: dict(gauge))
    read = client.post("/recognize/gauge", headers=engineer, files={"frame": ("gauge.jpg", jpeg(), "image/jpeg")},
                       data={"equipment_id": "N-101", "inspection_id": str(inspection_id)})
    assert read.status_code == 200, read.text
    read = read.json()
    assert read["value"] == 6.2 and read["sensor_value"] == levels["press_out"]["value"]
    assert read["difference_percent"] == round(abs(6.2 - read["sensor_value"]) / 6.2 * 100, 1)
    assert read["exceeds"] is True and read["finding"]["rule_id"] == "R05"
    gauge.update(ok=False, value=None, reason="Манометр не прочитан: циферблат не найден")
    unsure = client.post("/recognize/gauge", headers=engineer, files={"frame": ("gauge.jpg", jpeg(), "image/jpeg")},
                         data={"equipment_id": "N-101"}).json()
    assert unsure["ok"] is False and unsure["value"] is None and unsure["exceeds"] is None and unsure["finding"] is None

    added = client.post(f"/inspections/{inspection_id}/findings", headers=engineer,
                        data={"kind": "defect", "node": "seal", "sign": "leak", "comment": "Капает под валом"},
                        files={"frame": ("leak.jpg", jpeg(), "image/jpeg")})
    assert added.status_code == 201, added.text
    assert added.json()["rule_id"] == "R01" and added.json()["has_photo"] is True

    finished = client.post(f"/inspections/{inspection_id}/finish", headers=engineer)
    assert finished.status_code == 200, finished.text
    summary = finished.json()["summary"]
    assert summary["status"] == "defect" and summary["by_status"]["defect"] >= 2
    rules = {found["rule_id"] for found in finished.json()["findings"]}
    assert {"R01", "R05", "R08"} <= rules

    with client.websocket_connect(f"/ws/inspect/{inspection_id}?token={token}") as socket:
        message, code = closed_with(socket)
        assert code == 4409 and "завершён" in message["detail"]

    history = client.get("/equipment/N-101/history", headers=engineer).json()
    assert history[0]["type"] == "inspection" and history[0]["id"] == inspection_id

    pdf = client.get(f"/inspections/{inspection_id}/report.pdf", headers=engineer)
    if pdf.status_code == 503:
        pytest.skip("на машине нет шрифта с кириллицей для PDF")
    assert pdf.status_code == 200 and pdf.content.startswith(b"%PDF")
    xlsx = client.get(f"/inspections/{inspection_id}/report.xlsx", headers=engineer)
    assert xlsx.status_code == 200 and xlsx.content.startswith(b"PK")

    reply = client.post("/assistant/ask", headers=engineer,
                        json={"question": "Какие открытые замечания по уплотнению?", "equipment_id": "N-101"})
    assert reply.status_code == 200, reply.text
    reply = reply.json()
    assert reply["mode"] == "search" and reply["answer"]
    assert reply["links"] and all(link["deeplink"].startswith("kstvizor://") for link in reply["links"])
    assert any(link["kind"] == "finding" for link in reply["links"])


def test_websocket_requires_token(server):
    """Без токена или с негодным токеном соединения закрываются с кодом 4401, детектор не вызывается."""
    client, detector = server
    calls = detector.calls
    for url in ("/ws/detect", "/ws/detect?token=bad", "/ws/inspect/1", "/ws/inspect/1?token=bad"):
        with client.websocket_connect(url) as socket:
            message, code = closed_with(socket)
            assert code == 4401 and message["type"] == "closed", url
    assert detector.calls == calls


def test_inspect_unknown_inspection(server):
    """Несуществующий осмотр закрывает соединение с кодом 4404."""
    client, _ = server
    _, token = login(client, "engineer@kst.demo")
    with client.websocket_connect(f"/ws/inspect/999999?token={token}") as socket:
        assert closed_with(socket)[1] == 4404


def test_detect_stream(server):
    """Поток без осмотра: рамки со статусом, слабый дефект - «проверить», негодный кадр не рвёт соединение."""
    client, detector = server
    _, token = login(client, "engineer@kst.demo")
    detector.boxes = [box("corrosion", 0.3), box("motor", 0.7), box("flange", 0.1)]
    with client.websocket_connect(f"/ws/detect?token={token}") as socket:
        socket.send_bytes(jpeg())
        reply = socket.receive_json()
        assert reply["type"] == "frame" and (reply["w"], reply["h"]) == (FRAME_W, FRAME_H)
        assert [(item["cls"], item["status"]) for item in reply["boxes"]] == [("motor", "ok"), ("corrosion", "check")]
        socket.send_bytes(b"")
        assert socket.receive_json()["status"] == 422
        socket.send_bytes(jpeg())
        assert socket.receive_json()["type"] == "frame"


def test_logout_closes_running_stream(server):
    """После выхода из сеанса следующий кадр закрывает соединение кодом 4401."""
    client, detector = server
    headers, token = login(client, "engineer@kst.demo")
    detector.boxes = []
    with client.websocket_connect(f"/ws/detect?token={token}") as socket:
        socket.send_bytes(jpeg())
        assert socket.receive_json()["type"] == "frame"
        assert client.post("/auth/logout", headers=headers).status_code in (200, 204)
        socket.send_bytes(jpeg())
        assert closed_with(socket)[1] == 4401


def test_unit_without_telemetry_and_gauge(server):
    """Агрегат без телеметрии: телеметрия недоступна с причиной, маршрут и ресурс есть, манометра в карточке нет."""
    client, _ = server
    headers, _ = login(client, "engineer@kst.demo")
    telemetry = client.get("/equipment/AMS-1/telemetry", headers=headers).json()
    assert telemetry["available"] is False and telemetry["reason"]
    assert client.get("/equipment/AMS-1/scenarios", headers=headers).status_code == 404
    assert client.get("/equipment/AMS-1/route", headers=headers).status_code == 200
    resource = client.get("/equipment/AMS-1/resource", headers=headers).json()
    assert resource["telemetry"] is False and resource["nodes"]
    gauge = client.post("/recognize/gauge", headers=headers, files={"frame": ("g.jpg", jpeg(), "image/jpeg")},
                        data={"equipment_id": "AMS-1"})
    assert gauge.status_code == 422
    missing = client.post("/recognize/gauge", headers=headers, files={"frame": ("g.jpg", jpeg(), "image/jpeg")},
                          data={"equipment_id": "X-999"})
    assert missing.status_code == 404


def test_recognize_rejects_bad_frames(server, monkeypatch):
    """Распознавание шильдика отклоняет не JPEG и пустой кадр; без совпадения предлагает ввести номер вручную."""
    client, _ = server
    headers, _ = login(client, "engineer@kst.demo")
    png = io.BytesIO()
    Image.new("RGB", (20, 20)).save(png, "PNG")
    answer = client.post("/recognize/nameplate", headers=headers, files={"frame": ("p.png", png.getvalue(), "image/png")})
    assert answer.status_code == 415
    assert client.post("/recognize/nameplate", headers=headers, files={"frame": ("p.jpg", b"", "image/jpeg")}).status_code == 422
    monkeypatch.setattr(recognition, "read_text", lambda frame: [{"text": "PCP60S12/3", "score": 0.8}])
    unknown = client.post("/recognize/nameplate", headers=headers, files={"frame": ("p.jpg", jpeg(), "image/jpeg")}).json()
    assert unknown["found"] is False and unknown["match"] is None
    monkeypatch.setattr(recognition, "read_text", lambda frame: [{"text": "XYZ", "score": 0.8}])
    nothing = client.post("/recognize/nameplate", headers=headers, files={"frame": ("p.jpg", jpeg(), "image/jpeg")}).json()
    assert nothing["found"] is False and nothing["candidates"] == [] and "вручную" in nothing["message"]


def test_app_starts_without_model_files(tmp_path, monkeypatch):
    """Без файлов модели сервер запускается, готовность сообщает причину, кадр получает ошибку 503."""
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    monkeypatch.setenv("KST_SECRET", "m" * 48)
    monkeypatch.setattr(auth, "SCRYPT_N", 2**10)
    seeding._demo_hash.cache_clear()
    try:
        with TestClient(create_app(recognition.Detector(tmp_path / "models"))) as client:
            health = client.get("/health").json()
            assert health["ok"] is True and health["detector"]["ready"] is False
            assert health["detector"]["missing"] == ["detector.onnx"]
            _, token = login(client, "engineer@kst.demo")
            with client.websocket_connect(f"/ws/detect?token={token}") as socket:
                socket.send_bytes(jpeg())
                reply = socket.receive_json()
                assert reply["type"] == "error" and reply["status"] == 503 and "detector.onnx" in reply["detail"]
    finally:
        seeding._demo_hash.cache_clear()
        db.engine.dispose()


class FakeResult:
    """Ответ модели в виде, который возвращает библиотека детектора: рамки, классы и уверенности."""

    def __init__(self, rows, names):
        """Запоминает строки (x1, y1, x2, y2, номер класса, уверенность) и названия классов."""
        self.names = names
        self.boxes = type("Boxes", (), {
            "xyxy": np.array([row[:4] for row in rows], dtype=float).reshape(-1, 4),
            "cls": np.array([row[4] for row in rows]), "conf": np.array([row[5] for row in rows])})()


def write_manifest(folder: Path, document) -> None:
    """Записывает описание моделей и пустые файлы перечисленных моделей."""
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "models.json").write_text(json.dumps(document), encoding="utf-8")


def test_detector_merges_models_from_manifest(tmp_path):
    """По models.json загружаются все модели, рамки одного класса объединяются, дефектные классы берутся из описания."""
    folder = tmp_path / "models"
    write_manifest(folder, [{"file": "stand.onnx", "defect_classes": ["leak"]},
                            {"file": "defects.onnx", "defect_classes": ["damage"]}, {"file": "../escape.onnx"}])
    for name in ("stand.onnx", "defects.onnx"):
        (folder / name).write_bytes(b"x")
    outputs = {
        "stand.onnx": FakeResult([(10, 10, 110, 110, 0, 0.6), (300, 300, 400, 400, 1, 0.9)], {0: "leak", 1: "motor"}),
        "defects.onnx": FakeResult([(12, 12, 112, 112, 0, 0.8), (500, 10, 600, 90, 1, 0.4)], {0: "leak", 1: "damage"}),
    }
    loaded = []

    def loader(path):
        """Подменная загрузка: модель - функция, возвращающая заготовленный ответ."""
        loaded.append(path.name)
        return lambda frame, conf: [outputs[path.name]]

    detector = recognition.Detector(folder, loader)
    assert detector.info()["models"] == ["stand.onnx", "defects.onnx"] and not detector.loaded
    boxes = detector.detect(np.zeros((480, 640, 3), np.uint8))
    assert loaded == ["stand.onnx", "defects.onnx"]
    assert [(item["cls"], item["conf"]) for item in boxes] == [("motor", 0.9), ("leak", 0.8), ("damage", 0.4)]
    assert {"leak", "damage"} <= recognition.defect_classes(detector)
    detector.detect(np.zeros((480, 640, 3), np.uint8))
    assert loaded == ["stand.onnx", "defects.onnx"]


def test_detector_falls_back_to_default_model(tmp_path):
    """Нечитаемое описание моделей - используется detector.onnx; без него детектор недоступен с понятной причиной."""
    folder = tmp_path / "models"
    folder.mkdir()
    (folder / "models.json").write_text("{не json", encoding="utf-8")
    detector = recognition.Detector(folder, lambda path: pytest.fail("загрузка без файла модели"))
    assert detector.available is False and "не читается" in detector.info()["note"]
    with pytest.raises(recognition.DetectorUnavailable):
        detector.detect(np.zeros((10, 10, 3), np.uint8))
    (folder / "detector.onnx").write_bytes(b"x")
    broken = recognition.Detector(folder, lambda path: (_ for _ in ()).throw(RuntimeError("bad")))
    with pytest.raises(recognition.DetectorUnavailable):
        broken.detect(np.zeros((10, 10, 3), np.uint8))
    assert broken.info()["ready"] is False and "не загрузилась" in broken.info()["note"]


def test_box_status_thresholds():
    """Статус рамки: дефект от 0,5 - defect, ниже - check; обычный узел от 0,5 - ok, ниже - unsure."""
    defects = {"leak"}
    assert recognition.box_status("leak", 0.5, defects) == "defect"
    assert recognition.box_status("leak", 0.49, defects) == "check"
    assert recognition.box_status("motor", 0.5, defects) == "ok"
    assert recognition.box_status("motor", 0.3, defects) == "unsure"


def test_decode_frame_limits():
    """Кадр больше 8 МБ отклоняется с кодом 413, повреждённый JPEG - с кодом 422."""
    with pytest.raises(recognition.FrameError) as large:
        recognition.decode_frame(b"\xff\xd8" + b"0" * recognition.MAX_FRAME_BYTES)
    assert large.value.status == 413
    with pytest.raises(recognition.FrameError) as broken:
        recognition.decode_frame(b"\xff\xd8\xff\xe0broken")
    assert broken.value.status == 422
    assert recognition.decode_frame(jpeg()).shape == (FRAME_H, FRAME_W, 3)
