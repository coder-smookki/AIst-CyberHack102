"""Проверки чистых функций набора и оценки детектора типа оборудования (cv/build_equipment.py, cv/eval_equipment.py)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cv"))

from build_equipment import map_source, real_part_boxes, stand_boxes, union_box
from eval_equipment import class_stats, filtered, pick_thresholds


def test_union_box_and_stand_boxes():
    """Агрегат макета - объединение рамок узлов; без корпуса насоса агрегат не создаётся."""
    rows = [("motor", 0.1, 0.2, 0.4, 0.6), ("pump_casing", 0.5, 0.3, 0.8, 0.7), ("gauge", 0.0, 0.0, 0.05, 0.05)]
    assert union_box(rows, ("motor", "pump_casing")) == (0.1, 0.2, 0.8, 0.7)
    boxes = stand_boxes(rows)
    assert ("pump_unit", 0.1, 0.2, 0.8, 0.7) in boxes and ("motor", 0.1, 0.2, 0.4, 0.6) in boxes
    assert stand_boxes([("motor", 0.1, 0.2, 0.4, 0.6)]) == [("motor", 0.1, 0.2, 0.4, 0.6)]
    assert union_box([], ("motor",)) is None


def test_real_part_boxes_and_map_source():
    """Реальные снимки дают двигатель, агрегат и задвижку; классы Roboflow сопоставляются по имени и площади."""
    rows = [("motor", 0.1, 0.1, 0.3, 0.3), ("pump_casing", 0.3, 0.1, 0.5, 0.3), ("valve", 0.6, 0.6, 0.7, 0.7)]
    names = [box[0] for box in real_part_boxes(rows)]
    assert names.count("motor") == 1 and names.count("pump_unit") == 1 and names.count("valve") == 1
    source = {"map": {"Main transformer-": "transformer"}, "min_area": 0.01}
    assert map_source(source, [("Main transformer-", 0.0, 0.0, 0.5, 0.5)]) == [("transformer", 0.0, 0.0, 0.5, 0.5)]
    assert map_source(source, [("Main transformer-", 0.0, 0.0, 0.05, 0.05)]) is None
    assert map_source(source, [("insulator-", 0.0, 0.0, 0.5, 0.5)]) is None


def record(predicted, truth):
    """Собирает запись снимка 100 на 100 пикселей."""
    return {"truth": truth, "predicted": predicted, "size": (100, 100)}


def test_filtered_thresholds_and_min_area():
    """Рамки ниже порога класса, мелкие рамки и классы без порога отбрасываются."""
    rec = record([("valve", (0, 0, 50, 50), 0.6), ("valve", (0, 0, 5, 5), 0.9), ("compressor", (0, 0, 50, 50), 0.9),
                  ("motor", (0, 0, 50, 50), 0.2)], [])
    kept = filtered(rec, {"valve": 0.5, "compressor": None, "motor": 0.3}, 0.01)
    assert kept == [("valve", (0, 0, 50, 50), 0.6)]


def test_class_stats_and_pick_thresholds():
    """Порог класса поднимается до первой точки сетки, где точность на val не ниже цели."""
    truth = [("motor", (0, 0, 50, 50))]
    records = [record([("motor", (0, 0, 50, 50), 0.8), ("motor", (60, 60, 95, 95), 0.3)], truth),
               record([("motor", (0, 0, 50, 50), 0.7)], truth)]
    loose = class_stats(records, {"motor": 0.1}, 0.0)["motor"]
    assert loose["tp"] == 2 and loose["fp"] == 1 and loose["recall"] == 1.0
    chosen = pick_thresholds(records, 0.9, 0.0)
    assert chosen["motor"] is not None and 0.3 < chosen["motor"] <= 0.7
    assert chosen["transformer"] is None
