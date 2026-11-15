"""Тесты правил диагностики, уставок заказчика, оценки ресурса и прогноза времени до уставки."""

import ast
import copy
import io
import json
import random
import tokenize
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest

from server.rules import (
    CUSTOMER_THRESHOLDS,
    EQUIPMENT_NODE,
    GAUGE_READING,
    NO_DATA_LABEL,
    NORMAL_LABEL,
    STRONG_CONFIDENCE,
    WEAK_CONFIDENCE,
    accrue_hours,
    defect_signs,
    diagnose,
    gauge_difference_percent,
    hours_to_threshold,
    load_rules,
    maintenance_intervals,
    parameter_level,
    resource_estimates,
    temperature_label,
    vibration_label,
)

ROOT = Path(__file__).resolve().parents[1]
VIBRATION_FILE = ROOT / "data" / "customer" / "Вибрация" / "БД значений (вибрация).xlsx"
TEMPERATURE_FILE = ROOT / "data" / "customer" / "Температура" / "БД значений (температура).xlsx"
OWN_FILES = [*sorted((ROOT / "server" / "rules").glob("*.py")), Path(__file__)]
TODAY = date(2026, 11, 10)

VIBRATION_SAMPLES = (
    ("2026-11-12 08:00", 0.68, 0.26, 0.08, "Норма"),
    ("2026-11-15 11:00", 2.79, 0.55, 0.11, "Норма"),
    ("2026-11-20 04:00", 1.29, 1.76, 0.07, "Норма"),
    ("2026-11-11 00:00", 0.8, 0.34, 0, "Норма"),
    ("2026-11-25 06:00", 0.8, 0.26, 2.47, "Норма"),
    ("2026-11-15 14:00", 2.85, 0.52, 0.05, "Пред: Рост дисбаланса"),
    ("2026-11-17 00:00", 4.44, 0.65, 0.15, "Пред: Рост дисбаланса"),
    ("2026-11-17 02:00", 4.52, 0.69, 0.12, "Тревога: Выс. дисбаланс (РК)"),
    ("2026-11-17 19:00", 5.25, 0.87, 0.1, "Тревога: Выс. дисбаланс (РК)"),
    ("2026-11-20 08:00", 1.23, 1.81, 0.13, "Пред: Ухудшение центровки"),
    ("2026-11-21 09:00", 1.52, 2.96, 0.05, "Пред: Ухудшение центровки"),
    ("2026-11-21 12:00", 1.51, 3.08, 0.04, "Тревога: Расцентровка"),
    ("2026-11-22 18:00", 1.98, 4.27, 0, "Тревога: Расцентровка"),
    ("2026-11-25 09:00", 0.76, 0.28, 2.57, "Пред: Износ/Шум"),
    ("2026-11-27 01:00", 0.81, 0.28, 4.99, "Пред: Износ/Шум"),
    ("2026-11-27 02:00", 0.89, 0.37, 5.09, "Тревога: Дефект подшипника"),
    ("2026-11-27 18:00", 0.89, 0.3, 6, "Тревога: Дефект подшипника"),
)
TEMPERATURE_SAMPLES = (
    ("2026-11-17 12:00", 46.7, 65.9, "Норма"),
    ("2026-11-26 16:00", 74.4, 64.1, "Норма"),
    ("2026-11-29 08:00", 50.3, 89.6, "Норма"),
    ("2026-11-26 17:00", 75.2, 64.6, "Пред: Рост темп. подш."),
    ("2026-11-27 06:00", 88, 64.9, "Пред: Рост темп. подш."),
    ("2026-11-27 08:00", 90.2, 66.1, "Тревога: Перегрев подш. насоса"),
    ("2026-11-27 17:00", 98.5, 63.2, "Тревога: Перегрев подш. насоса"),
    ("2026-11-29 07:00", 47.9, 90.5, "Пред: Рост темп. ЭД"),
    ("2026-11-30 11:00", 49.6, 109.8, "Пред: Рост темп. ЭД"),
    ("2026-11-30 12:00", 50.8, 110.4, "Тревога: Перегрев обмоток ЭД"),
    ("2026-12-01 03:00", 50.8, 120.7, "Тревога: Перегрев обмоток ЭД"),
)
NORMAL = {
    "rpm": 2950,
    "vib_rms": 1.0,
    "vib_1x": 0.8,
    "vib_2x": 0.3,
    "vib_hf": 0.1,
    "vib_axial": 0.6,
    "temp_bearing": 50.0,
    "temp_winding": 65.0,
    "current_a": 11.0,
    "current_b": 11.05,
    "current_c": 10.95,
    "current_unbalance": 0.5,
    "press_in": 1.5,
    "press_out": 4.6,
    "press_out_true": 4.6,
    "flow": 47.0,
    "power": 5.5,
    "efficiency": 73.5,
    "mode": 1,
}
FLAT = {code: 0.0 for code in NORMAL}


def _equipment(equipment_id: str = "N-101") -> dict:
    """Возвращает копию карточки агрегата из data/equipment.json."""
    with open(ROOT / "data" / "equipment.json", encoding="utf-8") as file:
        units = json.load(file)["equipment"]
    return copy.deepcopy(next(unit for unit in units if unit["id"] == equipment_id))


def _pump() -> dict:
    """Возвращает насос Н-101 со свежим обслуживанием, чтобы правило R11 не мешало проверке остальных."""
    pump = _equipment()
    for item in pump["maintenance"]:
        item["last_at_hours"] = pump["run_hours"]
    return pump


def _readings(**changes) -> dict:
    """Возвращает нормальные показания с заменой отдельных параметров; None убирает параметр."""
    readings = dict(NORMAL)
    readings.update(changes)
    return {code: value for code, value in readings.items() if value is not None}


def _find(result: dict, rule_id: str) -> dict | None:
    """Ищет находку правила в результате диагностики."""
    return next((finding for finding in result["findings"] if finding["rule_id"] == rule_id), None)


def _run(readings=None, trends=None, visual=None, manual=frozenset(), equipment=None) -> dict:
    """Запускает диагностику насоса Н-101 с нормальными показаниями по умолчанию."""
    return diagnose(
        equipment or _pump(),
        NORMAL if readings is None else readings,
        FLAT if trends is None else trends,
        visual or {},
        manual,
    )


def _customer_rows(path: Path) -> list:
    """Читает строки базы заказчика без заголовка; без файла тест пропускается."""
    if not path.exists():
        pytest.skip(f"нет файла заказчика: {path}")
    import openpyxl

    sheet = openpyxl.load_workbook(path, data_only=True, read_only=True).worksheets[0]
    return list(sheet.iter_rows(values_only=True))[1:]


def _slope(values: list) -> float | None:
    """Считает наклон прямой наименьших квадратов за один шаг; меньше четырёх точек - None."""
    count = len(values)
    if count < 4:
        return None
    mean_x = (count - 1) / 2
    mean_y = sum(values) / count
    spread = sum((index - mean_x) ** 2 for index in range(count))
    return sum((index - mean_x) * (value - mean_y) for index, value in enumerate(values)) / spread


