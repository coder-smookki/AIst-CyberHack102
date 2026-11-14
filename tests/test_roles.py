"""Проверки ролевой модели: права пяти системных ролей, роли как данные, администратор ИБ, журнал и политика
безопасности, временный пароль, блокировка, перевод старой базы и цепочка «сообщение - задание - осмотр».

Сервер собирается целиком, детектор подменён, стоимость хэша пароля снижена, чтобы проверки шли быстро.
"""
import hashlib
import shutil
import sqlite3
from datetime import date, timedelta

import jwt
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from starlette.websockets import WebSocketDisconnect

from server import auth, db, migrate
from server import seed as seeding
from server.app import create_app
from server.inspections import service
from server.models import RefreshToken, Role, SecurityEvent, User
from server.permissions import GROUPS, PERMISSIONS, SYSTEM_ROLES

SECRET = "r" * 48
PASSWORD = "demo12345"
FRESH = "Pump2026secure"
EMAILS = {"engineer": "engineer@kst.demo", "master": "master@kst.demo", "operator": "operator@kst.demo",
          "admin": "admin@kst.demo", "security": "security@kst.demo"}
EVERYONE = set(EMAILS)


class FakeDetector:
    """Подменный детектор: рамок на кадре нет, модель всегда готова."""

    def detect(self, frame):
        """Возвращает пустой список рамок."""
        return []


def forget_caches():
    """Сбрасывает запомненные хэши демонстрационных паролей и счётчик неудачных входов."""
    seeding._demo_hash.cache_clear()
    auth._decoy_hash.cache_clear()
    auth._failures.clear()


@pytest.fixture(scope="module")
def seeded_database(tmp_path_factory):
    """Один раз создаёт базу с начальными данными; каждая проверка работает со своей копией."""
    path = tmp_path_factory.mktemp("roles") / "kst.db"
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("KST_DB", str(path))
        patch.setattr(auth, "SCRYPT_N", 2**10)
        forget_caches()
        db.init_db()
        with db.SessionLocal() as session:
            seeding.seed(session)
        db.engine.dispose()
        forget_caches()
    return path


@pytest.fixture
def client(seeded_database, tmp_path, monkeypatch):
    """Полный сервер на отдельной копии базы."""
    shutil.copyfile(seeded_database, tmp_path / "kst.db")
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    monkeypatch.setenv("KST_SECRET", SECRET)
    monkeypatch.delenv("KST_LLM_URL", raising=False)
    monkeypatch.setattr(auth, "SCRYPT_N", 2**10)
    forget_caches()
    with TestClient(create_app(FakeDetector())) as test_client:
        yield test_client
    service._live.clear()
    db.engine.dispose()
    forget_caches()


def sign_in(client, email, password=PASSWORD):
    """Входит и возвращает ответ сервера; вход обязан быть успешным."""
    response = client.post("/auth/login", json={"email": email, "password": password})
    assert response.status_code == 200, response.text
    return response.json()


def bearer(tokens):
    """Заголовок авторизации по ответу входа."""
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def headers_for(client):
    """Заголовки авторизации всех пяти демонстрационных сотрудников."""
    return {role: bearer(sign_in(client, email)) for role, email in EMAILS.items()}


def events(client, security, **params):
    """Записи журнала безопасности, видимые администратору ИБ."""
    response = client.get("/admin/security-log", headers=security, params=params)
    assert response.status_code == 200, response.text
    return response.json()


def create_user(client, security, email, role, name="Новый сотрудник"):
    """Администратор ИБ заводит учётную запись; возвращает её описание и временный пароль."""
    response = client.post("/admin/users", headers=security, json={"email": email, "name": name, "role": role})
    assert response.status_code == 201, response.text
    body = response.json()
    return body["user"], body["temporary_password"]


def activate(client, email, temporary, password=FRESH):
    """Входит с временным паролем, меняет его и возвращает заголовок авторизации."""
    tokens = sign_in(client, email, temporary)
    assert tokens["must_change_password"] is True
    changed = client.post("/auth/password", headers=bearer(tokens),
                          json={"current_password": temporary, "new_password": password})
    assert changed.status_code == 200, changed.text
    return bearer(tokens)


