"""Осмотры оборудования: начало, фиксация результатов, завершение со сводкой, замечания и данные для отчёта.

Осмотр ведёт сотрудник, начавший его; сотрудник с правом «Дополнение чужих осмотров» (мастер) может
дополнять и завершать чужой осмотр. Пока осмотр идёт,
сервер держит в памяти счётчик полноты обхода и показание манометра, считанное камерой. При завершении
в сводку осмотра сохраняются три раздельные оценки по каждому узлу, а находки диагностики, которые инженер
не зафиксировал сам, записываются автоматически - увиденный признак дефекта не должен потеряться.
"""
import io
import os
from datetime import date, datetime
from importlib import import_module
from pathlib import Path
from threading import Lock

from fastapi import HTTPException
from PIL import Image, ImageOps, UnidentifiedImageError
from sqlalchemy import select, update
from sqlalchemy.orm import Session, joinedload, selectinload

from server import config, fingerprint
from server import workflow
from server.auth import has_permission, role_title
from server.equipment import equipment_card, get_equipment
from server.inspections.coverage import CoverageTracker, static_priority
from server.models import Equipment, Finding, Inspection, MaintenanceRecord, SoundRecord, User, now
from server.rules import EQUIPMENT_NODE, GAUGE_READING, defect_signs, diagnose, maintenance_intervals, resource_estimates
from server.telemetry import CODES, TelemetryDataError, get_player

KINDS = ("checked", "defect", "maintenance", "replacement")
DECISION_LINE = "Решение принимает инженер"
OK_NOTE = "не является подтверждением исправности"
STATUS_TITLES = {
    "ok": "Видимых проблем не обнаружено",
    "check": "Рекомендуется проверка",
    "defect": "Обнаружены признаки возможного дефекта",
    "unknown": "Узел не осмотрен / недостаточно данных",
    "incomplete": "Осмотр неполный",
}
INCOMPLETE = "incomplete"
STATUS_RANK = {"unknown": 0, "ok": 1, "check": 2, "defect": 3}
STATE_TITLES = {"open": "Открыто", "in_work": "В работе", "resolved": "Устранено", "rejected": "Отклонено"}
NEXT_STATE = {"open": "in_work", "in_work": "resolved"}
REJECTED = "rejected"
CLOSED_STATES = ("resolved", REJECTED)
REJECTABLE = ("open", "in_work")
SOURCE_TITLES = {"camera": "Камера", "sensor": "Датчики", "resource": "Ресурс", "manual": "Инженер"}
SEVERITY_TITLES = {1: "наблюдение и проверка", 2: "устранить в плановом порядке", 3: "критично"}
KIND_TITLES = {
    "checked": "Проверено, замечаний нет",
    "defect": "Дефект, зафиксированный инженером",
    "maintenance": "Выполнено техническое обслуживание",
    "replacement": "Выполнена замена узла",
}
INSPECTION_TITLES = {"active": "Идёт", "finished": "Завершён"}
IDENTIFIED_TITLES = {"nameplate": "По шильдику", "manual": "Выбран вручную", "qr": "По QR-коду"}
MODE_TITLES = {"running": "В работе", "stopped": "Остановлен"}
WHOLE_UNIT = "Агрегат в целом"
ENGINEER_MARK = "Отметка инженера"
MAX_FRAME_BYTES = 8 * 1024 * 1024
MAX_FRAME_PIXELS = 40_000_000
MAX_PHOTO_SIDE = 1920
TREND_HOURS = 12
ROUTINE_RANK = 6
ROUTINE_REASON = "Плановый осмотр: отклонений по данным нет"
NOT_WALKED = "Камерой при обходе узел не осмотрен и инженером не отмечен"
CAMERA_MISSED = "Камерой узел не осмотрен"
FOREIGN_INSPECTION = "Изменять осмотр может начавший его сотрудник или мастер"

_live: dict[tuple[str, int], dict] = {}
_live_lock = Lock()


def _stamp(moment: datetime | None) -> str | None:
    """Записывает время в виде ISO с точностью до секунды; отсутствующее время остаётся пустым."""
    return moment.isoformat(timespec="seconds") if moment else None


def _person(user: User | None) -> dict | None:
    """Кто выполнил осмотр: имя и роль, без почты."""
    if user is None:
        return None
    return {"id": user.id, "name": user.name, "role": user.role, "role_title": role_title(user)}


def _meta(finding: Finding) -> dict:
    """Возвращает служебные пометки находки: они хранятся в первой строке её оснований."""
    evidence = finding.evidence or []
    return evidence[0] if evidence and isinstance(evidence[0], dict) else {}


def _with_models(finding: Finding) -> Finding:
    """Ставит в служебные пометки новой находки отпечаток набора моделей, которым работал сервер."""
    evidence = list(finding.evidence or [])
    if evidence and isinstance(evidence[0], dict):
        evidence[0] = {**evidence[0], "models": fingerprint.short()}
        finding.evidence = evidence
    return finding


def finding_kind(finding: Finding) -> str:
    """Определяет вид записи: проверка без замечаний, дефект, обслуживание или замена узла."""
    kind = _meta(finding).get("kind")
    if kind in KINDS:
        return kind
    return "checked" if finding.status == "ok" else "defect"


def _node_names(item: Equipment) -> dict[str, str]:
    """Названия узлов агрегата по их кодам."""
    return {node.code: node.name for node in item.nodes}


def is_rejected(finding: Finding) -> bool:
    """Сообщает, что находку отклонили как ложную: она не учитывается нигде, кроме собственной карточки."""
    return finding.state == REJECTED


def counted(findings) -> list[Finding]:
    """Оставляет находки, которые учитываются в диагнозе, сводке и отчёте: все, кроме отклонённых."""
    return [finding for finding in findings if not is_rejected(finding)]


def _note_person(user_id: int | None, name: str | None) -> dict | None:
    """Автор комментария или отклонения: номер и имя."""
    return None if user_id is None else {"id": user_id, "name": name}


