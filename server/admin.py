"""Администрирование: учётные записи, роли, журнал и политика безопасности (/admin), состояние системы (/system).

Раздел /admin ведёт администратор ИБ: каждый маршрут требует своего права - «Управление учётными записями»,
«Управление ролями», «Журнал безопасности» или «Политика безопасности». Все изменения пишутся в журнал
безопасности. Изменение, после которого не осталось бы ни одной активной учётной записи с правами управления
учётными записями и ролями, отклоняется. Временный пароль возвращается только в ответе на создание
учётной записи или сброс пароля и больше нигде не хранится в открытом виде.

Раздел /system - для администратора системы (право «Обслуживание системы»): состояние базы, моделей и телеметрии.
"""

import os
import re
from datetime import datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import case, func, or_, select
from sqlalchemy.orm import Session, joinedload

from server import config, security, telemetry_api
from server.auth import current_user, hash_password, require_permission
from server.db import get_session
from server.models import Equipment, RefreshToken, Role, SecurityEvent, User, now
from server.permissions import catalogue, ordered, unknown
from server.security import EVENT_TITLES

EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
ROLE_CODE = r"^[a-z][a-z0-9_]{1,31}$"
STATUS_TITLES = {"active": "Активна", "blocked": "Заблокирована"}

router = APIRouter(prefix="/admin", tags=["admin"], dependencies=[Depends(current_user)])
system_router = APIRouter(prefix="/system", tags=["system"], dependencies=[Depends(current_user)])
USERS = require_permission("users.manage")
ROLES = require_permission("roles.manage")
ROLES_READ = require_permission("users.manage", "roles.manage", any_of=True)
ACTIVE = case((User.is_active.is_(True), 1), else_=0)


class UserCreateBody(BaseModel):
    """Новая учётная запись: почта, имя и код роли."""

    email: str = Field(min_length=3, max_length=254)
    name: str = Field(min_length=1, max_length=120)
    role: str = Field(min_length=1, max_length=32)


class RoleAssignBody(BaseModel):
    """Смена роли сотрудника."""

    role: str = Field(min_length=1, max_length=32)


class RoleCreateBody(BaseModel):
    """Новая роль: код латиницей, название, описание, права; copy_from - взять права другой роли."""

    code: str = Field(pattern=ROLE_CODE)
    title: str = Field(min_length=1, max_length=80)
    description: str | None = Field(default=None, max_length=500)
    permissions: list[str] | None = Field(default=None, max_length=100)
    copy_from: str | None = Field(default=None, max_length=32)


class RoleUpdateBody(BaseModel):
    """Правка роли: переданные поля заменяются, остальные остаются прежними."""

    title: str | None = Field(default=None, min_length=1, max_length=80)
    description: str | None = Field(default=None, max_length=500)
    permissions: list[str] | None = Field(default=None, max_length=100)


class PolicyBody(BaseModel):
    """Правка политики безопасности: переданные поля заменяются, остальные остаются прежними."""

    min_password_length: int | None = Field(default=None, ge=6, le=128)
    require_letters_digits: bool | None = None
    lockout_attempts: int | None = Field(default=None, ge=3, le=100)
    lockout_minutes: int | None = Field(default=None, ge=1, le=1440)
    session_hours: int | None = Field(default=None, ge=1, le=8760)
    biometrics_allowed: bool | None = None


def _stamp(moment: datetime | None) -> str | None:
    """Записывает время в виде ISO с точностью до секунды; отсутствующее время остаётся пустым."""
    return moment.isoformat(timespec="seconds") if moment else None


def _fold(text: str) -> str:
    """Приводит строку к виду для поиска: без регистра, буква ё как е."""
    return text.casefold().replace("ё", "е")


def _ip(request: Request) -> str:
    """Адрес устройства, с которого пришёл запрос."""
    return request.client.host if request.client else ""


