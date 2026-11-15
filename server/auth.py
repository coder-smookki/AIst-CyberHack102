"""Вход сотрудников: хэши паролей, токены доступа и обновления, смена пароля, проверка прав.

Вход по почте и паролю выдаёт пару токенов. Токен доступа живёт 30 минут и передаётся в заголовке
Authorization: Bearer. Токен обновления лежит на телефоне в защищённом хранилище и служит для входа по
биометрии; на сервере хранится только его хэш. Каждое обновление заменяет токен новым, а повторное
предъявление уже использованного токена закрывает весь сеанс. Сеанс живёт не дольше срока из политики
безопасности, считая от входа по паролю.

Права сотрудника берутся из его роли в базе при каждом запросе, поэтому правка роли действует сразу,
без повторного входа. Заблокированная учётная запись войти не может, а сотрудник с временным паролем
до его смены может только сменить пароль, выйти и узнать сведения о себе.
"""

import base64
import hashlib
import hmac
import secrets
import time
import unicodedata
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from functools import lru_cache
from threading import Lock
from typing import Annotated

import jwt
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from sqlalchemy import delete, exists, select, update
from sqlalchemy.orm import Session

from server import config, security
from server.db import get_session
from server.models import RefreshToken, Role, User, now
from server.permissions import PERMISSIONS, ordered
from server.permissions import title as permission_title

ALGORITHM = "HS256"
SCRYPT_N = 2**15
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_MAXMEM = 64 * 1024 * 1024
SALT_BYTES = 16
KEY_BYTES = 32
BLOCKED_ACCOUNT = "Учётная запись заблокирована. Обратитесь к администратору ИБ"
CHANGE_PASSWORD = "Требуется сменить временный пароль"
NO_BIOMETRICS = "Вход по биометрии запрещён политикой безопасности - войдите по паролю"

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
    """Запрос новой пары токенов по токену обновления; biometric - вход по биометрии на телефоне."""

    refresh_token: str = Field(min_length=1, max_length=2048)
    biometric: bool = False


class PasswordBody(BaseModel):
    """Запрос смены пароля: действующий (или временный) пароль и новый."""

    current_password: str = Field(min_length=1, max_length=256)
    new_password: str = Field(min_length=1, max_length=256)


def _password_bytes(password: str) -> bytes:
    """Приводит пароль к единой форме записи символов, чтобы разные клавиатуры давали один и тот же хэш."""
    return unicodedata.normalize("NFKC", password).encode("utf-8")


def hash_password(password: str) -> str:
    """Считает хэш пароля алгоритмом scrypt со случайной солью; параметры записаны в саму строку хэша."""
    salt = secrets.token_bytes(SALT_BYTES)
    key = hashlib.scrypt(
        _password_bytes(password), salt=salt, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P, maxmem=SCRYPT_MAXMEM, dklen=KEY_BYTES
    )
    parts = ("scrypt", SCRYPT_N, SCRYPT_R, SCRYPT_P, base64.b64encode(salt).decode(), base64.b64encode(key).decode())
    return "$".join(str(part) for part in parts)


def verify_password(password: str, stored: str) -> bool:
    """Проверяет пароль по сохранённому хэшу; повреждённая строка хэша означает отказ, а не ошибку."""
    try:
        scheme, n, r, p, salt, key = stored.split("$")
        if scheme != "scrypt":
            return False
        expected = base64.b64decode(key, validate=True)
        actual = hashlib.scrypt(
            _password_bytes(password),
            salt=base64.b64decode(salt, validate=True),
            n=int(n),
            r=int(r),
            p=int(p),
            maxmem=SCRYPT_MAXMEM,
            dklen=len(expected),
        )
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


def _lifetime(session: Session) -> timedelta:
    """Наибольший срок сеанса от входа по паролю по политике безопасности."""
    return timedelta(hours=security.get_policy(session).session_hours)


def _encode(user_id: int, family: str, kind: str, auth_time: int, lifetime: timedelta) -> str:
    """Выпускает подписанный токен вида access или refresh для сотрудника и его сеанса.

    auth_time - момент входа по паролю; токен обновления не переживает срок сеанса, отсчитанный от него.
    """
    issued = datetime.now(UTC)
    if kind == "access":
        expires = issued + config.ACCESS_TTL
    else:
        expires = datetime.fromtimestamp(auth_time, UTC) + lifetime
    claims = {
        "sub": str(user_id),
        "sid": family,
        "typ": kind,
        "jti": secrets.token_urlsafe(16),
        "iat": issued,
        "exp": expires,
        "auth_time": auth_time,
    }
    return jwt.encode(claims, config.secret_key(), algorithm=ALGORITHM)