def finding_view(finding: Finding, node_names: dict[str, str]) -> dict:
    """Описывает находку для ответа сервера; путь к снимку на диске не раскрывается."""
    meta = _meta(finding)
    notes = list(finding.notes or [])
    rejection = next((note for note in reversed(notes) if note.get("kind") == REJECTED), None)
    return {
        "id": finding.id, "inspection_id": finding.inspection_id, "equipment_id": finding.equipment_id,
        "node_code": finding.node_code, "node_name": node_names.get(finding.node_code) or WHOLE_UNIT,
        "kind": finding_kind(finding), "source": finding.source,
        "source_title": SOURCE_TITLES.get(finding.source, finding.source), "rule_id": finding.rule_id,
        "status": finding.status, "status_title": STATUS_TITLES.get(finding.status, finding.status),
        "severity": finding.severity, "severity_title": SEVERITY_TITLES.get(finding.severity),
        "title": finding.title, "diagnosis": finding.diagnosis, "recommendation": finding.recommendation,
        "confidence": finding.confidence, "evidence": finding.evidence or [], "missing": list(meta.get("missing") or []),
        "automatic": bool(meta.get("automatic")), "models_fingerprint": meta.get("models"), "comment": finding.comment, "has_photo": bool(finding.photo_path),
        "photo_url": f"/inspections/findings/{finding.id}/photo" if finding.photo_path else None,
        "state": finding.state, "state_title": STATE_TITLES.get(finding.state, finding.state),
        "created_at": _stamp(finding.created_at),
        "rejected": is_rejected(finding), "rejected_at": _stamp(finding.rejected_at),
        "rejected_by": _note_person(finding.rejected_by_id, rejection.get("user_name") if rejection else None)
        if finding.rejected_by_id else None,
        "reject_reason": rejection.get("text") if rejection and is_rejected(finding) else None,
        "notes": notes,
    }


def get_inspection(session: Session, inspection_id: int) -> Inspection:
    """Возвращает осмотр с сотрудником, агрегатом и находками или отвечает 404."""
    inspection = session.scalar(
        select(Inspection).where(Inspection.id == inspection_id).options(
            joinedload(Inspection.user), joinedload(Inspection.equipment).selectinload(Equipment.nodes),
            selectinload(Inspection.findings)).execution_options(populate_existing=True))
    if inspection is None:
        raise HTTPException(status_code=404, detail="Осмотр не найден")
    return inspection


def get_finding(session: Session, finding_id: int) -> Finding:
    """Возвращает находку по номеру или отвечает 404."""
    finding = session.get(Finding, finding_id)
    if finding is None:
        raise HTTPException(status_code=404, detail="Замечание не найдено")
    return finding


def can_edit(inspection: Inspection, user: User) -> bool:
    """Сообщает, может ли сотрудник изменять осмотр: это его автор или у него право дополнять чужие осмотры."""
    return inspection.user_id == user.id or has_permission(user, "inspect.supervise")


def _ensure_editor(inspection: Inspection, user: User) -> None:
    """Пропускает к изменению осмотра его автора и сотрудника с правом дополнять чужие осмотры."""
    if not can_edit(inspection, user):
        raise HTTPException(status_code=403, detail=FOREIGN_INSPECTION)


def _ensure_active(inspection: Inspection) -> None:
    """Отклоняет изменение завершённого осмотра."""
    if inspection.status != "active":
        raise HTTPException(status_code=409, detail="Осмотр уже завершён - начните новый осмотр")


def start_inspection(session: Session, user: User, equipment_id: str,
                     identified_by: str | None = None) -> tuple[Inspection, bool]:
    """Начинает осмотр агрегата; незавершённый осмотр этого же сотрудника на этом агрегате продолжается.

    identified_by - как агрегат опознан: nameplate (по шильдику), manual (выбран вручную) или qr.
    Возвращает осмотр и признак того, что он создан этим вызовом. Повтор запроса после обрыва связи
    не плодит пустые осмотры; способ опознания продолжаемого осмотра дописывается, если его не было.
    """
    item = get_equipment(session, equipment_id)
    active = session.scalar(
        select(Inspection.id).where(Inspection.equipment_id == item.id, Inspection.user_id == user.id,
                                    Inspection.status == "active").order_by(Inspection.id.desc()))
    if active is not None:
        found = get_inspection(session, active)
        if identified_by and not found.identified_by:
            found.identified_by = identified_by
            session.commit()
        return found, False
    inspection = Inspection(equipment_id=item.id, user_id=user.id, started_at=now(), status="active",
                            identified_by=identified_by)
    session.add(inspection)
    session.commit()
    return get_inspection(session, inspection.id), True


def list_inspections(session: Session, equipment_id: str | None = None, status: str | None = None,
                     limit: int = 50) -> list[dict]:
    """Список осмотров, сначала новые: кто, когда, по какому агрегату и с каким итогом."""
    query = select(Inspection).options(joinedload(Inspection.user), joinedload(Inspection.equipment))
    if equipment_id:
        query = query.where(Inspection.equipment_id == equipment_id)
    if status:
        query = query.where(Inspection.status == status)
    rows = session.scalars(query.order_by(Inspection.started_at.desc(), Inspection.id.desc()).limit(limit))
    return [_inspection_brief(inspection) for inspection in rows]


def _inspection_brief(inspection: Inspection) -> dict:
    """Краткое описание осмотра без находок."""
    item = inspection.equipment
    return {
        "id": inspection.id, "equipment_id": inspection.equipment_id,
        "equipment": {"id": item.id, "name": item.name, "model": item.model, "serial": item.serial,
                      "location": item.location},
        "user": _person(inspection.user), "started_at": _stamp(inspection.started_at),
        "finished_at": _stamp(inspection.finished_at), "status": inspection.status,
        "status_title": INSPECTION_TITLES.get(inspection.status, inspection.status), "summary": inspection.summary,
        "identified_by": inspection.identified_by,
        "identified_title": IDENTIFIED_TITLES.get(inspection.identified_by) if inspection.identified_by else None,
    }


def inspection_view(session: Session, inspection: Inspection) -> dict:
    """Полное описание осмотра: находки и полнота обхода - текущая у идущего осмотра, сохранённая у завершённого."""
    names = _node_names(inspection.equipment)
    if inspection.status == "active":
        coverage = tracker_for(session, inspection).state()
    else:
        coverage = (inspection.summary or {}).get("coverage")
    return {**_inspection_brief(inspection), "coverage": coverage,
            "findings": [finding_view(finding, names) for finding in inspection.findings]}


def _live_key(inspection_id: int) -> tuple[str, int]:
    """Ключ состояния идущего осмотра: номер осмотра уникален только в пределах своей базы."""
    return os.path.abspath(config.db_path()), inspection_id


