"""Телеметрия и оценки агрегата для приложения и пульта демонстрации.

Маршруты дополняют раздел /equipment: показания на текущий момент ленты с уставками и диагнозами заказчика,
ряды для графиков, прогноз времени до уставки, сценарии и курсор времени (пульт мастера), диагноз по
правилам, маршрут осмотра и три раздельные оценки по каждому узлу. Текущий момент для всех расчётов -
курсор проигрывателя телеметрии; у агрегата без телеметрии оценки строятся по карточке и сегодняшней дате.
"""
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy.orm import Session

from server.auth import current_user, require_role
from server.db import get_session
from server.equipment import equipment_card, get_equipment
from server.inspections import current_diagnosis, get_inspection, node_route, tracker_for
from server.inspections.service import CAMERA_MISSED, NOT_WALKED, OK_NOTE, SEVERITY_TITLES, STATUS_TITLES, WHOLE_UNIT
from server.models import Equipment
from server.rules import (
    EQUIPMENT_NODE,
    diagnose,
    hours_to_threshold,
    maintenance_intervals,
    resource_estimates,
    temperature_label,
    vibration_label,
)
from server.telemetry import CODES, TelemetryDataError, TelemetryPlayer, get_player

TREND_HOURS = 12
MIN_FORECAST_POINTS = 4
MAX_WINDOW_HOURS = 720
NO_TELEMETRY = "Для этого оборудования нет телеметрии"
LEVEL_TITLES = {"ok": "В норме", "warn": "Предупреждение", "alarm": "Тревога"}
LEVEL_RANK = {"ok": 0, "warn": 1, "alarm": 2}
THRESHOLD_TITLES = {"warn": "уставка предупреждения", "alarm": "уставка тревоги"}
LABELS = {"vibration": vibration_label, "temperature": temperature_label}
NOT_INSPECTED = "Узел не осмотрен, данных по нему нет"

router = APIRouter(prefix="/equipment", tags=["telemetry"], dependencies=[Depends(current_user)])


class CursorBody(BaseModel):
    """Запрос перестановки текущего момента ленты телеметрии."""

    at: datetime


@dataclass(frozen=True)
class Feed:
    """Срез телеметрии агрегата на текущий момент ленты: показания и тренды за 12 часов.

    У агрегата без телеметрии проигрывателя нет, показания пусты, а reason объясняет причину.
    """

    player: TelemetryPlayer | None
    reason: str | None
    at: datetime | None
    readings: dict
    trends: dict


def stamp(moment: datetime | None) -> str | None:
    """Записывает время в виде ISO с точностью до секунды; отсутствующее время остаётся пустым."""
    return moment.isoformat(timespec="seconds") if moment else None


def find_player(equipment_id: str) -> tuple[TelemetryPlayer | None, str | None]:
    """Возвращает проигрыватель телеметрии агрегата или причину, по которой его нет."""
    try:
        return get_player(equipment_id), None
    except KeyError:
        return None, NO_TELEMETRY
    except TelemetryDataError as error:
        return None, str(error)


def require_player(equipment_id: str) -> TelemetryPlayer:
    """Возвращает проигрыватель или отвечает 404 для агрегата без телеметрии и 503 при отсутствии баз заказчика."""
    try:
        return get_player(equipment_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=NO_TELEMETRY) from None
    except TelemetryDataError as error:
        raise HTTPException(status_code=503, detail=str(error)) from error


def feed_for(equipment_id: str) -> Feed:
    """Собирает показания и тренды агрегата на текущий момент ленты; без телеметрии - пустой срез с причиной."""
    player, reason = find_player(equipment_id)
    if player is None:
        return Feed(None, reason, None, {}, {})
    at = player.cursor
    trends = {}
    for code in CODES:
        slope = player.trend(code, TREND_HOURS, at)
        if slope is not None:
            trends[code] = slope
    return Feed(player, None, at, player.snapshot(at), trends)


