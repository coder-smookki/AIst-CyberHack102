"""Начальное наполнение базы: системные роли, политика безопасности, оборудование из data/equipment.json,
демонстрационные учётные записи и прошлая история.

Наполнение только добавляет недостающее и никогда не меняет существующие строки, поэтому его можно вызывать при
каждом запуске сервера: наработка, режим, замены узлов, пароли, а также права ролей и политика, изменённые
администратором ИБ, сохраняются.
Прошлые осмотры и работы - демонстрационные записи, согласованные с карточками оборудования.
"""
import json
from datetime import date, datetime
from functools import lru_cache
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from server import config
from server.auth import hash_password
from server.models import FINDING_STATUSES, Equipment, Finding, Inspection, MaintenanceRecord, Node, Role, User
from server.permissions import SYSTEM_ROLES, ordered
from server.security import get_policy

DEMO_PASSWORD = "demo12345"
DEMO_USERS = (
    ("engineer@kst.demo", "Алексей Смирнов", "engineer"),
    ("master@kst.demo", "Марина Орлова", "master"),
    ("admin@kst.demo", "Игорь Власов", "admin"),
    ("operator@kst.demo", "Ольга Кузнецова", "operator"),
    ("security@kst.demo", "Дмитрий Захаров", "security_admin"),
)
EQUIPMENT_COLUMNS = ("id", "name", "type", "model", "serial", "location", "mode", "run_hours")
NODE_COLUMNS = ("id", "name", "hours", "installed", "replaced")
NO_REMARKS = "Проверено, замечаний нет"
DEMO_HISTORY: dict[str, dict[str, Any]] = {
    "SHU-3": {
        "maintenance": [
            {"at": "2025-05-20T10:00", "kind": "maintenance", "node": None, "user": "master@kst.demo", "hours_at": 35000,
             "comment": "Ревизия шкафа: проверены контакторы и автоматические выключатели, замерено сопротивление изоляции"},
            {"at": "2026-07-01T09:30", "kind": "maintenance", "node": "vent_filter", "user": "engineer@kst.demo",
             "hours_at": 45000, "comment": "ТО-1: протянуты клеммные соединения, заменён фильтр вентиляции"},
        ],
        "inspections": [],
    },
    "TR-1": {
        "maintenance": [
            {"at": "2026-06-10T10:00", "kind": "maintenance", "node": None, "user": "master@kst.demo", "hours_at": 60000,
             "comment": "Текущий ремонт: очищены изоляторы, заменён силикагель, отобрана проба масла"},
            {"at": "2026-08-20T11:00", "kind": "maintenance", "node": None, "user": "engineer@kst.demo", "hours_at": 61000,
             "comment": "Осмотр: бак, радиаторы и вводы без замечаний, уровень масла в норме"},
        ],
        "inspections": [],
    },
    "N-101": {
        "maintenance": [
            {"at": "2022-06-10T10:30", "kind": "replacement", "node": "seal", "user": "master@kst.demo", "hours_at": 6000,
             "comment": "Ревизия: заменено торцевое уплотнение, проверены вал и рабочее колесо"},
            {"at": "2024-03-05T09:00", "kind": "maintenance", "node": None, "user": "master@kst.demo", "hours_at": 11200,
             "comment": "ТО-2: проверены зазор муфты и уплотнительные кольца, очищены крышка вентилятора и клеммная коробка"},
            {"at": "2025-02-01T11:15", "kind": "replacement", "node": "gauge", "user": "master@kst.demo", "hours_at": 13920,
             "comment": "Установлен поверенный манометр на нагнетании, шкала 0-10 бар"},
            {"at": "2025-07-08T09:20", "kind": "maintenance", "node": None, "user": "master@kst.demo", "hours_at": 15200,
             "comment": "ТО-1: осмотрены уплотнения, проверены нагрев, шум, вибрация и электрические параметры, "
                        "подтянуты фланцы"},
            {"at": "2026-08-25T15:40", "kind": "maintenance", "node": "casing", "user": "engineer@kst.demo", "hours_at": 18560,
             "comment": "Очаг коррозии на корпусе зачищен, покрытие восстановлено"},
        ],
        "inspections": [
            {"started": "2026-08-18T09:10", "finished": "2026-08-18T09:36", "user": "engineer@kst.demo", "findings": [
                {"node": "casing", "source": "camera", "status": "defect", "severity": 1, "confidence": 0.58,
                 "title": "Коррозия на корпусе насоса",
                 "diagnosis": "Поверхностная коррозия корпуса, целостность не нарушена",
                 "recommendation": "Зачистить очаг и восстановить покрытие",
                 "comment": "Очаг около 3 см у нижнего фланца", "state": "resolved",
                 "evidence": [{"source": "camera", "what": "Коррозия на корпусе насоса", "value": "уверенность 0,58",
                               "threshold": "от 0,50", "met": True}]},
                {"node": "motor", "source": "manual", "status": "ok", "title": NO_REMARKS, "state": "resolved"},
            ]},
            {"started": "2026-10-27T14:05", "finished": "2026-10-27T14:31", "user": "engineer@kst.demo", "findings": [
                {"node": "seal", "source": "camera", "status": "check", "severity": 2, "confidence": 0.44, "rule_id": "R01",
                 "title": "Следы влаги у торцевого уплотнения",
                 "diagnosis": "Возможное начало течи торцевого уплотнения - требуется проверка",
                 "recommendation": "Повторно осмотреть зону уплотнения вала, проверить вибрацию и температуру подшипника",
                 "comment": "Капель нет, поверхность влажная", "state": "open",
                 "evidence": [{"source": "camera", "what": "Подтёк у вала", "value": "уверенность 0,44",
                               "threshold": "от 0,25", "met": True}]},
                {"node": "coupling", "source": "manual", "status": "ok", "title": NO_REMARKS, "state": "resolved"},
            ]},
        ],
    },
    "AMS-1": {
        "maintenance": [
            {"at": "2025-12-01T13:00", "kind": "replacement", "node": "seal", "user": "master@kst.demo", "hours_at": 3700,
             "comment": "Заменено торцевое уплотнение"},
            {"at": "2026-09-02T10:10", "kind": "maintenance", "node": "frame", "user": "engineer@kst.demo", "hours_at": 8580,
             "comment": "Затяжка крепежа рамы и анкерных болтов по п. 8.1.1 инструкции"},
        ],
        "inspections": [
            {"started": "2026-10-06T10:20", "finished": "2026-10-06T10:38", "user": "engineer@kst.demo", "findings": [
                {"node": "unit", "source": "manual", "status": "ok", "title": NO_REMARKS, "state": "resolved"},
            ]},
        ],
    },
    "AMS-2": {
        "maintenance": [
            {"at": "2024-08-15T12:00", "kind": "replacement", "node": "seal", "user": "master@kst.demo", "hours_at": 3250,
             "comment": "Заменено торцевое уплотнение"},
        ],
        "inspections": [
            {"started": "2026-09-15T11:00", "finished": "2026-09-15T11:22", "user": "engineer@kst.demo", "findings": [
                {"node": "frame", "source": "camera", "status": "check", "severity": 2, "confidence": 0.61, "rule_id": "R02",
                 "title": "Коррозия рамы у анкерного болта",
                 "diagnosis": "Возможное ослабление крепления к фундаменту - требуется проверка затяжки анкерных болтов",
                 "recommendation": "Проверить затяжку анкерных болтов, зачистить и обработать раму",
                 "comment": "Агрегат остановлен до проверки крепления", "state": "in_work",
                 "evidence": [{"source": "camera", "what": "Коррозия на раме", "value": "уверенность 0,61",
                               "threshold": "от 0,50", "met": True}]},
            ]},
        ],
    },
}