def _telemetry(equipment_id: str) -> tuple[dict, dict, datetime | None]:
    """Возвращает показания, тренды за 12 часов и момент ленты телеметрии; без телеметрии - пустые значения."""
    try:
        player = get_player(equipment_id)
    except (KeyError, TelemetryDataError):
        return {}, {}, None
    moment = player.cursor
    readings = player.snapshot(moment)
    trends = {}
    for code in CODES:
        slope = player.trend(code, TREND_HOURS, moment)
        if slope is not None:
            trends[code] = slope
    return readings, trends, moment


def node_route(session: Session, item: Equipment) -> list[dict]:
    """Возвращает узлы агрегата в порядке приоритета осмотра, у каждого - причина его места в маршруте.

    Незакрытое замечание завершённых осмотров важнее отклонения по датчикам, оно важнее ресурса на исходе,
    далее - плановый осмотр в порядке критичности правил. Запись: {code, name, rank, group, reason}, где group -
    "previous_finding", "sensor", "resource" или "routine".
    """
    card = equipment_card(item)
    order = static_priority(card)
    names = {node["id"]: node["name"] for node in card["nodes"]}
    route = {code: {"code": code, "name": names[code], "rank": ROUTINE_RANK, "group": "routine", "reason": ROUTINE_REASON}
             for code in order}

    def promote(code: str | None, rank: int, group: str, reason: str) -> None:
        """Поднимает узел в маршруте, если новая причина важнее уже найденной."""
        if code in route and rank < route[code]["rank"]:
            route[code].update(rank=rank, group=group, reason=reason)

    readings, trends, moment = _telemetry(item.id)
    today = moment.date() if moment else date.today()
    run_hours = readings.get("run_hours", item.run_hours)
    for node in card["nodes"]:
        calculated = resource_estimates(card, node, run_hours, today)["calculated"]
        if calculated["state"] in ("due", "approaching"):
            promote(node["id"], 4 if calculated["state"] == "due" else 5, "resource", calculated["text"])
    if readings:
        for code, state in diagnose(card, readings, trends, {})["nodes"].items():
            if state["status"] in ("defect", "check"):
                promote(code, 2 if state["status"] == "defect" else 3, "sensor",
                        "Отклонение по датчикам: " + "; ".join(state["reasons"]))
    unresolved = session.execute(
        select(Finding.id, Finding.node_code, Finding.status, Finding.title, Finding.created_at).where(
            Finding.equipment_id == item.id, Finding.state.notin_(CLOSED_STATES), Finding.status != "ok",
            Finding.inspection_id.in_(select(Inspection.id).where(Inspection.status == "finished")),
        ).order_by(Finding.id.desc()))
    for number, code, status, title, created in unresolved:
        promote(code, 0 if status == "defect" else 1, "previous_finding",
                f"Не устранено замечание № {number} от {created:%d.%m.%Y}: {title}")
    return sorted(route.values(), key=lambda entry: (entry["rank"], order.index(entry["code"])))


def node_priority(session: Session, item: Equipment) -> list[str]:
    """Возвращает коды узлов в порядке приоритета осмотра - в этом порядке идут подсказки обхода."""
    return [entry["code"] for entry in node_route(session, item)]


def _live_state(session: Session, inspection: Inspection) -> dict:
    """Возвращает состояние идущего осмотра в памяти сервера, создавая его при первом обращении.

    После перезапуска сервера счётчик кадров начинается заново, но узлы, по которым инженер уже сделал
    записи в этом осмотре, сразу считаются осмотренными.
    """
    _ensure_active(inspection)
    key = _live_key(inspection.id)
    with _live_lock:
        state = _live.get(key)
        if state is None:
            card = equipment_card(inspection.equipment)
            tracker = CoverageTracker(card, node_priority(session, inspection.equipment))
            known = _node_names(inspection.equipment)
            for finding in counted(inspection.findings):
                if finding.node_code in known:
                    tracker.mark_checked(finding.node_code)
            state = {"tracker": tracker, "gauge": None}
            _live[key] = state
        return state


def tracker_for(session: Session, inspection: Inspection) -> CoverageTracker:
    """Возвращает счётчик полноты обхода идущего осмотра; для завершённого осмотра отвечает 409.

    Счётчик живёт в памяти сервера, поэтому переподключение телефона не обнуляет накопленное.
    """
    return _live_state(session, inspection)["tracker"]


def note_gauge_reading(session: Session, inspection: Inspection, value: float | None) -> None:
    """Запоминает показание стрелочного манометра, считанное камерой: оно участвует в правиле R05."""
    _live_state(session, inspection)["gauge"] = None if value is None else float(value)


def _manual_marks(inspection: Inspection) -> set[str]:
    """Собирает отметки инженера из записей осмотра: подтверждённые признаки и узлы, проверенные без замечаний."""
    marks = set()
    for finding in counted(inspection.findings):
        meta = _meta(finding)
        if meta.get("sign"):
            marks.add(meta["sign"])
        if finding_kind(finding) == "checked" and finding.node_code:
            marks.add(f"checked:{finding.node_code}")
    return marks


def diagnosis_inputs(session: Session, inspection: Inspection, extra_marks: frozenset = frozenset()) -> dict:
    """Входные данные диагностики в осмотре: карточка, показания, тренды, признаки камеры и отметки инженера.

    У идущего осмотра учитываются показание манометра и узлы, увиденные камерой (без неподтверждённых
    признаков дефектов); у завершённого - только датчики и записи инженера. Отклонённые находки не учитываются.
    """
    item = inspection.equipment
    card = equipment_card(item)
    readings, trends, moment = _telemetry(item.id)
    run_hours = readings.get("run_hours", item.run_hours)
    seen = {}
    if inspection.status == "active":
        live = _live_state(session, inspection)
        if live["gauge"] is not None:
            readings = {**readings, GAUGE_READING: live["gauge"]}
        signs = defect_signs()
        seen = {cls: conf for cls, conf in live["tracker"].visual.items() if cls not in signs}
    return {"card": card, "readings": readings, "trends": trends, "visual": seen,
            "marks": _manual_marks(inspection) | extra_marks, "moment": moment, "run_hours": run_hours}