def level_of(value: float | None, meta: dict) -> str | None:
    """Сравнивает значение с уставками параметра: "ok", "warn" или "alarm"; без уставок или значения - None.

    Сравнение строгое, как в базах заказчика: отклонением считается значение за уставкой, а не на ней.
    """
    direction = meta.get("direction")
    if value is None or direction not in ("high", "low"):
        return None
    for name in ("alarm", "warn"):
        limit = meta.get(name)
        if limit is not None and (value > limit if direction == "high" else value < limit):
            return name
    return "ok"


def labels_at(player: TelemetryPlayer, readings: dict, at: datetime) -> dict:
    """Диагнозы по вибрации и температуре в формулировках заказчика с указанием происхождения.

    На часах из баз заказчика берётся его собственная запись; на модельных часах диагноз считается по тем же
    уставкам и помечается как модельный.
    """
    result = {}
    for kind, compute in LABELS.items():
        text = player.customer_label(kind, at)
        result[kind] = {"text": text, "source": "customer"} if text else {"text": compute(readings), "source": "model"}
    return result


def diagnosis_view(result: dict, names: dict[str, str]) -> dict:
    """Дополняет итог диагностики названиями узлов и статусов для показа инженеру.

    Статус без замечаний всегда сопровождается оговоркой: он не подтверждает исправность.
    """
    status = result["status"]
    findings = [{**found, "node_name": names.get(found["node_id"], WHOLE_UNIT),
                 "status_title": STATUS_TITLES[found["status"]], "severity_title": SEVERITY_TITLES.get(found["severity"])}
                for found in result["findings"]]
    nodes = {code: {**state, "name": names.get(code, WHOLE_UNIT), "status_title": STATUS_TITLES[state["status"]]}
             for code, state in result["nodes"].items()}
    return {"status": status, "status_title": STATUS_TITLES[status],
            "status_note": f"Статус «{STATUS_TITLES['ok']}» {OK_NOTE}" if status == "ok" else None,
            "findings": findings, "nodes": nodes}


def mark_unwalked(nodes: dict, card: dict, coverage: dict | None) -> dict:
    """Переводит в серый статус узлы, которые камера распознаёт, но при обходе не осмотрела.

    Зелёный статус означает «узел распознан, видимых проблем нет», поэтому без осмотра камерой узел с
    классами детектора не может быть зелёным только по датчикам. coverage - состояние полноты обхода идущего
    осмотра; без осмотра (None) неосмотренными считаются все такие узлы. Причины от датчиков сохраняются.
    """
    trackable = {node["id"] for node in card.get("nodes") or [] if node.get("classes")}
    walked = {code for code, state in ((coverage or {}).get("nodes") or {}).items() if state.get("inspected")}
    reason = CAMERA_MISSED if coverage is None else NOT_WALKED
    result = {}
    for code, state in nodes.items():
        if state["status"] == "ok" and code in trackable and code not in walked:
            kept = [text for text in state["reasons"] if text not in (CAMERA_MISSED, NOT_WALKED)]
            state = {**state, "status": "unknown", "reasons": [reason, *kept]}
        result[code] = state
    return result


def node_names(item: Equipment) -> dict[str, str]:
    """Названия узлов агрегата по их кодам."""
    return {node.code: node.name for node in item.nodes}


def _meta(player: TelemetryPlayer, code: str, at: datetime) -> dict:
    """Возвращает описание параметра на момент at или отвечает 404 для неизвестного кода."""
    for meta in player.parameters(at):
        if meta["code"] == code:
            return meta
    raise HTTPException(status_code=404, detail=f"Неизвестный параметр телеметрии: {code}")


def _number(value: float) -> str:
    """Записывает число для русского текста: без лишних нулей, с десятичной запятой."""
    return f"{round(value, 2):g}".replace(".", ",")


