"""Проверки осмотров: полнота обхода по кадрам, фиксация результатов, завершение, замечания, маршрут и отчёты."""

import io
import shutil
from datetime import date, datetime
from importlib import import_module

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import func, select

from server import auth, db
from server import seed as seeding
from server.inspections import CoverageTracker, node_route, router, service, static_priority
from server.inspections.coverage import ALL_DONE_HINT, NOTHING_TO_TRACK_HINT
from server.models import Equipment, Finding, Inspection, MaintenanceRecord, User
from server.seed import load_cards, seed

FRAME_W, FRAME_H = 1280, 720
XLSX_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
CALM = {
    "rpm": 2950.0,
    "vib_rms": 1.0,
    "vib_1x": 0.8,
    "vib_2x": 0.3,
    "vib_hf": 0.1,
    "vib_axial": 0.45,
    "temp_bearing": 50.0,
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


def card(equipment_id="N-101"):
    """Карточка оборудования из data/equipment.json."""
    return next(entry for entry in load_cards() if entry["id"] == equipment_id)


def box(cls, conf=0.8, share=0.03):
    """Рамка детектора заданного класса, занимающая указанную долю площади кадра."""
    side = (share * FRAME_W * FRAME_H) ** 0.5
    return {"cls": cls, "conf": conf, "x1": 100.0, "y1": 100.0, "x2": 100.0 + side, "y2": 100.0 + side}


def show(tracker, frames, *boxes):
    """Подаёт счётчику один и тот же кадр несколько раз и возвращает последнее состояние."""
    state = tracker.state()
    for _ in range(frames):
        state = tracker.observe(list(boxes), FRAME_W, FRAME_H)
    return state


def jpeg(size=(640, 480), color=(90, 120, 150)):
    """Стоп-кадр камеры в формате JPEG."""
    output = io.BytesIO()
    Image.new("RGB", size, color).save(output, "JPEG")
    return output.getvalue()


class FakePlayer:
    """Подмена проигрывателя телеметрии: заданные показания и тренды на заданный момент."""

    def __init__(self, readings, trends=None, cursor=datetime(2026, 11, 20, 12, 0)):
        """Запоминает показания, тренды и момент ленты."""
        self.readings, self.trends, self.cursor = dict(readings), dict(trends or {}), cursor

    def snapshot(self, at=None):
        """Показания на момент курсора."""
        return dict(self.readings)

    def trend(self, code, hours=12, at=None):
        """Наклон параметра за час или None, если тренд не задан."""
        return self.trends.get(code)


def test_node_becomes_inspected_after_five_counted_frames():
    """Узел осмотрен после пяти кадров с уверенностью от 0,5 и площадью рамки от 1,5 % кадра - не раньше."""
    tracker = CoverageTracker(card())
    state = show(tracker, 4, box("terminal_box", 0.8, 0.02))
    assert state["nodes"]["terminal_box"]["seen"] == 4
    assert state["nodes"]["terminal_box"]["inspected"] is False
    assert state["inspected"] == 0 and state["percent"] == 0
    state = show(tracker, 1, box("terminal_box", 0.8, 0.02))
    assert state["nodes"]["terminal_box"] == {**state["nodes"]["terminal_box"], "seen": 5, "inspected": True, "best_conf": 0.8}
    assert state["inspected"] == 1 and state["total"] == 7
    assert state["percent"] == round(100 / 7)


def test_three_close_frames_are_enough():
    """Трёх кадров с рамкой от 4 % кадра достаточно; двух - нет."""
    tracker = CoverageTracker(card())
    assert show(tracker, 2, box("motor", 0.6, 0.05))["nodes"]["motor"]["inspected"] is False
    state = show(tracker, 1, box("motor", 0.6, 0.05))
    assert state["nodes"]["motor"]["inspected"] is True
    assert state["nodes"]["motor"]["seen"] == 3 and state["nodes"]["motor"]["close"] == 3
    state = show(tracker, 4, box("gauge", 0.9, 0.039))
    assert state["nodes"]["gauge"]["inspected"] is False and state["nodes"]["gauge"]["close"] == 0
    assert show(tracker, 1, box("gauge", 0.9, 0.039))["nodes"]["gauge"]["inspected"] is True


def test_threshold_values_count():
    """Значения ровно на порогах засчитываются: уверенность 0,5, площадь 1,5 % и 4 %."""
    tracker = CoverageTracker(card())
    edge = {"cls": "flange", "conf": 0.5, "x1": 0, "y1": 0, "x2": FRAME_W * 0.15, "y2": FRAME_H * 0.1}
    assert show(tracker, 5, edge)["nodes"]["flanges"]["inspected"] is True
    close = {"cls": "gauge", "conf": 0.5, "x1": 0, "y1": 0, "x2": FRAME_W * 0.2, "y2": FRAME_H * 0.2}
    assert show(tracker, 3, close)["nodes"]["gauge"]["inspected"] is True


def test_small_boxes_do_not_count():
    """Мелкая рамка (меньше 1,5 % кадра) не засчитывается, сколько бы кадров ни прошло."""
    tracker = CoverageTracker(card())
    state = show(tracker, 40, box("terminal_box", 0.95, 0.014))
    node = state["nodes"]["terminal_box"]
    assert node["seen"] == 0 and node["inspected"] is False
    assert node["best_conf"] == 0.95
    assert state["percent"] == 0
    assert "Подойдите ближе" in show(CoverageTracker(card(), ["terminal_box"]), 3, box("terminal_box", 0.95, 0.014))["hint"]


def test_low_confidence_boxes_do_not_count():
    """Неуверенная рамка (ниже 0,5) не засчитывается даже крупным планом."""
    tracker = CoverageTracker(card(), ["motor"])
    state = show(tracker, 40, box("motor", 0.49, 0.3))
    assert state["nodes"]["motor"]["seen"] == 0 and state["nodes"]["motor"]["inspected"] is False
    assert state["percent"] == 0
    assert "с другой стороны" in state["hint"] and "Электродвигатель" in state["hint"]


def test_several_boxes_of_one_node_count_once_per_frame():
    """Несколько рамок одного узла в кадре дают один засчитанный кадр, лучшая уверенность берётся по всем рамкам."""
    tracker = CoverageTracker(card())
    state = show(tracker, 1, box("flange", 0.6, 0.02), box("flange", 0.9, 0.001), box("flange", 0.7, 0.03))
    assert state["nodes"]["flanges"]["seen"] == 1
    assert state["nodes"]["flanges"]["best_conf"] == 0.9
    assert state["frames"] == 1
    state = show(tracker, 1, box("terminal_box", 0.9, 0.03), box("terminal_box_burnt", 0.8, 0.02))
    assert state["nodes"]["terminal_box"]["seen"] == 1
    state = show(tracker, 1, box("pump_casing", 0.9, 0.2), box("corrosion", 0.7, 0.05), box("corrosion", 0.6, 0.05))
    assert state["nodes"]["casing"]["seen"] == 1 and state["nodes"]["casing"]["close"] == 1


def test_defect_evidence_is_sticky():
    """Дефект, уверенно увиденный с одной стороны, не снимается кадрами, где его не видно или он виден хуже."""
    tracker = CoverageTracker(card())
    state = show(tracker, 1, box("terminal_box_burnt", 0.82, 0.02))
    assert state["visual"]["terminal_box_burnt"] == 0.82
    assert state["nodes"]["terminal_box"]["defect_classes"] == {"terminal_box_burnt": 0.82}
    state = show(tracker, 30, box("terminal_box", 0.9, 0.05), box("motor", 0.9, 0.1))
    state = show(tracker, 3, box("terminal_box_burnt", 0.55, 0.02))
    state = show(tracker, 10)
    assert state["visual"]["terminal_box_burnt"] == 0.82
    assert state["nodes"]["terminal_box"]["defect_classes"] == {"terminal_box_burnt": 0.82}
    assert tracker.visual["terminal_box_burnt"] == 0.82
    assert state["nodes"]["motor"]["defect_classes"] == {}


def test_defect_on_small_box_is_remembered_but_node_is_not_inspected():
    """Уверенный дефект на мелкой рамке запоминается как признак, но узел осмотренным не считается."""
    tracker = CoverageTracker(card())
    state = show(tracker, 8, box("leak", 0.9, 0.004))
    assert state["visual"]["leak"] == 0.9
    assert state["nodes"]["seal"]["defect_classes"] == {"leak": 0.9}
    assert state["nodes"]["seal"]["inspected"] is False


def test_weak_defect_needs_repetition():
    """Слабый признак дефекта (0,25-0,5) принимается после повторения в трёх кадрах, ниже 0,25 - никогда."""
    tracker = CoverageTracker(card())
    assert "corrosion" not in show(tracker, 2, box("corrosion", 0.4, 0.02))["visual"]
    state = show(tracker, 1, box("corrosion", 0.3, 0.02))
    assert state["visual"]["corrosion"] == 0.4
    assert state["nodes"]["casing"]["defect_classes"] == {"corrosion": 0.4}
    assert state["nodes"]["casing"]["inspected"] is False
    assert "leak" not in show(tracker, 50, box("leak", 0.24, 0.05))["visual"]


def test_percent_grows_monotonically():
    """Доля осмотренных узлов не убывает, осмотренный узел не сбрасывается ни пустыми, ни плохими кадрами."""
    tracker = CoverageTracker(card())
    walk = [
        [box("motor", 0.9, 0.2)],
        [],
        [box("motor", 0.3, 0.2)],
        [box("motor", 0.9, 0.2), box("terminal_box", 0.7, 0.02)],
        [box("motor", 0.9, 0.2)],
        [box("terminal_box", 0.7, 0.02)],
        [box("terminal_box", 0.2, 0.001)],
        [],
        [box("terminal_box", 0.7, 0.02), box("coupling_guard", 0.6, 0.05)],
        [box("coupling_guard", 0.6, 0.05)],
        [box("terminal_box", 0.7, 0.02)],
        [box("coupling_guard", 0.6, 0.05)],
        [box("terminal_box", 0.7, 0.02)],
        [box("pump_casing", 0.8, 0.3), box("flange", 0.8, 0.02), box("gauge", 0.8, 0.02)],
        [],
        [box("pump_casing", 0.8, 0.3), box("flange", 0.8, 0.02), box("gauge", 0.8, 0.02)],
        [box("pump_casing", 0.1, 0.3)],
        [box("pump_casing", 0.8, 0.3), box("flange", 0.8, 0.02), box("gauge", 0.8, 0.02)],
        [box("flange", 0.8, 0.02), box("gauge", 0.8, 0.02)],
        [box("flange", 0.8, 0.02), box("gauge", 0.8, 0.02)],
        [],
        [],
        [box("motor", 0.3, 0.2)],
        [box("terminal_box", 0.9, 0.001)],
        [box("pump_casing", 0.1, 0.3), box("gauge", 0.4, 0.5)],
        [box("coupling_guard", 0.26, 0.0001), box("flange", 0.01, 0.9)],
        [],
    ]
    percents, inspected = [], set()
    for boxes in walk:
        state = tracker.observe(boxes, FRAME_W, FRAME_H)
        percents.append(state["percent"])
        now_inspected = {code for code, node in state["nodes"].items() if node["inspected"]}
        assert inspected <= now_inspected
        inspected = now_inspected
    assert percents == sorted(percents)
    assert percents[0] == 0 and percents[-1] == round(100 * 6 / 7)
    assert inspected == {"motor", "terminal_box", "coupling", "casing", "flanges", "gauge"}
    state = tracker.mark_checked("seal")
    assert state["percent"] == 100 and state["hint"] == ALL_DONE_HINT and state["next_node"] is None
    assert state["nodes"]["seal"]["manual"] is True


def test_total_counts_only_nodes_with_detector_classes():
    """В общий счёт входят узлы с классами детектора; узел без классов камерой не отслеживается."""
    state = CoverageTracker(card()).state()
    assert state["total"] == 7 and state["inspected"] == 0 and state["percent"] == 0
    assert state["nodes"]["motor_bearings"]["trackable"] is False
    assert set(state["nodes"]) == {node["id"] for node in card()["nodes"]}
    assert "motor_bearings" not in state["pending"]
    for node in state["nodes"].values():
        assert {"seen", "best_conf", "inspected", "defect_classes"} <= set(node)


def test_static_priority_follows_rule_severity():
    """Без текущих данных выше стоят узлы, к которым относятся правила с большей критичностью."""
    assert static_priority(card()) == [
        "terminal_box",
        "coupling",
        "seal",
        "casing",
        "motor_bearings",
        "gauge",
        "motor",
        "flanges",
    ]


def test_hint_names_next_node_by_priority():
    """Подсказка называет первый неосмотренный узел по приоритету и переходит к следующему, когда он осмотрен."""
    tracker = CoverageTracker(card(), ["gauge", "motor"])
    state = tracker.state()
    assert state["pending"][:4] == ["gauge", "motor", "terminal_box", "coupling"]
    assert state["hint"] == "Покажите узел «Манометр на нагнетании»" and state["next_node"] == "gauge"
    state = show(tracker, 5, box("gauge", 0.9, 0.03))
    assert state["hint"] == "Покажите узел «Электродвигатель»" and state["next_node"] == "motor"
    state = show(tracker, 3, box("motor", 0.9, 0.2))
    assert state["hint"] == "Покажите узел «Клеммная коробка»" and state["next_node"] == "terminal_box"
    tracker.set_priority(["flanges"])
    state = tracker.state()
    assert state["next_node"] == "flanges" and "Фланцевые соединения" in state["hint"]
    assert state["pending"] == ["flanges", "terminal_box", "coupling", "seal", "casing"]


def test_hint_guides_the_camera():
    """Подсказка просит удержать камеру, вернуться к узлу или отметить вручную узел, где камера видит только дефекты."""
    tracker = CoverageTracker(card(), ["terminal_box", "seal"])
    state = show(tracker, 2, box("terminal_box", 0.9, 0.02))
    assert state["hint"] == "Удерживайте камеру на узле «Клеммная коробка» - засчитано кадров: 2 из 5"
    assert state["hint_node"] == "terminal_box"
    state = show(tracker, 1)
    assert state["hint"] == "Вернитесь к узлу «Клеммная коробка» - осмотр не завершён"
    state = show(tracker, 1, box("motor", 0.9, 0.2))
    assert state["hint_node"] == "motor" and state["next_node"] == "terminal_box"
    assert state["hint"].startswith("Удерживайте камеру на узле «Электродвигатель»")
    state = show(tracker, 3, box("terminal_box", 0.9, 0.02))
    assert state["next_node"] == "seal"
    state = show(tracker, 1)
    assert "Торцевое уплотнение" in state["hint"] and "вручную" in state["hint"]


def test_all_done_and_nothing_to_track_hints():
    """Когда осмотрено всё, подсказка сообщает об этом; для оборудования без классов камеры - просит отметки вручную."""
    tracker = CoverageTracker(card("AMS-1"))
    assert tracker.state()["total"] == 4
    for code in ("unit", "motor", "seal", "frame"):
        state = tracker.mark_checked(code)
    assert state["percent"] == 100 and state["hint"] == ALL_DONE_HINT and state["pending"] == []
    blind = CoverageTracker({"id": "X", "type": "other", "nodes": [{"id": "body", "name": "Корпус", "classes": []}]})
    state = blind.observe([box("motor")], FRAME_W, FRAME_H)
    assert state["total"] == 0 and state["percent"] == 0 and state["hint"] == NOTHING_TO_TRACK_HINT


def test_bad_boxes_are_skipped_and_frame_size_is_checked():
    """Негодные рамки пропускаются, рамка обрезается по кадру, неположительный размер кадра - ошибка."""
    tracker = CoverageTracker(card())
    rubbish = [
        None,
        {},
        {"cls": "motor"},
        {"cls": "motor", "conf": "x", "x1": 0, "y1": 0, "x2": 9, "y2": 9},
        {"cls": "motor", "conf": 0.9, "x1": 50, "y1": 50, "x2": 50, "y2": 90},
        {"cls": "motor", "conf": float("nan"), "x1": 0, "y1": 0, "x2": 900, "y2": 700},
        {"cls": "motor", "conf": 0.9, "x1": 5000, "y1": 5000, "x2": 9000, "y2": 9000},
        {"cls": "nameplate", "conf": 0.9, "x1": 0, "y1": 0, "x2": 400, "y2": 300},
    ]
    state = tracker.observe(rubbish, FRAME_W, FRAME_H)
    assert state["nodes"]["motor"]["seen"] == 0 and state["nodes"]["motor"]["best_conf"] == 0
    assert state["visual"] == {"nameplate": 0.9}
    outside = {"cls": "motor", "conf": 0.9, "x1": -4000, "y1": -4000, "x2": 9000, "y2": 9000}
    state = tracker.observe([outside], FRAME_W, FRAME_H)
    assert state["nodes"]["motor"]["seen"] == 1 and state["nodes"]["motor"]["best_area"] == 100.0
    for width, height in ((0, 720), (1280, -1), (None, 720), ("a", 720)):
        with pytest.raises(ValueError):
            tracker.observe([], width, height)
    with pytest.raises(KeyError):
        tracker.mark_checked("no_such_node")
    assert tracker.node_for("coupling_no_guard") == "coupling" and tracker.node_for("nameplate") is None


def forget_cached_hashes():
    """Сбрасывает запомненные хэши демонстрационных паролей, чтобы сниженная стоимость хэша не утекла в другие проверки."""
    seeding._demo_hash.cache_clear()


@pytest.fixture(scope="module")
def seeded_database(tmp_path_factory):
    """Один раз создаёт базу с начальными данными и вторым инженером; каждая проверка берёт её копию."""
    path = tmp_path_factory.mktemp("inspections") / "kst.db"
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("KST_DB", str(path))
        patch.setattr(auth, "SCRYPT_N", 2**10)
        forget_cached_hashes()
        db.init_db()
        with db.SessionLocal() as session:
            seed(session)
            session.add(User(email="second@kst.demo", name="Пётр Иванов", role="engineer", password_hash="-"))
            session.commit()
        db.engine.dispose()
        forget_cached_hashes()
    return path


class Api:
    """Клиент сервера осмотров, выполняющий запросы от имени выбранного сотрудника."""

    def __init__(self, client, app):
        """Запоминает клиента и приложение; сотрудник по умолчанию - инженер."""
        self.client, self.app, self.user = client, app, None
        self.act("engineer@kst.demo")

    def act(self, email):
        """Переключает сотрудника, от имени которого идут запросы."""
        with db.SessionLocal() as session:
            self.user = session.scalar(select(User).where(User.email == email))
        self.app.dependency_overrides[auth.current_user] = lambda: self.user
        return self.user

    def start(self, equipment_id="N-101"):
        """Начинает осмотр и возвращает его описание."""
        response = self.client.post("/inspections", json={"equipment_id": equipment_id})
        assert response.status_code in (200, 201), response.text
        return response.json()

    def add(self, inspection_id, frame=None, **fields):
        """Добавляет запись в осмотр и возвращает ответ сервера."""
        files = {"frame": ("frame.jpg", frame, "image/jpeg")} if frame is not None else None
        return self.client.post(f"/inspections/{inspection_id}/findings", data=fields, files=files)

    def finish(self, inspection_id):
        """Завершает осмотр и возвращает ответ сервера."""
        return self.client.post(f"/inspections/{inspection_id}/finish")


@pytest.fixture
def api(seeded_database, tmp_path, monkeypatch):
    """Сервер с маршрутами осмотров на отдельной временной базе; телеметрии по умолчанию нет ни у одного агрегата."""
    shutil.copyfile(seeded_database, tmp_path / "kst.db")
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    monkeypatch.setenv("KST_SECRET", "k" * 48)

    def no_telemetry(equipment_id):
        """Подмена: у агрегата нет телеметрии."""
        raise KeyError(equipment_id)

    monkeypatch.setattr(service, "get_player", no_telemetry)
    db.init_db()
    app = FastAPI(docs_url=None, redoc_url=None)
    app.include_router(router)
    with TestClient(app) as client:
        yield Api(client, app)
    service._live.clear()
    db.engine.dispose()


def use_telemetry(monkeypatch, player):
    """Подключает к агрегату N-101 подменный проигрыватель телеметрии."""

    def get_player(equipment_id):
        """Подмена: телеметрия есть только у N-101."""
        if equipment_id != "N-101":
            raise KeyError(equipment_id)
        return player

    monkeypatch.setattr(service, "get_player", get_player)


def test_requests_require_login(api):
    """Без токена доступа маршруты осмотров отвечают 401."""
    api.app.dependency_overrides.clear()
    assert api.client.post("/inspections", json={"equipment_id": "N-101"}).status_code == 401
    assert api.client.get("/inspections/1").status_code == 401
    assert api.client.get("/inspections/1/report.pdf").status_code == 401
    assert api.client.get("/inspections/findings").status_code == 401


def test_start_creates_inspection_and_resumes_unfinished(api):
    """Начало осмотра возвращает номер; повторный запрос того же сотрудника продолжает идущий осмотр."""
    response = api.client.post("/inspections", json={"equipment_id": "N-101"})
    assert response.status_code == 201
    started = response.json()
    assert started["status"] == "active" and started["resumed"] is False and started["finished_at"] is None
    assert started["equipment"]["id"] == "N-101" and started["user"]["name"] == "Алексей Смирнов"
    assert started["coverage"]["percent"] == 0 and started["coverage"]["total"] == 7
    assert started["findings"] == []
    again = api.client.post("/inspections", json={"equipment_id": "N-101"})
    assert again.status_code == 200 and again.json()["id"] == started["id"] and again.json()["resumed"] is True
    api.act("second@kst.demo")
    other = api.client.post("/inspections", json={"equipment_id": "N-101"})
    assert other.status_code == 201 and other.json()["id"] != started["id"]
    assert api.client.post("/inspections", json={"equipment_id": "НЕТ"}).status_code == 404
    assert api.client.post("/inspections", json={}).status_code == 422
    assert api.client.get("/inspections/99999").status_code == 404
    listed = api.client.get("/inspections", params={"equipment_id": "N-101", "status": "active"}).json()
    assert [entry["id"] for entry in listed] == [other.json()["id"], started["id"]]


def test_first_hint_follows_unresolved_finding_of_previous_inspection(api):
    """Подсказки обхода начинаются с узла, по которому с прошлого осмотра осталось неустранённое замечание."""
    coverage = api.start("N-101")["coverage"]
    assert coverage["next_node"] == "seal" and "Торцевое уплотнение" in coverage["hint"]
    coverage = api.start("AMS-2")["coverage"]
    assert coverage["next_node"] == "frame" and "Рама и анкерные болты" in coverage["hint"]


def test_route_puts_previous_findings_before_resource(api):
    """Маршрут: незакрытое замечание прошлого осмотра выше ресурса на исходе, далее плановые узлы; у каждого причина."""
    with db.SessionLocal() as session:
        route = node_route(session, session.get(Equipment, "N-101"))
        assert service.node_priority(session, session.get(Equipment, "N-101")) == [entry["code"] for entry in route]
    assert [entry["code"] for entry in route][:2] == ["seal", "motor_bearings"]
    assert route[0]["group"] == "previous_finding" and "Следы влаги у торцевого уплотнения" in route[0]["reason"]
    assert "27.10.2026" in route[0]["reason"]
    assert route[1]["group"] == "resource" and "израсходовано" in route[1]["reason"]
    assert {entry["group"] for entry in route[3:]} == {"routine"}
    assert [entry["rank"] for entry in route] == sorted(entry["rank"] for entry in route)
    assert len(route) == 8 and all(entry["name"] and entry["reason"] for entry in route)


def test_route_uses_sensor_deviation(api, monkeypatch):
    """Отклонение по датчикам поднимает узел в маршруте выше ресурса на исходе, но ниже прошлых замечаний."""
    use_telemetry(monkeypatch, FakePlayer({**CALM, "vib_2x": 3.4, "vib_axial": 4.2}))
    with db.SessionLocal() as session:
        route = node_route(session, session.get(Equipment, "N-101"))
    assert [entry["code"] for entry in route][:2] == ["seal", "coupling"]
    assert route[1]["group"] == "sensor" and route[1]["reason"].startswith("Отклонение по датчикам: ")


def test_checked_mark_closes_node(api):
    """Отметка «проверено, замечаний нет» сохраняется записью со статусом ok и закрывает узел в полноте обхода."""
    inspection = api.start()
    response = api.add(inspection["id"], kind="checked", node="seal", comment="  Сухо, следов влаги нет  ")
    assert response.status_code == 201, response.text
    record = response.json()
    assert record["kind"] == "checked" and record["status"] == "ok" and record["state"] == "resolved"
    assert record["node_name"] == "Торцевое уплотнение" and record["comment"] == "Сухо, следов влаги нет"
    assert record["source"] == "manual" and record["has_photo"] is False and record["photo_url"] is None
    view = api.client.get(f"/inspections/{inspection['id']}").json()
    assert view["coverage"]["nodes"]["seal"]["inspected"] is True and view["coverage"]["nodes"]["seal"]["manual"] is True
    assert view["coverage"]["inspected"] == 1 and view["coverage"]["next_node"] != "seal"
    assert [entry["id"] for entry in view["findings"]] == [record["id"]]
    assert api.client.get(f"/inspections/{inspection['id']}/findings").json() == view["findings"]


def test_engineer_records_survive_server_restart(api):
    """Узел с записью инженера считается осмотренным, и после перезапуска сервера это не теряется."""
    number = api.start()["id"]
    assert api.add(number, kind="defect", node="seal", sign="leak").status_code == 201
    assert api.add(number, kind="checked", node="flanges").status_code == 201
    assert api.add(number, kind="defect", comment="Общий шум агрегата").status_code == 201
    before = api.client.get(f"/inspections/{number}").json()["coverage"]
    assert before["inspected"] == 2 and before["nodes"]["seal"]["manual"] is True
    service._live.clear()
    after = api.client.get(f"/inspections/{number}").json()["coverage"]
    assert after["inspected"] == 2 and after["percent"] == before["percent"]
    assert after["nodes"]["seal"]["inspected"] is True and after["nodes"]["flanges"]["inspected"] is True
    assert after["nodes"]["motor"]["inspected"] is False


def test_defect_by_sign_uses_rule_and_keeps_photo(api):
    """Дефект по признаку из перечня получает диагноз и рекомендацию правила, основания и стоп-кадр камеры."""
    inspection = api.start()
    response = api.add(
        inspection["id"], frame=jpeg((2400, 1800)), kind="defect", node="seal", sign="leak", comment="Капли у вала"
    )
    assert response.status_code == 201, response.text
    finding = response.json()
    assert finding["rule_id"] == "R01" and finding["status"] == "defect" and finding["state"] == "open"
    assert finding["kind"] == "defect" and finding["automatic"] is False and finding["node_code"] == "seal"
    assert finding["status_title"] == "Обнаружены признаки возможного дефекта"
    assert "уплотнени" in finding["diagnosis"] and finding["recommendation"]
    assert any(line["source"] == "manual" and line["met"] for line in finding["evidence"])
    assert finding["has_photo"] is True and finding["photo_url"] == f"/inspections/findings/{finding['id']}/photo"
    photo = api.client.get(finding["photo_url"])
    assert photo.status_code == 200 and photo.headers["content-type"] == "image/jpeg"
    with Image.open(io.BytesIO(photo.content)) as picture:
        assert picture.format == "JPEG" and max(picture.size) == 1920
    with db.SessionLocal() as session:
        stored = session.get(Finding, finding["id"])
        assert stored.photo_path == f"inspection_{inspection['id']}/finding_{finding['id']}.jpg"
        assert service.photo_file(stored).is_file()
    assert "photo_path" not in finding
    assert api.client.get(f"/inspections/findings/{finding['id']}").json()["id"] == finding["id"]
    assert api.client.get("/inspections/findings/99999").status_code == 404


def test_free_defect_and_severity(api):
    """Дефект без признака и правила - свободная отметка инженера; критичность можно задать от 1 до 3."""
    inspection = api.start("AMS-1")
    plain = api.add(inspection["id"], kind="defect", node="gearbox", comment="Посторонний шум").json()
    assert plain["status"] == "defect" and plain["severity"] == 2 and plain["rule_id"] is None
    assert plain["source"] == "manual" and plain["title"] == "Дефект, зафиксированный инженером"
    critical = api.add(inspection["id"], kind="defect", severity=3).json()
    assert critical["severity"] == 3 and critical["node_code"] is None and critical["node_name"] == "Агрегат в целом"
    assert critical["severity_title"] == "критично"
    assert api.add(inspection["id"], kind="defect", severity=4).status_code == 422
    assert api.add(inspection["id"], kind="defect", severity=0).status_code == 422
    assert api.client.get(f"/inspections/findings/{plain['id']}/photo").status_code == 404


def test_input_is_validated(api):
    """Неверные данные записи отклоняются с понятным кодом и ничего не сохраняют."""
    inspection = api.start()
    number = inspection["id"]
    assert api.add(number, kind="broken").status_code == 422
    assert api.add(number).status_code == 422
    assert api.add(number, kind="defect", node="no_such_node").status_code == 404
    assert api.add(number, kind="replacement").status_code == 422
    assert api.add(number, kind="checked", node="seal", sign="leak").status_code == 422
    assert api.add(number, kind="defect", sign="no_such_sign").status_code == 422
    assert api.add(number, kind="defect", rule_id="R06").status_code == 409
    assert api.add(number, kind="maintenance", maintenance_code="TO-9").status_code == 422
    assert api.add(number, kind="replacement", node="seal", maintenance_code="TO-1").status_code == 422
    assert api.add(99999, kind="checked").status_code == 404
    png = io.BytesIO()
    Image.new("RGB", (64, 64)).save(png, "PNG")
    assert api.add(number, frame=png.getvalue(), kind="defect").status_code == 415
    assert api.add(number, frame=b"\xff\xd8\xff\xe0 broken", kind="defect").status_code == 422
    assert api.add(number, frame=b"", kind="defect").status_code == 422
    assert api.client.get(f"/inspections/{number}").json()["findings"] == []
    with db.SessionLocal() as session:
        assert session.scalars(select(Finding).where(Finding.inspection_id == number)).all() == []
    assert not (service._photos_dir() / f"inspection_{number}").exists()


def test_replacement_resets_node_hours_and_writes_maintenance_record(api):
    """Замена узла обнуляет его наработку, ставит дату замены и пишет запись о работе с именем сотрудника."""
    inspection = api.start()
    with db.SessionLocal() as session:
        before = session.scalar(select(func.count()).select_from(MaintenanceRecord))
    response = api.add(inspection["id"], kind="replacement", node="seal", comment="Установлено новое торцевое уплотнение")
    assert response.status_code == 201, response.text
    record = response.json()
    assert record["kind"] == "replacement" and record["status"] == "ok" and record["state"] == "resolved"
    assert record["title"] == "Выполнена замена узла"
    with db.SessionLocal() as session:
        item = session.get(Equipment, "N-101")
        hours = {node.code: node.hours for node in item.nodes}
        replaced = {node.code: node.replaced for node in item.nodes}
        assert hours["seal"] == 0 and replaced["seal"] == date.today()
        assert hours["motor"] == 19190 and replaced["motor"] is None and item.run_hours == 19190
        records = session.scalars(select(MaintenanceRecord).order_by(MaintenanceRecord.id.desc())).all()
        assert len(records) == before + 1
        latest = records[0]
        assert (latest.equipment_id, latest.node_code, latest.kind) == ("N-101", "seal", "replacement")
        assert latest.comment == "Установлено новое торцевое уплотнение" and latest.hours_at == 19190
        assert latest.user.name == "Алексей Смирнов"
    summary = api.finish(inspection["id"]).json()["summary"]
    seal = next(node for node in summary["nodes"] if node["code"] == "seal")
    assert seal["calculated"]["state"] == "ok" and seal["calculated"]["used_percent"] == 0
    assert seal["calculated"]["remaining_hours"] == 15000


def test_replacement_follows_telemetry_counter(api, monkeypatch):
    """При замене наработка агрегата и узлов подтягивается к счётчику телеметрии, дата замены - день ленты."""
    use_telemetry(monkeypatch, FakePlayer({**CALM, "run_hours": 19250.0}, cursor=datetime(2026, 11, 12, 20, 0)))
    inspection = api.start()
    assert api.add(inspection["id"], kind="replacement", node="gauge").status_code == 201
    with db.SessionLocal() as session:
        item = session.get(Equipment, "N-101")
        nodes = {node.code: node for node in item.nodes}
        assert item.run_hours == 19250
        assert nodes["motor"].hours == 19250 and nodes["seal"].hours == 13250
        assert nodes["gauge"].hours == 0 and nodes["gauge"].replaced == date(2026, 11, 12)
        latest = session.scalars(select(MaintenanceRecord).order_by(MaintenanceRecord.id.desc())).first()
        assert latest.hours_at == 19250
    summary = api.finish(inspection["id"]).json()["summary"]
    gauge = next(node for node in summary["nodes"] if node["code"] == "gauge")
    assert gauge["calculated"]["state"] == "ok" and gauge["calculated"]["used_percent"] == 0
    assert summary["run_hours"] == 19250 and summary["estimates_on"] == "2026-11-12"
    assert summary["telemetry_at"] == "2026-11-12T20:00:00"


def test_maintenance_updates_schedule(api, monkeypatch):
    """Выполненное ТО отмечается в регламенте текущей наработкой и снимает правило о наступившем сроке обслуживания."""
    use_telemetry(monkeypatch, FakePlayer({**CALM, "run_hours": 19210.0}))
    inspection = api.start()
    with db.SessionLocal() as session:
        due = service.current_diagnosis(session, service.get_inspection(session, inspection["id"]))
    assert "R11" in {found["rule_id"] for found in due["findings"]}
    assert api.add(inspection["id"], kind="maintenance", maintenance_code="TO-1").status_code == 201
    done = api.add(inspection["id"], kind="maintenance", maintenance_code="TO-2", comment="Выполнено в полном объёме")
    assert done.status_code == 201 and done.json()["title"] == "Выполнено техническое обслуживание: ТО-2"
    with db.SessionLocal() as session:
        item = session.get(Equipment, "N-101")
        marks = {entry["code"]: entry["last_at_hours"] for entry in item.data["maintenance"]}
        assert marks == {"TO-1": 19210, "TO-2": 19210, "TR": 6000}
        latest = session.scalars(select(MaintenanceRecord).order_by(MaintenanceRecord.id.desc())).first()
        assert (latest.kind, latest.node_code, latest.hours_at) == ("maintenance", None, 19210)
        after = service.current_diagnosis(session, service.get_inspection(session, inspection["id"]))
    assert "R11" not in {found["rule_id"] for found in after["findings"]}


def test_finish_returns_summary_and_is_idempotent(api):
    """Завершение сохраняет сводку: число записей по статусам, длительность, полнота, три оценки по каждому узлу."""
    inspection = api.start()
    number = inspection["id"]
    api.add(number, kind="checked", node="flanges")
    api.add(number, kind="defect", node="casing", comment="Скол краски")
    api.add(number, kind="defect", node="seal", sign="leak")
    response = api.finish(number)
    assert response.status_code == 200, response.text
    finished = response.json()
    summary = finished["summary"]
    assert finished["status"] == "finished" and finished["finished_at"] is not None
    assert summary["findings"] == 3 and summary["by_status"] == {"ok": 1, "check": 0, "defect": 2}
    assert isinstance(summary["duration_s"], int) and 0 <= summary["duration_s"] < 60
    assert summary["status"] == "defect"
    assert summary["coverage"]["inspected"] == 3 and summary["coverage"]["total"] == 7
    assert {code for code, node in summary["coverage"]["nodes"].items() if node["manual"]} == {"flanges", "casing", "seal"}
    assert finished["coverage"] == summary["coverage"]
    assert [node["code"] for node in summary["nodes"]] == [node["id"] for node in card()["nodes"]]
    for node in summary["nodes"]:
        assert set(node) == {"code", "name", "normative", "calculated", "actual"}
        assert node["normative"]["text"] and node["calculated"]["text"] and node["actual"]["reasons"]
    by_code = {node["code"]: node for node in summary["nodes"]}
    assert by_code["seal"]["actual"]["status"] == "defect"
    assert by_code["seal"]["calculated"]["state"] == "approaching"
    assert by_code["seal"]["normative"]["hours"] == 15000
    assert by_code["flanges"]["actual"] == {"status": "ok", "reasons": ["Проверено инженером: замечаний нет"]}
    assert by_code["casing"]["actual"]["status"] == "defect"
    assert by_code["motor"]["calculated"]["state"] == "insufficient_data" and by_code["motor"]["calculated"]["missing"]
    assert by_code["motor"]["actual"]["status"] == "unknown"
    again = api.finish(number)
    assert again.status_code == 200 and again.json()["summary"] == summary
    assert again.json()["finished_at"] == finished["finished_at"]
    for fields in (
        {"kind": "checked", "node": "motor"},
        {"kind": "defect", "node": "motor"},
        {"kind": "replacement", "node": "seal"},
    ):
        refused = api.add(number, **fields)
        assert refused.status_code == 409 and "завершён" in refused.json()["detail"]
    assert len(api.client.get(f"/inspections/{number}").json()["findings"]) == 3
    assert api.start()["id"] != number
    with db.SessionLocal() as session:
        stored = session.get(Inspection, number)
        assert stored.status == "finished" and stored.summary == summary


def test_finish_does_not_record_camera_defects_the_engineer_did_not_confirm(api):
    """Признаки дефектов, увиденные только камерой, не попадают ни в диагноз, ни в находки без решения инженера."""
    inspection = api.start()
    number = inspection["id"]
    with db.SessionLocal() as session:
        tracker = service.tracker_for(session, service.get_inspection(session, number))
        show(tracker, 1, box("terminal_box_burnt", 0.9, 0.03))
        show(tracker, 6, box("leak", 0.7, 0.02), box("motor", 0.9, 0.2))
        diagnosis = service.current_diagnosis(session, service.get_inspection(session, number))
    assert "R04" not in {found["rule_id"] for found in diagnosis["findings"]}
    assert not any(line["source"] == "camera" and line["met"] for found in diagnosis["findings"] for line in found["evidence"])
    finished = api.finish(number).json()
    assert not any(found.get("source") == "camera" for found in finished["findings"])
    assert "R04" not in {found["rule_id"] for found in finished["findings"]}
    assert finished["summary"]["coverage"]["nodes"]["motor"]["inspected"] is True
    assert finished["summary"]["coverage"]["frames"] == 7
    with db.SessionLocal() as session:
        with pytest.raises(Exception) as refusal:
            service.tracker_for(session, service.get_inspection(session, number))
        assert refusal.value.status_code == 409


def test_diagnosis_uses_telemetry_and_gauge_reading(api, monkeypatch):
    """Диагноз осмотра учитывает датчики, а считанное камерой показание манометра включает правило R05."""
    use_telemetry(
        monkeypatch,
        FakePlayer({**CALM, "vib_hf": 3.4, "temp_bearing": 82.0, "press_out": 3.6}, {"vib_hf": 0.06, "temp_bearing": 0.6}),
    )
    inspection = api.start()
    with db.SessionLocal() as session:
        found = service.get_inspection(session, inspection["id"])
        rules = {entry["rule_id"] for entry in service.current_diagnosis(session, found)["findings"]}
        assert "R08" in rules and "R05" not in rules
        service.note_gauge_reading(session, found, 4.6)
        diagnosis = service.current_diagnosis(session, found)
        gauge = next(entry for entry in diagnosis["findings"] if entry["rule_id"] == "R05")
        assert gauge["status"] == "defect" and gauge["node_id"] == "gauge"
        service.note_gauge_reading(session, found, None)
        assert "R05" not in {entry["rule_id"] for entry in service.current_diagnosis(session, found)["findings"]}
    response = api.add(inspection["id"], kind="defect", rule_id="R08")
    assert response.status_code == 201 and response.json()["source"] == "sensor"
    assert response.json()["node_code"] == "motor_bearings"
    finished = api.finish(inspection["id"]).json()
    assert [entry["rule_id"] for entry in finished["findings"]].count("R08") == 1
    assert finished["summary"]["telemetry_at"] == "2026-11-20T12:00:00"


def test_only_author_and_master_change_inspection(api):
    """Чужой осмотр инженер и администратор системы изменить и завершить не могут; мастер может."""
    number = api.start()["id"]
    author = api.user
    with db.SessionLocal() as session:
        found = service.get_inspection(session, number)
        assert service.can_edit(found, author) is True
        assert service.can_edit(found, api.act("second@kst.demo")) is False
        assert service.can_edit(found, api.act("master@kst.demo")) is True
        assert service.can_edit(found, api.act("admin@kst.demo")) is False
    api.act("second@kst.demo")
    assert api.add(number, kind="checked", node="motor").status_code == 403
    assert api.finish(number).status_code == 403
    assert api.client.get(f"/inspections/{number}").status_code == 200
    api.act("admin@kst.demo")
    assert api.add(number, kind="checked", node="motor").status_code == 403
    assert api.finish(number).status_code == 403
    api.act("master@kst.demo")
    assert api.add(number, kind="checked", node="motor").status_code == 201
    assert api.finish(number).status_code == 200


def test_finding_state_transitions(api):
    """Замечание проходит путь «открыто - в работе - устранено»; переводит его мастер, а не инженер и не администратор."""
    number = api.start("AMS-1")["id"]
    finding = api.add(number, kind="defect", node="frame", sign="corrosion", comment="Очаг у анкера").json()
    address = f"/inspections/findings/{finding['id']}/state"
    assert api.client.post(address, json={"state": "in_work"}).status_code == 403
    api.act("master@kst.demo")
    assert api.client.post(address, json={"state": "resolved"}).status_code == 409
    assert api.client.post(address, json={"state": "closed"}).status_code == 422
    moved = api.client.post(address, json={"state": "in_work", "comment": "Выдан наряд"})
    assert moved.status_code == 200 and moved.json()["state"] == "in_work" and moved.json()["state_title"] == "В работе"
    assert moved.json()["comment"].startswith("Очаг у анкера\nВ работе - Марина Орлова, ")
    assert moved.json()["comment"].endswith(": Выдан наряд")
    same = api.client.post(address, json={"state": "in_work", "comment": "Повтор"})
    assert same.status_code == 200 and same.json()["comment"] == moved.json()["comment"]
    assert api.client.post(address, json={"state": "open"}).status_code == 409
    api.act("admin@kst.demo")
    assert api.client.post(address, json={"state": "resolved"}).status_code == 403
    api.act("master@kst.demo")
    done = api.client.post(address, json={"state": "resolved"})
    assert done.status_code == 200 and done.json()["state"] == "resolved"
    assert api.client.post(address, json={"state": "in_work"}).status_code == 409
    assert api.client.post("/inspections/findings/99999/state", json={"state": "in_work"}).status_code == 404
    with db.SessionLocal() as session:
        assert session.get(Finding, finding["id"]).state == "resolved"


def test_findings_board_filters(api):
    """Доска замечаний: записи без замечаний скрыты, есть отбор по состоянию и оборудованию, сначала новые."""
    number = api.start("AMS-1")["id"]
    api.add(number, kind="checked", node="motor")
    defect = api.add(number, kind="defect", node="motor", comment="Вибрация лап").json()
    board = api.client.get("/inspections/findings").json()
    assert board[0]["id"] == defect["id"] and board[0]["equipment_name"] == "Агрегат насосный винтовой №1"
    assert all(entry["status"] != "ok" for entry in board)
    assert [entry["created_at"] for entry in board] == sorted((entry["created_at"] for entry in board), reverse=True)
    assert {entry["state"] for entry in board} == {"open", "in_work", "resolved"}
    opened = api.client.get("/inspections/findings", params={"state": "open"}).json()
    assert {entry["id"] for entry in opened} == {defect["id"], 3}
    in_work = api.client.get("/inspections/findings", params={"state": "in_work"}).json()
    assert [(entry["equipment_id"], entry["node_code"]) for entry in in_work] == [("AMS-2", "frame")]
    own = api.client.get("/inspections/findings", params={"equipment_id": "AMS-1", "include_ok": "true"}).json()
    assert len(own) > len(api.client.get("/inspections/findings", params={"equipment_id": "AMS-1"}).json())
    assert api.client.get("/inspections/findings", params={"state": "closed"}).status_code == 422


def test_report_files_are_served(api, monkeypatch):
    """Отчёты PDF и Excel отдаются файлами для идущего, завершённого и старого осмотра; без шрифта PDF отвечает 503."""
    number = api.start()["id"]
    api.add(number, frame=jpeg(), kind="defect", node="seal", sign="leak", comment="Капли у вала")
    for stage in ("active", "finished"):
        pdf = api.client.get(f"/inspections/{number}/report.pdf")
        assert pdf.status_code == 200, stage
        assert pdf.headers["content-type"] == "application/pdf" and pdf.content.startswith(b"%PDF-")
        assert f"kst-vizor-osmotr-{number}.pdf" in pdf.headers["content-disposition"]
        xlsx = api.client.get(f"/inspections/{number}/report.xlsx")
        assert xlsx.status_code == 200, stage
        assert xlsx.headers["content-type"] == XLSX_TYPE and xlsx.content.startswith(b"PK")
        api.finish(number)
    assert api.client.get("/inspections/1/report.pdf").status_code == 200
    assert api.client.get("/inspections/1/report.xlsx").status_code == 200
    assert api.client.get("/inspections/99999/report.pdf").status_code == 404
    assert api.client.get("/inspections/99999/report.xlsx").status_code == 404

    def no_font(data):
        """Подмена: на сервере нет шрифта с кириллицей."""
        raise RuntimeError("Не найден шрифт с кириллицей")

    monkeypatch.setattr(import_module("server.inspections.router"), "build_pdf", no_font)
    refused = api.client.get(f"/inspections/{number}/report.pdf")
    assert refused.status_code == 503 and "шрифт" in refused.json()["detail"]