def _assess(session: Session, inspection: Inspection, extra_marks: frozenset = frozenset()) -> dict:
    """Собирает всё для оценки агрегата в идущем осмотре и запускает диагностику.

    Текущим днём для расчёта ресурса служит момент ленты телеметрии, а без телеметрии - сегодняшняя дата.
    """
    _ensure_active(inspection)
    inputs = diagnosis_inputs(session, inspection, extra_marks)
    diagnosis = diagnose(inputs["card"], inputs["readings"], inputs["trends"], inputs["visual"], inputs["marks"])
    moment = inputs["moment"]
    return {"card": inputs["card"], "moment": moment, "run_hours": inputs["run_hours"], "diagnosis": diagnosis,
            "today": moment.date() if moment else date.today()}


def current_diagnosis(session: Session, inspection: Inspection) -> dict:
    """Диагноз агрегата на текущий момент идущего осмотра: камера, датчики, ресурс и отметки инженера."""
    return _assess(session, inspection)["diagnosis"]


def _worst(statuses) -> str:
    """Выбирает наихудший статус из перечисленных; без статусов - «нет данных»."""
    return max(statuses, key=STATUS_RANK.__getitem__, default="unknown")


def uninspected_nodes(nodes: list[dict] | None) -> list[dict]:
    """Перечисляет узлы, оставшиеся без осмотра: фактическое состояние «не осмотрен / недостаточно данных»."""
    return [{"code": row["code"], "name": row["name"]} for row in nodes or ()
            if (row.get("actual") or {}).get("status") == "unknown"]


def verdict(status: str | None, nodes: list[dict] | None) -> str:
    """Итог осмотра с учётом полноты обхода.

    Найденный признак дефекта или повод для проверки важнее всего. Иначе, если хотя бы один узел остался
    без осмотра, итог - «Осмотр неполный», а не «видимых проблем не обнаружено».
    """
    status = status or "unknown"
    if status in ("check", "defect"):
        return status
    return INCOMPLETE if uninspected_nodes(nodes) else status


def _not_walked(coverage: dict | None, code: str) -> bool:
    """Сообщает, что узел камера распознаёт, но при обходе он не осмотрен и инженер его не отметил."""
    node = ((coverage or {}).get("nodes") or {}).get(code)
    return bool(node and node.get("trackable") and not node.get("inspected"))


def _node_estimates(card: dict, run_hours: float, today: date, states: dict, findings: list[Finding],
                    coverage: dict | None = None) -> list[dict]:
    """Собирает по каждому узлу три раздельные оценки: норматив, расчётный остаток и фактическое состояние.

    Фактическое состояние берётся из диагностики и дополняется записями инженера в этом осмотре. Узел,
    который камера распознаёт, но при обходе он не осмотрен, не получает «видимых проблем не обнаружено»:
    без осмотра он остаётся в категории «не осмотрен».
    """
    rows = []
    for node in card["nodes"]:
        estimate = resource_estimates(card, node, run_hours, today)
        rows.append({"code": node["id"], "name": node["name"], "normative": estimate["normative"],
                     "calculated": estimate["calculated"]})
    codes = {row["code"] for row in rows}
    loose = [finding for finding in findings if finding.node_code not in codes and finding.status != "ok"]
    if EQUIPMENT_NODE in states or loose:
        rows.append({"code": EQUIPMENT_NODE, "name": WHOLE_UNIT, "normative": None, "calculated": None})
    for row in rows:
        state = states.get(row["code"]) or {"status": "unknown", "reasons": []}
        reasons = list(state.get("reasons") or [])
        own = [finding for finding in findings
               if (finding.node_code if finding.node_code in codes else EQUIPMENT_NODE) == row["code"]]
        statuses = [state["status"]]
        for finding in own:
            if finding.status == "ok":
                continue
            statuses.append(finding.status)
            if not (finding.rule_id and any(reason.endswith(f"({finding.rule_id})") for reason in reasons)):
                reasons.append(f"{finding.title} (зафиксировано в осмотре)")
        if state["status"] == "unknown" and any(finding_kind(finding) == "checked" for finding in own):
            statuses.append("ok")
            reasons.insert(0, "Проверено инженером: замечаний нет")
        status = _worst(statuses)
        if status == "ok" and _not_walked(coverage, row["code"]):
            status = "unknown"
            reasons = [NOT_WALKED, *(reason for reason in reasons if reason != CAMERA_MISSED)]
        if not reasons:
            reasons = ["Узел не осмотрен, данных по нему нет"]
        row["actual"] = {"status": status, "reasons": reasons}
    return rows


def _coverage_brief(state: dict) -> dict:
    """Сокращает состояние полноты обхода до того, что сохраняется в сводке осмотра."""
    nodes = {code: {key: node[key] for key in ("name", "seen", "best_conf", "inspected", "manual", "trackable", "defect_classes")}
             for code, node in state["nodes"].items()}
    return {"percent": state["percent"], "inspected": state["inspected"], "total": state["total"],
            "frames": state["frames"], "nodes": nodes}


def _photos_dir() -> Path:
    """Папка снимков к находкам - рядом с файлом базы."""
    return Path(config.db_path()).resolve().parent / "photos"


def photo_file(finding: Finding) -> Path:
    """Возвращает путь к снимку находки или отвечает 404, если снимка нет."""
    if not finding.photo_path:
        raise HTTPException(status_code=404, detail="К этому замечанию снимок не приложен")
    root = _photos_dir()
    path = (root / finding.photo_path).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        raise HTTPException(status_code=404, detail="Файл снимка не найден")
    return path


def clean_frame(data: bytes) -> bytes:
    """Проверяет стоп-кадр камеры и пересохраняет его как JPEG без служебных данных, не крупнее 1920 пикселей.

    Принимается только JPEG: именно так телефон передаёт кадры камеры.
    """
    if len(data) > MAX_FRAME_BYTES:
        raise HTTPException(status_code=413, detail=f"Кадр больше {MAX_FRAME_BYTES // (1024 * 1024)} МБ")
    if not data.startswith(b"\xff\xd8"):
        raise HTTPException(status_code=415, detail="Кадр должен быть в формате JPEG")
    try:
        with Image.open(io.BytesIO(data)) as image:
            if image.format != "JPEG":
                raise HTTPException(status_code=415, detail="Кадр должен быть в формате JPEG")
            if image.width * image.height > MAX_FRAME_PIXELS:
                raise HTTPException(status_code=413, detail="Кадр слишком большого размера в пикселях")
            picture = ImageOps.exif_transpose(image).convert("RGB")
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError) as error:
        raise HTTPException(status_code=422, detail="Кадр повреждён: изображение не читается") from error
    picture.thumbnail((MAX_PHOTO_SIDE, MAX_PHOTO_SIDE))
    output = io.BytesIO()
    picture.save(output, format="JPEG", quality=88)
    return output.getvalue()


