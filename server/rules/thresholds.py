"""Уставки заказчика по вибрации и температуре и диагнозы в формулировках его баз.

Строки диагнозов и числа взяты из файлов заказчика без изменений: функции этого модуля
обязаны повторять колонки «Диагноз по вибрации» и «Диагноз по температуре» строка в строку.
"""
import math
from numbers import Real

NORMAL_LABEL = "Норма"
NO_DATA_LABEL = "Недостаточно данных"

CUSTOMER_THRESHOLDS = (
    {
        "code": "vib_1x",
        "kind": "vibration",
        "name": "Амплитуда вибрации 1x",
        "unit": "мм/с",
        "warn": 2.8,
        "alarm": 4.5,
        "warn_label": "Пред: Рост дисбаланса",
        "alarm_label": "Тревога: Выс. дисбаланс (РК)",
    },
    {
        "code": "vib_2x",
        "kind": "vibration",
        "name": "Амплитуда вибрации 2x",
        "unit": "мм/с",
        "warn": 1.8,
        "alarm": 3.0,
        "warn_label": "Пред: Ухудшение центровки",
        "alarm_label": "Тревога: Расцентровка",
    },
    {
        "code": "vib_hf",
        "kind": "vibration",
        "name": "ВЧ шум вибрации",
        "unit": "g",
        "warn": 2.5,
        "alarm": 5.0,
        "warn_label": "Пред: Износ/Шум",
        "alarm_label": "Тревога: Дефект подшипника",
    },
    {
        "code": "temp_bearing",
        "kind": "temperature",
        "name": "Температура подшипника",
        "unit": "°C",
        "warn": 75.0,
        "alarm": 90.0,
        "warn_label": "Пред: Рост темп. подш.",
        "alarm_label": "Тревога: Перегрев подш. насоса",
    },
    {
        "code": "temp_winding",
        "kind": "temperature",
        "name": "Температура обмоток двигателя",
        "unit": "°C",
        "warn": 90.0,
        "alarm": 110.0,
        "warn_label": "Пред: Рост темп. ЭД",
        "alarm_label": "Тревога: Перегрев обмоток ЭД",
    },
)


def as_number(value) -> float | None:
    """Возвращает число с плавающей точкой или None, если значение не является конечным числом.

    Принимаются и числовые типы numpy: уверенность детектора часто приходит именно в них.
    """
    if isinstance(value, bool) or not isinstance(value, Real):
        return None
    number = float(value)
    return number if math.isfinite(number) else None


def _label(kind: str, readings: dict) -> str:
    """Выбирает диагноз заказчика: сначала тревоги, затем предупреждения, в порядке параметров таблицы.

    Сравнение строгое («выше уставки»). Если ни одна уставка не превышена, но части параметров нет,
    возвращается «Недостаточно данных», а не «Норма».
    """
    rows = [row for row in CUSTOMER_THRESHOLDS if row["kind"] == kind]
    values = {row["code"]: as_number((readings or {}).get(row["code"])) for row in rows}
    for level in ("alarm", "warn"):
        for row in rows:
            value = values[row["code"]]
            if value is not None and value > row[level]:
                return row[level + "_label"]
    if any(value is None for value in values.values()):
        return NO_DATA_LABEL
    return NORMAL_LABEL


def vibration_label(readings: dict) -> str:
    """Возвращает диагноз по вибрации для показаний vib_1x, vib_2x, vib_hf в формулировке заказчика."""
    return _label("vibration", readings)


def temperature_label(readings: dict) -> str:
    """Возвращает диагноз по температуре для показаний temp_bearing, temp_winding в формулировке заказчика."""
    return _label("temperature", readings)


def parameter_level(code: str, value) -> str | None:
    """Сравнивает значение с уставками заказчика: "ok", "warn" или "alarm".

    Возвращает None, если для параметра уставок заказчика нет или значение не число.
    """
    number = as_number(value)
    for row in CUSTOMER_THRESHOLDS:
        if row["code"] != code:
            continue
        if number is None:
            return None
        if number > row["alarm"]:
            return "alarm"
        if number > row["warn"]:
            return "warn"
        return "ok"
    return None
