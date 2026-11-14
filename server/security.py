"""Безопасность учётных записей: политика, журнал событий, требования к паролю и защита от потери управления.

Политика хранится в базе одной строкой и читается при каждом входе, поэтому изменение действует сразу.
Журнал пишется в ту же транзакцию, что и само действие: запись появляется только вместе с изменением.
"""
import secrets
import string

from fastapi import HTTPException
from sqlalchemy import func, select, update
from sqlalchemy.orm import Session

from server.models import RefreshToken, Role, SecurityEvent, SecurityPolicy, User, now
from server.permissions import GUARDIAN_PERMISSIONS

POLICY_ID = 1
POLICY_FIELDS = ("min_password_length", "require_letters_digits", "lockout_attempts", "lockout_minutes",
                 "session_hours", "biometrics_allowed")
TEMPORARY_ALPHABET = "".join(symbol for symbol in string.ascii_letters + string.digits if symbol not in "0O1lI")
TEMPORARY_MIN_LENGTH = 12
LOCKOUT_GUARD = ("Изменение отклонено: не останется ни одной активной учётной записи с правами управления "
                 "учётными записями и ролями")
EVENT_TITLES = {
    "login_success": "Успешный вход",
    "login_failure": "Неудачная попытка входа",
    "login_locked": "Вход временно закрыт после неудачных попыток",
    "login_blocked": "Попытка входа заблокированной учётной записи",
    "password_changed": "Смена пароля",
    "password_change_failed": "Неудачная попытка смены пароля",
    "password_reset": "Выдан временный пароль",
    "user_created": "Создана учётная запись",
    "user_blocked": "Учётная запись заблокирована",
    "user_unblocked": "Учётная запись разблокирована",
    "user_role_changed": "Изменена роль сотрудника",
    "sessions_revoked": "Закрыты сеансы",
    "role_created": "Создана роль",
    "role_updated": "Изменена роль",
    "role_deleted": "Удалена роль",
    "policy_changed": "Изменена политика безопасности",
}


def get_policy(session: Session) -> SecurityPolicy:
    """Возвращает политику безопасности; если строки ещё нет, создаёт её со значениями по умолчанию."""
    policy = session.get(SecurityPolicy, POLICY_ID)
    if policy is None:
        policy = SecurityPolicy(id=POLICY_ID)
        session.add(policy)
        session.flush()
    return policy


def policy_view(policy: SecurityPolicy) -> dict:
    """Описывает политику для ответа сервера."""
    view = {field: getattr(policy, field) for field in POLICY_FIELDS}
    view["updated_at"] = policy.updated_at.isoformat(timespec="seconds") if policy.updated_at else None
    view["updated_by_id"] = policy.updated_by_id
    return view


def password_problems(policy: SecurityPolicy, password: str) -> list[str]:
    """Перечисляет, чем пароль не удовлетворяет политике; пустой список - пароль подходит."""
    problems = []
    if len(password) < policy.min_password_length:
        problems.append(f"Пароль должен быть не короче {policy.min_password_length} символов")
    if policy.require_letters_digits and not (any(ch.isalpha() for ch in password) and any(ch.isdigit() for ch in password)):
        problems.append("Пароль должен содержать и буквы, и цифры")
    if password != password.strip():
        problems.append("Пароль не должен начинаться или заканчиваться пробелом")
    return problems


def temporary_password(policy: SecurityPolicy) -> str:
    """Создаёт случайный временный пароль, который заведомо удовлетворяет политике."""
    length = max(TEMPORARY_MIN_LENGTH, policy.min_password_length)
    while True:
        value = "".join(secrets.choice(TEMPORARY_ALPHABET) for _ in range(length))
        if any(ch.isalpha() for ch in value) and any(ch.isdigit() for ch in value):
            return value


def record(session: Session, event: str, *, actor: User | None = None, target_user: User | None = None,
           target_role: str | None = None, email: str | None = None, ip: str | None = None,
           details: dict | None = None) -> SecurityEvent:
    """Добавляет запись в журнал безопасности; сохраняет её вызывающий вместе со своим изменением."""
    if event not in EVENT_TITLES:
        raise ValueError(f"Неизвестное событие журнала: {event}")
    entry = SecurityEvent(event=event, at=now(), actor_id=actor.id if actor else None,
                          target_user_id=target_user.id if target_user else None, target_role=target_role,
                          email=email, ip=ip or None, details=details or None)
    session.add(entry)
    return entry


def revoke_sessions(session: Session, user_id: int, family: str | None = None, keep: str | None = None) -> int:
    """Закрывает сеансы сотрудника: все, один (family) или все, кроме текущего (keep); возвращает число токенов."""
    query = update(RefreshToken).where(RefreshToken.user_id == user_id, RefreshToken.revoked.is_(False))
    if family is not None:
        query = query.where(RefreshToken.family == family)
    if keep is not None:
        query = query.where(RefreshToken.family != keep)
    return session.execute(query.values(revoked=True).execution_options(synchronize_session=False)).rowcount


def guardian_roles(session: Session) -> list[str]:
    """Коды ролей, у которых есть и управление учётными записями, и управление ролями."""
    return [role.code for role in session.scalars(select(Role)) if GUARDIAN_PERMISSIONS <= set(role.permissions or ())]


def ensure_guardians(session: Session) -> None:
    """Отклоняет несохранённое изменение, после которого никто не сможет управлять учётными записями и ролями.

    Изменение уже внесено в сеанс; при нарушении оно откатывается и запрос получает ответ 409.
    """
    session.flush()
    codes = guardian_roles(session)
    left = 0
    if codes:
        left = session.scalar(select(func.count()).select_from(User).where(User.is_active.is_(True), User.role.in_(codes)))
    if not left:
        session.rollback()
        raise HTTPException(status_code=409, detail=LOCKOUT_GUARD)