def _sync_run_hours(item: Equipment, run_hours: float) -> None:
    """Подтягивает наработку агрегата и его узлов в базе к счётчику телеметрии, если тот ушёл вперёд."""
    delta = run_hours - item.run_hours
    if delta <= 0:
        return
    for node in item.nodes:
        if node.hours is not None:
            node.hours += delta
    item.run_hours = run_hours


def _manual_evidence(kind: str, value: str, what: str = ENGINEER_MARK, **extra) -> list[dict]:
    """Собирает основание записи, сделанной инженером вручную, вместе со служебными пометками."""
    return [{"source": "manual", "what": what, "value": value, "threshold": None, "met": True, "kind": kind, **extra}]


def _source_of(evidence: list[dict]) -> str:
    """Определяет источник находки диагностики по её основаниям: камера важнее датчиков, датчики - ресурса."""
    sources = {line["source"] for line in evidence if line.get("met")} or {line["source"] for line in evidence}
    return next((source for source in ("camera", "sensor", "resource", "manual") if source in sources), "sensor")


def _from_rule(inspection: Inspection, found: dict, automatic: bool) -> Finding:
    """Превращает находку диагностики в запись осмотра, сохраняя основания и подсказки."""
    evidence = [dict(line) for line in found["evidence"]] or _manual_evidence("defect", found["title"])
    evidence[0] = {**evidence[0], "kind": "defect", "missing": list(found.get("missing") or []), "automatic": automatic}
    node_code = None if found["node_id"] == EQUIPMENT_NODE else found["node_id"]
    return Finding(
        inspection_id=inspection.id, equipment_id=inspection.equipment_id, node_code=node_code,
        source=_source_of(found["evidence"]), rule_id=found["rule_id"], status=found["status"],
        severity=found["severity"], title=found["title"], diagnosis=found["diagnosis"],
        recommendation=found["recommendation"], confidence=found["confidence"], evidence=evidence, state="open",
        created_at=now())


def _defect_finding(session: Session, inspection: Inspection, node: str | None, severity: int | None,
                    sign: str | None, rule_id: str | None) -> Finding:
    """Собирает запись о дефекте: по правилу диагностики, по признаку из перечня или свободную отметку инженера."""
    if rule_id:
        found = next((entry for entry in _assess(session, inspection)["diagnosis"]["findings"]
                      if entry["rule_id"] == rule_id and node in (None, entry["node_id"])), None)
        if found is None:
            raise HTTPException(status_code=409, detail=f"Правило {rule_id} сейчас не выполняется для этого узла - "
                                                        "зафиксируйте дефект без ссылки на правило")
        finding = _from_rule(inspection, found, automatic=False)
    elif sign:
        titles = defect_signs()
        if sign not in titles:
            raise HTTPException(status_code=422, detail=f"Неизвестный признак дефекта: {sign}")
        confirmed = _assess(session, inspection, frozenset({sign}))["diagnosis"]["findings"]
        found = next((entry for entry in confirmed if node in (None, entry["node_id"]) and any(
            line["source"] == "manual" and line["met"] and line["what"] == titles[sign] for line in entry["evidence"])), None)
        if found:
            finding = _from_rule(inspection, found, automatic=False)
            finding.evidence = [{**finding.evidence[0], "sign": sign}, *finding.evidence[1:]]
            finding.title = titles[sign]
        else:
            finding = Finding(
                inspection_id=inspection.id, equipment_id=inspection.equipment_id, node_code=node, source="manual",
                status="defect", severity=2, title=titles[sign], state="open", created_at=now(),
                evidence=_manual_evidence("defect", "подтверждено инженером", titles[sign], sign=sign))
    else:
        finding = Finding(
            inspection_id=inspection.id, equipment_id=inspection.equipment_id, node_code=node, source="manual",
            status="defect", severity=2, title=KIND_TITLES["defect"], state="open", created_at=now(),
            evidence=_manual_evidence("defect", "зафиксирован дефект"))
    if severity is not None:
        finding.severity = severity
    return finding


def _work_finding(inspection: Inspection, user: User, kind: str, node: str | None, comment: str | None,
                  maintenance_code: str | None) -> tuple[Finding, MaintenanceRecord]:
    """Записывает обслуживание или замену узла: наработка, регламент, отметка в осмотре и запись о работе.

    Наработка агрегата в базе сначала подтягивается к счётчику телеметрии, чтобы узел после замены
    начинал счёт с нуля, а отметка последнего обслуживания соответствовала текущей наработке. Датой замены
    служит день, на который рассчитываются оценки ресурса: момент ленты телеметрии, а без неё - сегодня.
    """
    item = inspection.equipment
    schedule = [dict(entry) for entry in item.data.get("maintenance") or []]
    done = next((entry for entry in schedule if entry.get("code") == maintenance_code), None)
    if maintenance_code and done is None:
        raise HTTPException(status_code=422, detail=f"В регламенте агрегата нет вида обслуживания {maintenance_code}")
    readings, _, moment = _telemetry(item.id)
    _sync_run_hours(item, readings.get("run_hours", item.run_hours))
    title = KIND_TITLES[kind]
    if done is not None:
        done["last_at_hours"] = item.run_hours
        item.data = {**item.data, "maintenance": schedule}
        title = f"{title}: {done.get('name') or maintenance_code}"
    if kind == "replacement":
        target = next(entry for entry in item.nodes if entry.code == node)
        target.hours = 0.0
        target.replaced = moment.date() if moment else now().date()
    record = MaintenanceRecord(equipment_id=item.id, node_code=node, kind=kind, comment=comment or title,
                               user_id=user.id, at=now(), hours_at=item.run_hours)
    finding = Finding(
        inspection_id=inspection.id, equipment_id=item.id, node_code=node, source="manual", status="ok", severity=0,
        title=title, state="resolved", created_at=record.at,
        evidence=_manual_evidence(kind, title[:1].lower() + title[1:], maintenance_code=maintenance_code))
    return finding, record