def _series(start: float, step: float, count: int = 12, noise=None) -> list:
    """Строит почасовой ряд: линейный рост с необязательной добавкой шума."""
    begin = datetime(2026, 11, 25, 0, 0)
    return [(begin + timedelta(hours=index), start + step * index + (noise[index] if noise else 0.0)) for index in range(count)]


def test_vibration_label_samples():
    """Диагноз по вибрации совпадает с колонкой заказчика на контрольных строках, включая ближайшие к уставкам."""
    for moment, first, second, noise, expected in VIBRATION_SAMPLES:
        readings = {"vib_1x": first, "vib_2x": second, "vib_hf": noise}
        assert vibration_label(readings) == expected, moment


def test_temperature_label_samples():
    """Диагноз по температуре совпадает с колонкой заказчика на контрольных строках."""
    for moment, bearing, winding, expected in TEMPERATURE_SAMPLES:
        readings = {"temp_bearing": bearing, "temp_winding": winding}
        assert temperature_label(readings) == expected, moment


def test_label_priority_and_bounds():
    """Тревога важнее предупреждения, при равных уровнях берётся первый параметр, уставка сама по себе не превышение."""
    assert vibration_label({"vib_1x": 3.0, "vib_2x": 0.3, "vib_hf": 5.5}) == "Тревога: Дефект подшипника"
    assert vibration_label({"vib_1x": 3.0, "vib_2x": 2.0, "vib_hf": 3.0}) == "Пред: Рост дисбаланса"
    assert vibration_label({"vib_1x": 5.0, "vib_2x": 3.5, "vib_hf": 6.0}) == "Тревога: Выс. дисбаланс (РК)"
    assert vibration_label({"vib_1x": 2.8, "vib_2x": 1.8, "vib_hf": 2.5}) == NORMAL_LABEL
    assert vibration_label({"vib_1x": 4.5, "vib_2x": 3.0, "vib_hf": 5.0}) == "Пред: Рост дисбаланса"
    assert temperature_label({"temp_bearing": 80, "temp_winding": 115}) == "Тревога: Перегрев обмоток ЭД"
    assert temperature_label({"temp_bearing": 80, "temp_winding": 95}) == "Пред: Рост темп. подш."
    assert temperature_label({"temp_bearing": 75, "temp_winding": 90}) == NORMAL_LABEL


def test_label_without_data_is_not_normal():
    """Без части параметров «Норма» не выдаётся, но уже превышенная уставка называется."""
    assert vibration_label({}) == NO_DATA_LABEL
    assert vibration_label({"vib_1x": 0.8, "vib_2x": 0.3}) == NO_DATA_LABEL
    assert vibration_label({"vib_1x": 0.8, "vib_2x": None, "vib_hf": 0.1}) == NO_DATA_LABEL
    assert vibration_label({"vib_hf": 5.4}) == "Тревога: Дефект подшипника"
    assert temperature_label({"temp_winding": 60}) == NO_DATA_LABEL
    assert temperature_label({"temp_bearing": float("nan"), "temp_winding": 60}) == NO_DATA_LABEL


def test_customer_files_match_all_rows():
    """Обе базы заказчика воспроизводятся полностью: 500 из 500 строк по вибрации и 500 из 500 по температуре."""
    vibration = _customer_rows(VIBRATION_FILE)
    temperature = _customer_rows(TEMPERATURE_FILE)
    assert len(vibration) == 500 and len(temperature) == 500
    wrong = [row for row in vibration if vibration_label({"vib_1x": row[3], "vib_2x": row[4], "vib_hf": row[5]}) != row[6]]
    wrong += [row for row in temperature if temperature_label({"temp_bearing": row[2], "temp_winding": row[3]}) != row[4]]
    assert wrong == []
    labels = {row[6] for row in vibration} | {row[4] for row in temperature}
    known = {NORMAL_LABEL} | {row[key] for row in CUSTOMER_THRESHOLDS for key in ("warn_label", "alarm_label")}
    assert labels == known


def test_parameter_level():
    """Уровень параметра относительно уставок заказчика: норма, предупреждение, тревога; без уставок - None."""
    assert parameter_level("vib_1x", 2.0) == "ok"
    assert parameter_level("vib_1x", 2.81) == "warn"
    assert parameter_level("temp_winding", 110.4) == "alarm"
    assert parameter_level("press_in", 1.5) is None
    assert parameter_level("vib_hf", None) is None


def test_rules_file_structure():
    """В файле правил есть все 12 правил заказчика с обязательными полями и без длинных тире."""
    rules = load_rules()
    by_id = {rule["id"]: rule for rule in rules}
    customer = [rule["id"] for rule in rules if rule.get("group") == "customer"]
    assert customer == [f"R{number:02d}" for number in range(1, 13)]
    for rule in rules:
        assert rule["title"] and rule["diagnosis"] and rule["recommendation"]
        assert rule["severity"] in (1, 2, 3)
        assert rule["applies_to"] and isinstance(rule["node"], str) and rule["node"]
    text = (ROOT / "data" / "rules.json").read_text(encoding="utf-8")
    assert chr(0x2014) not in text and chr(0x2013) not in text
    rules[0]["title"] = "изменено"
    assert load_rules()[0]["title"] != "изменено"
    assert "ref" not in json.dumps(by_id["R01"]["parts"])


def test_load_rules_groups():
    """Группы правил: 12 заказчика, 5 уставок, одно по звуку, 7 демонстрационных для шкафа и трансформатора, одно визуальное."""
    assert len(load_rules("customer")) == 12
    assert [rule["id"] for rule in load_rules("threshold")] == ["S01", "S02", "S03", "S04", "S05"]
    assert [rule["id"] for rule in load_rules("sound")] == ["N01"]
    assert [rule["id"] for rule in load_rules("demo")] == ["C01", "C02", "C03", "T01", "T02", "T03", "T04"]
    assert [rule["id"] for rule in load_rules("visual")] == ["V01"]
    assert len(load_rules()) == 26


def test_shared_constants_and_defect_signs():
    """Пороги уверенности, служебные ключи и перечень дефектных признаков доступны остальным модулям."""
    assert (WEAK_CONFIDENCE, STRONG_CONFIDENCE) == (0.25, 0.5)
    assert EQUIPMENT_NODE == "equipment" and GAUGE_READING == "gauge_reading"
    signs = defect_signs()
    assert {"leak", "corrosion", "terminal_box_burnt", "coupling_no_guard"} <= set(signs)
    assert not {"motor", "pump_casing", "flange", "coupling_guard", "terminal_box", "nameplate", "gauge"} & set(signs)
    used = set()
    for rule in load_rules():
        for part in rule["parts"]:
            stack = [part["expr"]]
            while stack:
                expr = stack.pop()
                stack.extend(expr.get("all", []) + expr.get("any", []))
                used.update(expr.get("signs", []))
    assert used <= set(signs)


