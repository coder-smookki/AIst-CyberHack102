"""Проверки подключения детектора типа оборудования как третьей модели-подсказки (server/recognition.py)."""
import json
from pathlib import Path

import numpy as np

from server import recognition

ROOT = Path(__file__).resolve().parents[1]
FRAME = np.zeros((480, 640, 3), np.uint8)
EQUIPMENT_NAMES = {0: "pump_unit", 1: "control_cabinet", 2: "transformer", 3: "motor", 4: "valve", 5: "compressor"}


class FakeResult:
    """Ответ модели в виде, который возвращает библиотека детектора: рамки, классы и уверенности."""

    def __init__(self, rows, names):
        """Запоминает строки (x1, y1, x2, y2, номер класса, уверенность) и названия классов."""
        self.names = names
        self.boxes = type("Boxes", (), {
            "xyxy": np.array([row[:4] for row in rows], dtype=float).reshape(-1, 4),
            "cls": np.array([row[4] for row in rows]), "conf": np.array([row[5] for row in rows])})()


def make_detector(tmp_path, equipment_rows, stand_rows=(), defect_rows=(), with_equipment=True):
    """Создаёт детектор с подменными моделями: узлы, дефекты и, при with_equipment, подсказка типа оборудования."""
    folder = tmp_path / "models"
    folder.mkdir(parents=True, exist_ok=True)
    document = [{"file": "detector.onnx", "defect_classes": ["leak"]},
                {"file": "defects.onnx", "defect_classes": ["damage"], "conf_check": 0.15}]
    if with_equipment:
        document.append({"file": "equipment.onnx", "role": "equipment", "hint": True, "conf_check": 0.6,
                         "thresholds": {"control_cabinet": 0.6, "motor": 0.7}, "only": ["control_cabinet", "motor", "pump_unit"],
                         "rename": {"motor": "electric_motor"}, "min_share": 0.01,
                         "labels": {"control_cabinet": "Шкаф управления", "motor": "Электродвигатель"}})
    (folder / "models.json").write_text(json.dumps(document), encoding="utf-8")
    outputs = {"detector.onnx": FakeResult(list(stand_rows), {0: "motor", 1: "leak"}),
               "defects.onnx": FakeResult(list(defect_rows), {0: "damage"}),
               "equipment.onnx": FakeResult(list(equipment_rows), EQUIPMENT_NAMES)}
    for entry in document:
        (folder / entry["file"]).write_bytes(b"x")
    return recognition.Detector(folder, lambda path: (lambda frame, conf: [outputs[path.name]]))


def test_hint_box_gets_label_and_flag(tmp_path):
    """Рамка типа оборудования получает русскую подпись и пометку hint и не считается дефектом."""
    detector = make_detector(tmp_path, [(100, 100, 400, 400, 1, 0.9)])
    boxes = detector.detect(FRAME)
    assert boxes == [{"cls": "control_cabinet", "conf": 0.9, "x1": 100.0, "y1": 100.0, "x2": 400.0, "y2": 400.0,
                      "label": "Шкаф управления", "hint": True}]
    assert "control_cabinet" not in recognition.defect_classes(detector)
    assert recognition.box_status("control_cabinet", 0.9, recognition.defect_classes(detector)) == "ok"


def test_hint_model_stays_silent_below_threshold_and_on_dropped_classes(tmp_path):
    """Неуверенные рамки, классы вне перечня only и слишком мелкие рамки не выдаются вовсе."""
    rows = [(100, 100, 400, 400, 1, 0.55), (100, 100, 400, 400, 2, 0.95), (10, 10, 30, 30, 1, 0.95),
            (50, 50, 300, 300, 5, 0.99)]
    assert make_detector(tmp_path, rows).detect(FRAME) == []


def test_existing_models_output_unchanged_by_hint_model(tmp_path):
    """Рамки моделей узлов и дефектов одинаковы с третьей моделью и без неё."""
    stand = [(10, 10, 210, 210, 0, 0.8), (300, 300, 400, 400, 1, 0.7)]
    defects = [(500, 10, 600, 90, 0, 0.4)]
    equipment = [(12, 12, 212, 212, 3, 0.95), (100, 100, 500, 400, 0, 0.9)]
    without = make_detector(tmp_path / "a", [], stand, defects, with_equipment=False).detect(FRAME)
    combined = make_detector(tmp_path / "b", equipment, stand, defects).detect(FRAME)
    solid = [box for box in combined if not box.get("hint")]
    assert sorted(solid, key=lambda box: box["cls"]) == sorted(without, key=lambda box: box["cls"])
    assert [box["cls"] for box in combined if box.get("hint")] == ["pump_unit"]


def test_renamed_motor_hint_kept_only_without_part_motor(tmp_path):
    """Подсказка "электродвигатель" остаётся, когда модель узлов двигатель не нашла, и уступает её рамке иначе."""
    alone = make_detector(tmp_path / "a", [(12, 12, 212, 212, 3, 0.95)]).detect(FRAME)
    assert [(box["cls"], box["label"]) for box in alone] == [("electric_motor", "Электродвигатель")]
    assert all("_twin" not in box for box in alone)
    both = make_detector(tmp_path / "b", [(12, 12, 212, 212, 3, 0.95)], [(10, 10, 210, 210, 0, 0.8)]).detect(FRAME)
    assert [box["cls"] for box in both] == ["motor"]


