"""Оборудование: список с поиском, цифровая карточка, узлы, история осмотров и работ, режим работы.

Карточка отдаётся в том же виде, что и запись в data/equipment.json, но с текущими значениями из базы:
режим, наработка агрегата и узлов, даты замены. Все запросы требуют права «Просмотр оборудования».
"""
from datetime import datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.orm import Session, joinedload, selectinload

from server.auth import require_permission, role_title
from server.db import get_session
from server.models import Equipment, Finding, Inspection, MaintenanceRecord, Node, User

router = APIRouter(prefix="/equipment", tags=["equipment"], dependencies=[Depends(require_permission("equipment.view"))])


class ModeBody(BaseModel):
    """Запрос смены режима: агрегат в работе или остановлен."""

    mode: Literal["running", "stopped"]


def _fold(text: str) -> str:
    """Приводит строку к виду для сравнения: без различия регистра, буква ё как е."""
    return text.casefold().replace("ё", "е")


def _compact(text: str) -> str:
    """Оставляет только буквы и цифры: «Н-101» и «н101», «2786107-0142» и «27861070142» становятся равны."""
    return "".join(symbol for symbol in _fold(text) if symbol.isalnum())


def _stamp(moment: datetime | None) -> str | None:
    """Записывает время в виде ISO с точностью до секунды; отсутствующее время остаётся пустым."""
    return moment.isoformat(timespec="seconds") if moment else None


def _matches(item: Equipment, query: str) -> bool:
    """Проверяет, что каждое слово запроса встречается в обозначении, названии, модели, номере или месте установки.

    Слово ищется как есть, а если в нём после удаления разделителей осталось хотя бы три знака - ещё и без
    разделителей; более короткие обрывки совпадали бы с чем угодно.
    """
    fields = [item.id, item.name, item.model, item.serial, item.location, item.data.get("manufacturer") or ""]
    plain = " ".join(_fold(field) for field in fields)
    dense = " ".join(_compact(field) for field in fields)
    for word in query.split():
        solid = _compact(word)
        if _fold(word) not in plain and not (len(solid) >= 3 and solid in dense):
            return False
    return True