MATRIX = [
    ("GET", "/auth/me", None, EVERYONE),
    ("GET", "/notifications", None, EVERYONE),
    ("GET", "/equipment", None, {"engineer", "master", "operator", "admin"}),
    ("GET", "/equipment/AMS-1/history", None, {"engineer", "master", "operator", "admin"}),
    ("GET", "/equipment/AMS-1/telemetry", None, {"engineer", "master", "operator", "admin"}),
    ("POST", "/equipment/AMS-1/mode", {"mode": "stopped"}, {"master"}),
    ("POST", "/equipment/AMS-1/cursor", {"at": "2026-11-20T12:00:00"}, {"master", "admin"}),
    ("POST", "/inspections", {"equipment_id": "AMS-1"}, {"engineer", "master"}),
    ("GET", "/inspections", None, {"engineer", "master", "operator"}),
    ("GET", "/inspections/findings", None, {"engineer", "master", "operator"}),
    ("POST", "/inspections/findings/3/state", {"state": "in_work"}, {"master"}),
    ("GET", "/inspections/1/report.xlsx", None, {"engineer", "master"}),
    ("POST", "/assistant/ask", {"question": "история АМС-1"}, {"engineer", "master", "operator"}),
    ("POST", "/fault-reports", {"equipment_id": "AMS-1", "signs": ["шум"]}, {"operator"}),
    ("GET", "/fault-reports", None, {"master"}),
    ("GET", "/tasks", None, {"master"}),
    ("GET", "/tasks/my", None, {"engineer", "master"}),
    ("GET", "/system/status", None, {"admin"}),
    ("GET", "/admin/users", None, {"security"}),
    ("GET", "/admin/roles", None, {"security"}),
    ("GET", "/admin/permissions", None, {"security"}),
    ("GET", "/admin/security-log", None, {"security"}),
    ("GET", "/admin/policy", None, {"security"}),
]


def test_system_roles_and_catalogue(client):
    """Пять системных ролей с русскими названиями; перечень прав разложен по семи группам на русском."""
    security = bearer(sign_in(client, EMAILS["security"]))
    roles = {role["code"]: role for role in client.get("/admin/roles", headers=security).json()}
    assert set(roles) == {"security_admin", "admin", "master", "engineer", "operator"}
    assert {code: role["title"] for code, role in roles.items()} == {
        "security_admin": "Администратор ИБ", "admin": "Администратор системы", "master": "Мастер",
        "engineer": "Инженер", "operator": "Оператор"}
    assert all(role["is_system"] and role["members"] == 1 for role in roles.values())
    assert set(roles["engineer"]["permissions"]) < set(roles["master"]["permissions"])
    assert {"findings.confirm", "equipment.mode", "maintenance.plan", "reports.all", "tasks.assign"} <= set(
        roles["master"]["permissions"])
    assert "inspect.run" not in roles["operator"]["permissions"] and "fault.report" in roles["operator"]["permissions"]
    assert not {"users.manage", "roles.manage", "inspect.run", "findings.confirm"} & set(roles["admin"]["permissions"])
    assert not any(code.startswith(("equipment.", "telemetry.", "inspect.")) for code in roles["security_admin"]["permissions"])
    groups = client.get("/admin/permissions", headers=security).json()
    assert [group["title"] for group in groups] == [title for _, title in GROUPS] == [
        "Осмотр", "Находки", "Оборудование", "Отчёты", "Ассистент", "Система", "Учётные записи"]
    listed = [entry["code"] for group in groups for entry in group["permissions"]]
    assert sorted(listed) == sorted(PERMISSIONS) and len(listed) == len(set(listed))
    me = sign_in(client, EMAILS["operator"])
    assert me["user"]["role_title"] == "оператор" and me["permissions"] == me["user"]["permissions"]
    assert sign_in(client, EMAILS["security"])["user"]["role_title"] == "администратор ИБ"


def test_permission_matrix(client):
    """Каждая роль получает доступ ровно к своим разделам: остальным отвечает 403, а не 401 или 500."""
    headers = headers_for(client)
    for method, path, body, allowed in MATRIX:
        for role, header in headers.items():
            response = client.request(method, path, headers=header, json=body)
            if role in allowed:
                assert response.status_code not in (401, 403, 500), (role, method, path, response.text)
            else:
                assert response.status_code == 403, (role, method, path, response.status_code)
                assert response.json()["detail"].startswith("Недостаточно прав"), (role, path)


def test_reports_of_others_need_reports_all(client):
    """Инженер выгружает отчёт по своему осмотру, но не по чужому; мастер - по любому."""
    headers = headers_for(client)
    started = client.post("/inspections", headers=headers["master"], json={"equipment_id": "AMS-2"}).json()
    foreign = client.get(f"/inspections/{started['id']}/report.xlsx", headers=headers["engineer"])
    assert foreign.status_code == 403 and "Отчёты по всем осмотрам" in foreign.json()["detail"]
    assert client.get("/inspections/1/report.xlsx", headers=headers["engineer"]).status_code == 200
    assert client.get(f"/inspections/{started['id']}/report.xlsx", headers=headers["master"]).status_code == 200


def test_camera_stream_needs_inspection_permission(client):
    """Поток кадров камеры открыт инженеру, а оператору закрывается с кодом 4403."""
    operator = sign_in(client, EMAILS["operator"])["access_token"]
    with client.websocket_connect(f"/ws/detect?token={operator}") as socket:
        message = socket.receive_json()
        with pytest.raises(WebSocketDisconnect) as closed:
            socket.receive_json()
    assert closed.value.code == 4403 and "Проведение осмотров" in message["detail"]
    engineer = sign_in(client, EMAILS["engineer"])["access_token"]
    with client.websocket_connect(f"/ws/detect?token={engineer}") as socket:
        socket.send_text("ping")
        assert socket.receive_json() == {"type": "pong"}