def test_rules_file_errors(tmp_path, monkeypatch):
    """Отсутствующий, повреждённый или неполный файл правил даёт понятную ошибку, а не молчаливый пропуск."""
    from server.rules import engine

    cases = (
        (None, "не найден"),
        ("{ не json", "повреждён"),
        ('{"rules": [{"id": "R99"}]}', "В правиле R99 нет полей"),
    )
    engine._document.cache_clear()
    try:
        for number, (content, message) in enumerate(cases):
            path = tmp_path / f"rules_{number}.json"
            if content is not None:
                path.write_text(content, encoding="utf-8")
            monkeypatch.setattr(engine, "RULES_FILE", path)
            engine._document.cache_clear()
            with pytest.raises(RuntimeError, match=message):
                load_rules()
        unknown_kind = json.loads((ROOT / "data" / "rules.json").read_text(encoding="utf-8"))
        unknown_kind["rules"][0]["parts"][0]["expr"]["kind"] = "smell"
        path = tmp_path / "rules_kind.json"
        path.write_text(json.dumps(unknown_kind, ensure_ascii=False), encoding="utf-8")
        monkeypatch.setattr(engine, "RULES_FILE", path)
        engine._document.cache_clear()
        with pytest.raises(RuntimeError, match="неизвестного вида"):
            diagnose(_pump(), NORMAL, FLAT, {})
    finally:
        monkeypatch.undo()
        engine._document.cache_clear()
    assert len(load_rules()) == 26


def test_inputs_of_other_types():
    """Числа numpy принимаются как обычные, а нечисловые значения и пропуски считаются отсутствием данных."""
    numpy = pytest.importorskip("numpy")
    visual = {"leak": numpy.float32(0.8), "motor": numpy.float64(0.9), "corrosion": "0.9", "crack": None}
    readings = _readings(vib_hf=numpy.float64(3.2), temp_bearing=numpy.int64(80), time="2026-11-26 17:00", flow=None)
    result = diagnose(_pump(), readings, {"vib_hf": None, "temp_bearing": numpy.float32(0.5)}, visual, ["oil_dark"])
    assert _find(result, "R01")["status"] == "defect"
    assert _find(result, "R03")["status"] == "defect"
    assert _find(result, "R02") is None and _find(result, "V01") is None
    assert json.loads(json.dumps(result, ensure_ascii=False))["status"] == "defect"
    nothing = diagnose(_pump(), None, None, None, None)
    assert nothing["status"] == "unknown"


def test_threshold_rules_repeat_customer_labels():
    """Правила уставок S01-S05 содержат те же числа и формулировки диагнозов, что и таблица уставок заказчика."""
    rules = {rule["parts"][0]["expr"]["param"]: rule for rule in load_rules() if rule.get("group") == "threshold"}
    assert set(rules) == {row["code"] for row in CUSTOMER_THRESHOLDS}
    for row in CUSTOMER_THRESHOLDS:
        rule = rules[row["code"]]
        assert rule["parts"][0]["expr"]["value"] == row["warn"]
        assert rule["escalation"]["expr"]["value"] == row["alarm"]
        assert f"«{row['warn_label']}»" in rule["diagnosis"]
        assert f"«{row['alarm_label']}»" in rule["escalation"]["diagnosis"]


def test_result_contract():
    """Результат диагностики имеет оговорённый состав полей и типы значений."""
    result = _run(_readings(vib_hf=3.2, temp_bearing=80.0), visual={"leak": 0.8, "motor": 0.9})
    assert set(result) == {"status", "findings", "nodes"}
    assert result["status"] == "defect"
    for finding in result["findings"]:
        assert set(finding) == {
            "rule_id",
            "title",
            "node_id",
            "status",
            "severity",
            "diagnosis",
            "recommendation",
            "confidence",
            "evidence",
            "missing",
        }
        assert finding["status"] in ("check", "defect") and finding["severity"] in (1, 2, 3)
        assert 0.0 <= finding["confidence"] <= 1.0
        assert finding["node_id"] in result["nodes"]
        for line in finding["evidence"]:
            assert set(line) == {"source", "what", "value", "threshold", "met"}
            assert line["source"] in ("camera", "sensor", "resource", "manual")
            assert isinstance(line["met"], bool) and isinstance(line["value"], str)
        assert all(isinstance(hint, str) for hint in finding["missing"])
    statuses = [finding["status"] for finding in result["findings"]]
    assert statuses == sorted(statuses, key=["defect", "check"].index)
    assert set(result["nodes"]) >= {node["id"] for node in _pump()["nodes"]}
    assert result["nodes"]["motor"] == {"status": "ok", "reasons": ["Камера: видимых проблем не обнаружено"]}


def test_normal_state_and_no_data():
    """Нормальные показания дают «ok» без находок; без каких-либо данных состояние неизвестно, а не исправно."""
    normal = _run()
    assert normal["status"] == "ok" and normal["findings"] == []
    assert normal["nodes"]["motor_bearings"]["status"] == "ok"
    assert normal["nodes"]["flanges"]["status"] == "unknown"
    empty = diagnose(_pump(), {}, {}, {})
    assert empty["status"] == "unknown" and empty["findings"] == []
    assert all(node["status"] == "unknown" for node in empty["nodes"].values())
    no_telemetry = diagnose(_equipment("AMS-1"), {}, {}, {"motor": 0.9})
    assert no_telemetry["status"] == "ok"
    assert no_telemetry["nodes"]["motor"]["status"] == "ok"
    assert no_telemetry["nodes"]["seal"]["status"] == "unknown"


def test_r01_seal_leak():
    """R01: течь у вала с ростом вибрации и температуры подшипника - дефект; только датчики - проверка с подсказкой."""
    full = _find(_run(_readings(vib_hf=3.2, temp_bearing=80.0), visual={"leak": 0.8}), "R01")
    assert full["status"] == "defect" and full["severity"] == 3 and full["node_id"] == "seal"
    assert full["missing"] == [] and full["confidence"] == 0.9
    assert {line["source"] for line in full["evidence"] if line["met"]} == {"camera", "sensor"}
    partial = _find(_run(_readings(vib_hf=3.2, temp_bearing=80.0)), "R01")
    assert partial["status"] == "check" and partial["confidence"] == 0.5
    assert partial["missing"] == ["наведите камеру на зону уплотнения вала"]
    assert _find(_run(), "R01") is None
    assert _find(_run(_readings(vib_hf=3.2)), "R01") is None


def test_r02_foundation_looseness():
    """R02: коррозия или дефект анкерного болта с ростом вибрации 1x - ослабление крепления; иначе частично."""
    full = _find(_run(_readings(vib_1x=3.5), visual={"corrosion": 0.7}), "R02")
    assert full["status"] == "defect" and full["node_id"] == "casing"
    assert "мягкая лапа" in full["diagnosis"]
    frame = diagnose(_equipment("AMS-1"), {"vib_1x": 3.5}, {}, {}, {"anchor_bolt_loose"})
    assert _find(frame, "R02")["status"] == "defect" and _find(frame, "R02")["node_id"] == "frame"
    by_trend = _find(_run(trends=dict(FLAT, vib_1x=0.045)), "R02")
    assert by_trend["status"] == "check"
    assert by_trend["missing"] == ["наведите камеру на раму и анкерные болты"]
    camera = _find(_run(visual={"corrosion": 0.7}), "R02")
    assert camera["status"] == "defect" and camera["severity"] == 2 and camera["confidence"] == 0.7
    assert _find(_run(), "R02") is None