def get_equipment(session: Session, equipment_id: str) -> Equipment:
    """Возвращает оборудование по идентификатору или отвечает 404, если такого нет."""
    item = session.get(Equipment, equipment_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Оборудование не найдено")
    return item


def node_card(node: Node) -> dict:
    """Описывает узел как в data/equipment.json: код узла повторён в полях id и code."""
    return {"id": node.code, "code": node.code, "name": node.name, "hours": node.hours,
            "installed": node.installed.isoformat() if node.installed else None,
            "replaced": node.replaced.isoformat() if node.replaced else None, **node.data}


def equipment_card(item: Equipment) -> dict:
    """Собирает цифровую карточку в виде записи data/equipment.json с текущими значениями из базы."""
    return {"id": item.id, "name": item.name, "type": item.type, "model": item.model, "serial": item.serial,
            "location": item.location, "mode": item.mode, "run_hours": item.run_hours, **item.data,
            "nodes": [node_card(node) for node in item.nodes]}


def _activity(session: Session, equipment_ids: list[str]) -> dict[str, dict]:
    """Считает по каждому агрегату незакрытые замечания (без устранённых и отклонённых) и время последнего осмотра."""
    opened = dict(session.execute(
        select(Finding.equipment_id, func.count()).where(
            Finding.equipment_id.in_(equipment_ids), Finding.state.notin_(("resolved", "rejected")), Finding.status != "ok",
        ).group_by(Finding.equipment_id)).all())
    latest = dict(session.execute(
        select(Inspection.equipment_id, func.max(Inspection.started_at)).where(
            Inspection.equipment_id.in_(equipment_ids)).group_by(Inspection.equipment_id)).all())
    return {key: {"open_findings": opened.get(key, 0), "last_inspection_at": _stamp(latest.get(key))} for key in equipment_ids}


def _summary(item: Equipment) -> dict:
    """Краткое описание агрегата для списка."""
    return {"id": item.id, "name": item.name, "type": item.type, "model": item.model, "serial": item.serial,
            "location": item.location, "mode": item.mode, "run_hours": item.run_hours,
            "manufacturer": item.data.get("manufacturer"), "telemetry": bool(item.data.get("telemetry"))}


def _card_response(session: Session, item: Equipment) -> dict:
    """Карточка для ответа сервера: описание агрегата с узлами плюс сведения о замечаниях и последнем осмотре."""
    return {**equipment_card(item), **_activity(session, [item.id])[item.id]}


def _person(user: User | None) -> dict | None:
    """Кто выполнил осмотр или работу: имя и роль, без почты."""
    if user is None:
        return None
    return {"id": user.id, "name": user.name, "role": user.role, "role_title": role_title(user)}


def _finding_view(finding: Finding, node_names: dict[str, str]) -> dict:
    """Описывает находку осмотра для истории; путь к снимку на сервере не раскрывается."""
    return {"id": finding.id, "inspection_id": finding.inspection_id, "node_code": finding.node_code,
            "node_name": node_names.get(finding.node_code), "source": finding.source, "rule_id": finding.rule_id,
            "status": finding.status, "severity": finding.severity, "title": finding.title,
            "diagnosis": finding.diagnosis, "recommendation": finding.recommendation,
            "confidence": finding.confidence, "evidence": finding.evidence or [], "comment": finding.comment,
            "has_photo": bool(finding.photo_path), "state": finding.state, "created_at": _stamp(finding.created_at)}


@router.get("")
def list_equipment(
    session: Annotated[Session, Depends(get_session)],
    q: Annotated[str | None, Query(max_length=100)] = None,
    kind: Annotated[str | None, Query(alias="type", max_length=64)] = None,
    mode: Annotated[Literal["running", "stopped"] | None, Query()] = None,
) -> list[dict]:
    """Список оборудования: поиск по словам запроса q, отбор по типу (параметр type) и режиму работы."""
    query = select(Equipment).order_by(Equipment.id)
    if kind:
        query = query.where(Equipment.type == kind)
    if mode:
        query = query.where(Equipment.mode == mode)
    items = [item for item in session.scalars(query) if not q or _matches(item, q)]
    activity = _activity(session, [item.id for item in items])
    return [{**_summary(item), **activity[item.id]} for item in items]


@router.get("/by-serial/{serial}")
def by_serial(serial: str, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Карточка по серийному номеру с шильдика; разделители и регистр при вводе не важны."""
    item = session.scalar(select(Equipment).where(Equipment.serial == serial.strip()))
    if item is None:
        wanted = _compact(serial)
        close = [other for other in session.scalars(select(Equipment)) if wanted and _compact(other.serial) == wanted]
        if len(close) != 1:
            raise HTTPException(status_code=404, detail="Оборудование с таким серийным номером не найдено")
        item = close[0]
    return _card_response(session, item)


@router.get("/{equipment_id}")
def card(equipment_id: str, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Цифровая карточка оборудования с узлами, характеристиками, регламентом и документами."""
    return _card_response(session, get_equipment(session, equipment_id))


@router.get("/{equipment_id}/nodes")
def nodes(equipment_id: str, session: Annotated[Session, Depends(get_session)]) -> list[dict]:
    """Узлы оборудования с текущей наработкой и датами установки и замены."""
    return [node_card(node) for node in get_equipment(session, equipment_id).nodes]


@router.get("/{equipment_id}/history")
def history(
    equipment_id: str,
    session: Annotated[Session, Depends(get_session)],
    node: Annotated[str | None, Query(max_length=64)] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> list[dict]:
    """История агрегата или одного его узла: осмотры с находками и записи о работах, сначала новые."""
    item = get_equipment(session, equipment_id)
    node_names = {entry.code: entry.name for entry in item.nodes}
    if node is not None and node not in node_names:
        raise HTTPException(status_code=404, detail="Узел не найден")
    inspections = select(Inspection).where(Inspection.equipment_id == item.id)
    records = select(MaintenanceRecord).where(MaintenanceRecord.equipment_id == item.id)
    if node is not None:
        inspections = inspections.where(Inspection.findings.any(Finding.node_code == node))
        records = records.where(MaintenanceRecord.node_code == node)
    inspections = inspections.options(joinedload(Inspection.user), selectinload(Inspection.findings))
    events = []
    for inspection in session.scalars(inspections.order_by(Inspection.started_at.desc(), Inspection.id.desc()).limit(limit)):
        findings = [finding for finding in inspection.findings if node is None or finding.node_code == node]
        events.append((inspection.started_at, 1, inspection.id, {
            "type": "inspection", "id": inspection.id, "at": _stamp(inspection.started_at),
            "started_at": _stamp(inspection.started_at), "finished_at": _stamp(inspection.finished_at),
            "status": inspection.status, "user": _person(inspection.user), "summary": inspection.summary,
            "findings": [_finding_view(finding, node_names) for finding in findings]}))
    records = records.options(joinedload(MaintenanceRecord.user))
    for record in session.scalars(records.order_by(MaintenanceRecord.at.desc(), MaintenanceRecord.id.desc()).limit(limit)):
        events.append((record.at, 0, record.id, {
            "type": "maintenance", "id": record.id, "at": _stamp(record.at), "kind": record.kind,
            "node_code": record.node_code, "node_name": node_names.get(record.node_code), "comment": record.comment,
            "user": _person(record.user), "hours_at": record.hours_at}))
    events.sort(key=lambda event: event[:3], reverse=True)
    return [event[3] for event in events[:limit]]


@router.post("/{equipment_id}/mode", dependencies=[Depends(require_permission("equipment.mode"))])
def set_mode(equipment_id: str, body: ModeBody, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Переводит агрегат в режим «в работе» или «остановлен»; нужно право «Смена режима агрегата»."""
    item = get_equipment(session, equipment_id)
    item.mode = body.mode
    session.commit()
    return {**_summary(item), **_activity(session, [item.id])[item.id]}