def test_custom_role_changes_access_immediately(client):
    """Своя роль по образцу другой; правка её прав действует на уже выданный токен без повторного входа."""
    security = bearer(sign_in(client, EMAILS["security"]))
    created = client.post("/admin/roles", headers=security, json={
        "code": "senior_operator", "title": "Старший оператор", "copy_from": "operator"})
    assert created.status_code == 201, created.text
    role = created.json()
    assert role["permissions"] == [code for code in PERMISSIONS if code in SYSTEM_ROLES["operator"][2]]
    assert role["is_system"] is False and role["members"] == 0
    assert role["description"] == SYSTEM_ROLES["operator"][1]
    user, temporary = create_user(client, security, "ivanov@kst.demo", "operator", "Иван Иванов")
    head = activate(client, "ivanov@kst.demo", temporary)
    assert client.post("/inspections", headers=head, json={"equipment_id": "AMS-1"}).status_code == 403
    moved = client.post(f"/admin/users/{user['id']}/role", headers=security, json={"role": "senior_operator"})
    assert moved.status_code == 200 and moved.json()["role_title"] == "Старший оператор"
    assert client.get("/auth/me", headers=head).json()["role_title"] == "старший оператор"
    grant = client.patch("/admin/roles/senior_operator", headers=security,
                         json={"permissions": role["permissions"] + ["inspect.run"]})
    assert grant.status_code == 200 and "inspect.run" in grant.json()["permissions"]
    assert grant.json()["members"] == 1
    assert client.post("/inspections", headers=head, json={"equipment_id": "AMS-1"}).status_code == 201
    assert "inspect.run" in client.get("/auth/me", headers=head).json()["permissions"]
    narrowed = [code for code in grant.json()["permissions"] if code != "equipment.view"]
    assert client.patch("/admin/roles/senior_operator", headers=security, json={"permissions": narrowed}).status_code == 200
    assert client.get("/equipment", headers=head).status_code == 403
    renamed = client.patch("/admin/roles/engineer", headers=security, json={"title": "Инженер-диагност"})
    assert renamed.status_code == 200 and renamed.json()["is_system"] is True
    assert sign_in(client, EMAILS["engineer"])["user"]["role_title"] == "инженер-диагност"
    assert client.patch("/admin/roles/engineer", headers=security, json={"permissions": ["no.such"]}).status_code == 422
    assert client.post("/admin/roles", headers=security, json={"code": "senior_operator", "title": "Повтор"}).status_code == 409
    assert client.post("/admin/roles", headers=security, json={"code": "Плохой код", "title": "-"}).status_code == 422
    assert client.post("/admin/roles", headers=security,
                       json={"code": "ghost", "title": "Призрак", "copy_from": "nobody"}).status_code == 404
    assert client.post(f"/admin/users/{user['id']}/role", headers=security, json={"role": "nobody"}).status_code == 422


def test_role_deletion_rules(client):
    """Системную роль удалить нельзя, свою - только когда она никому не назначена."""
    security = bearer(sign_in(client, EMAILS["security"]))
    for code in SYSTEM_ROLES:
        refused = client.delete(f"/admin/roles/{code}", headers=security)
        assert refused.status_code == 409 and refused.json()["detail"] == "Системную роль удалить нельзя"
    client.post("/admin/roles", headers=security, json={"code": "trainee", "title": "Стажёр",
                                                         "permissions": ["equipment.view"]})
    user, _ = create_user(client, security, "trainee@kst.demo", "trainee")
    busy = client.delete("/admin/roles/trainee", headers=security)
    assert busy.status_code == 409 and "сначала смените им роль" in busy.json()["detail"]
    client.post(f"/admin/users/{user['id']}/role", headers=security, json={"role": "engineer"})
    assert client.delete("/admin/roles/trainee", headers=security).status_code == 204
    assert client.get("/admin/roles/trainee", headers=security).status_code == 404
    master = bearer(sign_in(client, EMAILS["master"]))
    assert client.delete("/admin/roles/engineer", headers=master).status_code == 403


def test_lockout_protection(client):
    """Нельзя оставить систему без активной учётной записи с управлением учётными записями и ролями."""
    security = bearer(sign_in(client, EMAILS["security"]))
    me = client.get("/auth/me", headers=security).json()
    guard = "не останется ни одной активной учётной записи"
    narrowed = [code for code in SYSTEM_ROLES["security_admin"][2] if code != "roles.manage"]
    refused = client.patch("/admin/roles/security_admin", headers=security, json={"permissions": narrowed})
    assert refused.status_code == 409 and guard in refused.json()["detail"]
    assert client.post(f"/admin/users/{me['id']}/role", headers=security, json={"role": "engineer"}).status_code == 409
    assert client.post(f"/admin/users/{me['id']}/block", headers=security).status_code == 409
    roles = {role["code"]: role for role in client.get("/admin/roles", headers=security).json()}
    assert "roles.manage" in roles["security_admin"]["permissions"]
    assert client.get("/auth/me", headers=security).json()["role"] == "security_admin"
    deputy, temporary = create_user(client, security, "deputy@kst.demo", "security_admin", "Заместитель")
    assert client.post(f"/admin/users/{me['id']}/role", headers=security, json={"role": "engineer"}).status_code == 200
    assert client.get("/admin/users", headers=security).status_code == 403
    second = activate(client, "deputy@kst.demo", temporary)
    assert client.post(f"/admin/users/{deputy['id']}/role", headers=second, json={"role": "master"}).status_code == 409
    assert client.post(f"/admin/users/{deputy['id']}/block", headers=second).status_code == 409
    assert client.post(f"/admin/users/{me['id']}/role", headers=second, json={"role": "security_admin"}).status_code == 200


