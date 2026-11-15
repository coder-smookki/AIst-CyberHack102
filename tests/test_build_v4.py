"""Проверки чистых функций сборки defects_ds_v4 (cv/build_defects_v4.py) и ноутбука cv/kaggle_train_v4.py."""
import os
import random
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cv"))

from build_defects_v4 import Index, class_names, is_mosaic, map_boxes, parse_rows, rank_items, safenet_original, union_share


def test_class_names_inline_and_block(tmp_path):
    """Имена классов читаются и из списка в скобках, и из построчного словаря."""
    (tmp_path / "data.yaml").write_text("nc: 2\nnames: ['burned socket', 'damage wire']\n", encoding="utf-8")
    assert class_names(str(tmp_path)) == ["burned socket", "damage wire"]
    (tmp_path / "data.yaml").write_text("names:\n  0: leakage\n  1: rock\ntrain: x\n", encoding="utf-8")
    assert class_names(str(tmp_path)) == ["leakage", "rock"]


def test_parse_rows_boxes_polygons_and_broken_lines():
    """Рамка и полигон переводятся в углы, битые строки и чужие номера классов пропускаются."""
    rows = parse_rows(["0 0.5 0.5 0.2 0.4", "1 0.1 0.1 0.3 0.1 0.3 0.4", "x 1 2 3 4", "7 0.5 0.5 0.1 0.1"],
                      ["leakage", "rock"])
    assert rows[0][0] == "leakage" and np.allclose(rows[0][1:], (0.4, 0.3, 0.6, 0.7))
    assert rows[1][0] == "rock" and np.allclose(rows[1][1:], (0.1, 0.1, 0.3, 0.4))
    assert len(rows) == 2


def test_map_boxes_rules():
    """Сопоставление учитывает skip_if, only_if, порог площади и закрытие всего кадра."""
    source = {"map": {"rust": "corrosion", "burned socket": "terminal_box_burnt"}, "skip_if": {"clean"},
              "min_area": {"corrosion": 0.01}, "max_cover": 0.9}
    small = ("rust", 0.1, 0.1, 0.15, 0.15)
    big = ("rust", 0.2, 0.2, 0.5, 0.5)
    assert map_boxes(source, [small]) is None
    assert map_boxes(source, [small, big]) == [("corrosion", 0.2, 0.2, 0.5, 0.5)]
    assert map_boxes(source, [big, ("clean", 0, 0, 1, 1)]) is None
    assert map_boxes(source, [("rust", 0.0, 0.0, 1.0, 1.0)]) is None
    only = dict(source, only_if={"burned socket"})
    assert map_boxes(only, [big]) is None
    assert map_boxes(only, [big, ("burned socket", 0.6, 0.6, 0.8, 0.8)])[1][0] == "terminal_box_burnt"


def test_union_share_counts_overlap_once():
    """Перекрытые рамки считаются по объединению, а не суммой площадей."""
    boxes = [("corrosion", 0.0, 0.0, 0.5, 0.5), ("corrosion", 0.0, 0.0, 0.5, 0.5)]
    assert abs(union_share(boxes) - 0.25) < 0.02


def test_is_mosaic_finds_four_tile_collage():
    """Склейка четырёх разных кадров узнаётся, гладкий градиент и одиночный шов нет."""
    rng = np.random.default_rng(0)
    tiles = [np.full((60, 80), value, np.uint8) for value in (30, 200, 120, 60)]
    collage = np.vstack([np.hstack(tiles[:2]), np.hstack(tiles[2:])])
    collage = (collage + rng.integers(0, 5, collage.shape)).astype(np.uint8)
    assert is_mosaic(collage)
    gradient = np.tile(np.linspace(0, 255, 160, dtype=np.uint8), (120, 1))
    assert not is_mosaic(gradient)
    halves = np.vstack([np.full((60, 160), 40, np.uint8), np.full((60, 160), 200, np.uint8)])
    assert not is_mosaic(halves)


def test_rank_items_puts_rare_first():
    """Снимки с редкими классами идут раньше снимков только с коррозией."""
    items = [(f"c{i}", [("corrosion", 0, 0, 1, 1)]) for i in range(5)] + [("leak", [("leak", 0, 0, 1, 1)])]
    ranked = rank_items(items, ("leak",), random.Random(0))
    assert ranked[0][0] == "leak" and len(ranked) == 6


def test_safenet_original_groups_crops():
    """Кадрирования одной фотографии SAFE-Net дают один номер исходника."""
    first = safenet_original("x/Image_832_8538-0_0_1200_1200_0_4912_3264.jpg")
    second = safenet_original("Image_832_8538-960_0_1200_1200_0_4912_3264.jpg")
    assert first == second == "Image_832_8538"


def test_index_finds_same_frame_not_other():
    """Тот же кадр находится на расстоянии 0, совсем другой кадр далеко."""
    rng = np.random.default_rng(1)
    frame = (rng.random((64, 64)) * 255).astype(np.uint8)
    index = Index()
    index.add("a", frame)
    assert index.nearest(frame) == (0, "a")
    other = (rng.random((64, 64)) * 255).astype(np.uint8)
    assert index.nearest(other)[0] > 8


def test_kaggle_v4_resume_and_weights(tmp_path, monkeypatch):
    """Прерванный опыт продолжается с last.pt из приложенного вывода, иначе берутся начальные веса."""
    import kaggle_train_v4 as notebook
    monkeypatch.setattr(notebook, "INPUT", str(tmp_path / "input"))
    monkeypatch.setattr(notebook, "OUT", str(tmp_path / "out"))
    monkeypatch.setattr(notebook, "WORK", str(tmp_path / "work"))
    data = tmp_path / "input" / "data" / "ds"
    for kind in ("images", "labels"):
        for split in ("train", "train_screen", "val"):
            os.makedirs(data / kind / split)
            (data / kind / split / f"{split}.{'jpg' if kind == 'images' else 'txt'}").write_text("x")
    os.makedirs(tmp_path / "input" / "init")
    (tmp_path / "input" / "init" / "v3.pt").write_text("w")
    experiment = {"name": "e1", "weights": "input:v3.pt", "epochs": 3, "minutes": 5}
    config = notebook.child_config(experiment, str(data))
    assert config["weights"].endswith("v3.pt") and "resume" not in config and config["epochs"] == 3
    assert len(os.listdir(tmp_path / "work" / "sets" / "e1" / "images" / "train")) == 2
    old = tmp_path / "input" / "prev" / "runs" / "e2" / "weights"
    os.makedirs(old)
    (old / "last.pt").write_text("l")
    config = notebook.child_config(dict(experiment, name="e2"), str(data))
    assert config["resume"] == config["weights"] == os.path.join(str(tmp_path / "out"), "runs", "e2", "weights", "last.pt")
    assert os.path.exists(config["resume"])