def _active_sessions(session: Session, user_ids: list[int]) -> dict[int, int]:
    """Число открытых сеансов по каждому сотруднику."""
    if not user_ids:
        return {}
    rows = session.execute(
        select(RefreshToken.user_id, func.count(func.distinct(RefreshToken.family)))
        .where(RefreshToken.user_id.in_(user_ids), RefreshToken.revoked.is_(False))
        .group_by(RefreshToken.user_id)
    )
    return dict(rows.all())


def user_admin_view(user: User, sessions: int = 0) -> dict:
    """Описывает учётную запись для администратора ИБ: роль, состояние, временный пароль, сеансы; без хэша."""
    status = "active" if user.is_active else "blocked"
    return {
        "id": user.id,
        "email": user.email,
        "name": user.name,
        "role": user.role,
        "role_title": user.role_info.title if user.role_info else user.role,
        "is_active": user.is_active,
        "status": status,
        "status_title": STATUS_TITLES[status],
        "must_change_password": user.must_change_password,
        "created_at": _stamp(user.created_at),
        "last_login_at": _stamp(user.last_login_at),
        "password_changed_at": _stamp(user.password_changed_at),
        "active_sessions": sessions,
    }


def _user_response(session: Session, user: User) -> dict:
    """Учётная запись с числом открытых сеансов."""
    return user_admin_view(user, _active_sessions(session, [user.id]).get(user.id, 0))


def _get_user(session: Session, user_id: int) -> User:
    """Учётная запись по номеру или ответ 404."""
    user = session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="Учётная запись не найдена")
    return user


def _get_role(session: Session, code: str, status: int = 404) -> Role:
    """Роль по коду или отказ с указанным кодом ответа."""
    role = session.get(Role, code)
    if role is None:
        raise HTTPException(status_code=status, detail=f"Роль «{code}» не найдена")
    return role


def role_view(role: Role, members: int = 0, active: int = 0) -> dict:
    """Описывает роль: название, описание, права с названиями, число сотрудников с этой ролью."""
    return {
        "code": role.code,
        "title": role.title,
        "description": role.description or "",
        "is_system": role.is_system,
        "permissions": ordered(role.permissions),
        "members": members,
        "active_members": active,
        "created_at": _stamp(role.created_at),
        "updated_at": _stamp(role.updated_at),
    }


def _members(session: Session) -> dict[str, tuple[int, int]]:
    """Число сотрудников по каждой роли: всего и активных."""
    rows = session.execute(select(User.role, func.count(), func.sum(ACTIVE)).group_by(User.role))
    return {code: (total, int(active or 0)) for code, total, active in rows.all()}


def _role_response(session: Session, role: Role) -> dict:
    """Роль вместе с числом сотрудников."""
    total, active = _members(session).get(role.code, (0, 0))
    return role_view(role, total, active)


def _checked_permissions(codes: list[str]) -> list[str]:
    """Проверяет коды прав по перечню; неизвестный код - ответ 422."""
    wrong = unknown(codes)
    if wrong:
        raise HTTPException(status_code=422, detail=f"Неизвестные права: {', '.join(wrong)}")
    return ordered(codes)


@router.get("/permissions", dependencies=[Depends(ROLES_READ)])
def permissions_catalogue() -> list[dict]:
    """Перечень прав по группам с русскими названиями и пояснениями."""
    return catalogue()


@router.get("/users", dependencies=[Depends(USERS)])
def list_users(
    session: Annotated[Session, Depends(get_session)],
    q: Annotated[str | None, Query(max_length=100)] = None,
    role: Annotated[str | None, Query(max_length=32)] = None,
    status: Annotated[Literal["active", "blocked"] | None, Query()] = None,
) -> list[dict]:
    """Учётные записи по алфавиту имён: поиск по имени и почте, отбор по роли и состоянию."""
    query = select(User).order_by(User.name, User.id)
    if role:
        query = query.where(User.role == role)
    if status:
        query = query.where(User.is_active.is_(status == "active"))
    words = _fold(q or "").split()
    users = [user for user in session.scalars(query) if all(word in _fold(f"{user.name} {user.email}") for word in words)]
    sessions = _active_sessions(session, [user.id for user in users])
    return [user_admin_view(user, sessions.get(user.id, 0)) for user in users]