def test_r03_lubricant():
    """R03: тёмное масло или низкий уровень с температурой подшипника на 10 °C выше нормы - потеря свойств смазки."""
    full = _find(_run(_readings(temp_bearing=62.0), manual={"oil_dark"}), "R03")
    assert full["status"] == "defect" and full["node_id"] == "motor_bearings"
    assert any(line["source"] == "manual" and line["met"] for line in full["evidence"])
    partial = _find(_run(_readings(temp_bearing=62.0)), "R03")
    assert partial["status"] == "check" and "смотровом стекле" in partial["missing"][0]
    assert _find(_run(_readings(temp_bearing=58.0)), "R03") is None
    lone = _find(_run(manual={"oil_low"}), "R03")
    assert lone["status"] == "defect" and lone["confidence"] == 1.0


def test_r04_terminal_box():
    """R04: следы перегрева на клеммной коробке с небалансом токов более 5 % - плохой контакт."""
    full = _find(_run(_readings(current_unbalance=7.5), visual={"terminal_box_burnt": 0.75}), "R04")
    assert full["status"] == "defect" and full["severity"] == 3 and full["node_id"] == "terminal_box"
    partial = _find(_run(_readings(current_unbalance=7.5)), "R04")
    assert partial["status"] == "check" and partial["missing"] == ["наведите камеру на клеммную коробку"]
    phases = _readings(current_a=11.9, current_b=10.6, current_c=10.5, current_unbalance=None)
    computed = _find(_run(phases), "R04")
    assert computed["status"] == "check"
    assert any("фазы" in line["value"] and line["met"] for line in computed["evidence"])
    seen_normal = _find(_run(_readings(current_unbalance=7.5), visual={"terminal_box": 0.9}), "R04")
    assert seen_normal["status"] == "check" and "наведите камеру на клеммную коробку" not in seen_normal["missing"]
    checked = _find(_run(_readings(current_unbalance=7.5), manual={"checked:terminal_box"}), "R04")
    assert checked["status"] == "check" and "наведите камеру на клеммную коробку" not in checked["missing"]
    heating = _find(_run(visual={"terminal_box_burnt": 0.6}, manual={"local_heating"}), "R04")
    assert heating["status"] == "defect" and heating["severity"] == 3
    assert _find(_run(_readings(current_unbalance=2.0)), "R04") is None


def test_r05_gauge_mismatch():
    """R05: показание манометра, считанное камерой, расходится с датчиком более чем на 15 %; без чтения находки нет."""
    full = _find(_run(_readings(gauge_reading=4.6, press_out=3.68)), "R05")
    assert full["status"] == "defect" and full["node_id"] == "gauge"
    assert full["evidence"][0]["source"] == "camera" and "расхождение 20 %" in full["evidence"][0]["value"]
    assert _find(_run(_readings(gauge_reading=4.6, press_out=4.2)), "R05") is None
    assert _find(_run(_readings(press_out=3.68)), "R05") is None
    assert gauge_difference_percent(4.6, 3.68) == pytest.approx(20.0)
    assert gauge_difference_percent(0.0, 0.0) == 0.0
    assert gauge_difference_percent(0.0, 2.0) == pytest.approx(100.0)


def test_r06_coupling_guard_needs_no_sensors():
    """R06: отсутствие кожуха муфты - дефект с запретом эксплуатации без единого показания датчиков."""
    result = diagnose(_pump(), {}, {}, {"coupling_no_guard": 0.8})
    full = _find(result, "R06")
    assert result["status"] == "defect"
    assert full["status"] == "defect" and full["severity"] == 3 and full["node_id"] == "coupling"
    assert "Эксплуатация запрещена" in full["recommendation"]
    assert all(line["source"] == "camera" for line in full["evidence"])
    weak = _find(diagnose(_pump(), {}, {}, {"coupling_no_guard": 0.3}), "R06")
    assert weak["status"] == "check" and weak["confidence"] == 0.3 and weak["missing"]
    by_hand = _find(diagnose(_pump(), {}, {}, {}, {"coupling_guard_shifted"}), "R06")
    assert by_hand["status"] == "defect"
    in_place = diagnose(_pump(), {}, {}, {"coupling_guard": 0.9})
    assert _find(in_place, "R06") is None and in_place["nodes"]["coupling"]["status"] == "ok"
    sticky = diagnose(_pump(), {}, {}, {"coupling_guard": 0.9, "coupling_no_guard": 0.6})
    assert _find(sticky, "R06")["status"] == "defect"


def test_r07_cavitation_confirmed_on_site():
    """R07: падение давления на входе и рост ВЧ вибрации, подтверждённые признаком на месте, - кавитация."""
    readings = _readings(press_in=0.6, vib_hf=3.5)
    full = _find(_run(readings, manual={"cavitation_noise"}), "R07")
    assert full["status"] == "defect" and full["severity"] == 3 and full["node_id"] == "casing"
    partial = _find(_run(readings), "R07")
    assert partial["status"] == "check" and "признаки кавитации" in partial["missing"][0]
    lone = _find(_run(manual={"flow_instability"}), "R07")
    assert lone["status"] == "check"
    assert _find(_run(), "R07") is None
    assert _find(_run(_readings(vib_hf=3.5)), "R07") is None


def test_r08_bearing_wear():
    """R08: вибрация и температура подшипника растут при нормальном токе - износ подшипников или проблема смазки."""
    full = _find(_run(_readings(vib_hf=3.2, temp_bearing=80.0)), "R08")
    assert full["status"] == "defect" and full["node_id"] == "motor_bearings" and full["confidence"] == 1.0
    no_current = _readings(vib_hf=3.2, temp_bearing=80.0, current_a=None, current_b=None, current_c=None)
    partial = _find(_run(no_current), "R08")
    assert partial["status"] == "check" and partial["missing"] == ["нет данных: токи фаз двигателя"]
    raised = _readings(vib_hf=3.2, temp_bearing=80.0, current_a=12.0, current_b=12.0, current_c=12.0)
    assert _find(_run(raised), "R08")["status"] == "check"
    assert _find(_run(_readings(vib_hf=3.2)), "R08") is None
    assert _find(_run(_readings(temp_bearing=80.0)), "R08") is None
    assert _find(_run(), "R08") is None


