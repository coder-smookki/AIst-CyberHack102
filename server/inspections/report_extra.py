"""Дополнительные разделы отчёта об осмотре: обход узлов, датчики с графиками, звук, рекомендации и подписи.

Данные датчиков берутся из ленты телеметрии на момент осмотра (сохранённый момент завершённого осмотра или
текущий момент ленты у идущего), графики - за 24 часа и 7 суток до этого момента с уставками параметров.
Правила, сработавшие по датчикам, пересчитываются на тот же момент только по датчикам и ресурсу.
"""
from datetime import datetime
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from server.auth import has_permission
from server.equipment import equipment_card
from server.models import Finding, Inspection, SoundRecord, User
from server.rules import diagnose, maintenance_intervals
from server.telemetry import CODES, TelemetryDataError, get_player

CHART_CODES = ("vib_rms", "vib_1x", "vib_2x", "vib_hf", "temp_bearing", "temp_winding")
CHART_GROUPS = (
    ("vibration", "Вибрация, мм/с", ("vib_rms", "vib_1x", "vib_2x")),
    ("vibration_hf", "ВЧ шум вибрации, g", ("vib_hf",)),
    ("temperature", "Температуры, °C", ("temp_bearing", "temp_winding")),
)
WINDOWS = (("24h", "24 часа", 24, 1), ("7d", "7 суток", 168, 3))
TREND_HOURS = 12
SEVERITY_ORDER = {3: 0, 2: 1, 1: 2}


def _stamp(moment: datetime | None) -> str | None:
    """Время в виде ISO с точностью до секунды."""
    return moment.isoformat(timespec="seconds") if moment else None


def _level(value: float | None, meta: dict) -> str | None:
    """Уровень значения относительно уставок параметра: ok, warn или alarm; без уставок - None."""
    direction = meta.get("direction")
    if value is None or direction not in ("high", "low"):
        return None
    for name in ("alarm", "warn"):
        limit = meta.get(name)
        if limit is not None and (value > limit if direction == "high" else value < limit):
            return name
    return "ok"


def sensors_section(inspection: Inspection, telemetry_at: str | None) -> dict:
    """Раздел датчиков: текущие значения с уставками, ряды за 24 ч и 7 сут, правила, сработавшие по датчикам.

    Без телеметрии у агрегата раздел помечается available = false с причиной.
    """
    try:
        player = get_player(inspection.equipment_id)
    except KeyError:
        return {"available": False, "reason": "Для этого оборудования нет телеметрии"}
    except TelemetryDataError as error:
        return {"available": False, "reason": str(error)}
    at = datetime.fromisoformat(telemetry_at) if telemetry_at else player.cursor
    metas = {meta["code"]: meta for meta in player.parameters(at)}
    readings = player.snapshot(at)
    current = []
    for code in CHART_CODES:
        meta = metas.get(code)
        if meta is None:
            continue
        value = readings.get(code)
        current.append({"code": code, "name": meta["name"], "unit": meta["unit"], "value": value,
                        "warn": meta.get("warn"), "alarm": meta.get("alarm"), "level": _level(value, meta),
                        "source": meta.get("source")})
    series: dict[str, Any] = {}
    for key, title, hours, step in WINDOWS:
        series[key] = {"title": title, "hours": hours, "codes": {}}
        for code in CHART_CODES:
            points = player.window(code, hours, at)[::step]
            series[key]["codes"][code] = [{"t": _stamp(moment), "v": value} for moment, value in points]
    trends = {}
    for code in CODES:
        slope = player.trend(code, TREND_HOURS, at)
        if slope is not None:
            trends[code] = slope
    card = equipment_card(inspection.equipment)
    fired = [found for found in diagnose(card, readings, trends, {})["findings"]
             if any(line["source"] in ("sensor", "resource") and line["met"] for line in found["evidence"])]
    rules = [{"rule_id": found["rule_id"], "title": found["title"], "status": found["status"],
              "severity": found["severity"], "diagnosis": found["diagnosis"],
              "evidence": [line for line in found["evidence"] if line["source"] in ("sensor", "resource")]}
             for found in fired]
    return {"available": True, "at": _stamp(at), "current": current, "series": series, "groups": [
        {"code": code, "title": title, "params": [entry for entry in params if entry in metas]}
        for code, title, params in CHART_GROUPS], "meta": {code: metas[code] for code in CHART_CODES if code in metas},
        "rules": rules}