def test_blocked_user_and_sessions(client):
    """Блокировка закрывает все сеансы; вход заблокированного - 403 с понятной причиной и записью в журнале."""
    security = bearer(sign_in(client, EMAILS["security"]))
    phone, tablet = sign_in(client, EMAILS["engineer"]), sign_in(client, EMAILS["engineer"])
    engineer_id = phone["user"]["id"]
    sessions = client.get(f"/admin/users/{engineer_id}/sessions", headers=security).json()
    assert len(sessions) == 2 and all(entry["active"] for entry in sessions)
    one = client.delete(f"/admin/users/{engineer_id}/sessions/{sessions[0]['id']}", headers=security)
    assert one.status_code == 200
    assert len(client.get(f"/admin/users/{engineer_id}/sessions", headers=security).json()) == 1
    assert client.delete(f"/admin/users/{engineer_id}/sessions/nope", headers=security).status_code == 404
    blocked = client.post(f"/admin/users/{engineer_id}/block", headers=security)
    assert blocked.status_code == 200 and blocked.json()["status"] == "blocked" and blocked.json()["active_sessions"] == 0
    for tokens in (phone, tablet):
        assert client.get("/auth/me", headers=bearer(tokens)).status_code == 401
        assert client.post("/auth/refresh", json={"refresh_token": tokens["refresh_token"]}).status_code == 401
    denied = client.post("/auth/login", json={"email": EMAILS["engineer"], "password": PASSWORD})
    assert denied.status_code == 403
    assert denied.json()["detail"] == "Учётная запись заблокирована. Обратитесь к администратору ИБ"
    wrong = client.post("/auth/login", json={"email": EMAILS["engineer"], "password": "мимо"})
    assert wrong.status_code == 401 and wrong.json()["detail"] == "Неверная почта или пароль"
    listed = client.get("/admin/users", headers=security, params={"status": "blocked"}).json()
    assert [entry["email"] for entry in listed] == [EMAILS["engineer"]]
    assert [entry["email"] for entry in client.get("/admin/users", headers=security, params={"q": "смирнов"}).json()] == [
        EMAILS["engineer"]]
    assert {entry["role"] for entry in client.get("/admin/users", headers=security, params={"role": "master"}).json()} == {
        "master"}
    attempts = events(client, security, event="login_blocked")
    assert attempts[0]["target_user"]["email"] == EMAILS["engineer"]
    assert client.post(f"/admin/users/{engineer_id}/unblock", headers=security).json()["status"] == "active"
    assert sign_in(client, EMAILS["engineer"])["user"]["id"] == engineer_id


def test_temporary_password_flow(client):
    """Временный пароль: только смена пароля, выход и сведения о себе до смены; после смены - обычная работа."""
    security = bearer(sign_in(client, EMAILS["security"]))
    old = sign_in(client, EMAILS["engineer"])
    reset = client.post(f"/admin/users/{old['user']['id']}/reset-password", headers=security)
    assert reset.status_code == 200 and reset.json()["user"]["must_change_password"] is True
    temporary = reset.json()["temporary_password"]
    assert len(temporary) >= 12 and any(ch.isdigit() for ch in temporary) and any(ch.isalpha() for ch in temporary)
    assert client.get("/auth/me", headers=bearer(old)).status_code == 401
    assert client.post("/auth/login", json={"email": EMAILS["engineer"], "password": PASSWORD}).status_code == 401
    tokens = sign_in(client, EMAILS["engineer"], temporary)
    head = bearer(tokens)
    assert tokens["must_change_password"] is True and tokens["user"]["must_change_password"] is True
    for method, path in (("GET", "/equipment"), ("POST", "/inspections"), ("GET", "/notifications"),
                         ("GET", "/tasks/my")):
        gated = client.request(method, path, headers=head, json={"equipment_id": "AMS-1"})
        assert gated.status_code == 403 and gated.json()["detail"] == "Требуется сменить временный пароль", path
    assert client.get("/auth/me", headers=head).json()["must_change_password"] is True
    with client.websocket_connect(f"/ws/detect?token={tokens['access_token']}") as socket:
        assert socket.receive_json()["detail"] == "Требуется сменить временный пароль"
    wrong = client.post("/auth/password", headers=head, json={"current_password": "мимо", "new_password": FRESH})
    assert wrong.status_code == 400
    weak = {"short1": "не короче 10", "onlyletterslong": "и буквы, и цифры", "1234567890123": "и буквы, и цифры",
            temporary: "отличаться от текущего"}
    for candidate, reason in weak.items():
        refused = client.post("/auth/password", headers=head, json={"current_password": temporary, "new_password": candidate})
        assert refused.status_code == 422 and reason in refused.json()["detail"], candidate
    done = client.post("/auth/password", headers=head, json={"current_password": temporary, "new_password": FRESH})
    assert done.status_code == 200 and done.json()["user"]["must_change_password"] is False
    assert client.get("/equipment", headers=head).status_code == 200
    assert sign_in(client, EMAILS["engineer"], FRESH)["must_change_password"] is False
    second = sign_in(client, EMAILS["master"])
    assert client.post("/auth/logout", headers=bearer(second)).status_code == 200