def add_finding(session: Session, inspection: Inspection, user: User, *, kind: str, node: str | None = None,
                severity: int | None = None, comment: str | None = None, sign: str | None = None,
                rule_id: str | None = None, maintenance_code: str | None = None, frame: bytes | None = None) -> Finding:
    """Фиксирует результат осмотра узла: проверено, дефект, обслуживание или замена; к записи можно приложить стоп-кадр.

    Замена обнуляет наработку узла и ставит дату замены; обслуживание и замена пишутся в историю работ.
    Узел, по которому инженер сделал запись, считается осмотренным в полноте обхода.
    """
    _ensure_editor(inspection, user)
    _ensure_active(inspection)
    if kind not in KINDS:
        raise HTTPException(status_code=422, detail="Вид записи: checked, defect, maintenance или replacement")
    node = (node or "").strip() or None
    if node == EQUIPMENT_NODE:
        node = None
    comment = (comment or "").strip() or None
    sign, rule_id, maintenance_code = ((value or "").strip() or None for value in (sign, rule_id, maintenance_code))
    if node is not None and node not in _node_names(inspection.equipment):
        raise HTTPException(status_code=404, detail="Узел не найден")
    if kind == "replacement" and node is None:
        raise HTTPException(status_code=422, detail="Для замены укажите узел")
    if kind != "defect" and (sign or rule_id):
        raise HTTPException(status_code=422, detail="Признак и правило указываются только при фиксации дефекта")
    if kind != "maintenance" and maintenance_code:
        raise HTTPException(status_code=422, detail="Вид обслуживания указывается только при фиксации обслуживания")
    picture = clean_frame(frame) if frame is not None else None
    record = None
    if kind == "defect":
        finding = _defect_finding(session, inspection, node, severity, sign, rule_id)
    elif kind == "checked":
        finding = Finding(
            inspection_id=inspection.id, equipment_id=inspection.equipment_id, node_code=node, source="manual",
            status="ok", severity=0, title=KIND_TITLES["checked"], state="resolved", created_at=now(),
            evidence=_manual_evidence("checked", "проверено, замечаний нет"))
    else:
        finding, record = _work_finding(inspection, user, kind, node, comment, maintenance_code)
    finding.comment = comment
    _with_models(finding)
    saved = None
    try:
        session.add(finding)
        if record is not None:
            session.add(record)
        session.flush()
        if picture is not None:
            relative = Path(f"inspection_{inspection.id}") / f"finding_{finding.id}.jpg"
            saved = _photos_dir() / relative
            saved.parent.mkdir(parents=True, exist_ok=True)
            saved.write_bytes(picture)
            finding.photo_path = relative.as_posix()
        session.commit()
    except Exception:
        session.rollback()
        if saved is not None:
            saved.unlink(missing_ok=True)
        raise
    if finding.node_code:
        tracker_for(session, inspection).mark_checked(finding.node_code)
    return finding


def _record_automatic(session: Session, inspection: Inspection, diagnosis: dict) -> None:
    """Записывает в осмотр находки диагностики, которые инженер не зафиксировал сам.

    Если такое же замечание с прошлого осмотра ещё не устранено, в комментарии ставится ссылка на него.
    """
    known = {(finding.rule_id, finding.node_code) for finding in inspection.findings if finding.rule_id}
    for found in diagnosis["findings"]:
        finding = _from_rule(inspection, found, automatic=True)
        if (finding.rule_id, finding.node_code) in known:
            continue
        earlier = session.execute(
            select(Finding.id, Finding.created_at).where(
                Finding.equipment_id == inspection.equipment_id, Finding.rule_id == finding.rule_id,
                Finding.node_code.is_(None) if finding.node_code is None else Finding.node_code == finding.node_code,
                Finding.inspection_id != inspection.id, Finding.state.notin_(CLOSED_STATES), Finding.status != "ok",
            ).order_by(Finding.id.desc())).first()
        if earlier:
            finding.comment = f"Повторно: замечание № {earlier.id} от {earlier.created_at:%d.%m.%Y} не устранено"
        inspection.findings.append(_with_models(finding))
        known.add((finding.rule_id, finding.node_code))


def finish_inspection(session: Session, inspection: Inspection, user: User) -> Inspection:
    """Завершает осмотр: дописывает незафиксированные находки диагностики и сохраняет сводку.

    В сводке - число записей по статусам, длительность, общий статус, полнота обхода и три оценки по узлам
    на момент завершения. Задания на осмотр этого агрегата, выданные автору осмотра, закрываются.
    Повторное завершение ничего не меняет и возвращает тот же осмотр.
    """
    _ensure_editor(inspection, user)
    if inspection.status != "active":
        return inspection
    finished = now()
    try:
        claimed = session.execute(
            update(Inspection).where(Inspection.id == inspection.id, Inspection.status == "active")
            .values(status="finished", finished_at=finished).execution_options(synchronize_session=False))
        if claimed.rowcount == 0:
            session.rollback()
            return get_inspection(session, inspection.id)
        assessment = _assess(session, inspection)
        coverage = tracker_for(session, inspection).state()
        _record_automatic(session, inspection, assessment["diagnosis"])
        session.flush()
        card, diagnosis = assessment["card"], assessment["diagnosis"]
        kept = counted(inspection.findings)
        statuses = [finding.status for finding in kept]
        nodes = _node_estimates(card, assessment["run_hours"], assessment["today"], diagnosis["nodes"], kept, coverage)
        overall = verdict(_worst([diagnosis["status"], *statuses]), nodes)
        inspection.status, inspection.finished_at = "finished", finished
        inspection.summary = {
            "findings": len(statuses),
            "by_status": {status: statuses.count(status) for status in ("ok", "check", "defect")},
            "rejected": len(inspection.findings) - len(kept),
            "duration_s": max(int((finished - inspection.started_at).total_seconds()), 0),
            "status": overall,
            "status_title": STATUS_TITLES[overall],
            "uninspected": uninspected_nodes(nodes),
            "coverage": _coverage_brief(coverage),
            "nodes": nodes,
            "maintenance": maintenance_intervals(card, assessment["run_hours"]),
            "run_hours": assessment["run_hours"],
            "telemetry_at": _stamp(assessment["moment"]),
            "estimates_on": assessment["today"].isoformat(),
            "sound": sound_brief(session, inspection.id),
        }
        workflow.close_tasks(session, inspection, finished)
        session.commit()
    except Exception:
        session.rollback()
        raise
    with _live_lock:
        _live.pop(_live_key(inspection.id), None)
    return get_inspection(session, inspection.id)