@router.get("/users/{user_id}", dependencies=[Depends(USERS)])
def get_user(user_id: int, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Одна учётная запись."""
    return _user_response(session, _get_user(session, user_id))


@router.post("/users", status_code=201)
def create_user(
    body: UserCreateBody,
    request: Request,
    actor: Annotated[User, Depends(USERS)],
    session: Annotated[Session, Depends(get_session)],
) -> dict:
    """Заводит учётную запись с временным паролем; пароль возвращается один раз, при входе его нужно сменить."""
    email = body.email.strip().lower()
    name = " ".join(body.name.split())
    if not EMAIL.match(email):
        raise HTTPException(status_code=422, detail="Почта указана неверно")
    if not name:
        raise HTTPException(status_code=422, detail="Укажите имя сотрудника")
    role = _get_role(session, body.role.strip(), status=422)
    if session.scalar(select(User.id).where(User.email == email)) is not None:
        raise HTTPException(status_code=409, detail="Учётная запись с такой почтой уже есть")
    password = security.temporary_password(security.get_policy(session))
    user = User(
        email=email,
        name=name,
        role=role.code,
        password_hash=hash_password(password),
        is_active=True,
        must_change_password=True,
        created_at=now(),
    )
    session.add(user)
    session.flush()
    security.record(
        session,
        "user_created",
        actor=actor,
        target_user=user,
        target_role=role.code,
        ip=_ip(request),
        details={"email": email, "role": role.code},
    )
    session.commit()
    return {"user": _user_response(session, user), "temporary_password": password}


@router.post("/users/{user_id}/role")
def change_role(
    user_id: int,
    body: RoleAssignBody,
    request: Request,
    actor: Annotated[User, Depends(USERS)],
    session: Annotated[Session, Depends(get_session)],
) -> dict:
    """Меняет роль сотрудника; новые права действуют с его следующего запроса."""
    user = _get_user(session, user_id)
    role = _get_role(session, body.role.strip(), status=422)
    previous = user.role
    if previous == role.code:
        return _user_response(session, user)
    user.role = role.code
    security.ensure_guardians(session)
    security.record(
        session,
        "user_role_changed",
        actor=actor,
        target_user=user,
        target_role=role.code,
        ip=_ip(request),
        details={"from": previous, "to": role.code},
    )
    session.commit()
    session.refresh(user)
    return _user_response(session, user)


@router.post("/users/{user_id}/block")
def block_user(
    user_id: int, request: Request, actor: Annotated[User, Depends(USERS)], session: Annotated[Session, Depends(get_session)]
) -> dict:
    """Блокирует учётную запись и сразу закрывает все её сеансы."""
    user = _get_user(session, user_id)
    if user.id == actor.id:
        raise HTTPException(status_code=409, detail="Нельзя заблокировать собственную учётную запись")
    if not user.is_active:
        return _user_response(session, user)
    user.is_active = False
    security.ensure_guardians(session)
    closed = security.revoke_sessions(session, user.id)
    security.record(session, "user_blocked", actor=actor, target_user=user, ip=_ip(request), details={"sessions_closed": closed})
    session.commit()
    return _user_response(session, user)


@router.post("/users/{user_id}/unblock")
def unblock_user(
    user_id: int, request: Request, actor: Annotated[User, Depends(USERS)], session: Annotated[Session, Depends(get_session)]
) -> dict:
    """Снимает блокировку учётной записи."""
    user = _get_user(session, user_id)
    if not user.is_active:
        user.is_active = True
        security.record(session, "user_unblocked", actor=actor, target_user=user, ip=_ip(request))
        session.commit()
    return _user_response(session, user)


@router.post("/users/{user_id}/reset-password")
def reset_password(
    user_id: int, request: Request, actor: Annotated[User, Depends(USERS)], session: Annotated[Session, Depends(get_session)]
) -> dict:
    """Выдаёт новый временный пароль (возвращается один раз) и закрывает все сеансы сотрудника."""
    user = _get_user(session, user_id)
    password = security.temporary_password(security.get_policy(session))
    user.password_hash = hash_password(password)
    user.must_change_password = True
    closed = security.revoke_sessions(session, user.id)
    security.record(
        session, "password_reset", actor=actor, target_user=user, ip=_ip(request), details={"sessions_closed": closed}
    )
    session.commit()
    return {"user": _user_response(session, user), "temporary_password": password}


@router.get("/users/{user_id}/sessions", dependencies=[Depends(USERS)])
def user_sessions(user_id: int, session: Annotated[Session, Depends(get_session)]) -> list[dict]:
    """Открытые сеансы сотрудника: устройство, начало сеанса и последнее обновление токена, сначала свежие."""
    user = _get_user(session, user_id)
    tokens = session.scalars(select(RefreshToken).where(RefreshToken.user_id == user.id).order_by(RefreshToken.id))
    families: dict[str, dict] = {}
    for token in tokens:
        entry = families.setdefault(
            token.family,
            {
                "id": token.family,
                "device": token.device,
                "started_at": token.created_at,
                "last_seen_at": token.created_at,
                "active": False,
            },
        )
        entry["last_seen_at"] = max(entry["last_seen_at"], token.created_at)
        entry["device"] = token.device or entry["device"]
        entry["active"] = entry["active"] or not token.revoked
    alive = sorted(
        (entry for entry in families.values() if entry["active"]), key=lambda entry: entry["last_seen_at"], reverse=True
    )
    return [
        {**entry, "started_at": _stamp(entry["started_at"]), "last_seen_at": _stamp(entry["last_seen_at"])} for entry in alive
    ]


@router.delete("/users/{user_id}/sessions/{family}")
def revoke_session(
    user_id: int,
    family: str,
    request: Request,
    actor: Annotated[User, Depends(USERS)],
    session: Annotated[Session, Depends(get_session)],
) -> dict:
    """Закрывает один сеанс сотрудника."""
    user = _get_user(session, user_id)
    closed = security.revoke_sessions(session, user.id, family=family)
    if not closed:
        raise HTTPException(status_code=404, detail="Открытый сеанс не найден")
    security.record(session, "sessions_revoked", actor=actor, target_user=user, ip=_ip(request), details={"session": family})
    session.commit()
    return {"revoked": 1}


@router.delete("/users/{user_id}/sessions")
def revoke_all_sessions(
    user_id: int, request: Request, actor: Annotated[User, Depends(USERS)], session: Annotated[Session, Depends(get_session)]
) -> dict:
    """Закрывает все сеансы сотрудника; возвращает число закрытых сеансов."""
    user = _get_user(session, user_id)
    families = session.scalar(
        select(func.count(func.distinct(RefreshToken.family))).where(
            RefreshToken.user_id == user.id, RefreshToken.revoked.is_(False)
        )
    )
    security.revoke_sessions(session, user.id)
    security.record(session, "sessions_revoked", actor=actor, target_user=user, ip=_ip(request), details={"sessions": families})
    session.commit()
    return {"revoked": families}


@router.get("/roles", dependencies=[Depends(ROLES_READ)])
def list_roles(session: Annotated[Session, Depends(get_session)]) -> list[dict]:
    """Роли: сначала системные, затем созданные администратором ИБ, с числом сотрудников."""
    members = _members(session)
    roles = sorted(session.scalars(select(Role)), key=lambda role: (not role.is_system, role.title))
    return [role_view(role, *members.get(role.code, (0, 0))) for role in roles]


@router.get("/roles/{code}", dependencies=[Depends(ROLES_READ)])
def get_role(code: str, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Одна роль."""
    return _role_response(session, _get_role(session, code))


@router.post("/roles", status_code=201)
def create_role(
    body: RoleCreateBody,
    request: Request,
    actor: Annotated[User, Depends(ROLES)],
    session: Annotated[Session, Depends(get_session)],
) -> dict:
    """Создаёт роль; права берутся из permissions, а без них - из роли copy_from."""
    if session.get(Role, body.code) is not None:
        raise HTTPException(status_code=409, detail=f"Роль с кодом «{body.code}» уже есть")
    source = _get_role(session, body.copy_from) if body.copy_from else None
    if body.permissions is not None:
        granted = _checked_permissions(body.permissions)
    else:
        granted = ordered(source.permissions) if source else []
    description = body.description if body.description is not None else (source.description if source else "")
    moment = now()
    role = Role(
        code=body.code,
        title=body.title.strip(),
        description=(description or "").strip(),
        is_system=False,
        permissions=granted,
        created_at=moment,
        updated_at=moment,
    )
    session.add(role)
    security.record(
        session,
        "role_created",
        actor=actor,
        target_role=role.code,
        ip=_ip(request),
        details={"title": role.title, "permissions": granted, "copy_from": body.copy_from},
    )
    session.commit()
    return _role_response(session, role)


@router.patch("/roles/{code}")
def update_role(
    code: str,
    body: RoleUpdateBody,
    request: Request,
    actor: Annotated[User, Depends(ROLES)],
    session: Annotated[Session, Depends(get_session)],
) -> dict:
    """Меняет название, описание или права роли, в том числе системной; права действуют сразу."""
    role = _get_role(session, code)
    changes = {}
    if body.title is not None and body.title.strip() != role.title:
        changes["title"] = [role.title, body.title.strip()]
        role.title = body.title.strip()
    if body.description is not None and body.description.strip() != (role.description or ""):
        changes["description"] = [role.description, body.description.strip()]
        role.description = body.description.strip()
    if body.permissions is not None:
        wanted = _checked_permissions(body.permissions)
        before = set(role.permissions or ())
        added, removed = ordered(set(wanted) - before), ordered(before - set(wanted))
        if added or removed:
            changes["added"], changes["removed"] = added, removed
            role.permissions = wanted
    if not changes:
        return _role_response(session, role)
    role.updated_at = now()
    if "removed" in changes:
        security.ensure_guardians(session)
    security.record(session, "role_updated", actor=actor, target_role=code, ip=_ip(request), details=changes)
    session.commit()
    return _role_response(session, _get_role(session, code))


@router.delete("/roles/{code}", status_code=204)
def delete_role(
    code: str, request: Request, actor: Annotated[User, Depends(ROLES)], session: Annotated[Session, Depends(get_session)]
) -> Response:
    """Удаляет роль, созданную администратором ИБ, если она никому не назначена; системные роли не удаляются."""
    role = _get_role(session, code)
    if role.is_system:
        raise HTTPException(status_code=409, detail="Системную роль удалить нельзя")
    members = session.scalar(select(func.count()).select_from(User).where(User.role == code))
    if members:
        raise HTTPException(status_code=409, detail=f"Роль назначена сотрудникам ({members}) - сначала смените им роль")
    security.record(
        session,
        "role_deleted",
        actor=actor,
        target_role=code,
        ip=_ip(request),
        details={"title": role.title, "permissions": ordered(role.permissions)},
    )
    session.delete(role)
    session.commit()
    return Response(status_code=204)


def _person(user: User | None) -> dict | None:
    """Сотрудник в записи журнала: номер, имя и почта."""
    return None if user is None else {"id": user.id, "name": user.name, "email": user.email}


@router.get("/security-log/events", dependencies=[Depends(require_permission("security.log"))])
def log_events() -> list[dict]:
    """Виды событий журнала безопасности с русскими названиями."""
    return [{"code": code, "title": title} for code, title in EVENT_TITLES.items()]


@router.get("/security-log", dependencies=[Depends(require_permission("security.log"))])
def security_log(
    session: Annotated[Session, Depends(get_session)],
    event: Annotated[str | None, Query(max_length=32)] = None,
    user_id: Annotated[int | None, Query(ge=1)] = None,
    since: Annotated[datetime | None, Query()] = None,
    until: Annotated[datetime | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 200,
) -> list[dict]:
    """Журнал безопасности, сначала новые записи; user_id отбирает записи, где сотрудник действовал или был целью."""
    if event and event not in EVENT_TITLES:
        raise HTTPException(status_code=422, detail=f"Неизвестный вид события: {event}")
    query = select(SecurityEvent).options(joinedload(SecurityEvent.actor), joinedload(SecurityEvent.target_user))
    if event:
        query = query.where(SecurityEvent.event == event)
    if user_id:
        query = query.where(or_(SecurityEvent.actor_id == user_id, SecurityEvent.target_user_id == user_id))
    if since:
        query = query.where(SecurityEvent.at >= since)
    if until:
        query = query.where(SecurityEvent.at <= until)
    rows = session.scalars(query.order_by(SecurityEvent.at.desc(), SecurityEvent.id.desc()).limit(limit))
    return [
        {
            "id": row.id,
            "at": _stamp(row.at),
            "event": row.event,
            "title": EVENT_TITLES.get(row.event, row.event),
            "actor": _person(row.actor),
            "target_user": _person(row.target_user),
            "target_role": row.target_role,
            "email": row.email,
            "ip": row.ip,
            "details": row.details or {},
        }
        for row in rows
    ]


@router.get("/policy", dependencies=[Depends(require_permission("security.policy"))])
def get_policy(session: Annotated[Session, Depends(get_session)]) -> dict:
    """Политика безопасности: длина и состав пароля, блокировка входа, срок сеанса, вход по биометрии."""
    view = security.policy_view(security.get_policy(session))
    session.commit()
    return view


@router.patch("/policy")
def update_policy(
    body: PolicyBody,
    request: Request,
    actor: Annotated[User, Depends(require_permission("security.policy"))],
    session: Annotated[Session, Depends(get_session)],
) -> dict:
    """Меняет переданные поля политики; новые значения действуют с ближайшего входа или смены пароля."""
    policy = security.get_policy(session)
    changes = {}
    for field, value in body.model_dump(exclude_none=True).items():
        if getattr(policy, field) != value:
            changes[field] = [getattr(policy, field), value]
            setattr(policy, field, value)
    if changes:
        policy.updated_at, policy.updated_by_id = now(), actor.id
        security.record(session, "policy_changed", actor=actor, ip=_ip(request), details=changes)
    session.commit()
    return security.policy_view(policy)


@system_router.get("/status", dependencies=[Depends(require_permission("system.manage"))])
def system_status(request: Request, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Состояние системы для администратора: время работы, база данных, модели распознавания, телеметрия, сеансы."""
    path = config.db_path()
    started = getattr(request.app.state, "started_at", None)
    detector = getattr(request.app.state, "detector", None)
    info = getattr(detector, "info", None)
    telemetry = []
    for item in session.scalars(select(Equipment).order_by(Equipment.id)):
        if item.data.get("telemetry"):
            player, reason = telemetry_api.find_player(item.id)
            telemetry.append({"equipment_id": item.id, "available": player is not None, "reason": reason})
    users = session.execute(select(func.count(), func.sum(ACTIVE)).select_from(User)).one()
    sessions = session.scalar(select(func.count(func.distinct(RefreshToken.family))).where(RefreshToken.revoked.is_(False)))
    return {
        "time": _stamp(now()),
        "started_at": _stamp(started),
        "uptime_s": int((now() - started).total_seconds()) if started else None,
        "database": {
            "file": os.path.basename(path),
            "size_bytes": os.path.getsize(path) if os.path.exists(path) else None,
            "equipment": session.scalar(select(func.count()).select_from(Equipment)),
        },
        "detector": info() if callable(info) else None,
        "telemetry": telemetry,
        "users": {"total": users[0], "active": int(users[1] or 0)},
        "open_sessions": sessions,
    }
