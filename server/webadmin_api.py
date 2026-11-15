"""Сведения для веб-панели администратора (/webadmin): метрики сервера, модели распознавания, журнал событий
сервера, резервные копии базы и блокировка учётной записи с указанием причины.

Метрики, модели, журнал и копии требуют права «Обслуживание системы»; блокировка с причиной - права
«Управление учётными записями». Описание моделей читается из models/models.json только для показа, файлы
моделей не меняются. Резервная копия - копия базы SQLite штатным механизмом резервного копирования в папку
backups рядом с файлом базы (по умолчанию data/runtime/backups). Сервер не обращается к внешним адресам.
"""
import json
import os
import platform
import shutil
import sqlite3
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Annotated, Any

import cv2
import numpy as np
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session, joinedload

from server import config, fingerprint, recognition, security
from server.admin import _user_response
from server.auth import current_user, require_permission
from server.db import get_session
from server.models import Finding, Inspection, SecurityEvent, SoundRecord, User, now

MODELS_FILE = Path(__file__).resolve().parents[1] / "models" / "models.json"
SYSTEM = require_permission("system.manage")
USERS = require_permission("users.manage")
BACKUP_PREFIX = "kst-"
SEVERITY_LEVEL = {1: "info", 2: "warn", 3: "bad"}
NOTE_EVENTS = {"rejected": ("warn", "Находка отклонена"), "state": ("info", "Состояние замечания изменено"),
               "comment": ("info", "Комментарий к замечанию")}
MODEL_FIELDS = ("file", "role", "family", "classes", "defect_classes", "imgsz", "conf_check", "conf_defect", "size_mb",
                "weights_licence", "code_licence", "trained_from", "data", "measured", "thresholds", "every_n")

router = APIRouter(prefix="/webadmin", tags=["webadmin"], dependencies=[Depends(current_user)])


class BlockBody(BaseModel):
    """Блокировка учётной записи: причина обязательна, комментарий - по желанию."""

    reason: str = Field(min_length=1, max_length=120)
    comment: str | None = Field(default=None, max_length=500)


def _stamp(moment: datetime | None) -> str | None:
    """Время в виде ISO с точностью до секунды."""
    return moment.isoformat(timespec="seconds") if moment else None