def sound_brief(session: Session, inspection_id: int) -> dict | None:
    """Итог последней записи звука осмотра: уровень, отличие от нормы и тексты кандидатов; без записей - None."""
    record = session.scalar(select(SoundRecord).where(SoundRecord.inspection_id == inspection_id)
                            .order_by(SoundRecord.id.desc()))
    if record is None:
        return None
    data = record.summary or {}
    return {"id": record.id, "created_at": _stamp(record.created_at), "level_dbfs": data.get("level_dbfs"),
            "delta_db": (data.get("baseline") or {}).get("delta_db"),
            "candidates": [entry["text"] for entry in data.get("candidates") or []]}


def list_findings(session: Session, *, inspection_id: int | None = None, equipment_id: str | None = None,
                  state: str | None = None, include_ok: bool = False, include_rejected: bool = False,
                  limit: int = 200) -> list[dict]:
    """Список замечаний, сначала новые; записи без замечаний и отклонённые показываются только по запросу.

    Отклонённые попадают в список, если запрошено именно состояние rejected или include_rejected.
    """
    query = select(Finding)
    if inspection_id is not None:
        query = query.where(Finding.inspection_id == inspection_id)
    if equipment_id:
        query = query.where(Finding.equipment_id == equipment_id)
    if state:
        query = query.where(Finding.state == state)
    elif not include_rejected:
        query = query.where(Finding.state != REJECTED)
    if not include_ok:
        query = query.where(Finding.status != "ok")
    findings = list(session.scalars(query.order_by(Finding.created_at.desc(), Finding.id.desc()).limit(limit)))
    names = {}
    owners = sorted({finding.equipment_id for finding in findings})
    for item in session.scalars(select(Equipment).where(Equipment.id.in_(owners)).options(selectinload(Equipment.nodes))):
        names[item.id] = (item.name, _node_names(item))
    views = []
    for finding in findings:
        equipment_name, node_names = names[finding.equipment_id]
        views.append({**finding_view(finding, node_names), "equipment_name": equipment_name})
    return views


def one_finding_view(session: Session, finding: Finding) -> dict:
    """Описывает одно замечание вместе с названием его агрегата и узла."""
    item = get_equipment(session, finding.equipment_id)
    return {**finding_view(finding, _node_names(item)), "equipment_name": item.name}


def _note(user: User, text: str, kind: str) -> dict:
    """Комментарий сотрудника к находке: вид, текст, автор и время."""
    return {"kind": kind, "text": text, "user_id": user.id, "user_name": user.name, "at": _stamp(now())}


def _comment_line(title: str, user: User, text: str) -> str:
    """Строка комментария в общем тексте находки: заголовок, автор, дата и текст."""
    return f"{title} - {user.name}, {now():%d.%m.%Y %H:%M}: {text}"


def _summary_after_reject(session: Session, finding: Finding) -> None:
    """Пересчитывает счётчики сводки завершённого осмотра после отклонения находки.

    Итоговый статус становится наихудшим из оставшихся находок; если замечаний не осталось, а прежний итог
    был «проверка» или «дефект», итог - «видимых проблем не обнаружено», а при неосмотренных узлах -
    «Осмотр неполный».
    """
    inspection = session.get(Inspection, finding.inspection_id)
    summary = dict(inspection.summary or {}) if inspection else {}
    if not summary:
        return
    rows = session.execute(select(Finding.status, Finding.state).where(Finding.inspection_id == inspection.id)).all()
    statuses = [status for status, state in rows if state != REJECTED]
    summary["findings"] = len(statuses)
    summary["by_status"] = {status: statuses.count(status) for status in ("ok", "check", "defect")}
    summary["rejected"] = len(rows) - len(statuses)
    if summary.get("status") in ("check", "defect"):
        summary["status"] = _worst([*statuses, "ok"])
        if summary["status"] == "ok" and (summary.get("uninspected") or uninspected_nodes(summary.get("nodes"))):
            summary["status"] = INCOMPLETE
        if "status_title" in summary:
            summary["status_title"] = STATUS_TITLES[summary["status"]]
    inspection.summary = summary


def set_finding_state(session: Session, finding: Finding, state: str, user: User, comment: str | None = None) -> Finding:
    """Переводит замечание по цепочке «открыто - в работе - устранено» или отклоняет его как ложное.

    Шаг назад и через ступень не допускается. Отклонить можно открытое замечание или замечание в работе,
    только с комментарием-причиной; отклонённое замечание больше не меняет состояние. Повтор уже выполненного
    перехода ничего не меняет. Комментарий дописывается к замечанию с именем и датой.
    """
    if state not in STATE_TITLES:
        raise HTTPException(status_code=422, detail="Состояние: open, in_work, resolved или rejected")
    if finding.state == state:
        return finding
    note = (comment or "").strip()
    if state == REJECTED:
        if finding.state not in REJECTABLE:
            raise HTTPException(status_code=409, detail=f"Замечание в состоянии «{STATE_TITLES[finding.state]}» "
                                                        "отклонить нельзя: отклоняются открытые замечания и замечания в работе")
        if not note:
            raise HTTPException(status_code=422, detail="Укажите причину отклонения замечания")
    elif NEXT_STATE.get(finding.state) != state:
        raise HTTPException(
            status_code=409,
            detail=f"Переход из состояния «{STATE_TITLES[finding.state]}» в «{STATE_TITLES[state]}» невозможен: "
                   "порядок - открыто, в работе, устранено")
    values = {"state": state}
    if note:
        line = _comment_line(STATE_TITLES[state], user, note)
        values["comment"] = f"{finding.comment}\n{line}" if finding.comment else line
        values["notes"] = [*(finding.notes or []), _note(user, note, REJECTED if state == REJECTED else "state")]
    if state == REJECTED:
        values["rejected_at"], values["rejected_by_id"] = now(), user.id
    moved = session.execute(
        update(Finding).where(Finding.id == finding.id, Finding.state == finding.state).values(**values)
        .execution_options(synchronize_session=False))
    if moved.rowcount and state == REJECTED:
        _summary_after_reject(session, finding)
    session.commit()
    session.refresh(finding)
    if moved.rowcount == 0 and finding.state != state:
        raise HTTPException(status_code=409, detail="Состояние замечания уже изменил другой сотрудник - обновите список")
    return finding