@router.get("/{equipment_id}/telemetry")
def telemetry(equipment_id: str, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Показания агрегата на текущий момент ленты: значения, уставки, уровни, тренды и диагнозы заказчика.

    У каждого параметра source показывает происхождение значения: "customer" - из баз заказчика, "model" -
    рассчитано моделью. Для агрегата без телеметрии возвращается available = false с причиной.
    """
    item = get_equipment(session, equipment_id)
    feed = feed_for(item.id)
    if feed.player is None:
        return {"equipment_id": item.id, "available": False, "reason": feed.reason, "at": None, "bounds": None,
                "customer_until": None, "level": None, "level_title": None, "labels": None, "parameters": []}
    first, last = feed.player.bounds()
    parameters = []
    for meta in feed.player.parameters(feed.at):
        value = feed.readings.get(meta["code"])
        level = level_of(value, meta)
        slope = feed.trends.get(meta["code"])
        parameters.append({**meta, "value": value, "level": level, "level_title": LEVEL_TITLES.get(level),
                           "trend": None if slope is None else round(slope, 4)})
    worst = max((entry["level"] for entry in parameters if entry["level"]), key=LEVEL_RANK.__getitem__, default=None)
    return {"equipment_id": item.id, "available": True, "reason": None, "at": stamp(feed.at),
            "bounds": {"first": stamp(first), "last": stamp(last)},
            "customer_until": stamp(feed.player.customer_bounds()[1]),
            "level": worst, "level_title": LEVEL_TITLES.get(worst),
            "labels": labels_at(feed.player, feed.readings, feed.at), "parameters": parameters}


@router.get("/{equipment_id}/telemetry/{code}")
def series(equipment_id: str, code: str, session: Annotated[Session, Depends(get_session)],
           hours: Annotated[int, Query(ge=1, le=MAX_WINDOW_HOURS)] = 24) -> dict:
    """Ряд значений параметра за последние hours часов до текущего момента ленты - для графика с линиями уставок.

    model_since - время первой точки окна, рассчитанной моделью; None, если все точки из баз заказчика.
    """
    player = require_player(get_equipment(session, equipment_id).id)
    at = player.cursor
    meta = _meta(player, code, at)
    points = player.window(code, hours, at)
    slope = player.trend(code, min(hours, TREND_HOURS), at)
    model_since = next((moment for moment, _ in points if player.source(code, moment) == "model"), None)
    return {**meta, "equipment_id": equipment_id, "at": stamp(at), "hours": hours,
            "trend": None if slope is None else round(slope, 4), "model_since": stamp(model_since),
            "points": [{"t": stamp(moment), "v": value} for moment, value in points]}


def _crossing(points: list, limit: float | None, direction: str) -> dict | None:
    """Оценивает достижение одной уставки: через сколько часов и в какой момент; None, если уставки нет."""
    if limit is None:
        return None
    hours = hours_to_threshold(points, limit, direction)
    moment = points[-1][0] + timedelta(hours=hours) if hours is not None and points else None
    return {"threshold": limit, "hours": hours, "at": stamp(moment), "reached": hours == 0.0}


def _forecast_text(name: str, unit: str, window: int, crossings: dict) -> str:
    """Составляет русский текст прогноза по найденным пересечениям уставок."""
    parts = []
    for kind in ("warn", "alarm"):
        crossing = crossings.get(kind)
        if crossing is None:
            continue
        limit = f"{THRESHOLD_TITLES[kind]} {_number(crossing['threshold'])} {unit}".strip()
        if crossing["reached"]:
            parts.append(f"{limit}: уже достигнута")
        elif crossing["hours"] is not None:
            moment = datetime.fromisoformat(crossing["at"])
            parts.append(f"{limit}: ожидается примерно через {_number(crossing['hours'])} ч ({moment:%d.%m.%Y %H:%M})")
        else:
            parts.append(f"{limit}: достижение не прогнозируется")
    return f"{name}, тренд за {window} ч: " + "; ".join(parts)


@router.get("/{equipment_id}/forecast/{code}")
def forecast(equipment_id: str, code: str, session: Annotated[Session, Depends(get_session)],
             hours: Annotated[int, Query(ge=MIN_FORECAST_POINTS, le=168)] = TREND_HOURS) -> dict:
    """Прогноз времени до уставок параметра по линейному тренду последних hours часов.

    state: "no_thresholds" - уставок у параметра нет; "insufficient_data" - в окне меньше четырёх точек;
    "reached" - уставка уже достигнута; "approaching" - тренд ведёт к уставке; "steady" - достижение не
    прогнозируется. Прогноз - оценка по прямой, решение о действиях принимает инженер.
    """
    player = require_player(get_equipment(session, equipment_id).id)
    at = player.cursor
    meta = _meta(player, code, at)
    points = player.window(code, hours, at)
    slope = player.trend(code, hours, at)
    answer = {"equipment_id": equipment_id, "code": code, "name": meta["name"], "unit": meta["unit"], "at": stamp(at),
              "hours": hours, "value": points[-1][1] if points else None, "direction": meta["direction"],
              "trend": None if slope is None else round(slope, 4), "warn": None, "alarm": None}
    if meta["direction"] is None or (meta["warn"] is None and meta["alarm"] is None):
        return {**answer, "state": "no_thresholds",
                "text": f"{meta['name']}: уставки не заданы, прогноз не строится"}
    if len(points) < MIN_FORECAST_POINTS:
        return {**answer, "state": "insufficient_data",
                "text": f"{meta['name']}: недостаточно данных - в окне {hours} ч меньше {MIN_FORECAST_POINTS} точек"}
    crossings = {kind: _crossing(points, meta[kind], meta["direction"]) for kind in ("warn", "alarm")}
    found = [crossing for crossing in crossings.values() if crossing]
    if any(crossing["reached"] for crossing in found):
        state = "reached"
    elif any(crossing["hours"] is not None for crossing in found):
        state = "approaching"
    else:
        state = "steady"
    return {**answer, **crossings, "state": state, "text": _forecast_text(meta["name"], meta["unit"], hours, crossings)}


def _scenario_view(scenario: dict, cursor: datetime) -> dict:
    """Описывает сценарий для пульта: время в виде ISO и признак того, что курсор сейчас внутри сценария."""
    view = {key: stamp(value) if isinstance(value, datetime) else value for key, value in scenario.items()}
    if scenario.get("kind") == "fault":
        view["active"] = scenario["onset"] <= cursor <= scenario["end"]
    else:
        view["active"] = cursor == scenario["peak"]
    return view


@router.get("/{equipment_id}/scenarios")
def scenarios(equipment_id: str, session: Annotated[Session, Depends(get_session)]) -> list[dict]:
    """Сценарии демонстрации: эпизоды неисправностей и опорные точки, с ожидаемыми правилами диагностики."""
    player = require_player(get_equipment(session, equipment_id).id)
    cursor = player.cursor
    return [_scenario_view(scenario, cursor) for scenario in player.scenarios()]


@router.post("/{equipment_id}/scenarios/{scenario_id}", dependencies=[Depends(require_role("master", "admin"))])
def select_scenario(equipment_id: str, scenario_id: str, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Ставит текущий момент ленты на час наибольшего отклонения сценария; доступно мастеру и администратору."""
    player = require_player(get_equipment(session, equipment_id).id)
    try:
        chosen = player.select_scenario(scenario_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Сценарий не найден") from None
    cursor = player.cursor
    return {"equipment_id": equipment_id, "at": stamp(cursor), "scenario": _scenario_view(chosen, cursor)}


@router.post("/{equipment_id}/cursor", dependencies=[Depends(require_role("master", "admin"))])
def set_cursor(equipment_id: str, body: CursorBody, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Переставляет текущий момент ленты телеметрии; доступно мастеру и администратору.

    Момент вне записи отклоняется с кодом 422 и указанием доступного интервала.
    """
    player = require_player(get_equipment(session, equipment_id).id)
    try:
        player.set_cursor(body.at)
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    first, last = player.bounds()
    return {"equipment_id": equipment_id, "at": stamp(player.cursor), "bounds": {"first": stamp(first), "last": stamp(last)}}


@router.get("/{equipment_id}/diagnosis")
def diagnosis(equipment_id: str, session: Annotated[Session, Depends(get_session)],
              inspection_id: Annotated[int | None, Query(ge=1)] = None) -> dict:
    """Диагноз агрегата по правилам на текущий момент ленты с основаниями по каждой находке.

    Без inspection_id учитываются только датчики и ресурс. С номером идущего осмотра этого агрегата в диагноз
    входят также признаки, увиденные камерой, показание манометра и отметки инженера. Узел, который камера
    распознаёт, но при обходе не осмотрела, показывается серым «не осмотрен», а не зелёным.
    """
    item = get_equipment(session, equipment_id)
    card = equipment_card(item)
    feed = feed_for(item.id)
    if inspection_id is None:
        result = diagnose(card, feed.readings, feed.trends, {})
        coverage = None
    else:
        inspection = get_inspection(session, inspection_id)
        if inspection.equipment_id != item.id:
            raise HTTPException(status_code=422, detail="Осмотр относится к другому оборудованию")
        result = current_diagnosis(session, inspection)
        coverage = tracker_for(session, inspection).state()
    result = {**result, "nodes": mark_unwalked(result["nodes"], card, coverage)}
    labels = labels_at(feed.player, feed.readings, feed.at) if feed.player else None
    return {"equipment_id": item.id, "inspection_id": inspection_id, "at": stamp(feed.at),
            "telemetry": feed.player is not None, "telemetry_reason": feed.reason, "labels": labels,
            **diagnosis_view(result, node_names(item))}


@router.get("/{equipment_id}/route")
def route(equipment_id: str, session: Annotated[Session, Depends(get_session)]) -> list[dict]:
    """Маршрут осмотра: узлы в порядке приоритета с причиной места каждого.

    Порядок групп: незакрытое замечание прошлого осмотра, отклонение по датчикам, ресурс на исходе,
    плановый осмотр. Запись: {code, name, rank, group, reason}.
    """
    return node_route(session, get_equipment(session, equipment_id))


def _actual(state: dict | None) -> dict:
    """Фактическое состояние узла по диагностике; узел без данных получает явное «не осмотрен»."""
    state = state or {"status": "unknown", "reasons": []}
    reasons = list(state["reasons"])
    if state["status"] == "unknown" and not reasons:
        reasons = [NOT_INSPECTED]
    return {"status": state["status"], "status_title": STATUS_TITLES[state["status"]], "reasons": reasons}


@router.get("/{equipment_id}/resource")
def resource(equipment_id: str, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Три раздельные оценки по каждому узлу и состояние регламента обслуживания.

    normative - срок службы по документам, calculated - расчётный остаток ресурса, actual - фактическое
    состояние по диагностике на текущий момент. Оценки не объединяются в одну. Днём расчёта служит момент
    ленты телеметрии, а без телеметрии - сегодняшняя дата.
    """
    item = get_equipment(session, equipment_id)
    card = equipment_card(item)
    feed = feed_for(item.id)
    run_hours = feed.readings.get("run_hours", item.run_hours)
    today = feed.at.date() if feed.at else date.today()
    states = mark_unwalked(diagnose(card, feed.readings, feed.trends, {})["nodes"], card, None)
    nodes = []
    for node in card["nodes"]:
        estimate = resource_estimates(card, node, run_hours, today)
        nodes.append({"code": node["id"], "name": node["name"], "normative": estimate["normative"],
                      "calculated": estimate["calculated"], "actual": _actual(states.get(node["id"]))})
    if EQUIPMENT_NODE in states:
        nodes.append({"code": EQUIPMENT_NODE, "name": WHOLE_UNIT, "normative": None, "calculated": None,
                      "actual": _actual(states[EQUIPMENT_NODE])})
    return {"equipment_id": item.id, "run_hours": run_hours, "estimates_on": today.isoformat(),
            "telemetry_at": stamp(feed.at), "telemetry": feed.player is not None, "telemetry_reason": feed.reason,
            "nodes": nodes, "maintenance": maintenance_intervals(card, run_hours)}