def test_password_change_closes_other_sessions(client):
    """Смена пароля оставляет текущий сеанс и закрывает остальные сеансы того же сотрудника."""
    phone, tablet = sign_in(client, EMAILS["master"]), sign_in(client, EMAILS["master"])
    changed = client.post("/auth/password", headers=bearer(phone), json={"current_password": PASSWORD, "new_password": FRESH})
    assert changed.status_code == 200
    assert client.get("/auth/me", headers=bearer(phone)).status_code == 200
    assert client.get("/auth/me", headers=bearer(tablet)).status_code == 401


def test_policy_enforced(client):
    """Политика из базы: длина пароля, порог блокировки входа, срок сеанса и запрет входа по биометрии."""
    security = bearer(sign_in(client, EMAILS["security"]))
    policy = client.get("/admin/policy", headers=security).json()
    assert {key: policy[key] for key in ("min_password_length", "require_letters_digits", "lockout_attempts",
                                         "lockout_minutes", "session_hours", "biometrics_allowed")} == {
        "min_password_length": 10, "require_letters_digits": True, "lockout_attempts": 10, "lockout_minutes": 5,
        "session_hours": 720, "biometrics_allowed": True}
    assert client.patch("/admin/policy", headers=security, json={"lockout_attempts": 1}).status_code == 422
    master = bearer(sign_in(client, EMAILS["master"]))
    assert client.patch("/admin/policy", headers=master, json={"min_password_length": 6}).status_code == 403
    updated = client.patch("/admin/policy", headers=security, json={
        "min_password_length": 16, "lockout_attempts": 3, "lockout_minutes": 1, "biometrics_allowed": False})
    assert updated.status_code == 200 and updated.json()["updated_by_id"] is not None
    engineer = sign_in(client, EMAILS["engineer"])
    assert engineer["biometrics_allowed"] is False
    short = client.post("/auth/password", headers=bearer(engineer), json={"current_password": PASSWORD, "new_password": FRESH})
    assert short.status_code == 422 and "не короче 16" in short.json()["detail"]
    for _ in range(3):
        assert client.post("/auth/login", json={"email": EMAILS["operator"], "password": "мимо"}).status_code == 401
    locked = client.post("/auth/login", json={"email": EMAILS["operator"], "password": PASSWORD})
    assert locked.status_code == 429 and int(locked.headers["retry-after"]) <= 61
    assert events(client, security, event="login_locked")[0]["email"] == EMAILS["operator"]
    biometric = client.post("/auth/refresh", json={"refresh_token": engineer["refresh_token"], "biometric": True})
    assert biometric.status_code == 403 and "биометрии" in biometric.json()["detail"]
    renewed = client.post("/auth/refresh", json={"refresh_token": engineer["refresh_token"]})
    assert renewed.status_code == 200
    client.patch("/admin/policy", headers=security, json={"session_hours": 1})
    stale = renewed.json()["refresh_token"]
    payload = jwt.decode(stale, SECRET, algorithms=["HS256"]) | {"auth_time": payload_time(stale) - 7200}
    aged = jwt.encode(payload, SECRET, algorithm="HS256")
    with db.SessionLocal() as session:
        token = session.scalar(select(RefreshToken).where(RefreshToken.token_hash == hashlib.sha256(stale.encode()).hexdigest()))
        token.token_hash = hashlib.sha256(aged.encode()).hexdigest()
        session.commit()
    expired = client.post("/auth/refresh", json={"refresh_token": aged})
    assert expired.status_code == 401 and "Срок сеанса истёк" in expired.json()["detail"]
    fresh = sign_in(client, EMAILS["master"])
    lifetime = jwt.decode(fresh["refresh_token"], SECRET, algorithms=["HS256"])
    assert lifetime["exp"] - lifetime["auth_time"] == 3600


def payload_time(token):
    """Момент входа по паролю, записанный в токене."""
    return jwt.decode(token, SECRET, algorithms=["HS256"])["auth_time"]


