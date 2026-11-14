"""Вход сотрудников: хэши паролей, токены доступа и обновления, проверка прав.

Вход по почте и паролю выдаёт пару токенов. Токен доступа живёт 30 минут и передаётся в заголовке
Authorization: Bearer. Токен обновления живёт 30 дней, лежит на телефоне в защищённом хранилище и служит
для входа по биометрии; на сервере хранится только его хэш. Каждое обновление заменяет токен новым,
а повторное предъявление уже использованного токена закрывает весь сеанс.
"""
import base64
import hashlib
import hmac
import secrets
import time
import unicodedata
from collections.abc import Callable
from datetime import datetime, timezone
from functools import lru_cache
from threading import Lock
from typing import Annotated

import jwt
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from sqlalchemy import delete, exists, select, update
from sqlalchemy.orm import Session

from server import config
from server.db import get_session
from server.models import ROLES, RefreshToken, User, now

ALGORITHM = "HS256"
SCRYPT_N = 2**15
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_MAXMEM = 64 * 1024 * 1024
SALT_BYTES = 16
KEY_BYTES = 32
LOGIN_ATTEMPTS = 10
LOGIN_WINDOW_SECONDS = 300
ROLE_TITLES = {"engineer": "инженер", "master": "мастер", "admin": "администратор"}

router = APIRouter(prefix="/auth", tags=["auth"])
_bearer = HTTPBearer(auto_error=False)
_failures: dict[tuple[str, str], list[float]] = {}
_failures_lock = Lock()


class LoginBody(BaseModel):
    """Запрос входа: почта, пароль и необязательное название устройства для списка сеансов."""

    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=256)
    device: str | None = Field(default=None, max_length=120)


class RefreshBody(BaseModel):
    """Запрос новой пары токенов по токену обновления."""

    refresh_token: str = Field(min_length=1, max_length=2048)


def _password_bytes(password: str) -> bytes:
    """Приводит пароль к единой форме записи символов, чтобы разные клавиатуры давали один и тот же хэш."""
    return unicodedata.normalize("NFKC", password).encode("utf-8")


def hash_password(password: str) -> str:
    """Считает хэш пароля алгоритмом scrypt со случайной солью; параметры записаны в саму строку хэша."""
    salt = secrets.token_bytes(SALT_BYTES)
    key = hashlib.scrypt(_password_bytes(password), salt=salt, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P,
                         maxmem=SCRYPT_MAXMEM, dklen=KEY_BYTES)
    parts = ("scrypt", SCRYPT_N, SCRYPT_R, SCRYPT_P, base64.b64encode(salt).decode(), base64.b64encode(key).decode())
    return "$".join(str(part) for part in parts)


def verify_password(password: str, stored: str) -> bool:
    """Проверяет пароль по сохранённому хэшу; повреждённая строка хэша означает отказ, а не ошибку."""
    try:
        scheme, n, r, p, salt, key = stored.split("$")
        if scheme != "scrypt":
            return False
        expected = base64.b64decode(key, validate=True)
        actual = hashlib.scrypt(_password_bytes(password), salt=base64.b64decode(salt, validate=True),
                                n=int(n), r=int(r), p=int(p), maxmem=SCRYPT_MAXMEM, dklen=len(expected))
    except ValueError:
        return False
    return hmac.compare_digest(actual, expected)


@lru_cache
def _decoy_hash() -> str:
    """Хэш для сравнения, когда почта не найдена: ответ занимает то же время, что и при неверном пароле."""
    return hash_password(secrets.token_hex(16))


def _digest(token: str) -> str:
    """Возвращает хэш токена обновления - в базе хранится только он."""
    return hashlib.sha256(token.encode()).hexdigest()