def load_cards() -> list[dict]:
    """Читает карточки оборудования из data/equipment.json; без файла наполнение невозможно."""
    if not config.EQUIPMENT_FILE.is_file():
        raise RuntimeError(f"Не найден файл карточек оборудования: {config.EQUIPMENT_FILE}")
    with open(config.EQUIPMENT_FILE, encoding="utf-8") as file:
        return json.load(file)["equipment"]


@lru_cache
def _demo_hash(email: str) -> str:
    """Хэш демонстрационного пароля для учётной записи; считается один раз за запуск, так как расчёт небыстрый."""
    return hash_password(DEMO_PASSWORD)


def _day(text: str | None) -> date | None:
    """Превращает дату из карточки в значение для базы; пустая дата остаётся пустой."""
    return date.fromisoformat(text) if text else None


def _add_roles(session: Session) -> None:
    """Добавляет недостающие системные роли; уже существующие роли и их права не трогает."""
    for code, (title, description, permissions) in SYSTEM_ROLES.items():
        if session.get(Role, code) is None:
            session.add(Role(code=code, title=title, description=description, is_system=True,
                             permissions=ordered(permissions)))
    session.flush()


def _add_users(session: Session) -> dict[str, User]:
    """Добавляет недостающие демонстрационные учётные записи и возвращает их по почте."""
    users = {}
    for email, name, role in DEMO_USERS:
        user = session.scalar(select(User).where(User.email == email))
        if user is None:
            user = User(email=email, name=name, role=role, password_hash=_demo_hash(email))
            session.add(user)
        users[email] = user
    session.flush()
    return users