def _memory_total() -> int | None:
    """Объём оперативной памяти компьютера в байтах или None, если система его не сообщает."""
    try:
        return int(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES"))
    except (AttributeError, ValueError, OSError):
        return None


def _process_peak_memory() -> int | None:
    """Наибольший объём памяти, занятый процессом сервера, в байтах."""
    try:
        import resource
    except ImportError:
        return None
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(peak if sys.platform == "darwin" else peak * 1024)


def _load() -> dict:
    """Средняя загрузка процессора за 1, 5 и 15 минут и её доля от числа ядер в процентах."""
    cores = os.cpu_count() or 1
    try:
        one, five, fifteen = os.getloadavg()
    except (AttributeError, OSError):
        return {"cores": cores, "load_1": None, "load_5": None, "load_15": None, "percent": None}
    return {"cores": cores, "load_1": round(one, 2), "load_5": round(five, 2), "load_15": round(fifteen, 2),
            "percent": round(min(100.0, one / cores * 100), 1)}


@router.get("/metrics", dependencies=[Depends(SYSTEM)])
def metrics(request: Request) -> dict:
    """Метрики сервера: загрузка процессора, память, диск под базой, размер базы, время работы и версия Python."""
    path = config.db_path()
    started = getattr(request.app.state, "started_at", None)
    folder = os.path.dirname(os.path.abspath(path)) or "."
    try:
        usage = shutil.disk_usage(folder)
        disk = {"total_bytes": usage.total, "used_bytes": usage.used, "free_bytes": usage.free}
    except OSError:
        disk = None
    return {"time": _stamp(now()), "started_at": _stamp(started),
            "uptime_s": int((now() - started).total_seconds()) if started else None,
            "cpu": _load(), "memory": {"total_bytes": _memory_total(), "process_peak_bytes": _process_peak_memory()},
            "disk": disk, "database": {"file": os.path.basename(path),
                                       "size_bytes": os.path.getsize(path) if os.path.exists(path) else None},
            "host": platform.node(), "platform": f"{platform.system()} {platform.release()}",
            "python": platform.python_version(), "pid": os.getpid()}


def _manifest() -> list[dict]:
    """Описание моделей из models/models.json; без файла - пустой список."""
    try:
        document = json.loads(MODELS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    entries = document.get("models", []) if isinstance(document, dict) else document
    return [entry for entry in entries if isinstance(entry, dict) and entry.get("file")]


@router.get("/models", dependencies=[Depends(SYSTEM)])
def models(request: Request) -> dict:
    """Модели распознавания: файлы, лицензии, пороги, классы, метрики проверки и состояние загрузки."""
    detector = getattr(request.app.state, "detector", None)
    info = getattr(detector, "info", None)
    state = info() if callable(info) else None
    loaded = set((state or {}).get("models") or []) if (state or {}).get("loaded") else set()
    items = []
    for entry in _manifest():
        path = MODELS_FILE.parent / entry["file"]
        view = {key: entry[key] for key in MODEL_FIELDS if key in entry}
        view.update(present=path.is_file(), size_bytes=path.stat().st_size if path.is_file() else None,
                    loaded=entry["file"] in loaded)
        items.append(view)
    return {"manifest": MODELS_FILE.name, "detector": state, "models": items, "fingerprint": fingerprint.current()}


def _test_frame() -> bytes:
    """Кадр для замера: серое поле 640 x 480 в формате JPEG."""
    frame = np.full((480, 640, 3), 128, dtype=np.uint8)
    ok, encoded = cv2.imencode(".jpg", frame)
    if not ok:
        raise HTTPException(status_code=500, detail="Не удалось подготовить кадр для замера")
    return encoded.tobytes()


@router.post("/models/benchmark", dependencies=[Depends(SYSTEM)])
async def benchmark(request: Request) -> dict:
    """Замер времени распознавания: один кадр через все загруженные модели; возвращает миллисекунды на кадр."""
    detector = getattr(request.app.state, "detector", None)
    data = _test_frame()
    started = time.perf_counter()
    try:
        found = await run_in_threadpool(recognition.detect_frame, detector, data)
    except recognition.DetectorUnavailable as error:
        raise HTTPException(status_code=503, detail=str(error)) from None
    total = round((time.perf_counter() - started) * 1000, 1)
    return {"ms": found.get("ms"), "total_ms": total, "boxes": len(found.get("boxes") or []),
            "w": found.get("w"), "h": found.get("h"), "at": _stamp(now())}


@router.get("/events", dependencies=[Depends(SYSTEM)])
def events(request: Request, session: Annotated[Session, Depends(get_session)],
           limit: Annotated[int, Query(ge=1, le=500)] = 100) -> list[dict]:
    """Журнал событий сервера, сначала новые: запуск, осмотры, находки, решения по ним и записи звука."""
    rows = []
    started = getattr(request.app.state, "started_at", None)
    if started:
        rows.append({"at": started, "level": "info", "kind": "server", "title": "Сервер запущен",
                     "text": f"База {os.path.basename(config.db_path())}"})
    inspections = session.scalars(select(Inspection).options(joinedload(Inspection.user))
                                  .order_by(Inspection.started_at.desc()).limit(limit))
    item: Any
    for item in inspections:
        who = item.user.name if item.user else "сотрудник"
        rows.append({"at": item.started_at, "level": "info", "kind": "inspection",
                     "title": f"Начат осмотр № {item.id} · {item.equipment_id}", "text": who})
        if item.finished_at:
            rows.append({"at": item.finished_at, "level": "ok", "kind": "inspection",
                         "title": f"Завершён осмотр № {item.id} · {item.equipment_id}", "text": who})
    findings = session.scalars(select(Finding).order_by(Finding.created_at.desc()).limit(limit))
    for item in findings:
        rows.append({"at": item.created_at, "level": SEVERITY_LEVEL.get(item.severity or 1, "info"), "kind": "finding",
                     "title": f"Находка № {item.id} · {item.equipment_id}", "text": item.title})
    noted = session.scalars(select(Finding).where(Finding.notes.is_not(None)).order_by(Finding.id.desc()).limit(limit))
    for item in noted:
        for note in item.notes or []:
            level, title = NOTE_EVENTS.get(note.get("kind"), NOTE_EVENTS["comment"])
            if note.get("at"):
                rows.append({"at": datetime.fromisoformat(note["at"]), "level": level, "kind": "finding",
                             "title": f"{title} · № {item.id} · {item.equipment_id}",
                             "text": f"{note.get('user_name') or 'сотрудник'}: {note.get('text') or ''}"})
    sounds = session.scalars(select(SoundRecord).options(joinedload(SoundRecord.user))
                             .order_by(SoundRecord.created_at.desc()).limit(limit))
    for item in sounds:
        found = len((item.summary or {}).get("candidates") or [])
        rows.append({"at": item.created_at, "level": "warn" if found else "info", "kind": "sound",
                     "title": f"Запись звука · осмотр № {item.inspection_id} · {item.equipment_id}",
                     "text": f"{item.user.name if item.user else 'сотрудник'}: уровень {(item.summary or {}).get('level_dbfs')} дБ, "
                             f"признаков-кандидатов: {found}"})
    rows.sort(key=lambda row: row["at"], reverse=True)
    return [{**row, "at": _stamp(row["at"])} for row in rows[:limit]]


def _backup_dir() -> Path:
    """Папка резервных копий рядом с файлом базы."""
    return Path(config.db_path()).resolve().parent / "backups"


def _backup_view(path: Path) -> dict:
    """Описание файла резервной копии: имя, размер и время создания."""
    stat = path.stat()
    return {"file": path.name, "size_bytes": stat.st_size,
            "created_at": datetime.fromtimestamp(stat.st_mtime).isoformat(timespec="seconds")}


@router.get("/backups", dependencies=[Depends(SYSTEM)])
def list_backups() -> dict:
    """Резервные копии базы, сначала свежие."""
    folder = _backup_dir()
    files = sorted(folder.glob(f"{BACKUP_PREFIX}*.db"), key=lambda path: path.stat().st_mtime, reverse=True) \
        if folder.is_dir() else []
    return {"folder": str(folder), "backups": [_backup_view(path) for path in files]}


@router.post("/backups", status_code=201, dependencies=[Depends(SYSTEM)])
def create_backup() -> dict:
    """Создаёт резервную копию базы SQLite штатным механизмом копирования без остановки сервера."""
    source = Path(config.db_path())
    if not source.is_file():
        raise HTTPException(status_code=503, detail="Файл базы данных не найден")
    folder = _backup_dir()
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / f"{BACKUP_PREFIX}{now():%Y%m%d-%H%M%S}.db"
    suffix = 1
    while target.exists():
        target = folder / f"{BACKUP_PREFIX}{now():%Y%m%d-%H%M%S}-{suffix}.db"
        suffix += 1
    with sqlite3.connect(str(source)) as origin, sqlite3.connect(str(target)) as copy:
        origin.backup(copy)
    return _backup_view(target)


def _ip(request: Request) -> str:
    """Адрес устройства, с которого пришёл запрос."""
    return request.client.host if request.client else ""


@router.post("/users/{user_id}/block")
def block_with_reason(user_id: int, body: BlockBody, request: Request, actor: Annotated[User, Depends(USERS)],
                      session: Annotated[Session, Depends(get_session)]) -> dict:
    """Блокирует учётную запись с причиной: закрывает все сеансы и пишет причину в журнал безопасности."""
    user = session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="Учётная запись не найдена")
    if user.id == actor.id:
        raise HTTPException(status_code=409, detail="Нельзя заблокировать собственную учётную запись")
    if not user.is_active:
        return _user_response(session, user)
    user.is_active = False
    security.ensure_guardians(session)
    closed = security.revoke_sessions(session, user.id)
    details = {"sessions_closed": closed, "reason": body.reason.strip()}
    if body.comment and body.comment.strip():
        details["comment"] = body.comment.strip()
    security.record(session, "user_blocked", actor=actor, target_user=user, ip=_ip(request), details=details)
    session.commit()
    return _user_response(session, user)


@router.get("/users/{user_id}/block", dependencies=[Depends(USERS)])
def block_reason(user_id: int, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Последняя блокировка учётной записи: когда, кто и по какой причине; без блокировки - пустые поля."""
    row = session.scalar(select(SecurityEvent).options(joinedload(SecurityEvent.actor))
                         .where(SecurityEvent.target_user_id == user_id, SecurityEvent.event == "user_blocked")
                         .order_by(SecurityEvent.at.desc(), SecurityEvent.id.desc()).limit(1))
    if row is None:
        return {"at": None, "actor": None, "reason": None, "comment": None}
    details = row.details or {}
    return {"at": _stamp(row.at), "actor": row.actor.name if row.actor else None,
            "reason": details.get("reason"), "comment": details.get("comment")}