def test_security_log(client):
    """Журнал фиксирует входы, действия с учётными записями, ролями и политикой: кто, когда, над кем, подробности."""
    security = bearer(sign_in(client, EMAILS["security"]))
    client.post("/auth/login", json={"email": EMAILS["master"], "password": "мимо"})
    client.post("/auth/login", json={"email": "nobody@kst.demo", "password": "мимо"})
    user, temporary = create_user(client, security, "log@kst.demo", "operator", "Журнальный")
    client.post(f"/admin/users/{user['id']}/role", headers=security, json={"role": "engineer"})
    client.post(f"/admin/users/{user['id']}/block", headers=security)
    client.post(f"/admin/users/{user['id']}/unblock", headers=security)
    client.post(f"/admin/users/{user['id']}/reset-password", headers=security)
    client.post("/admin/roles", headers=security, json={"code": "auditor", "title": "Аудитор", "permissions": []})
    client.patch("/admin/roles/auditor", headers=security, json={"permissions": ["security.log"]})
    client.delete("/admin/roles/auditor", headers=security)
    client.patch("/admin/policy", headers=security, json={"session_hours": 24})
    engineer = sign_in(client, EMAILS["engineer"])
    client.post("/auth/password", headers=bearer(engineer), json={"current_password": PASSWORD, "new_password": FRESH})
    log = events(client, security)
    seen = {entry["event"] for entry in log}
    assert {"login_success", "login_failure", "user_created", "user_role_changed", "user_blocked", "user_unblocked",
            "password_reset", "role_created", "role_updated", "role_deleted", "policy_changed",
            "password_changed"} <= seen
    assert [entry["at"] for entry in log] == sorted((entry["at"] for entry in log), reverse=True)
    changed = events(client, security, event="user_role_changed")[0]
    assert changed["title"] == "Изменена роль сотрудника" and changed["actor"]["email"] == EMAILS["security"]
    assert changed["target_user"]["email"] == "log@kst.demo" and changed["details"] == {"from": "operator", "to": "engineer"}
    failures = events(client, security, event="login_failure")
    assert {entry["email"] for entry in failures} == {EMAILS["master"], "nobody@kst.demo"}
    assert all(entry["actor"] is None for entry in failures)
    edited = events(client, security, event="role_updated")[0]
    assert edited["target_role"] == "auditor" and edited["details"]["added"] == ["security.log"]
    assert events(client, security, event="policy_changed")[0]["details"] == {"session_hours": [720, 24]}
    mine = events(client, security, user_id=user["id"])
    assert mine and all(user["id"] in (entry["target_user"] or {}).values() for entry in mine)
    assert temporary not in str(log)
    assert client.get("/admin/security-log", headers=security, params={"event": "nope"}).status_code == 422
    assert {entry["code"] for entry in client.get("/admin/security-log/events", headers=security).json()} >= seen
    with db.SessionLocal() as session:
        assert session.scalar(select(SecurityEvent).where(SecurityEvent.event == "user_created")).details["role"] == "operator"


def test_user_creation_validation(client):
    """Новая учётная запись: проверка почты и роли, повтор почты - 409, временный пароль не хранится открыто."""
    security = bearer(sign_in(client, EMAILS["security"]))
    assert client.post("/admin/users", headers=security,
                       json={"email": "без-собаки", "name": "Х", "role": "engineer"}).status_code == 422
    assert client.post("/admin/users", headers=security,
                       json={"email": "x@kst.demo", "name": "Х", "role": "boss"}).status_code == 422
    assert client.post("/admin/users", headers=security,
                       json={"email": EMAILS["master"].upper(), "name": "Х", "role": "engineer"}).status_code == 409
    user, temporary = create_user(client, security, " New.Person@KST.demo ", "engineer", "  Пётр   Петров ")
    assert user["email"] == "new.person@kst.demo" and user["name"] == "Пётр Петров" and user["must_change_password"]
    with db.SessionLocal() as session:
        stored = session.get(User, user["id"]).password_hash
    assert temporary not in stored and auth.verify_password(temporary, stored)
    assert client.get(f"/admin/users/{user['id']}", headers=security).json()["email"] == "new.person@kst.demo"
    assert client.get("/admin/users/99999", headers=security).status_code == 404


def test_system_status_for_admin(client):
    """Администратор системы видит состояние сервера, базы и моделей, но не учётные записи."""
    admin = bearer(sign_in(client, EMAILS["admin"]))
    status = client.get("/system/status", headers=admin).json()
    assert status["database"]["file"] == "kst.db" and status["database"]["equipment"] == 5
    assert status["users"]["total"] == 5 and status["detector"] is None
    assert client.get("/admin/users", headers=admin).status_code == 403