def _decode(token: str, kind: str) -> dict | None:
    """Проверяет подпись, срок действия и вид токена; возвращает его содержимое или None."""
    try:
        payload = jwt.decode(
            token, config.secret_key(), algorithms=[ALGORITHM], options={"require": ["exp", "sub", "sid", "typ"]}
        )
    except jwt.PyJWTError:
        return None
    if payload["typ"] != kind or not str(payload["sub"]).isdigit() or not isinstance(payload["sid"], str):
        return None
    return payload


def _unauthorized(detail: str) -> HTTPException:
    """Собирает отказ 401 с заголовком, по которому клиент понимает, что нужен токен."""
    return HTTPException(status_code=401, detail=detail, headers={"WWW-Authenticate": "Bearer"})


def _client_ip(request: Request) -> str:
    """Адрес устройства, с которого пришёл запрос."""
    return request.client.host if request.client else ""


def sentence_title(text: str) -> str:
    """Название для середины фразы: «Инженер» - «инженер», а сокращения вроде «ИБ» сохраняются."""
    if len(text) > 1 and text[0].isupper() and text[1].islower():
        return text[0].lower() + text[1:]
    return text


def role_title(user: User) -> str:
    """Название роли сотрудника для середины фразы: «инженер», «администратор ИБ»."""
    info = user.role_info
    return sentence_title(info.title) if info is not None else user.role


def permissions_of(user: User) -> list[str]:
    """Права сотрудника по его роли в порядке перечня."""
    info = user.role_info
    return ordered(info.permissions) if info is not None else []


def has_permission(user: User, code: str) -> bool:
    """Есть ли у сотрудника право по его роли."""
    info = user.role_info
    return info is not None and code in (info.permissions or ())


def user_view(user: User) -> dict:
    """Описывает сотрудника для ответа сервера: без хэша пароля, с названием роли по-русски и правами."""
    return {
        "id": user.id,
        "email": user.email,
        "name": user.name,
        "role": user.role,
        "role_title": role_title(user),
        "permissions": permissions_of(user),
        "must_change_password": user.must_change_password,
    }


def _issue(session: Session, user: User, family: str, device: str | None, auth_time: int) -> dict:
    """Выпускает пару токенов сеанса и запоминает хэш токена обновления; сохранение - за вызывающим."""
    policy = security.get_policy(session)
    lifetime = timedelta(hours=policy.session_hours)
    refresh_token = _encode(user.id, family, "refresh", auth_time, lifetime)
    session.add(RefreshToken(user_id=user.id, token_hash=_digest(refresh_token), family=family, device=device))
    view = user_view(user)
    return {
        "access_token": _encode(user.id, family, "access", auth_time, lifetime),
        "refresh_token": refresh_token,
        "token_type": "bearer",
        "expires_in": int(config.ACCESS_TTL.total_seconds()),
        "user": view,
        "must_change_password": view["must_change_password"],
        "permissions": view["permissions"],
        "biometrics_allowed": policy.biometrics_allowed,
    }


def _session_user(session: Session, payload: dict) -> User | None:
    """Находит действующего сотрудника по содержимому токена доступа, если его сеанс не закрыт."""
    alive = exists().where(
        RefreshToken.family == payload["sid"], RefreshToken.user_id == User.id, RefreshToken.revoked.is_(False)
    )
    return session.scalar(select(User).where(User.id == int(payload["sub"]), User.is_active.is_(True), alive))


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


def signed_in_user(payload: Annotated[dict, Depends(_claims)], session: Annotated[Session, Depends(get_session)]) -> User:
    """Зависимость: вошедший сотрудник, даже если ему ещё нужно сменить временный пароль."""
    user = _session_user(session, payload)
    if user is None:
        raise _unauthorized("Сеанс завершён - войдите заново")
    return user


def current_user(user: Annotated[User, Depends(signed_in_user)]) -> User:
    """Зависимость: сотрудник, от имени которого выполняется запрос; с несменённым временным паролем - отказ 403."""
    if user.must_change_password:
        raise HTTPException(status_code=403, detail=CHANGE_PASSWORD)
    return user


def granted(session: Session, user: User) -> set[str]:
    """Права сотрудника, прочитанные из его роли в базе в момент запроса."""
    role = session.get(Role, user.role, populate_existing=True)
    return set(role.permissions or ()) if role is not None else set()