def can_comment(session: Session, finding: Finding, user: User, permissions: set[str]) -> bool:
    """Сообщает, может ли сотрудник комментировать находку: право «Просмотр замечаний» или он автор осмотра."""
    if "findings.view" in permissions:
        return True
    return session.scalar(select(Inspection.user_id).where(Inspection.id == finding.inspection_id)) == user.id


def add_comment(session: Session, finding: Finding, user: User, text: str) -> Finding:
    """Дописывает к находке комментарий сотрудника с временем и автором; пустой комментарий отклоняется."""
    note = (text or "").strip()
    if not note:
        raise HTTPException(status_code=422, detail="Комментарий пустой")
    line = _comment_line("Комментарий", user, note)
    finding.comment = f"{finding.comment}\n{line}" if finding.comment else line
    finding.notes = [*(finding.notes or []), _note(user, note, "comment")]
    session.commit()
    session.refresh(finding)
    return finding


def _report_nodes(session: Session, inspection: Inspection) -> tuple[list[dict], dict]:
    """Возвращает оценки по узлам для отчёта и сведения о том, на какой момент они рассчитаны."""
    summary = inspection.summary or {}
    item = inspection.equipment
    if inspection.status == "active":
        assessment = _assess(session, inspection)
        coverage = _coverage_brief(tracker_for(session, inspection).state())
        kept = counted(inspection.findings)
        nodes = _node_estimates(assessment["card"], assessment["run_hours"], assessment["today"],
                                assessment["diagnosis"]["nodes"], kept, coverage)
        return nodes, {
            "status": verdict(_worst([assessment["diagnosis"]["status"], *(finding.status for finding in kept)]), nodes),
            "uninspected": uninspected_nodes(nodes), "coverage": coverage, "maintenance": maintenance_intervals(assessment["card"], assessment["run_hours"]),
            "run_hours": assessment["run_hours"], "telemetry_at": _stamp(assessment["moment"]),
            "estimates_on": assessment["today"].isoformat(),
            "basis": "Осмотр не завершён: оценки рассчитаны на момент формирования отчёта",
        }
    if summary.get("nodes"):
        return summary["nodes"], {
            **{key: summary.get(key) for key in ("coverage", "maintenance", "run_hours", "telemetry_at", "estimates_on")},
            "status": verdict(summary.get("status"), summary["nodes"]), "uninspected": uninspected_nodes(summary["nodes"]),
            "basis": "Оценки сохранены на момент завершения осмотра",
        }
    card = equipment_card(item)
    kept = counted(inspection.findings)
    nodes = _node_estimates(card, item.run_hours, date.today(), {}, kept)
    for row in nodes:
        if row["actual"]["status"] == "unknown":
            row["actual"]["reasons"] = ["В этом осмотре по узлу записей нет"]
    return nodes, {
        "status": _worst(finding.status for finding in kept), "uninspected": [], "coverage": None,
        "maintenance": maintenance_intervals(card, item.run_hours), "run_hours": item.run_hours, "telemetry_at": None,
        "estimates_on": date.today().isoformat(),
        "basis": "Оценки ресурса рассчитаны на дату формирования отчёта: на момент осмотра они не сохранялись",
    }


def report_data(session: Session, inspection: Inspection) -> dict:
    """Собирает всё содержание отчёта об осмотре: агрегат, кто и когда, три оценки по узлам, находки с основаниями."""
    item = inspection.equipment
    names = _node_names(item)
    nodes, context = _report_nodes(session, inspection)
    nodes = [{**row, "actual": {**row["actual"], "title": STATUS_TITLES[row["actual"]["status"]]}} for row in nodes]
    views = []
    for finding in inspection.findings:
        view = finding_view(finding, names)
        view["photo_file"] = None
        if finding.photo_path:
            path = _photos_dir() / finding.photo_path
            view["photo_file"] = str(path) if path.is_file() else None
        views.append(view)
    finished = inspection.finished_at
    duration = int((finished - inspection.started_at).total_seconds()) if finished else None
    confirmed = [view for view in views if view["kind"] == "defect" and not view["rejected"]]
    extra = import_module("server.inspections.report_extra")
    card = equipment_card(item)
    return {
        "generated_at": _stamp(now()),
        "decision": DECISION_LINE,
        "ok_note": f"Статус «{STATUS_TITLES['ok']}» {OK_NOTE}",
        "inspection": {
            "id": inspection.id, "status": inspection.status,
            "status_title": INSPECTION_TITLES.get(inspection.status, inspection.status),
            "started_at": _stamp(inspection.started_at), "finished_at": _stamp(finished), "duration_s": duration,
            "user": _person(inspection.user),
        },
        "equipment": {
            "id": item.id, "name": item.name, "type": item.type, "model": item.model, "serial": item.serial,
            "manufacturer": item.data.get("manufacturer"), "location": item.location, "mode": item.mode,
            "mode_title": MODE_TITLES.get(item.mode, item.mode), "commissioned": item.data.get("commissioned"),
            "run_hours": context["run_hours"] if context["run_hours"] is not None else item.run_hours,
        },
        "overall": {"status": context["status"] or "unknown", "title": STATUS_TITLES[context["status"] or "unknown"]},
        "uninspected": context["uninspected"],
        "coverage": context["coverage"],
        "telemetry_at": context["telemetry_at"],
        "estimates_on": context["estimates_on"],
        "basis": context["basis"],
        "nodes": nodes,
        "maintenance": context["maintenance"] or [],
        "findings": confirmed,
        "checked": [view for view in views if view["kind"] == "checked"],
        "works": [view for view in views if view["kind"] in ("maintenance", "replacement")],
        "rejected": [view for view in views if view["rejected"]],
        "models": {"current": fingerprint.short(),
                   "findings": sorted({view["models_fingerprint"] for view in views if view["models_fingerprint"]})},
        "identified": {"code": inspection.identified_by,
                       "title": IDENTIFIED_TITLES.get(inspection.identified_by, "Не указано")},
        "walk": extra.walk_section(nodes, context["coverage"], counted(inspection.findings)),
        "sensors": extra.sensors_section(inspection, context["telemetry_at"]),
        "sound": extra.sound_section(session, inspection.id),
        "recommendations": extra.recommendations(confirmed),
        "next_maintenance": extra.next_maintenance(card, context["run_hours"], nodes),
        "signatures": extra.signatures(session, inspection, inspection.findings),
    }
