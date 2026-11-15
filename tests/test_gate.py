"""Проверки чистых функций порога качества cv/gate.py."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cv"))

from gate import check, clean_rate, defect_checks, latency_check, part_checks, tolerance, verdict


def test_tolerance_is_one_image_or_floor():
    """Допуск - одно изображение набора, но не меньше двух процентных пунктов."""
    assert tolerance(8) == 0.125
    assert tolerance(519) == 0.02
    assert tolerance(None) == 0.02


def test_check_direction_and_tolerance():
    """Ухудшение в пределах допуска проходит, за пределами - нет, в обе стороны показателя."""
    assert check("найден", 0.9, 0.89, True, 0.02)["result"] == "PASS"
    assert check("найден", 0.9, 0.85, True, 0.02)["result"] == "FAIL"
    assert check("тревоги", 0.10, 0.11, False, 0.02)["result"] == "PASS"
    assert check("тревоги", 0.10, 0.20, False, 0.02)["result"] == "FAIL"
    assert check("тревоги", 0.10, 0.0, False, 0.02)["result"] == "PASS"


def test_check_missing_values():
    """Отсутствующее у обоих значение не ошибка, отсутствующее только у кандидата - провал."""
    assert check("x", None, None, True, 0.02)["result"] == "PASS"
    assert check("x", 0.5, None, True, 0.02)["result"] == "FAIL"


def test_latency_check_allows_twenty_percent():
    """Время вывода может вырасти не больше чем на 20%."""
    assert latency_check("t", 100.0, 119.0)["result"] == "PASS"
    assert latency_check("t", 100.0, 125.0)["result"] == "FAIL"


def test_defect_and_part_checks_and_verdict():
    """Наборы проверок собираются из отчётов cv/delivered.py, итог FAIL при любой проваленной проверке."""
    base = {
        "map50": 0.45,
        "conf_served": {
            "image_defect_found": 0.75,
            "false_alarm_rate": None,
            "box_precision": 0.6,
            "defective_images": 8,
            "clean_images": 0,
        },
    }
    same = defect_checks("holdout", base, base)
    assert verdict(same) == "PASS" and len(same) == 4
    worse = {"map50": 0.45, "conf_served": dict(base["conf_served"], image_defect_found=0.5)}
    assert verdict(defect_checks("holdout", base, worse)) == "FAIL"
    parts = {"map50": 0.8, "conf_served": {"box_precision": 0.9, "box_recall": 0.9}}
    lower = {"map50": 0.8, "conf_served": {"box_precision": 0.9, "box_recall": 0.8}}
    assert verdict(part_checks("parts", parts, lower)) == "FAIL"
    assert verdict([]) == "FAIL"


def test_clean_rate():
    """Доля чистых снимков с тревогой."""
    assert clean_rate(1, 17) == 1 / 17
    assert clean_rate(0, 0) is None