def test_fault_report_task_notification_flow(client):
    """Оператор сообщает о шуме, мастер назначает инженера, инженер осматривает - задание и сообщение закрываются."""
    headers = headers_for(client)
    engineer_id = client.get("/auth/me", headers=headers["engineer"]).json()["id"]
    operator_id = client.get("/auth/me", headers=headers["operator"]).json()["id"]
    assert [entry["title"] for entry in client.get("/fault-reports/signs", headers=headers["operator"]).json()] == [
        "Шум", "Вибрация", "Течь", "Запах гари", "Нагрев", "Другое"]
    unknown = client.post("/fault-reports", headers=headers["operator"], json={"equipment_id": "AMS-1", "signs": ["скрип"]})
    assert unknown.status_code == 422 and "запах гари" in unknown.json()["detail"]
    vague = client.post("/fault-reports", headers=headers["operator"], json={"equipment_id": "AMS-1", "signs": ["другое"]})
    assert vague.status_code == 422
    assert client.post("/fault-reports", headers=headers["operator"],
                       json={"equipment_id": "НЕТ", "signs": ["шум"]}).status_code == 404
    sent = client.post("/fault-reports", headers=headers["operator"], json={
        "equipment_id": "AMS-1", "signs": ["Шум", "vibration", "шум"], "comment": "Гул со стороны редуктора"})
    assert sent.status_code == 201, sent.text
    report = sent.json()
    assert [sign["code"] for sign in report["signs"]] == ["noise", "vibration"] and report["status"] == "new"
    assert report["author"]["name"] == "Ольга Кузнецова"
    feed = client.get("/notifications", headers=headers["master"]).json()
    assert feed[0]["kind"] == "fault_report_new" and feed[0]["fault_report_id"] == report["id"]
    assert "шум, вибрация" in feed[0]["text"]
    assert client.get("/notifications", headers=headers["engineer"]).json() == []
    assert [entry["id"] for entry in client.get("/fault-reports", headers=headers["master"],
                                                params={"status": "new"}).json()] == [report["id"]]
    assert client.post("/tasks", headers=headers["master"], json={
        "equipment_id": "AMS-1", "assignee_id": operator_id, "reason": "Проверить"}).status_code == 422
    assert client.post("/tasks", headers=headers["master"], json={
        "equipment_id": "AMS-2", "assignee_id": engineer_id, "reason": "Проверить",
        "fault_report_id": report["id"]}).status_code == 422
    due = (date.today() + timedelta(days=1)).isoformat()
    created = client.post("/tasks", headers=headers["master"], json={
        "equipment_id": "AMS-1", "assignee_id": engineer_id, "reason": "Шум и вибрация по сообщению оператора",
        "fault_report_id": report["id"], "priority": "high", "due_date": due})
    assert created.status_code == 201, created.text
    task = created.json()
    assert task["status"] == "open" and task["priority_title"] == "Высокая" and task["due_date"] == due
    assert task["fault_report"]["status"] == "assigned" and task["overdue"] is False
    mine = client.get("/tasks/my", headers=headers["engineer"]).json()
    assert [entry["id"] for entry in mine] == [task["id"]]
    engineer_feed = client.get("/notifications", headers=headers["engineer"]).json()
    assert engineer_feed[0]["kind"] == "task_assigned" and engineer_feed[0]["task_id"] == task["id"]
    operator_feed = client.get("/notifications", headers=headers["operator"]).json()
    assert operator_feed[0]["kind"] == "fault_report_status" and operator_feed[0]["status"] == "assigned"
    assert client.get(f"/fault-reports/{report['id']}", headers=headers["operator"]).json()["task_id"] == task["id"]
    assert client.get(f"/tasks/{task['id']}", headers=headers["operator"]).status_code == 403
    by_master = client.post("/inspections", headers=headers["master"], json={"equipment_id": "AMS-1"}).json()
    client.post(f"/inspections/{by_master['id']}/finish", headers=headers["master"])
    assert client.get(f"/tasks/{task['id']}", headers=headers["engineer"]).json()["status"] == "open"
    inspection = client.post("/inspections", headers=headers["engineer"], json={"equipment_id": "AMS-1"}).json()
    assert client.post(f"/inspections/{inspection['id']}/finish", headers=headers["engineer"]).status_code == 200
    assert client.get("/tasks/my", headers=headers["engineer"]).json() == []
    done = client.get("/tasks/my", headers=headers["engineer"], params={"status": "done"}).json()
    assert done[0]["inspection_id"] == inspection["id"] and done[0]["closed_at"]
    closed = client.get("/fault-reports/my", headers=headers["operator"]).json()[0]
    assert closed["status"] == "inspected" and str(inspection["id"]) in closed["status_comment"]
    kinds = {entry["kind"]: entry for entry in client.get("/notifications", headers=headers["operator"]).json()}
    assert kinds["fault_report_status"]["status"] == "inspected"
    master_feed = client.get("/notifications", headers=headers["master"]).json()
    assert any(entry["kind"] == "task_done" and entry["inspection_id"] == inspection["id"] for entry in master_feed)
    assert not any(entry["kind"] == "fault_report_new" for entry in master_feed)
    later = client.get("/notifications", headers=headers["master"], params={"since": "2999-01-01T00:00:00"}).json()
    assert later == []