def _encode(user_id: int, family: str, kind: str) -> str:
    """Выпускает подписанный токен вида access или refresh для сотрудника и его сеанса."""
    issued = datetime.now(timezone.utc)
    lifetime = config.ACCESS_TTL if kind == "access" else config.REFRESH_TTL
    claims = {"sub": str(user_id), "sid": family, "typ": kind, "jti": secrets.token_urlsafe(16),
              "iat": issued, "exp": issued + lifetime}
    return jwt.encode(claims, config.secret_key(), algorithm=ALGORITHM)


def _decode(token: str, kind: str) -> dict | None:
    """Проверяет подпись, срок действия и вид токена; возвращает его содержимое или None."""
    try:
        payload = jwt.decode(token, config.secret_key(), algorithms=[ALGORITHM],
                             options={"require": ["exp", "sub", "sid", "typ"]})
    except jwt.PyJWTError:
        return None
    if payload["typ"] != kind or not str(payload["sub"]).isdigit() or not isinstance(payload["sid"], str):
        return None
    return payload


def _unauthorized(detail: str) -> HTTPException:
    """Собирает отказ 401 с заголовком, по которому клиент понимает, что нужен токен."""
    return HTTPException(status_code=401, detail=detail, headers={"WWW-Authenticate": "Bearer"})


def user_view(user: User) -> dict:
    """Описывает сотрудника для ответа сервера: без хэша пароля, с названием роли по-русски."""
    return {"id": user.id, "email": user.email, "name": user.name, "role": user.role, "role_title": ROLE_TITLES[user.role]}


def _issue(session: Session, user: User, family: str, device: str | None) -> dict:
    """Выпускает пару токенов сеанса и запоминает хэш токена обновления; сохранение - за вызывающим."""
    refresh_token = _encode(user.id, family, "refresh")
    session.add(RefreshToken(user_id=user.id, token_hash=_digest(refresh_token), family=family, device=device))
    return {"access_token": _encode(user.id, family, "access"), "refresh_token": refresh_token, "token_type": "bearer",
            "expires_in": int(config.ACCESS_TTL.total_seconds()), "user": user_view(user)}


def _session_user(session: Session, payload: dict) -> User | None:
    """Находит сотрудника по содержимому токена доступа, если его сеанс не закрыт."""
    alive = exists().where(RefreshToken.family == payload["sid"], RefreshToken.user_id == User.id,
                           RefreshToken.revoked.is_(False))
    return session.scalar(select(User).where(User.id == int(payload["sub"]), alive))


def user_from_token(session: Session, token: str) -> User | None:
    """Возвращает сотрудника по токену доступа или None - для мест, где нет заголовка, например WebSocket."""
    payload = _decode(token, "access")
    return _session_user(session, payload) if payload else None


def _claims(credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)]) -> dict:
    """Зависимость: достаёт токен доступа из заголовка и возвращает его проверенное содержимое."""
    payload = _decode(credentials.credentials, "access") if credentials else None
    if payload is None:
        raise _unauthorized("Требуется вход: токен доступа не передан, недействителен или истёк")
    return payload


def current_user(payload: Annotated[dict, Depends(_claims)], session: Annotated[Session, Depends(get_session)]) -> User:
    """Зависимость: сотрудник, от имени которого выполняется запрос."""
    user = _session_user(session, payload)
    if user is None:
        raise _unauthorized("Сеанс завершён - войдите заново")
    return user


def require_role(*roles: str) -> Callable[..., User]:
    """Создаёт зависимость, которая пропускает только сотрудников с одной из перечисленных ролей."""
    if not roles or set(roles) - set(ROLES):
        raise ValueError(f"Роли должны быть из перечня {ROLES}, получено {roles}")
    allowed = ", ".join(ROLE_TITLES[role] for role in roles)

    def checker(user: Annotated[User, Depends(current_user)]) -> User:
        """Проверяет роль сотрудника и возвращает его."""
        if user.role not in roles:
            raise HTTPException(status_code=403, detail=f"Недостаточно прав - действие доступно ролям: {allowed}")
        return user

    return checker