def test_r08_early_warning_by_trends():
    """Правило, выполненное только по трендам при значениях в пределах уставок, даёт раннее предупреждение, а не дефект."""
    trends = dict(FLAT, vib_hf=0.06, temp_bearing=0.6)
    early = _find(_run(_readings(vib_hf=1.9, temp_bearing=55.0), trends), "R08")
    assert early["status"] == "check" and early["diagnosis"].startswith("Ранний признак")
    mixed = _find(_run(_readings(vib_hf=3.2, temp_bearing=55.0), trends), "R08")
    assert mixed["status"] == "defect"
    assert _find(_run(_readings(vib_hf=1.9, temp_bearing=55.0), dict(FLAT, vib_hf=0.01, temp_bearing=0.2)), "R08") is None
    unknown_trend = _find(_run(_readings(vib_hf=1.9, temp_bearing=55.0), {"vib_hf": None}), "R08")
    assert unknown_trend is None


def test_r09_misalignment():
    """R09: высокая вибрация на муфте при нормальной температуре и слегка повышенном токе - расцентровка валов."""
    high = _readings(vib_axial=3.5, vib_2x=2.4, current_a=11.7, current_b=11.6, current_c=11.8)
    full = _find(_run(high), "R09")
    assert full["status"] == "defect" and full["node_id"] == "coupling" and full["confidence"] == 1.0
    partial = _find(_run(_readings(vib_axial=3.5)), "R09")
    assert partial["status"] == "check" and partial["confidence"] == pytest.approx(0.67)
    hot = _find(_run(dict(high, temp_winding=95.0)), "R09")
    assert hot["status"] == "check"
    by_second_harmonic = _find(_run(_readings(vib_2x=2.4, vib_axial=None)), "R09")
    assert by_second_harmonic["status"] == "check"
    assert _find(_run(), "R09") is None
    assert _find(_run(_readings(current_a=11.7, current_b=11.6, current_c=11.8)), "R09") is None


def test_r10_hydraulic_wear():
    """R10: КПД ниже паспортного на 15 % при нормальных вибрации и температуре - износ проточной части."""
    full = _find(_run(_readings(efficiency=61.0, flow=39.0)), "R10")
    assert full["status"] == "defect" and full["node_id"] == "casing"
    assert "паспортном 73.8 %" in full["evidence"][0]["value"]
    partial = _find(_run(_readings(efficiency=61.0, vib_1x=3.5)), "R10")
    assert partial["status"] == "check"
    no_vibration = _readings(efficiency=61.0, vib_1x=None, vib_2x=None, vib_hf=None)
    assert "нет данных вибрации" in _find(_run(no_vibration), "R10")["missing"][0]
    assert _find(_run(_readings(efficiency=64.0)), "R10") is None
    assert _find(_run(_readings(efficiency=0.0, mode=0, rpm=0)), "R10") is None
    assert _find(_run(_readings(efficiency=None)), "R10") is None


def test_r11_maintenance_interval():
    """R11: наработка после последнего обслуживания достигла интервала - находка с перечнем работ; до срока её нет."""
    pump = _equipment()
    before = diagnose(pump, _readings(run_hours=19190), FLAT, {})
    assert _find(before, "R11") is None
    after = _find(diagnose(pump, _readings(run_hours=19200), FLAT, {}), "R11")
    assert after["status"] == "check" and after["severity"] == 2 and after["node_id"] == "equipment"
    assert "ТО-1" in after["diagnosis"] and "ТО-2" in after["diagnosis"] and "Ревизия" not in after["diagnosis"]
    assert "проверка зазора муфты" in after["recommendation"]
    assert [line["met"] for line in after["evidence"]] == [True, True, False]
    assert all(line["source"] == "resource" for line in after["evidence"])
    from_card = _find(diagnose(dict(pump, run_hours=22100), {}, {}, {}), "R11")
    assert "Ревизия" in from_card["diagnosis"]
    assert _find(_run(_readings(run_hours=19200)), "R11") is None
    assert _find(diagnose(_equipment("AMS-1"), {"run_hours": 9800}, {}, {}), "R11") is None


def test_r12_cavitation_by_sensors():
    """R12: падение давления на входе с ростом широкополосной вибрации - кавитация по датчикам без камеры."""
    full = _find(_run(_readings(press_in=0.6, vib_hf=3.5)), "R12")
    assert full["status"] == "defect" and full["node_id"] == "casing" and full["missing"] == []
    partial = _find(_run(_readings(press_in=0.6)), "R12")
    assert partial["status"] == "check"
    falling = _find(_run(_readings(press_in=1.35), dict(FLAT, press_in=-0.04, vib_rms=0.03)), "R12")
    assert falling["status"] == "check" and falling["diagnosis"].startswith("Ранний признак")
    assert _find(_run(), "R12") is None
    assert _find(_run(_readings(vib_hf=3.5)), "R12") is None
    assert _find(_run(_readings(press_in=None, vib_hf=3.5)), "R12") is None


def test_seal_type_nuance():
    """Течь у сальниковой набивки без подтверждения датчиками - проверка, у торцевого уплотнения - дефект."""
    mechanical = _find(_run(visual={"leak": 0.8}), "R01")
    assert mechanical["status"] == "defect" and "торцевое уплотнение не должно течь" in mechanical["diagnosis"]
    gland_pump = _pump()
    next(node for node in gland_pump["nodes"] if node["id"] == "seal")["seal_type"] = "gland"
    gland = _find(_run(visual={"leak": 0.8}, equipment=gland_pump), "R01")
    assert gland["status"] == "check" and gland["severity"] == 1
    assert "5-20 капель в минуту - норма" in gland["diagnosis"]
    confirmed = _find(_run(_readings(vib_hf=3.2, temp_bearing=80.0), visual={"leak": 0.8}, equipment=gland_pump), "R01")
    assert confirmed["status"] == "defect" and confirmed["severity"] == 3
    untyped_pump = _pump()
    del next(node for node in untyped_pump["nodes"] if node["id"] == "seal")["seal_type"]
    untyped = _find(_run(visual={"leak": 0.8}, equipment=untyped_pump), "R01")
    assert untyped["status"] == "defect" and "Тип уплотнения в карточке узла не указан" in untyped["diagnosis"]


def test_missing_hints_are_short_and_specific():
    """Подсказки называют, чего именно не хватает: параметра, нормы для типа оборудования или точек для тренда."""
    no_telemetry = _find(diagnose(_equipment("AMS-1"), {}, {}, {"leak": 0.8}), "R01")
    assert no_telemetry["status"] == "defect"
    assert no_telemetry["missing"] == [
        "нет данных: ВЧ шум вибрации",
        "нет данных: СКЗ вибрации",
        "нет данных: Температура подшипника",
    ]
    no_baseline = _find(diagnose(_equipment("AMS-1"), {"temp_bearing": 70.0, "vib_hf": 3.0}, {}, {"leak": 0.8}), "R01")
    assert no_baseline["missing"] == [
        "для этого типа оборудования не задана нормальная температура подшипника",
        "недостаточно точек для тренда: Температура подшипника",
    ]
    no_noise = _find(_run(_readings(press_in=0.6, vib_hf=None), {}), "R12")
    assert no_noise["missing"] == ["нет данных: ВЧ шум вибрации", "недостаточно точек для тренда: СКЗ вибрации"]
    for finding in _run(_readings(vib_hf=3.2, temp_bearing=80.0), visual={"leak": 0.8})["findings"]:
        assert len(finding["missing"]) <= 1