def test_model_options_ignore_bad_values():
    """Негодные значения правил вывода в описании моделей не принимаются."""
    assert recognition.model_options("equipment.onnx") == {}
    assert recognition.model_options({"hint": "yes", "only": "motor", "rename": [], "min_share": 5}) == {}
    assert recognition.model_options({"hint": True, "min_share": 0.01}) == {"hint": True, "min_share": 0.01}


def test_delivered_equipment_entry_is_a_hint_with_confident_thresholds():
    """В поставленном описании модель типа оборудования - подсказка: пороги не ниже 0,5 и подписи для всех классов."""
    entries = json.loads((ROOT / "models" / "models.json").read_text(encoding="utf-8"))
    equipment = [entry for entry in entries if entry.get("role") == "equipment"]
    if not equipment:
        return
    entry = equipment[0]
    default, classes = recognition.model_thresholds(entry)
    options = recognition.model_options(entry)
    assert options["hint"] is True and not entry.get("defect_classes")
    assert options["only"] and options["only"] <= set(entry["classes"])
    assert all(classes.get(name, default) >= 0.5 and name in options["labels"] for name in options["only"])
    other = {cls for item in entries if item is not entry for cls in item["classes"]}
    assert not {options.get("rename", {}).get(name, name) for name in options["only"]} & other


def _card(unit_id):
    """Возвращает карточку агрегата из data/equipment.json."""
    document = json.loads((ROOT / "data" / "equipment.json").read_text(encoding="utf-8"))
    return next(card for card in document["equipment"] if card["id"] == unit_id)


def _shipped_hint_classes():
    """Классы подсказки типа оборудования, которые сервер выдаёт по поставленному описанию (после переименования)."""
    entries = json.loads((ROOT / "models" / "models.json").read_text(encoding="utf-8"))
    for entry in entries:
        if entry.get("role") == "equipment":
            options = recognition.model_options(entry)
            return {options.get("rename", {}).get(name, name) for name in options.get("only", ())}
    return set()


def test_cabinet_hint_covers_cabinet_node_in_walk_around():
    """Рамка шкафа управления засчитывает узел ШУ-3 в обходе, но не даёт находок диагностики."""
    from server.inspections.coverage import CoverageTracker
    from server.rules.engine import diagnose
    card = _card("SHU-3")
    tracker = CoverageTracker(card)
    assert tracker.node_for("control_cabinet") == "door_seal"
    box = {"cls": "control_cabinet", "conf": 0.9, "x1": 100, "y1": 50, "x2": 500, "y2": 450, "hint": True}
    for _ in range(5):
        state = tracker.observe([box], 640, 480)
    assert state["nodes"]["door_seal"]["inspected"] and state["inspected"] == state["total"] == 1
    assert diagnose(card, {}, {}, {"control_cabinet": 0.9})["findings"] == []


def test_every_mapped_node_class_is_shipped():
    """Каждый класс подсказки в узлах ШУ-3 и ТР-1 действительно выдаётся поставленной моделью."""
    shipped = _shipped_hint_classes()
    if not shipped:
        return
    hint_names = set(EQUIPMENT_NAMES.values()) | {"electric_motor"}
    for unit_id in ("SHU-3", "TR-1"):
        for node in _card(unit_id)["nodes"]:
            assert {cls for cls in node["classes"] if cls in hint_names} <= shipped, (unit_id, node["id"])


def test_hint_classes_are_not_defect_signs():
    """Классы подсказки не совпадают с признаками правил: рамка типа оборудования не становится дефектом."""
    from server.rules.engine import defect_signs
    assert not _shipped_hint_classes() & set(defect_signs())


def test_foreign_type_hint_does_not_touch_other_unit():
    """Подсказка другого типа на обходе насоса не засчитывает узлы и не даёт находок: агрегат остаётся прежним."""
    from server.inspections.coverage import CoverageTracker
    from server.rules.engine import diagnose
    card = _card("N-101")
    tracker = CoverageTracker(card)
    before = tracker.state()
    boxes = [{"cls": "control_cabinet", "conf": 0.95, "x1": 0, "y1": 0, "x2": 600, "y2": 460, "hint": True},
             {"cls": "transformer", "conf": 0.95, "x1": 0, "y1": 0, "x2": 600, "y2": 460, "hint": True}]
    for _ in range(6):
        state = tracker.observe(boxes, 640, 480)
    assert tracker.node_for("control_cabinet") is None and tracker.node_for("transformer") is None
    assert state["inspected"] == before["inspected"] == 0 and state["total"] == before["total"]
    assert diagnose(card, {}, {}, {"control_cabinet": 0.95, "transformer": 0.95})["findings"] == []
