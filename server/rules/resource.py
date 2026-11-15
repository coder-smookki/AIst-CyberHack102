"""Нормативный срок службы, расчётный остаточный ресурс узла и межремонтные интервалы агрегата.

Нормативная и расчётная оценки возвращаются отдельными блоками и не смешиваются; фактическое
состояние узла сюда не входит - его даёт диагностика.
"""
from datetime import date, datetime, timedelta
from operator import itemgetter
from typing import Any

from .thresholds import as_number

APPROACHING_PERCENT = 80.0
DUE_PERCENT = 100.0
DAYS_IN_YEAR = 365.25
ESTIMATE_NOTE = "Оценка расчётная"


def accrue_hours(hours: float, mode: str, elapsed_hours: float) -> float:
    """Прибавляет наработку за прошедшее время только в режиме «в работе»; в остановленном она не растёт."""
    if mode != "running" or elapsed_hours <= 0:
        return hours
    return hours + elapsed_hours


def _as_date(value) -> date | None:
    """Приводит дату, момент времени или строку ГГГГ-ММ-ДД к дате; при ошибке возвращает None."""
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if isinstance(value, str):
        try:
            return date.fromisoformat(value[:10])
        except ValueError:
            return None
    return None


def _fmt(value: float) -> str:
    """Записывает число без лишних нулей: не больше одного знака после точки."""
    return f"{round(value, 1):.1f}".rstrip("0").rstrip(".")


def _years_word(years: float) -> str:
    """Подбирает форму слова «год» к числу лет."""
    if years != int(years):
        return "года"
    tail = int(years) % 100
    if 11 <= tail <= 14:
        return "лет"
    if tail % 10 == 1:
        return "год"
    if 2 <= tail % 10 <= 4:
        return "года"
    return "лет"


def _state(used_percent: float) -> str:
    """Переводит долю израсходованного ресурса в состояние: от 80 % - срок приближается, от 100 % - наступил."""
    if used_percent >= DUE_PERCENT:
        return "due"
    if used_percent >= APPROACHING_PERCENT:
        return "approaching"
    return "ok"


def _daily_hours(equipment: dict, run_hours: float | None, today: date) -> float | None:
    """Считает среднюю суточную наработку агрегата с ввода в эксплуатацию; None, если данных нет."""
    commissioned = _as_date(equipment.get("commissioned"))
    if commissioned is None or run_hours is None:
        return None
    days = (today - commissioned).days
    if days <= 0 or run_hours <= 0:
        return None
    return run_hours / days


def _normative(node: dict) -> dict:
    """Собирает блок нормативного срока службы: часы, годы и документ-источник."""
    hours = as_number(node.get("norm_hours"))
    years = as_number(node.get("norm_years"))
    parts = []
    if hours is not None:
        parts.append(f"{_fmt(hours)} ч")
    if years is not None:
        parts.append(f"{_fmt(years)} {_years_word(years)}")
    text = "Норматив: " + " или ".join(parts) if parts else "Норматив не задан"
    return {"hours": hours, "years": years, "source": node.get("source"), "text": text}


def _hours_meter(equipment: dict, node: dict, run_hours: float | None, today: date, missing: list) -> dict | None:
    """Оценивает ресурс по наработке; при нехватке входных данных дописывает их в missing и возвращает None."""
    norm = as_number(node.get("norm_hours"))
    node_hours = as_number(node.get("hours"))
    if node_hours is None:
        missing.append("наработка узла в часах")
        return None
    base = as_number(equipment.get("run_hours"))
    if run_hours is not None and base is not None and run_hours > base:
        node_hours += run_hours - base
    used_percent = node_hours / norm * 100.0
    remaining = max(norm - node_hours, 0.0)
    meter = {
        "meter": "hours",
        "used": round(node_hours, 1),
        "norm": norm,
        "state": _state(used_percent),
        "used_percent": round(used_percent, 1),
        "remaining_hours": round(remaining, 1),
        "overrun_hours": round(max(node_hours - norm, 0.0), 1),
        "overrun_days": None,
        "remaining_days": None,
        "note": None,
    }
    if equipment.get("mode") == "stopped":
        meter["note"] = "Агрегат остановлен: наработка не прирастает, дата по наработке не прогнозируется"
        return meter
    daily = _daily_hours(equipment, run_hours if run_hours is not None else base, today)
    if daily is None:
        meter["note"] = "Нет даты ввода в эксплуатацию или наработки агрегата: дата по наработке не прогнозируется"
        return meter
    meter["remaining_days"] = int(remaining / daily)
    meter["note"] = f"Средняя суточная наработка агрегата {_fmt(daily)} ч"
    return meter


def _calendar_meter(node: dict, today: date, missing: list) -> dict | None:
    """Оценивает ресурс по календарному сроку от даты последней замены или установки."""
    norm_years = as_number(node.get("norm_years"))
    start = _as_date(node.get("replaced")) or _as_date(node.get("installed"))
    if start is None:
        missing.append("дата установки или последней замены узла")
        return None
    if start > today:
        missing.append("дата установки узла позже текущей даты")
        return None
    norm_days = norm_years * DAYS_IN_YEAR
    elapsed = (today - start).days
    return {
        "meter": "calendar",
        "used": elapsed,
        "norm": round(norm_days),
        "state": _state(elapsed / norm_days * 100.0),
        "used_percent": round(elapsed / norm_days * 100.0, 1),
        "remaining_hours": None,
        "overrun_hours": None,
        "overrun_days": max(int(elapsed - norm_days), 0),
        "remaining_days": max(int(norm_days - elapsed), 0),
        "note": f"Отсчёт с {start.strftime('%d.%m.%Y')}",
    }