def _add_equipment(session: Session, card: dict) -> bool:
    """Добавляет агрегат и его узлы, если их ещё нет; сообщает, был ли агрегат создан этим вызовом.

    У существующих узлов обновляется только перечень классов детектора: соответствие узлов и классов задаётся
    в data/equipment.json и может меняться с новой моделью распознавания, а остальные данные узла не трогаются.
    """
    item = session.get(Equipment, card["id"])
    created = item is None
    if created:
        extra = {key: value for key, value in card.items() if key not in EQUIPMENT_COLUMNS and key != "nodes"}
        item = Equipment(**{key: card[key] for key in EQUIPMENT_COLUMNS}, data=extra)
        session.add(item)
    known = {} if created else {node.code: node for node in item.nodes}
    for entry in card["nodes"]:
        stored = known.get(entry["id"])
        if stored is not None and (stored.data or {}).get("classes") != entry.get("classes", []):
            stored.data = {**(stored.data or {}), "classes": list(entry.get("classes", []))}
        if entry["id"] not in known:
            extra = {key: value for key, value in entry.items() if key not in NODE_COLUMNS}
            session.add(Node(equipment_id=card["id"], code=entry["id"], name=entry["name"], hours=entry["hours"],
                             installed=_day(entry["installed"]), replaced=_day(entry["replaced"]), data=extra))
    return created


def _add_history(session: Session, equipment_id: str, users: dict[str, User]) -> None:
    """Добавляет новому агрегату прошлые работы и осмотры с находками, чтобы история не была пустой."""
    history = DEMO_HISTORY.get(equipment_id, {})
    for record in history.get("maintenance", ()):
        session.add(MaintenanceRecord(equipment_id=equipment_id, node_code=record["node"], kind=record["kind"],
                                      comment=record["comment"], user_id=users[record["user"]].id,
                                      at=datetime.fromisoformat(record["at"]), hours_at=record["hours_at"]))
    for visit in history.get("inspections", ()):
        started, finished = datetime.fromisoformat(visit["started"]), datetime.fromisoformat(visit["finished"])
        statuses = [finding["status"] for finding in visit["findings"]]
        summary = {"findings": len(statuses),
                   "by_status": {status: statuses.count(status) for status in FINDING_STATUSES},
                   "duration_s": int((finished - started).total_seconds())}
        inspection = Inspection(equipment_id=equipment_id, user_id=users[visit["user"]].id, started_at=started,
                                finished_at=finished, status="finished", summary=summary)
        for finding in visit["findings"]:
            inspection.findings.append(Finding(
                equipment_id=equipment_id, node_code=finding["node"], source=finding["source"],
                rule_id=finding.get("rule_id"), status=finding["status"], severity=finding.get("severity"),
                title=finding["title"], diagnosis=finding.get("diagnosis"), recommendation=finding.get("recommendation"),
                confidence=finding.get("confidence"), evidence=finding.get("evidence"), comment=finding.get("comment"),
                state=finding["state"], created_at=finished))
        session.add(inspection)


def seed(session: Session) -> None:
    """Наполняет базу и сохраняет изменения; повторный вызов ничего не дублирует и не перезаписывает
    (кроме перечня классов детектора у узлов - он берётся из карточки)."""
    _add_roles(session)
    get_policy(session)
    users = _add_users(session)
    for card in load_cards():
        if _add_equipment(session, card):
            session.flush()
            _add_history(session, card["id"], users)
    session.commit()