def require_permission(*codes: str, any_of: bool = False) -> Callable[..., User]:
    """Создаёт зависимость, которая пропускает сотрудника, если его роль даёт все перечисленные права.

    С any_of=True достаточно одного из прав. Неизвестный код права - ошибка при сборке маршрутов.
    """
    wrong = [code for code in codes if code not in PERMISSIONS]
    if not codes or wrong:
        raise ValueError(f"Права должны быть из перечня server/permissions.py, получено {codes}")
    names = ", ".join(f"«{permission_title(code)}»" for code in codes)
    detail = (
        f"Недостаточно прав - нужно право {names}"
        if len(codes) == 1
        else (f"Недостаточно прав - нужно одно из прав: {names}" if any_of else f"Недостаточно прав - нужны права: {names}")
    )

    def checker(user: Annotated[User, Depends(current_user)], session: Annotated[Session, Depends(get_session)]) -> User:
        """Проверяет права сотрудника по роли в базе и возвращает его."""
        have = granted(session, user)
        allowed = any(code in have for code in codes) if any_of else all(code in have for code in codes)
        if not allowed:
            raise HTTPException(status_code=403, detail=detail)
        return user

    return checker


def _seconds_blocked(key: tuple[str, str], attempts: int, window: int) -> int:
    """Возвращает, сколько секунд вход для пары почта и адрес ещё закрыт после череды неудач; 0 - открыт."""
    moment = time.monotonic()
    with _failures_lock:
        recent = [at for at in _failures.get(key, ()) if moment - at < window]
        if len(recent) < attempts:
            return 0
        return int(window - (moment - recent[-attempts])) + 1


def _note_failure(key: tuple[str, str], window: int) -> int:
    """Запоминает неудачную попытку, забывает попытки за окном наблюдения и возвращает число недавних неудач."""
    moment = time.monotonic()
    with _failures_lock:
        _failures.setdefault(key, []).append(moment)
        for other in list(_failures):
            kept = [at for at in _failures[other] if moment - at < window]
            if kept:
                _failures[other] = kept
            else:
                del _failures[other]
        return len(_failures.get(key, ()))


def _throttle(session: Session, key: tuple[str, str]) -> tuple[int, int]:
    """Проверяет, не закрыт ли вход после неудач; возвращает порог неудач и окно наблюдения в секундах."""
    policy = security.get_policy(session)
    attempts, window = policy.lockout_attempts, policy.lockout_minutes * 60
    blocked = _seconds_blocked(key, attempts, window)
    if blocked:
        raise HTTPException(
            status_code=429,
            detail=f"Слишком много неудачных попыток входа - повторите через {blocked} с",
            headers={"Retry-After": str(blocked)},
        )
    return attempts, window