def sound_section(session: Session, inspection_id: int) -> list[dict]:
    """Записи звука осмотра с показателями, спектром и кандидатами, в порядке записи."""
    rows = session.scalars(select(SoundRecord).where(SoundRecord.inspection_id == inspection_id).order_by(SoundRecord.id))
    return [{"id": row.id, "created_at": _stamp(row.created_at), "normal": row.normal, **(row.summary or {})}
            for row in rows]


def walk_section(nodes: list[dict], coverage: dict | None, findings: list[Finding]) -> list[dict]:
    """Сводка обхода по узлам: осмотрен ли узел (камерой, отметкой или записью инженера) и его статус."""
    marked = {finding.node_code for finding in findings if finding.node_code}
    covered = (coverage or {}).get("nodes") or {}
    rows = []
    for node in nodes:
        state = covered.get(node["code"]) or {}
        inspected = bool(state.get("inspected") or state.get("manual") or node["code"] in marked)
        rows.append({"code": node["code"], "name": node["name"], "inspected": inspected,
                     "status": node["actual"]["status"], "title": node["actual"].get("title")})
    return rows


def recommendations(findings: list[dict]) -> list[dict]:
    """Рекомендации по подтверждённым находкам без повторов: сначала критичные."""
    ordered = sorted(findings, key=lambda view: (SEVERITY_ORDER.get(view.get("severity") or 1, 3), view["id"]))
    seen, rows = set(), []
    for view in ordered:
        text = (view.get("recommendation") or "").strip()
        if text and text not in seen:
            seen.add(text)
            rows.append({"finding_id": view["id"], "node_name": view["node_name"], "title": view["title"],
                         "severity": view.get("severity"), "text": text})
    return rows


def next_maintenance(card: dict, run_hours: float | None, nodes: list[dict]) -> dict | None:
    """Ближайшее обслуживание: вид регламента с наименьшим остатком наработки или узел с ближайшей датой ресурса."""
    known = [entry for entry in maintenance_intervals(card, run_hours) if entry.get("remaining_hours") is not None]
    if known:
        entry = min(known, key=lambda item: item["remaining_hours"])
        return {"kind": "maintenance", "name": entry["name"], "work": entry.get("work"),
                "remaining_hours": entry["remaining_hours"], "state": entry["state"]}
    dated = [node for node in nodes if (node.get("calculated") or {}).get("forecast_date")]
    if dated:
        node = min(dated, key=lambda item: item["calculated"]["forecast_date"])
        return {"kind": "resource", "name": node["name"], "work": "Замена или ревизия узла по ресурсу",
                "forecast_date": node["calculated"]["forecast_date"], "state": node["calculated"]["state"]}
    return None


def signatures(session: Session, inspection: Inspection, findings: list[Finding]) -> list[dict]:
    """Строки подписей: инженер, проводивший осмотр, и мастер - отклонивший замечание или с правом подтверждения."""
    master = None
    rejecters = [finding.rejected_by_id for finding in findings if finding.rejected_by_id]
    if rejecters:
        master = session.get(User, rejecters[-1])
    if master is None:
        master = next((user for user in session.scalars(select(User).where(User.is_active.is_(True)).order_by(User.id))
                       if has_permission(user, "findings.confirm")), None)
    engineer = inspection.user
    return [{"role": "Инженер", "name": engineer.name if engineer else None},
            {"role": "Мастер", "name": master.name if master else None}]