def _seconds_blocked(key: tuple[str, str]) -> int:
    """Возвращает, сколько секунд вход для пары почта и адрес ещё закрыт после череды неудач; 0 - открыт."""
    moment = time.monotonic()
    with _failures_lock:
        recent = [at for at in _failures.get(key, ()) if moment - at < LOGIN_WINDOW_SECONDS]
        if len(recent) < LOGIN_ATTEMPTS:
            return 0
        return int(LOGIN_WINDOW_SECONDS - (moment - recent[-LOGIN_ATTEMPTS])) + 1


def _note_failure(key: tuple[str, str]) -> None:
    """Запоминает неудачную попытку входа и забывает попытки, вышедшие за окно наблюдения."""
    moment = time.monotonic()
    with _failures_lock:
        _failures.setdefault(key, []).append(moment)
        for other in list(_failures):
            kept = [at for at in _failures[other] if moment - at < LOGIN_WINDOW_SECONDS]
            if kept:
                _failures[other] = kept
            else:
                del _failures[other]


@router.post("/login")
def login(body: LoginBody, request: Request, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Вход по почте и паролю: выдаёт токен доступа, токен обновления и данные сотрудника."""
    email = body.email.strip().lower()
    key = (email, request.client.host if request.client else "")
    blocked = _seconds_blocked(key)
    if blocked:
        raise HTTPException(status_code=429, detail=f"Слишком много неудачных попыток входа - повторите через {blocked} с",
                            headers={"Retry-After": str(blocked)})
    user = session.scalar(select(User).where(User.email == email))
    if not verify_password(body.password, user.password_hash if user else _decoy_hash()) or user is None:
        _note_failure(key)
        raise _unauthorized("Неверная почта или пароль")
    with _failures_lock:
        _failures.pop(key, None)
    session.execute(delete(RefreshToken).where(RefreshToken.created_at < now() - config.REFRESH_TTL)
                    .execution_options(synchronize_session=False))
    tokens = _issue(session, user, secrets.token_hex(16), body.device)
    session.commit()
    return tokens


@router.post("/refresh")
def refresh(body: RefreshBody, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Меняет токен обновления на новую пару токенов; старый токен после этого больше не действует."""
    payload = _decode(body.refresh_token, "refresh")
    if payload is None:
        raise _unauthorized("Токен обновления недействителен или истёк - войдите по паролю")
    spent = session.execute(
        update(RefreshToken)
        .where(RefreshToken.token_hash == _digest(body.refresh_token), RefreshToken.revoked.is_(False))
        .values(revoked=True)
        .returning(RefreshToken.user_id, RefreshToken.family, RefreshToken.device)
        .execution_options(synchronize_session=False)
    ).first()
    user = session.get(User, spent.user_id) if spent else None
    if user is None:
        session.execute(update(RefreshToken).where(RefreshToken.family == payload["sid"]).values(revoked=True)
                        .execution_options(synchronize_session=False))
        session.commit()
        raise _unauthorized("Токен обновления уже использован или отозван - войдите по паролю")
    tokens = _issue(session, user, spent.family, spent.device)
    session.commit()
    return tokens


@router.post("/logout")
def logout(payload: Annotated[dict, Depends(_claims)], user: Annotated[User, Depends(current_user)],
           session: Annotated[Session, Depends(get_session)]) -> dict:
    """Завершает сеанс: его токен обновления и выданные токены доступа перестают действовать сразу."""
    session.execute(update(RefreshToken).where(RefreshToken.family == payload["sid"], RefreshToken.user_id == user.id)
                    .values(revoked=True).execution_options(synchronize_session=False))
    session.commit()
    return {"ok": True}


@router.get("/me")
def me(user: Annotated[User, Depends(current_user)]) -> dict:
    """Возвращает данные вошедшего сотрудника для личного кабинета."""
    return user_view(user)