def _failed(session: Session, key: tuple[str, str], attempts: int, window: int, event: str, **fields) -> None:
    """Учитывает неудачу, пишет её в журнал, а при достижении порога - ещё и закрытие входа; сохраняет журнал."""
    count = _note_failure(key, window)
    security.record(session, event, email=key[0], ip=key[1], **fields)
    if count == attempts:
        security.record(
            session, "login_locked", email=key[0], ip=key[1], details={"attempts": attempts, "minutes": window // 60}, **fields
        )
    session.commit()


@router.post("/login")
def login(body: LoginBody, request: Request, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Вход по почте и паролю: токены, данные сотрудника, его права и признак обязательной смены пароля.

    Заблокированная учётная запись с верным паролем получает отказ 403; с неверным - тот же 401, что и все,
    чтобы по ответу нельзя было узнать, существует ли почта.
    """
    email = body.email.strip().lower()
    key = (email, _client_ip(request))
    attempts, window = _throttle(session, key)
    user = session.scalar(select(User).where(User.email == email))
    if not verify_password(body.password, user.password_hash if user else _decoy_hash()) or user is None:
        _failed(session, key, attempts, window, "login_failure", target_user=user)
        raise _unauthorized("Неверная почта или пароль")
    if not user.is_active:
        security.record(session, "login_blocked", target_user=user, email=email, ip=key[1])
        session.commit()
        raise HTTPException(status_code=403, detail=BLOCKED_ACCOUNT)
    with _failures_lock:
        _failures.pop(key, None)
    session.execute(
        delete(RefreshToken)
        .where(RefreshToken.created_at < now() - max(_lifetime(session), config.REFRESH_TTL))
        .execution_options(synchronize_session=False)
    )
    user.last_login_at = now()
    security.record(
        session,
        "login_success",
        actor=user,
        target_user=user,
        ip=key[1],
        details={"device": body.device} if body.device else None,
    )
    tokens = _issue(session, user, secrets.token_hex(16), body.device, int(time.time()))
    session.commit()
    return tokens


@router.post("/refresh")
def refresh(body: RefreshBody, session: Annotated[Session, Depends(get_session)], request: Request = None) -> dict:
    """Меняет токен обновления на новую пару токенов; старый токен после этого больше не действует.

    Сеанс старше срока из политики закрывается; вход по биометрии отклоняется, если политика его запрещает,
    а успешный вход по биометрии записывается в журнал безопасности.
    """
    payload = _decode(body.refresh_token, "refresh")
    if payload is None:
        raise _unauthorized("Токен обновления недействителен или истёк - войдите по паролю")
    policy = security.get_policy(session)
    if body.biometric and not policy.biometrics_allowed:
        raise HTTPException(status_code=403, detail=NO_BIOMETRICS)
    auth_time = int(payload.get("auth_time") or payload.get("iat") or 0)
    expired = time.time() - auth_time > policy.session_hours * 3600
    spent = None
    if not expired:
        spent = session.execute(
            update(RefreshToken)
            .where(RefreshToken.token_hash == _digest(body.refresh_token), RefreshToken.revoked.is_(False))
            .values(revoked=True)
            .returning(RefreshToken.user_id, RefreshToken.family, RefreshToken.device)
            .execution_options(synchronize_session=False)
        ).first()
    user = session.get(User, spent.user_id) if spent else None
    if user is None or not user.is_active:
        session.execute(
            update(RefreshToken)
            .where(RefreshToken.family == payload["sid"])
            .values(revoked=True)
            .execution_options(synchronize_session=False)
        )
        session.commit()
        if expired:
            raise _unauthorized("Срок сеанса истёк - войдите по паролю")
        raise _unauthorized("Токен обновления уже использован или отозван - войдите по паролю")
    tokens = _issue(session, user, spent.family, spent.device, auth_time)
    if body.biometric:
        user.last_login_at = now()
        security.record(
            session,
            "login_biometric",
            actor=user,
            target_user=user,
            ip=_client_ip(request) if request else None,
            details={"device": spent.device} if spent.device else None,
        )
    session.commit()
    return tokens


@router.post("/logout")
def logout(
    payload: Annotated[dict, Depends(_claims)],
    user: Annotated[User, Depends(signed_in_user)],
    session: Annotated[Session, Depends(get_session)],
) -> dict:
    """Завершает сеанс: его токен обновления и выданные токены доступа перестают действовать сразу."""
    security.revoke_sessions(session, user.id, family=payload["sid"])
    session.commit()
    return {"ok": True}


@router.get("/me")
def me(user: Annotated[User, Depends(signed_in_user)]) -> dict:
    """Возвращает данные вошедшего сотрудника для личного кабинета: роль, права, нужна ли смена пароля."""
    return user_view(user)


@router.post("/password")
def change_password(
    body: PasswordBody,
    request: Request,
    payload: Annotated[dict, Depends(_claims)],
    user: Annotated[User, Depends(signed_in_user)],
    session: Annotated[Session, Depends(get_session)],
) -> dict:
    """Меняет пароль: проверяет действующий пароль и соответствие нового политике, закрывает прочие сеансы.

    Неверный действующий пароль считается неудачной попыткой входа - так пароль не подобрать перебором.
    """
    key = (user.email, _client_ip(request))
    attempts, window = _throttle(session, key)
    if not verify_password(body.current_password, user.password_hash):
        _failed(session, key, attempts, window, "password_change_failed", actor=user, target_user=user)
        raise HTTPException(status_code=400, detail="Текущий пароль указан неверно")
    problems = security.password_problems(security.get_policy(session), body.new_password)
    if body.new_password == body.current_password:
        problems.append("Новый пароль должен отличаться от текущего")
    if problems:
        raise HTTPException(status_code=422, detail="; ".join(problems))
    user.password_hash = hash_password(body.new_password)
    user.must_change_password = False
    user.password_changed_at = now()
    closed = security.revoke_sessions(session, user.id, keep=payload["sid"])
    security.record(
        session, "password_changed", actor=user, target_user=user, ip=key[1], details={"other_sessions_closed": closed}
    )
    session.commit()
    return {"ok": True, "user": user_view(user)}
