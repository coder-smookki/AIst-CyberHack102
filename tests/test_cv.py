"""Проверки чтения манометра и разбора шильдика без обращения к моделям."""
import json
import math
import os
import sys

import cv2
import numpy as np
import pytest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "cv"))
sys.path.insert(0, os.path.join(ROOT, "blender"))

from gauge import read_gauge
from nameplate import match_equipment, parse_fields


def dial_with_needle(tmp_path, value: float, tilt: float = 1.0) -> np.ndarray:
    """Рисует циферблат со стрелкой на заданном значении и при необходимости сжимает его, как при съёмке под углом."""
    import make_textures
    path = str(tmp_path / "dial.png")
    make_textures.gauge_dial(path, size=512)
    dial = cv2.imread(path)
    angle = math.radians((value / 10.0) * 270.0 - 135.0)
    center = 256
    tip = (int(center + 170 * math.sin(angle)), int(center - 170 * math.cos(angle)))
    cv2.line(dial, (center, center), tip, (10, 10, 10), 9)
    canvas = np.full((640, 640, 3), 90, np.uint8)
    mask = np.zeros((512, 512), np.uint8)
    cv2.circle(mask, (center, center), 245, 255, -1)
    canvas[64:576, 64:576][mask > 0] = dial[mask > 0]
    if tilt < 1.0:
        canvas = cv2.resize(canvas, (int(640 * tilt), 640))
    return canvas


@pytest.mark.parametrize("value", [0.5, 2.0, 3.7, 5.0, 6.4, 8.1, 9.5])
def test_gauge_front_view(tmp_path, value):
    """Показание на снимке анфас читается с ошибкой не больше 2% шкалы."""
    answer = read_gauge(dial_with_needle(tmp_path, value))
    assert answer["ok"]
    assert abs(answer["value"] - value) <= 0.2


@pytest.mark.parametrize("value", [1.5, 5.0, 8.5])
def test_gauge_tilted_view(tmp_path, value):
    """Циферблат, сжатый до 70% ширины, выпрямляется, и ошибка остаётся в пределах 5% шкалы."""
    answer = read_gauge(dial_with_needle(tmp_path, value, tilt=0.7))
    assert answer["ok"]
    assert abs(answer["value"] - value) <= 0.5


def test_gauge_without_dial():
    """Кадр без циферблата не даёт выдуманного показания."""
    answer = read_gauge(np.full((200, 200, 3), 40, np.uint8))
    assert answer["value"] is None and not answer["ok"]


def cards() -> list[dict]:
    """Загружает карточки оборудования из файла данных."""
    return json.load(open(os.path.join(ROOT, "data", "equipment.json"), encoding="utf-8"))["equipment"]


def test_nameplate_exact_serial():
    """Серийный номер и модель выделяются из строк шильдика, карточка находится точно."""
    lines = [{"text": "KST DEMO PUMPS"}, {"text": "Type IL 65/160-5,5/2"}, {"text": "No. 2786107-0142"}]
    fields = parse_fields(lines)
    assert fields["serial"] == "2786107-0142"
    assert fields["model"] == "IL 65/160-5,5/2"
    assert match_equipment(fields, cards())["card"]["id"] == "N-101"


def test_nameplate_fuzzy_serial():
    """Одна неверно распознанная цифра не мешает найти оборудование."""
    fields = parse_fields([{"text": "No. 2786107-0148"}])
    match = match_equipment(fields, cards())
    assert match["card"]["id"] == "N-101" and match["by"] == "serial_fuzzy"


def test_nameplate_unknown():
    """Незнакомый номер не подставляет чужую карточку."""
    fields = parse_fields([{"text": "No. 9912345-7777"}])
    assert match_equipment(fields, cards()) is None