def test_lone_camera_defect_is_never_missed():
    """Одиночный уверенный дефектный признак камеры без данных датчиков всегда даёт находку не ниже «проверки»."""
    for sign in ("leak", "corrosion", "terminal_box_burnt", "coupling_no_guard", "crack", "anchor_bolt_missing"):
        for equipment in (_pump(), _equipment("AMS-2"), {"id": "X-1", "type": "valve", "nodes": []}):
            result = diagnose(equipment, {}, {}, {sign: 0.5})
            assert result["status"] in ("check", "defect"), (sign, equipment["id"])
            assert len(result["findings"]) == 1 and result["findings"][0]["confidence"] == 0.5
            assert result["findings"][0]["node_id"] in result["nodes"]
    normal_sensors = _run(visual={"corrosion": 0.9})
    assert normal_sensors["status"] == "defect" and normal_sensors["nodes"]["casing"]["status"] == "defect"


def test_visual_signs_outside_rules():
    """Признак без своего правила не теряется: уверенный - дефект, слабый - проверка, ниже 0.25 - не учитывается."""
    strong = _run(visual={"crack": 0.7})
    assert _find(strong, "V01")["status"] == "defect" and "трещина" in _find(strong, "V01")["diagnosis"]
    assert _find(strong, "V01")["node_id"] == "equipment" and strong["nodes"]["equipment"]["status"] == "defect"
    weak = _find(_run(visual={"crack": 0.3}), "V01")
    assert weak["status"] == "check" and weak["missing"]
    assert _run(visual={"crack": 0.2, "leak": 0.24})["findings"] == []
    assert _run(visual={"motor": 0.95, "gauge": 0.9, "unknown_part": 0.9})["findings"] == []
    by_hand = _find(_run(manual={"посторонний шум"}), "V01")
    assert by_hand["status"] == "defect" and by_hand["evidence"][0]["source"] == "manual"
    assert _find(_run(visual={"leak": 0.8}), "V01") is None


def test_every_model_defect_class_reaches_diagnosis():
    """Каждый дефектный класс из описания моделей - известный признак: уверенная рамка даёт находку, а не теряется."""
    described = ROOT / "models" / "models.json"
    if not described.exists():
        pytest.skip("Нет описания моделей models/models.json")
    entries = json.loads(described.read_text(encoding="utf-8"))
    classes = {cls for entry in entries for cls in entry.get("defect_classes") or []}
    assert classes and classes <= set(defect_signs())
    for cls in sorted(classes):
        result = _run(visual={cls: 0.9})
        assert result["status"] in ("check", "defect") and result["findings"], cls


def test_sensor_thresholds_give_customer_diagnosis():
    """Превышение уставки заказчика даёт находку с его формулировкой: предупреждение - проверка, тревога - дефект."""
    cases = (
        ("vib_1x", 3.0, 5.0, "S01", "casing"),
        ("vib_2x", 2.0, 3.5, "S02", "coupling"),
        ("vib_hf", 3.0, 5.5, "S03", "motor_bearings"),
        ("temp_bearing", 80.0, 95.0, "S04", "motor_bearings"),
        ("temp_winding", 95.0, 115.0, "S05", "motor"),
    )
    for code, warn_value, alarm_value, rule_id, node_id in cases:
        row = next(row for row in CUSTOMER_THRESHOLDS if row["code"] == code)
        warn = _find(_run(_readings(**{code: warn_value})), rule_id)
        assert warn["status"] == "check" and warn["node_id"] == node_id and row["warn_label"] in warn["diagnosis"]
        alarm = _find(_run(_readings(**{code: alarm_value})), rule_id)
        assert alarm["status"] == "defect" and alarm["severity"] == 3 and row["alarm_label"] in alarm["diagnosis"]
        assert _find(_run(), rule_id) is None
    only_vibration = diagnose({"id": "X-2", "type": "fan", "nodes": []}, {"vib_1x": 5.0}, {}, {})
    assert _find(only_vibration, "S01")["status"] == "defect"


def test_customer_timeline_replay():
    """Прогон обеих баз заказчика: находки по уставкам повторяют его диагнозы в каждой строке, спокойные часы чисты."""
    vibration = _customer_rows(VIBRATION_FILE)
    temperature = _customer_rows(TEMPERATURE_FILE)
    pump = _pump()
    labels = {row["code"]: (rule_id, row) for rule_id, row in zip(("S01", "S02", "S03", "S04", "S05"), CUSTOMER_THRESHOLDS)}
    columns = {
        "vib_rms": [row[2] for row in vibration],
        "vib_1x": [row[3] for row in vibration],
        "vib_2x": [row[4] for row in vibration],
        "vib_hf": [row[5] for row in vibration],
        "temp_bearing": [row[2] for row in temperature],
        "temp_winding": [row[3] for row in temperature],
    }
    statuses = []
    for index in range(len(vibration)):
        readings = _readings(rpm=vibration[index][1], **{code: values[index] for code, values in columns.items()})
        trends = {code: _slope(values[max(0, index - 11) : index + 1]) for code, values in columns.items()}
        result = diagnose(pump, readings, trends, {})
        statuses.append(result["status"])
        expected = {vibration[index][6], temperature[index][4]} - {NORMAL_LABEL}
        found = set()
        for rule_id, row in labels.values():
            finding = _find(result, rule_id)
            if finding:
                key = "alarm_label" if finding["status"] == "defect" else "warn_label"
                assert row[key] in finding["diagnosis"]
                found.add(row[key])
        assert found == expected, vibration[index][0]
    assert set(statuses[:80]) == {"ok"}
    moments = [row[0] for row in vibration]
    assert statuses[moments.index("2026-11-17 16:00")] == "defect"
    assert statuses[moments.index("2026-11-22 18:00")] == "defect"
    assert statuses[moments.index("2026-11-25 03:00")] == "check"
    assert statuses[moments.index("2026-11-25 09:00")] == "defect"
    assert statuses[moments.index("2026-11-30 12:00")] == "defect"
    assert statuses[moments.index("2026-11-23 12:00")] == "ok"


