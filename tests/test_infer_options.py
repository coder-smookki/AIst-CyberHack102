"""Проверки вариантов вывода детектора дефектов и выбора порогов без обращения к настоящим моделям."""
import os
import sys
from types import SimpleNamespace

import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "cv"))

from build_screen_copies import is_open_frame
from infer_options import Options, nms, remap_records, remap_score, tile_windows
from kaggle_push import build
from tune_defects import constrained_thresholds


class FakeModel:
    """Модель-заглушка: возвращает одну рамку в левой половине любого переданного кадра."""

    names = {0: "corrosion"}

    def __call__(self, frame, conf=0.25):
        """Возвращает рамку в левой четверти кадра с уверенностью 0.6."""
        height, width = frame.shape[:2]
        box = np.float32([[0, 0, width / 4, height / 4]])
        return SimpleNamespace(boxes=SimpleNamespace(xyxy=box, cls=np.array([0]), conf=np.float32([0.6])))


def test_nms_drops_overlapping_box():
    """Сильно перекрытая рамка с меньшей уверенностью подавляется, отдельная остаётся."""
    boxes = np.float32([[0, 0, 10, 10], [1, 1, 10, 10], [50, 50, 60, 60]])
    assert nms(boxes, np.float32([0.9, 0.8, 0.7]), 0.5) == [0, 2]


def test_tile_windows_cover_frame():
    """Сетка 2x2 с перекрытием покрывает кадр от края до края."""
    windows = tile_windows(100, 80, 2, 0.2)
    assert len(windows) == 4
    assert min(w[0] for w in windows) == 0 and max(w[2] for w in windows) == 100
    assert max(w[3] for w in windows) == 80


def test_flip_returns_box_in_original_coordinates():
    """Рамка с отражённого кадра возвращается в исходные координаты и не сливается с исходной."""
    result = Options(FakeModel(), flip=True)(np.zeros((40, 80, 3), np.uint8))
    xs = sorted(float(box[0]) for box in result.boxes.xyxy)
    assert xs == [0.0, 60.0]


def test_remap_keeps_order_and_maps_threshold():
    """Порог класса переходит в общий порог, порядок уверенностей сохраняется."""
    assert abs(remap_score(0.1, 0.1) - 0.25) < 1e-9
    assert remap_score(0.05, 0.1) < remap_score(0.1, 0.1) < remap_score(0.5, 0.1) <= 1.0
    rows = remap_records([{"predicted": [("leak", (0, 0, 1, 1), 0.2)], "truth": []}], {"leak": 0.2})
    assert abs(rows[0]["predicted"][0][2] - 0.25) < 1e-9


def test_constrained_thresholds_raise_only_while_recall_holds():
    """Порог класса с одной ложной рамкой поднимается, пока верная рамка остаётся найденной."""
    record = {"truth": [("leak", (0, 0, 10, 10))], "labelled": None,
              "predicted": [("leak", (0, 0, 10, 10), 0.4), ("leak", (50, 50, 60, 60), 0.1)]}
    chosen = constrained_thresholds([record], 1.0, 1.0)
    assert 0.1 < chosen["leak"]["threshold"] <= 0.4
    assert chosen["leak"]["val_false_boxes"] == 0


def test_open_frame_filter():
    """Кадры заказчика, макета и повторы редких классов не получают экранных копий."""
    assert is_open_frame("safenet_t00012")
    assert not is_open_frame("c05_s3") and not is_open_frame("b_0001") and not is_open_frame("elhaz_t00001_x0")


def test_kaggle_kernel_is_private(tmp_path, monkeypatch):
    """Папка ноутбука получает закрытое описание с видеокартой и список опытов как литерал Python."""
    import json
    import kaggle_push
    monkeypatch.setattr(kaggle_push, "ROOT", str(tmp_path))
    os.makedirs(tmp_path / "cv")
    (tmp_path / "cv" / "kaggle_train.py").write_text("EXPERIMENTS = []\n", encoding="utf-8")
    folder = build("k-test", [{"name": "a", "screen": True}], "user/set")
    meta = json.load(open(os.path.join(folder, "kernel-metadata.json")))
    assert meta["is_private"] is True and meta["enable_gpu"] is True and meta["dataset_sources"] == ["user/set"]
    assert "True" in open(os.path.join(folder, "train.py")).read()