def test_task_cancel_and_report_reject(client):
    """Отмена задания возвращает сообщение в новые; отклонённое сообщение видно оператору с пояснением."""
    headers = headers_for(client)
    engineer_id = client.get("/auth/me", headers=headers["engineer"]).json()["id"]
    first = client.post("/fault-reports", headers=headers["operator"],
                        json={"equipment_id": "AMS-2", "signs": ["течь"]}).json()
    task = client.post("/tasks", headers=headers["master"], json={
        "equipment_id": "AMS-2", "assignee_id": engineer_id, "reason": "Течь", "fault_report_id": first["id"]}).json()
    cancelled = client.post(f"/tasks/{task['id']}/cancel", headers=headers["master"], json={"comment": "Ошибочно"})
    assert cancelled.status_code == 200 and cancelled.json()["status"] == "cancelled"
    assert client.post(f"/tasks/{task['id']}/cancel", headers=headers["master"], json={}).status_code == 409
    assert client.get(f"/fault-reports/{first['id']}", headers=headers["master"]).json()["status"] == "new"
    kinds = [entry["kind"] for entry in client.get("/notifications", headers=headers["engineer"]).json()]
    assert "task_cancelled" in kinds
    rejected = client.post(f"/fault-reports/{first['id']}/reject", headers=headers["master"],
                           json={"comment": "Течь устранена при ТО"})
    assert rejected.status_code == 200 and rejected.json()["status_title"] == "Отклонено"
    assert client.post(f"/fault-reports/{first['id']}/reject", headers=headers["master"], json={}).status_code == 409
    assert client.post("/tasks", headers=headers["master"], json={
        "equipment_id": "AMS-2", "assignee_id": engineer_id, "reason": "-", "fault_report_id": first["id"]}).status_code == 409
    feed = client.get("/notifications", headers=headers["operator"]).json()
    assert feed[0]["status"] == "rejected" and "Течь устранена при ТО" in feed[0]["text"]
    assert client.get(f"/fault-reports/{first['id']}", headers=headers["engineer"]).status_code == 403


OLD_SCHEMA = """
CREATE TABLE users (id INTEGER NOT NULL, email VARCHAR(254) NOT NULL, name VARCHAR(120) NOT NULL,
    role VARCHAR(16) NOT NULL, password_hash VARCHAR(255) NOT NULL, PRIMARY KEY (id),
    CONSTRAINT ck_users_role CHECK (role IN ('engineer', 'master', 'admin')), UNIQUE (email));
CREATE TABLE refresh_tokens (id INTEGER NOT NULL, user_id INTEGER NOT NULL, token_hash VARCHAR(64) NOT NULL,
    family VARCHAR(32) NOT NULL, device VARCHAR(120), created_at DATETIME NOT NULL, revoked BOOLEAN NOT NULL,
    PRIMARY KEY (id), FOREIGN KEY(user_id) REFERENCES users (id), UNIQUE (token_hash));
"""


def test_old_database_is_migrated_in_place(tmp_path, monkeypatch):
    """База прежней схемы переводится на месте: сотрудники, их пароли и сеансы сохраняются, роли становятся данными."""
    path = tmp_path / "old.db"
    monkeypatch.setenv("KST_DB", str(path))
    monkeypatch.setattr(auth, "SCRYPT_N", 2**10)
    stored = auth.hash_password("старый-пароль-1")
    with sqlite3.connect(path) as connection:
        connection.executescript(OLD_SCHEMA)
        connection.executemany("INSERT INTO users VALUES (?, ?, ?, ?, ?)", [
            (1, "engineer@kst.demo", "Алексей Смирнов", "engineer", stored),
            (2, "master@kst.demo", "Марина Орлова", "master", stored),
            (7, "admin@kst.demo", "Игорь Власов", "admin", stored)])
        connection.execute("INSERT INTO refresh_tokens VALUES (1, 7, 'h', 'f', 'Телефон', '2026-11-01 10:00:00', 0)")
    forget_caches()
    try:
        db.init_db()
        with db.SessionLocal() as session:
            seeding.seed(session)
            users = {user.email: user for user in session.scalars(select(User))}
            assert users["admin@kst.demo"].id == 7 and users["admin@kst.demo"].password_hash == stored
            assert users["admin@kst.demo"].role_info.title == "Администратор системы"
            assert all(user.is_active and not user.must_change_password for user in users.values())
            assert {"operator@kst.demo", "security@kst.demo"} <= set(users)
            assert session.scalar(select(RefreshToken)).user_id == 7
            assert {role.code for role in session.scalars(select(Role))} == set(SYSTEM_ROLES)
            session.add(Role(code="custom", title="Своя роль", permissions=["equipment.view"]))
            session.flush()
            users["engineer@kst.demo"].role = "custom"
            session.commit()
        with sqlite3.connect(path) as connection:
            assert not migrate.needs_upgrade(connection)
            assert connection.execute("PRAGMA foreign_key_check").fetchall() == []
            assert "CHECK" not in connection.execute("SELECT sql FROM sqlite_master WHERE name = 'users'").fetchone()[0]
        db.init_db()
        with db.SessionLocal() as session:
            assert session.get(User, 1).role == "custom"
    finally:
        db.engine.dispose()
        forget_caches()