def _calculated_text(result: dict) -> str:
    """Составляет строку расчётной оценки для карточки узла и отчёта."""
    if result["state"] == "insufficient_data":
        return "Недостаточно данных для оценки: " + "; ".join(result["missing"])
    limiting = next(meter for meter in result["meters"] if meter["meter"] == result["limiting"])
    basis = "по наработке" if result["limiting"] == "hours" else "по календарному сроку"
    used = f"израсходовано {_fmt(result['used_percent'])} % ({basis})"
    if result["state"] == "due":
        tail = ""
        if limiting["overrun_hours"]:
            tail = f", превышение {_fmt(limiting['overrun_hours'])} ч"
        elif limiting["overrun_days"]:
            tail = f", превышение {limiting['overrun_days']} сут"
        return f"Срок наступил: {used}{tail}. {ESTIMATE_NOTE}"
    head = "Срок приближается: " + used if result["state"] == "approaching" else "И" + used[1:]
    remaining = []
    if result["remaining_hours"] is not None:
        remaining.append(f"около {_fmt(result['remaining_hours'])} ч по наработке")
    if result["remaining_days"] is not None:
        remaining.append(f"около {result['remaining_days']} сут")
    text = f"{head}. Остаток {', '.join(remaining)}"
    if result["forecast_date"]:
        forecast = date.fromisoformat(result["forecast_date"])
        text += f", ориентировочно до {forecast.strftime('%d.%m.%Y')}"
    elif result["remaining_days"] is None:
        note = next((meter["note"] for meter in result["meters"] if meter["remaining_days"] is None), None)
        if note:
            text += f". {note}"
    return f"{text}. {ESTIMATE_NOTE}"


def _calculated(equipment: dict, node: dict, run_hours: float | None, today: date) -> dict:
    """Собирает блок расчётного остатка: по каждому измерителю отдельно, итог - по самому израсходованному."""
    result: dict[str, Any] = {
        "state": "insufficient_data",
        "used_percent": None,
        "remaining_hours": None,
        "remaining_days": None,
        "forecast_date": None,
        "limiting": None,
        "meters": [],
        "missing": [],
        "text": "",
    }
    has_hours_norm = (as_number(node.get("norm_hours")) or 0) > 0
    has_years_norm = (as_number(node.get("norm_years")) or 0) > 0
    if not has_hours_norm and not has_years_norm:
        result["missing"].append("нормативный срок службы узла (часы или годы)")
    if has_hours_norm:
        meter = _hours_meter(equipment, node, run_hours, today, result["missing"])
        if meter:
            result["meters"].append(meter)
    if has_years_norm:
        meter = _calendar_meter(node, today, result["missing"])
        if meter:
            result["meters"].append(meter)
    if not result["missing"]:
        limiting = max(result["meters"], key=itemgetter("used_percent"))
        days = [meter["remaining_days"] for meter in result["meters"]]
        result["state"] = limiting["state"]
        result["used_percent"] = limiting["used_percent"]
        result["limiting"] = limiting["meter"]
        result["remaining_hours"] = next(
            (meter["remaining_hours"] for meter in result["meters"] if meter["meter"] == "hours"), None
        )
        if all(value is not None for value in days):
            result["remaining_days"] = min(days)
            if result["state"] != "due":
                result["forecast_date"] = (today + timedelta(days=min(days))).isoformat()
    result["text"] = _calculated_text(result)
    return result


def resource_estimates(equipment: dict, node: dict, run_hours: float, today: date) -> dict:
    """Возвращает оценки ресурса узла тремя раздельными блоками.

    normative - срок службы по документам; calculated - расчётный остаток с состоянием
    "ok", "approaching" (от 80 %), "due" (от 100 %) или "insufficient_data" со списком того,
    чего не хватает; actual - всегда None: фактическое состояние определяет диагностика.
    Наработка узла на текущий момент - его часы из карточки плюс прирост счётчика агрегата
    run_hours относительно значения в карточке; счётчик растёт только в режиме «в работе».
    """
    today_date = _as_date(today)
    if today_date is None:
        raise ValueError("Не задана текущая дата для расчёта ресурса")
    return {
        "node_id": node.get("id"),
        "normative": _normative(node),
        "calculated": _calculated(equipment, node, as_number(run_hours), today_date),
        "actual": None,
    }


def maintenance_intervals(equipment: dict, run_hours: float | None = None) -> list[dict]:
    """Сравнивает наработку после последнего обслуживания с интервалом каждого вида ТО агрегата.

    run_hours - текущая наработка агрегата; без неё берётся значение из карточки. Для записи без
    интервала или отметки последнего обслуживания состояние "insufficient_data" и список недостающего.
    """
    current = as_number(run_hours)
    if current is None:
        current = as_number(equipment.get("run_hours"))
    result = []
    for item in equipment.get("maintenance") or []:
        interval = as_number(item.get("interval_hours"))
        last = as_number(item.get("last_at_hours"))
        entry = {
            "code": item.get("code"),
            "name": item.get("name") or item.get("code"),
            "work": item.get("work"),
            "interval_hours": interval,
            "last_at_hours": last,
            "since_hours": None,
            "used_percent": None,
            "remaining_hours": None,
            "state": "insufficient_data",
            "missing": [],
        }
        if interval is None or interval <= 0:
            entry["missing"].append("интервал обслуживания в часах")
        if last is None:
            entry["missing"].append("наработка на момент последнего обслуживания")
        if current is None:
            entry["missing"].append("текущая наработка агрегата")
        if not entry["missing"]:
            since = max(current - last, 0.0)
            entry["since_hours"] = round(since, 1)
            entry["used_percent"] = round(since / interval * 100.0, 1)
            entry["remaining_hours"] = round(max(interval - since, 0.0), 1)
            entry["state"] = _state(since / interval * 100.0)
        result.append(entry)
    return result