def test_all_customer_rules_fire_on_telemetry_scenarios():
    """На ленте телеметрии в пике сценариев срабатывают все ожидаемые правила, а с признаками камеры - все 12 полностью."""
    if not VIBRATION_FILE.exists() or not TEMPERATURE_FILE.exists():
        pytest.skip("нет баз заказчика для ленты телеметрии")
    telemetry = pytest.importorskip("server.telemetry")
    player = telemetry.build_player("N-101")
    pump = _equipment()
    visual = {"leak": 0.8, "corrosion": 0.8, "terminal_box_burnt": 0.8, "coupling_no_guard": 0.8}
    manual = {"oil_dark", "cavitation_noise"}
    texts = {rule["id"]: rule["diagnosis"] for rule in load_rules("customer")}
    complete = set()
    for scenario in player.scenarios():
        moment = scenario["peak"]
        readings = player.snapshot(moment)
        trends = {code: player.trend(code, 12, moment) for code in telemetry.CODES}
        sensors_only = diagnose(pump, readings, trends, {})
        if not scenario["expected_rules"]:
            assert sensors_only["status"] == "ok" and sensors_only["findings"] == [], scenario["id"]
            continue
        with_gauge = dict(readings, gauge_reading=readings["press_out_true"])
        found = {finding["rule_id"]: finding for finding in diagnose(pump, with_gauge, trends, {})["findings"]}
        assert set(scenario["expected_rules"]) <= set(found), scenario["id"]
        for rule_id in set(scenario["expected_rules"]) & {"R05", "R08", "R09", "R10", "R12"}:
            assert found[rule_id]["status"] == "defect", (scenario["id"], rule_id)
        for finding in diagnose(pump, with_gauge, trends, visual, manual)["findings"]:
            rule_id = finding["rule_id"]
            same_text = rule_id == "R11" or finding["diagnosis"] == texts.get(rule_id)
            if same_text and finding["missing"] == []:
                complete.add(rule_id)
    assert set(texts) <= complete


def test_resource_three_separate_blocks():
    """Оценка ресурса отдаёт норматив и расчёт раздельно, а фактическое состояние не подменяет."""
    pump = _equipment()
    bearings = next(node for node in pump["nodes"] if node["id"] == "motor_bearings")
    estimate = resource_estimates(pump, bearings, 19190, TODAY)
    assert set(estimate) == {"node_id", "normative", "calculated", "actual"}
    assert estimate["actual"] is None
    assert estimate["normative"]["hours"] == 20000 and estimate["normative"]["years"] is None
    assert estimate["normative"]["source"].startswith("Документация производителя")
    assert estimate["normative"]["text"] == "Норматив: 20000 ч"
    calculated = estimate["calculated"]
    assert calculated["state"] == "approaching" and calculated["limiting"] == "hours"
    assert calculated["used_percent"] == 96.0 and calculated["remaining_hours"] == 810.0
    assert calculated["remaining_days"] == 87 and calculated["forecast_date"] == "2027-02-05"
    assert calculated["missing"] == []
    assert calculated["text"].startswith("Срок приближается: израсходовано 96 % (по наработке). Остаток около 810 ч")
    assert calculated["text"].endswith("ориентировочно до 05.02.2027. Оценка расчётная")


def test_resource_states_by_run_hours():
    """Состояние ресурса меняется с наработкой: в норме, приближается с 80 %, срок наступил со 100 %."""
    pump = _equipment()
    seal = next(node for node in pump["nodes"] if node["id"] == "seal")
    assert resource_estimates(pump, dict(seal, hours=3000), 19190, TODAY)["calculated"]["state"] == "ok"
    assert resource_estimates(pump, dict(seal, hours=11999), 19190, TODAY)["calculated"]["state"] == "ok"
    assert resource_estimates(pump, dict(seal, hours=12000), 19190, TODAY)["calculated"]["state"] == "approaching"
    grown = resource_estimates(pump, seal, 21000, TODAY)["calculated"]
    assert grown["state"] == "due" and grown["used_percent"] == 100.0 and grown["remaining_hours"] == 0.0
    assert grown["forecast_date"] is None
    overdue = resource_estimates(pump, seal, 21500, TODAY)["calculated"]
    assert overdue["state"] == "due" and "превышение 500 ч" in overdue["text"]
    assert overdue["meters"][0]["overrun_hours"] == 500.0


def test_resource_hours_count_only_while_running():
    """В остановленном режиме наработка не прирастает и дата по наработке не прогнозируется; календарный срок идёт."""
    assert accrue_hours(100.0, "running", 5.0) == 105.0
    assert accrue_hours(100.0, "stopped", 5.0) == 100.0
    assert accrue_hours(100.0, "running", -3.0) == 100.0
    stopped = _equipment()
    stopped["mode"] = "stopped"
    bearings = next(node for node in stopped["nodes"] if node["id"] == "motor_bearings")
    calculated = resource_estimates(stopped, bearings, 19190, TODAY)["calculated"]
    assert calculated["state"] == "approaching" and calculated["remaining_hours"] == 810.0
    assert calculated["remaining_days"] is None and calculated["forecast_date"] is None
    assert "остановлен" in calculated["meters"][0]["note"]
    gauge = next(node for node in stopped["nodes"] if node["id"] == "gauge")
    calendar = resource_estimates(stopped, gauge, 19190, TODAY)["calculated"]
    assert calendar["state"] == "approaching" and calendar["limiting"] == "calendar"
    assert calendar["used_percent"] == 88.6 and calendar["remaining_days"] == 83
    assert calendar["forecast_date"] == "2027-02-01" and calendar["remaining_hours"] is None
    later = resource_estimates(stopped, gauge, 19190, date(2027, 3, 1))["calculated"]
    assert later["state"] == "due"


def test_resource_two_meters_take_the_most_used():
    """При нормативе и в часах, и в годах итог берётся по самому израсходованному измерителю."""
    unit = _equipment("AMS-1")
    node = next(node for node in unit["nodes"] if node["id"] == "unit")
    estimate = resource_estimates(unit, node, 9800, TODAY)
    assert estimate["normative"]["text"] == "Норматив: 11000 ч или 20 лет"
    calculated = estimate["calculated"]
    assert [meter["meter"] for meter in calculated["meters"]] == ["hours", "calendar"]
    assert calculated["limiting"] == "hours" and calculated["state"] == "approaching"
    assert calculated["used_percent"] == 89.1 and calculated["remaining_hours"] == 1200.0


def test_resource_forecast_is_not_borrowed_from_another_meter():
    """Дата прогноза строится только тогда, когда её можно посчитать по каждому измерителю узла."""
    stopped = _equipment("AMS-2")
    unit = next(node for node in stopped["nodes"] if node["id"] == "unit")
    calculated = resource_estimates(stopped, unit, 10650, TODAY)["calculated"]
    assert calculated["state"] == "approaching" and calculated["limiting"] == "hours"
    assert calculated["remaining_hours"] == 350.0
    assert calculated["remaining_days"] is None and calculated["forecast_date"] is None
    assert "Агрегат остановлен" in calculated["text"]
    running = _equipment("AMS-1")
    motor = next(node for node in running["nodes"] if node["id"] == "motor")
    both = resource_estimates(running, motor, 9800, TODAY)["calculated"]
    assert both["state"] == "ok" and both["limiting"] == "calendar"
    assert both["remaining_days"] == min(meter["remaining_days"] for meter in both["meters"])
    sensor = next(node for node in running["nodes"] if node["id"] == "temp_sensor")
    overdue = resource_estimates(running, sensor, 9800, TODAY)["calculated"]
    assert overdue["state"] == "due" and overdue["limiting"] == "calendar" and overdue["forecast_date"] is None
    assert "превышение 478 сут" in overdue["text"]


def test_resource_insufficient_data_lists_what_is_missing():
    """Без норматива, наработки или даты установки значение не выдумывается: перечисляется, чего не хватает."""
    pump = _equipment()
    motor = next(node for node in pump["nodes"] if node["id"] == "motor")
    no_norm = resource_estimates(pump, motor, 19190, TODAY)
    assert no_norm["calculated"]["state"] == "insufficient_data"
    assert no_norm["calculated"]["missing"] == ["нормативный срок службы узла (часы или годы)"]
    assert no_norm["calculated"]["used_percent"] is None and no_norm["calculated"]["forecast_date"] is None
    assert no_norm["normative"]["text"] == "Норматив не задан"
    assert no_norm["calculated"]["text"].startswith("Недостаточно данных для оценки")
    no_hours = resource_estimates(pump, {"id": "x", "norm_hours": 5000, "hours": None}, 19190, TODAY)["calculated"]
    assert no_hours["state"] == "insufficient_data" and no_hours["missing"] == ["наработка узла в часах"]
    no_date = resource_estimates(pump, {"id": "y", "norm_years": 2}, 19190, TODAY)["calculated"]
    assert no_date["state"] == "insufficient_data"
    assert no_date["missing"] == ["дата установки или последней замены узла"]
    half = {"id": "z", "norm_hours": 5000, "hours": 1000, "norm_years": 2}
    partly = resource_estimates(pump, half, 19190, TODAY)["calculated"]
    assert partly["state"] == "insufficient_data" and partly["used_percent"] is None
    assert [meter["meter"] for meter in partly["meters"]] == ["hours"]
    future = {"id": "w", "norm_years": 2, "installed": "2027-01-01"}
    assert resource_estimates(pump, future, 19190, TODAY)["calculated"]["state"] == "insufficient_data"


def test_maintenance_intervals():
    """Межремонтные интервалы считаются от наработки на момент последнего обслуживания."""
    pump = _equipment()
    before = {item["code"]: item for item in maintenance_intervals(pump, 19190)}
    assert before["TO-1"]["state"] == "approaching" and before["TO-1"]["remaining_hours"] == 10.0
    assert before["TO-2"]["since_hours"] == 7990.0 and before["TO-2"]["used_percent"] == 99.9
    assert before["TR"]["state"] == "approaching" and before["TR"]["used_percent"] == 82.4
    after = {item["code"]: item for item in maintenance_intervals(pump, 19200)}
    assert after["TO-1"]["state"] == "due" and after["TO-2"]["state"] == "due" and after["TR"]["state"] == "approaching"
    assert maintenance_intervals(pump) == maintenance_intervals(pump, 19190)
    assert maintenance_intervals(_equipment("AMS-1"), 9800) == []
    broken = {"maintenance": [{"code": "TO-1", "name": "ТО-1", "interval_hours": 4000}]}
    assert maintenance_intervals(broken, 100)[0]["state"] == "insufficient_data"
    assert maintenance_intervals(broken, 100)[0]["missing"] == ["наработка на момент последнего обслуживания"]


def test_forecast_linear_growth():
    """Ровный линейный рост даёт точное время до уставки от последней точки окна."""
    points = _series(60.0, 1.0)
    assert hours_to_threshold(points, 75.0) == 4.0
    assert hours_to_threshold(points, 90.0) == 19.0
    assert hours_to_threshold(list(reversed(points)), 75.0) == 4.0
    assert hours_to_threshold(points, 75.0, "high") == 4.0
    half_hour = [(moment + timedelta(minutes=30 * index), value) for index, (moment, value) in enumerate(points)]
    assert hours_to_threshold(half_hour, 75.0) == 6.0


def test_forecast_is_hidden_when_unreliable():
    """Прогноз не показывается при ровном или уходящем от уставки тренде, шуме, нехватке точек и дальнем горизонте."""
    assert hours_to_threshold(_series(60.0, 0.0), 75.0) is None
    assert hours_to_threshold(_series(60.0, -0.5), 75.0) is None
    assert hours_to_threshold(_series(60.0, 1.0, count=3), 75.0) is None
    assert hours_to_threshold([], 75.0) is None
    generator = random.Random(7)
    noise = [generator.uniform(-3.0, 3.0) for _ in range(12)]
    assert hours_to_threshold(_series(60.0, 0.1, noise=noise), 75.0) is None
    assert hours_to_threshold(_series(60.0, 0.05), 75.0) is None
    with_gaps = [(moment, None if index % 2 else value) for index, (moment, value) in enumerate(_series(60.0, 1.0, 6))]
    assert hours_to_threshold(with_gaps, 75.0) is None
    same_moment = [(datetime(2026, 11, 25), 60.0 + index) for index in range(5)]
    assert hours_to_threshold(same_moment, 75.0) is None


def test_forecast_direction():
    """Для уставки снизу прогноз строится по падению; достигнутая уставка при заданной стороне даёт ноль."""
    falling = _series(1.5, -0.05)
    assert hours_to_threshold(falling, 0.75, "low") == 4.0
    assert hours_to_threshold(falling, 0.75) == 4.0
    assert hours_to_threshold(falling, 2.0, "high") is None
    assert hours_to_threshold(_series(80.0, 1.0), 75.0, "high") == 0.0
    assert hours_to_threshold(_series(80.0, 1.0), 75.0) is None
    assert hours_to_threshold(_series(0.5, -0.05), 1.0, "low") == 0.0


def test_forecast_on_customer_data():
    """На базе заказчика прогноз за 12 часов до уставки ВЧ шума близок к факту, а в спокойные часы не строится."""
    rows = _customer_rows(VIBRATION_FILE)
    moments = [datetime.strptime(row[0], "%Y-%m-%d %H:%M") for row in rows]
    noise = [row[5] for row in rows]
    crossing = next(index for index, value in enumerate(noise) if value > 5.0)
    start = crossing - 12
    window = list(zip(moments[start - 23 : start + 1], noise[start - 23 : start + 1]))
    assert 9.0 <= hours_to_threshold(window, 5.0, "high") <= 15.0
    for last in range(24, 80):
        quiet = list(zip(moments[last - 23 : last + 1], noise[last - 23 : last + 1]))
        assert hours_to_threshold(quiet, 2.5) is None


def test_own_code_has_docstrings_and_no_comments():
    """В файлах модуля правил нет комментариев с решёткой, а у каждого модуля, класса и функции есть докстринг."""
    for path in OWN_FILES:
        source = path.read_text(encoding="utf-8")
        tokens = tokenize.generate_tokens(io.StringIO(source).readline)
        assert [token.string for token in tokens if token.type == tokenize.COMMENT] == [], path.name
        tree = ast.parse(source)
        assert ast.get_docstring(tree), path.name
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                assert ast.get_docstring(node), f"{path.name}: {node.name}"
