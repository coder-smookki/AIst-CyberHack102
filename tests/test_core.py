"""Проверки ядра сервера: вход и токены, права по ролям, оборудование, история агрегата, начальное наполнение базы."""
import hashlib
import json
import shutil
import stat
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import func, select, text
from sqlalchemy.exc import IntegrityError

from server import auth, config, db, equipment
from server import seed as seeding
from server.models import (
    FINDING_SOURCES,
    FINDING_STATUSES,
    INSPECTION_STATUSES,
    Equipment,
    Finding,
    Inspection,
    MaintenanceRecord,
    Node,
    RefreshToken,
    Role,
    User,
)
from server.seed import DEMO_HISTORY, DEMO_PASSWORD, DEMO_USERS, seed

SECRET = "k" * 48
TABLES = (User, RefreshToken, Equipment, Node, Inspection, Finding, MaintenanceRecord)


def forget_cached_hashes():
    """Сбрасывает запомненные хэши и счётчик неудачных входов, чтобы проверки не влияли друг на друга."""
    seeding._demo_hash.cache_clear()
    auth._decoy_hash.cache_clear()
    auth._failures.clear()


@pytest.fixture(scope="module")
def seeded_database(tmp_path_factory):
    """Один раз создаёт базу с начальными данными; каждая проверка работает со своей копией этого файла.

    Стоимость хэша пароля здесь снижена, чтобы проверки шли быстро; боевые параметры проверяет отдельный тест.
    """
    path = tmp_path_factory.mktemp("seeded") / "kst.db"
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("KST_DB", str(path))
        patch.setattr(auth, "SCRYPT_N", 2**10)
        forget_cached_hashes()
        db.init_db()
        with db.SessionLocal() as session:
            seed(session)
        db.engine.dispose()
        forget_cached_hashes()
    return path


@pytest.fixture
def client(seeded_database, tmp_path, monkeypatch):
    """Приложение с маршрутами входа и оборудования на отдельной временной базе с начальными данными."""
    shutil.copyfile(seeded_database, tmp_path / "kst.db")
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    monkeypatch.setenv("KST_SECRET", SECRET)
    monkeypatch.setattr(auth, "SCRYPT_N", 2**10)
    forget_cached_hashes()
    db.init_db()
    app = FastAPI(docs_url=None, redoc_url=None)
    app.include_router(auth.router)
    app.include_router(equipment.router)
    with TestClient(app) as test_client:
        yield test_client
    db.engine.dispose()
    forget_cached_hashes()


def sign_in(client, role="engineer"):
    """Входит демонстрационным сотрудником с нужной ролью и возвращает ответ сервера с токенами."""
    response = client.post("/auth/login", json={"email": f"{role}@kst.demo", "password": DEMO_PASSWORD})
    assert response.status_code == 200, response.text
    return response.json()


def bearer(tokens):
    """Собирает заголовок с токеном доступа."""
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def reissued(token, secret=SECRET, **changes):
    """Перевыпускает токен с изменёнными полями или другим секретом - так получаются просроченные и чужие токены."""
    payload = jwt.decode(token, SECRET, algorithms=["HS256"]) | changes
    return jwt.encode(payload, secret, algorithm="HS256")


def table_counts():
    """Считает строки во всех таблицах базы."""
    with db.SessionLocal() as session:
        return {model.__tablename__: session.scalar(select(func.count()).select_from(model)) for model in TABLES}


def cards_from_file():
    """Читает карточки оборудования из data/equipment.json."""
    with open(config.EQUIPMENT_FILE, encoding="utf-8") as file:
        return json.load(file)["equipment"]


def test_password_hash_roundtrip():
    """Хэш пароля каждый раз новый из-за соли, проверяется только верным паролем и не содержит сам пароль."""
    first, second = auth.hash_password("Пароль-123"), auth.hash_password("Пароль-123")
    assert first != second
    assert first.startswith("scrypt$32768$8$1$") and "Пароль" not in first
    assert auth.verify_password("Пароль-123", first)
    assert not auth.verify_password("пароль-123", first)
    assert not auth.verify_password("Пароль-123", "")
    assert not auth.verify_password("Пароль-123", "scrypt$32768$8$1$не-base64$тоже")
    assert not auth.verify_password("Пароль-123", first.replace("scrypt$", "md5$", 1))


def test_login_success(client):
    """Вход по почте и паролю выдаёт пару токенов и данные сотрудника; в базе лежит только хэш токена обновления."""
    form = {"email": "  Engineer@KST.demo ", "password": DEMO_PASSWORD, "device": "Тестовый телефон"}
    response = client.post("/auth/login", json=form)
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"access_token", "refresh_token", "token_type", "expires_in", "user", "must_change_password",
                         "permissions", "biometrics_allowed"}
    assert body["token_type"] == "bearer" and body["expires_in"] == 30 * 60
    assert body["must_change_password"] is False and body["biometrics_allowed"] is True
    assert body["permissions"] == ["inspect.run", "findings.view", "findings.create", "equipment.view", "telemetry.view",
                                   "reports.own", "assistant.use"]
    assert body["user"] == {"id": body["user"]["id"], "email": "engineer@kst.demo", "name": DEMO_USERS[0][1],
                            "role": "engineer", "role_title": "инженер", "permissions": body["permissions"],
                            "must_change_password": False}
    assert client.get("/auth/me", headers=bearer(body)).json() == body["user"]
    access = jwt.decode(body["access_token"], SECRET, algorithms=["HS256"])
    renewal = jwt.decode(body["refresh_token"], SECRET, algorithms=["HS256"])
    assert access["typ"] == "access" and access["exp"] - access["iat"] == 30 * 60
    assert renewal["typ"] == "refresh" and renewal["exp"] - renewal["iat"] == 30 * 24 * 3600
    with db.SessionLocal() as session:
        stored = session.scalars(select(RefreshToken)).one()
        assert stored.token_hash == hashlib.sha256(body["refresh_token"].encode()).hexdigest()
        assert stored.device == "Тестовый телефон" and stored.revoked is False and stored.user_id == body["user"]["id"]
        assert session.get(User, stored.user_id).password_hash.startswith("scrypt$")


def test_login_failure(client):
    """Неверный пароль и неизвестная почта дают одинаковый отказ 401, сеанс при этом не создаётся."""
    wrong = client.post("/auth/login", json={"email": "engineer@kst.demo", "password": "demo12346"})
    unknown = client.post("/auth/login", json={"email": "nobody@kst.demo", "password": DEMO_PASSWORD})
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json() == unknown.json() == {"detail": "Неверная почта или пароль"}
    assert wrong.headers["www-authenticate"] == "Bearer"
    assert client.post("/auth/login", json={"email": "engineer@kst.demo"}).status_code == 422
    assert client.post("/auth/login", json={"email": "engineer@kst.demo", "password": ""}).status_code == 422
    assert table_counts()["refresh_tokens"] == 0


def test_login_throttle(client, monkeypatch):
    """После десяти неудач подряд вход для этой почты закрывается на время, даже с верным паролем, и потом открывается."""
    monkeypatch.setattr(auth, "verify_password", lambda password, stored: password == DEMO_PASSWORD)
    attempts, window = 10, 300
    for _ in range(attempts):
        assert client.post("/auth/login", json={"email": "master@kst.demo", "password": "мимо"}).status_code == 401
    blocked = client.post("/auth/login", json={"email": "master@kst.demo", "password": DEMO_PASSWORD})
    assert blocked.status_code == 429 and "Слишком много" in blocked.json()["detail"]
    assert 0 < int(blocked.headers["retry-after"]) <= window + 1
    assert client.post("/auth/login", json={"email": "admin@kst.demo", "password": DEMO_PASSWORD}).status_code == 200
    for moments in auth._failures.values():
        moments[:] = [moment - window for moment in moments]
    assert client.post("/auth/login", json={"email": "master@kst.demo", "password": DEMO_PASSWORD}).status_code == 200
    assert auth._failures == {}


def test_login_removes_expired_sessions(client):
    """При входе из базы убираются токены обновления старше срока их действия."""
    with db.SessionLocal() as session:
        user = session.scalar(select(User).where(User.email == "engineer@kst.demo"))
        old = datetime.now() - config.REFRESH_TTL - timedelta(hours=1)
        session.add(RefreshToken(user_id=user.id, token_hash="0" * 64, family="old", created_at=old, revoked=True))
        session.commit()
    sign_in(client)
    with db.SessionLocal() as session:
        assert [token.family != "old" for token in session.scalars(select(RefreshToken))] == [True]


def test_access_token_checks(client):
    """Защищённые маршруты отвечают 401 без токена, с чужой подписью, с просроченным токеном и с токеном обновления."""
    tokens = sign_in(client)
    assert client.get("/auth/me", headers=bearer(tokens)).status_code == 200
    missing = client.get("/auth/me")
    assert missing.status_code == 401 and missing.headers["www-authenticate"] == "Bearer"
    assert client.get("/equipment").status_code == 401
    still_valid = reissued(tokens["access_token"], jti="другой")
    assert client.get("/auth/me", headers={"Authorization": f"Bearer {still_valid}"}).status_code == 200
    past = int((datetime.now(UTC) - timedelta(minutes=1)).timestamp())
    rejected = [
        "not-a-token",
        tokens["refresh_token"],
        reissued(tokens["access_token"], exp=past),
        reissued(tokens["access_token"], secret="z" * 48),
        reissued(tokens["access_token"], sid="0" * 32),
        reissued(tokens["access_token"], sub="999"),
        jwt.encode({"sub": "1", "typ": "access", "exp": past + 3600}, SECRET, algorithm="HS256"),
    ]
    for token in rejected:
        assert client.get("/auth/me", headers={"Authorization": f"Bearer {token}"}).status_code == 401, token
    assert client.get("/auth/me", headers={"Authorization": f"Basic {tokens['access_token']}"}).status_code == 401


def test_refresh_rotation_and_reuse(client):
    """Обновление выдаёт новую пару и гасит старый токен; повторное предъявление старого закрывает весь сеанс."""
    first = sign_in(client)
    response = client.post("/auth/refresh", json={"refresh_token": first["refresh_token"]})
    assert response.status_code == 200
    second = response.json()
    assert second["refresh_token"] != first["refresh_token"] and second["access_token"] != first["access_token"]
    assert second["user"] == first["user"]
    assert client.get("/auth/me", headers=bearer(second)).status_code == 200
    assert client.get("/auth/me", headers=bearer(first)).status_code == 200
    with db.SessionLocal() as session:
        chain = session.scalars(select(RefreshToken).order_by(RefreshToken.id)).all()
        assert [token.revoked for token in chain] == [True, False] and chain[0].family == chain[1].family
    third = client.post("/auth/refresh", json={"refresh_token": second["refresh_token"]}).json()
    reuse = client.post("/auth/refresh", json={"refresh_token": first["refresh_token"]})
    assert reuse.status_code == 401 and "уже использован" in reuse.json()["detail"]
    assert client.post("/auth/refresh", json={"refresh_token": third["refresh_token"]}).status_code == 401
    assert client.get("/auth/me", headers=bearer(third)).status_code == 401
    with db.SessionLocal() as session:
        assert all(token.revoked for token in session.scalars(select(RefreshToken)))


def test_refresh_token_is_spent_once_under_race(client):
    """Один и тот же токен обновления, предъявленный одновременно из многих потоков, срабатывает ровно один раз."""
    tokens = sign_in(client)

    def spend(_):
        """Пробует обменять токен в отдельном сеансе базы и возвращает код исхода."""
        try:
            with db.SessionLocal() as session:
                auth.refresh(auth.RefreshBody(refresh_token=tokens["refresh_token"]), session)
        except HTTPException as error:
            return error.status_code
        return 200

    with ThreadPoolExecutor(max_workers=8) as pool:
        outcomes = sorted(pool.map(spend, range(8)))
    assert outcomes == [200] + [401] * 7


def test_refresh_rejects_wrong_tokens(client):
    """Обновление не принимает мусор, токен доступа, просроченный токен и токен с чужой подписью."""
    tokens = sign_in(client)
    past = int((datetime.now(UTC) - timedelta(minutes=1)).timestamp())
    for token in ("мусор", tokens["access_token"], reissued(tokens["refresh_token"], exp=past),
                  reissued(tokens["refresh_token"], secret="z" * 48)):
        response = client.post("/auth/refresh", json={"refresh_token": token})
        assert response.status_code == 401 and "недействителен" in response.json()["detail"], token
    assert client.post("/auth/refresh", json={}).status_code == 422
    assert client.post("/auth/refresh", json={"refresh_token": tokens["refresh_token"]}).status_code == 200


def test_logout_revokes_session(client):
    """Выход сразу гасит токен обновления и токен доступа этого сеанса, а другой сеанс того же сотрудника живёт."""
    phone, tablet = sign_in(client), sign_in(client)
    assert client.post("/auth/logout", headers=bearer(phone)).json() == {"ok": True}
    assert client.get("/auth/me", headers=bearer(phone)).status_code == 401
    assert client.post("/auth/refresh", json={"refresh_token": phone["refresh_token"]}).status_code == 401
    assert client.post("/auth/logout", headers=bearer(phone)).status_code == 401
    assert client.post("/auth/logout").status_code == 401
    assert client.get("/auth/me", headers=bearer(tablet)).status_code == 200
    assert client.post("/auth/refresh", json={"refresh_token": tablet["refresh_token"]}).status_code == 200


def test_user_from_token(client):
    """Сотрудник определяется по токену доступа и вне заголовка; токен обновления, мусор и закрытый сеанс не подходят."""
    tokens = sign_in(client, "master")
    with db.SessionLocal() as session:
        assert auth.user_from_token(session, tokens["access_token"]).email == "master@kst.demo"
        assert auth.user_from_token(session, tokens["refresh_token"]) is None
        assert auth.user_from_token(session, "мусор") is None
    client.post("/auth/logout", headers=bearer(tokens))
    with db.SessionLocal() as session:
        assert auth.user_from_token(session, tokens["access_token"]) is None


def test_role_restriction(client):
    """Режим агрегата меняет только мастер (право «Смена режима агрегата»); инженер и администратор системы - 403."""
    engineer, master, admin = (bearer(sign_in(client, role)) for role in ("engineer", "master", "admin"))
    denied = client.post("/equipment/N-101/mode", headers=engineer, json={"mode": "stopped"})
    assert denied.status_code == 403 and "Смена режима агрегата" in denied.json()["detail"]
    assert client.post("/equipment/N-101/mode", headers=admin, json={"mode": "stopped"}).status_code == 403
    assert client.get("/equipment/N-101", headers=engineer).json()["mode"] == "running"
    assert client.post("/equipment/N-101/mode", json={"mode": "stopped"}).status_code == 401
    stopped = client.post("/equipment/N-101/mode", headers=master, json={"mode": "stopped"})
    assert stopped.status_code == 200 and stopped.json()["mode"] == "stopped"
    assert client.get("/equipment/N-101", headers=engineer).json()["mode"] == "stopped"
    assert client.post("/equipment/N-101/mode", headers=master, json={"mode": "running"}).json()["mode"] == "running"
    assert client.post("/equipment/N-101/mode", headers=master, json={"mode": "paused"}).status_code == 422
    assert client.post("/equipment/NOPE/mode", headers=master, json={"mode": "stopped"}).status_code == 404
    with pytest.raises(ValueError):
        auth.require_permission("boss.rule")
    with pytest.raises(ValueError):
        auth.require_permission()


def test_equipment_list_and_filters(client):
    """Список отдаёт все агрегаты по порядку с числом незакрытых замечаний и умеет отбирать по режиму и типу."""
    head = bearer(sign_in(client))
    items = client.get("/equipment", headers=head).json()
    assert [item["id"] for item in items] == ["AMS-1", "AMS-2", "N-101", "SHU-3", "TR-1"]
    pump = items[2]
    assert pump["serial"] == "2786107-0142" and pump["mode"] == "running" and pump["run_hours"] == 19190
    assert pump["telemetry"] is True and pump["manufacturer"] == "KST DEMO PUMPS" and "nodes" not in pump
    assert {item["id"]: item["open_findings"] for item in items} == {"AMS-1": 0, "AMS-2": 1, "N-101": 1, "SHU-3": 0, "TR-1": 0}
    assert pump["last_inspection_at"] == "2026-10-27T14:05:00"
    stopped = client.get("/equipment", headers=head, params={"mode": "stopped"}).json()
    assert [item["id"] for item in stopped] == ["AMS-2"]
    screw = client.get("/equipment", headers=head, params={"type": "progressive_cavity_pump", "mode": "running"}).json()
    assert [item["id"] for item in screw] == ["AMS-1"]
    assert client.get("/equipment", headers=head, params={"type": "valve"}).json() == []
    assert client.get("/equipment", headers=head, params={"mode": "paused"}).status_code == 422


def test_equipment_search(client):
    """Поиск находит агрегат по обозначению, названию, модели, номеру и месту, не глядя на регистр и разделители."""
    head = bearer(sign_in(client))
    expected = {
        "н-101": ["N-101"], "Н101": ["N-101"], "n-101": ["N-101"], "2786107": ["N-101"], "27861070142": ["N-101"],
        "il 65/160": ["N-101"], "IL65160": ["N-101"], "kst demo pumps": ["N-101"], "kst demo": ["N-101", "SHU-3", "TR-1"], "зал 2": ["N-101"],
        "ВИНТОВОЙ №2": ["AMS-2"], "21031004-1": ["AMS-1"], "площадка винтовой": ["AMS-1", "AMS-2"],
        "насос": ["AMS-1", "AMS-2", "N-101", "SHU-3", "TR-1"], "насос зал": ["N-101"],
        "   ": ["AMS-1", "AMS-2", "N-101", "SHU-3", "TR-1"], "ТМ-400/10": ["TR-1"], "2408-0317": ["SHU-3"],
        "компрессор": [], "н-101 площадка": [],
    }
    for query, ids in expected.items():
        found = client.get("/equipment", headers=head, params={"q": query}).json()
        assert [item["id"] for item in found] == ids, query
    both = client.get("/equipment", headers=head, params={"q": "винтовой", "mode": "stopped"}).json()
    assert [item["id"] for item in both] == ["AMS-2"]
    assert client.get("/equipment", headers=head, params={"q": "я" * 101}).status_code == 422


def test_card_and_nodes_match_equipment_file(client):
    """Карточка и список узлов повторяют data/equipment.json: ничего не потеряно и не придумано."""
    head = bearer(sign_in(client))
    for source in cards_from_file():
        body = client.get(f"/equipment/{source['id']}", headers=head).json()
        for key, value in source.items():
            if key != "nodes":
                assert body[key] == value, (source["id"], key)
        assert [node["id"] for node in body["nodes"]] == [node["id"] for node in source["nodes"]]
        for got, want in zip(body["nodes"], source["nodes"]):
            assert got == {**want, "code": want["id"]}, (source["id"], want["id"])
        assert client.get(f"/equipment/{source['id']}/nodes", headers=head).json() == body["nodes"]
        with db.SessionLocal() as session:
            built = equipment.equipment_card(equipment.get_equipment(session, source["id"]))
        assert built == {**source, "nodes": [{**node, "code": node["id"]} for node in source["nodes"]]}
    assert client.get("/equipment/N-101", headers=head).json()["open_findings"] == 1
    for path in ("/equipment/NOPE", "/equipment/NOPE/nodes", "/equipment/NOPE/history"):
        missing = client.get(path, headers=head)
        assert missing.status_code == 404 and missing.json() == {"detail": "Оборудование не найдено"}


def test_by_serial(client):
    """Карточка находится по серийному номеру с шильдика, в том числе без разделителей; догадок по части номера нет."""
    head = bearer(sign_in(client))
    for serial, expected in (("2786107-0142", "N-101"), ("27861070142", "N-101"), (" 2786107 0142 ", "N-101"),
                             ("21031004-2", "AMS-2"), ("210310041", "AMS-1")):
        response = client.get(f"/equipment/by-serial/{serial}", headers=head)
        assert response.status_code == 200 and response.json()["id"] == expected, serial
        assert response.json()["nodes"]
    for serial in ("21031004", "2786107", "0000000-0000", "---"):
        response = client.get(f"/equipment/by-serial/{serial}", headers=head)
        assert response.status_code == 404 and "серийным номером" in response.json()["detail"], serial
    assert client.get("/equipment/by-serial/2786107-0142").status_code == 401


def test_history_ordering(client):
    """История агрегата идёт от новых записей к старым и объединяет осмотры с находками и записи о работах."""
    head = bearer(sign_in(client))
    events = client.get("/equipment/N-101/history", headers=head).json()
    moments = [event["at"] for event in events]
    assert moments == sorted(moments, reverse=True) and len(events) == 7
    assert [event["type"] for event in events[:3]] == ["inspection", "maintenance", "inspection"]
    latest = events[0]
    assert latest["at"] == "2026-10-27T14:05:00" and latest["status"] == "finished"
    assert latest["user"] == {"id": latest["user"]["id"], "name": DEMO_USERS[0][1], "role": "engineer", "role_title": "инженер"}
    assert latest["summary"]["duration_s"] == 26 * 60
    leak = latest["findings"][0]
    assert leak["node_code"] == "seal" and leak["node_name"] == "Торцевое уплотнение" and leak["state"] == "open"
    assert leak["evidence"][0]["source"] == "camera" and leak["has_photo"] is False and "photo_path" not in leak
    oldest = events[-1]
    assert oldest == {"type": "maintenance", "id": oldest["id"], "at": "2022-06-10T10:30:00", "kind": "replacement",
                      "node_code": "seal", "node_name": "Торцевое уплотнение", "comment": oldest["comment"],
                      "user": oldest["user"], "hours_at": 6000}
    assert oldest["user"]["role"] == "master"
    with db.SessionLocal() as session:
        user = session.scalar(select(User).where(User.email == "engineer@kst.demo"))
        moment = datetime(2026, 11, 12, 10, 0)
        session.add(MaintenanceRecord(equipment_id="N-101", node_code="flanges", kind="checked", user_id=user.id,
                                      at=moment, hours_at=19238, comment="Протечек нет"))
        session.add(Inspection(equipment_id="N-101", user_id=user.id, started_at=moment))
        session.add(Inspection(equipment_id="N-101", user_id=user.id, started_at=moment + timedelta(days=1)))
        session.add(Inspection(equipment_id="AMS-1", user_id=user.id, started_at=moment + timedelta(days=2)))
        session.commit()
    events = client.get("/equipment/N-101/history", headers=head).json()
    assert [(event["type"], event["at"]) for event in events[:4]] == [
        ("inspection", "2026-11-13T10:00:00"), ("inspection", "2026-11-12T10:00:00"),
        ("maintenance", "2026-11-12T10:00:00"), ("inspection", "2026-10-27T14:05:00")]
    assert events[0]["status"] == "active" and events[0]["finished_at"] is None and events[0]["findings"] == []
    assert {event["status"] for event in events if event["type"] == "inspection"} == set(INSPECTION_STATUSES)
    assert len(events) == 10
    newest = client.get("/equipment/N-101/history", headers=head, params={"limit": 2}).json()
    assert newest == events[:2]
    assert client.get("/equipment/N-101/history", headers=head, params={"limit": 0}).status_code == 422


def test_history_of_one_node(client):
    """История узла содержит только его работы и осмотры, где по нему есть находка; чужие находки скрыты."""
    head = bearer(sign_in(client))
    events = client.get("/equipment/N-101/history", headers=head, params={"node": "seal"}).json()
    assert [(event["type"], event["at"]) for event in events] == [
        ("inspection", "2026-10-27T14:05:00"), ("maintenance", "2022-06-10T10:30:00")]
    assert [finding["node_code"] for finding in events[0]["findings"]] == ["seal"]
    assert client.get("/equipment/N-101/history", headers=head, params={"node": "flanges"}).json() == []
    missing = client.get("/equipment/N-101/history", headers=head, params={"node": "gearbox"})
    assert missing.status_code == 404 and missing.json() == {"detail": "Узел не найден"}


def test_seed_is_idempotent(client):
    """Повторное наполнение ничего не дублирует и не затирает изменённые наработку, режим, замены и пароли."""
    before = table_counts()
    cards = cards_from_file()
    assert before["users"] == len(DEMO_USERS) == 5 and before["equipment"] == len(cards)
    assert before["nodes"] == sum(len(card["nodes"]) for card in cards)
    assert before["inspections"] == sum(len(history["inspections"]) for history in DEMO_HISTORY.values())
    assert before["maintenance_records"] == sum(len(history["maintenance"]) for history in DEMO_HISTORY.values())
    with db.SessionLocal() as session:
        pump = session.get(Equipment, "N-101")
        pump.mode, pump.run_hours = "stopped", 19250.5
        seal = session.scalar(select(Node).where(Node.equipment_id == "N-101", Node.code == "seal"))
        seal.hours, seal.replaced = 0, datetime(2026, 11, 14).date()
        session.scalar(select(User).where(User.email == "admin@kst.demo")).password_hash = "изменён"
        session.delete(session.scalar(select(Node).where(Node.equipment_id == "AMS-1", Node.code == "gearbox")))
        session.commit()
    for _ in range(2):
        with db.SessionLocal() as session:
            seed(session)
    assert table_counts() == before
    with db.SessionLocal() as session:
        pump = session.get(Equipment, "N-101")
        assert (pump.mode, pump.run_hours) == ("stopped", 19250.5)
        seal = session.scalar(select(Node).where(Node.equipment_id == "N-101", Node.code == "seal"))
        assert (seal.hours, seal.replaced.isoformat()) == (0, "2026-11-14")
        assert session.scalar(select(User).where(User.email == "admin@kst.demo")).password_hash == "изменён"
        assert session.scalar(select(Node).where(Node.equipment_id == "AMS-1", Node.code == "gearbox")).name == "Редуктор"


def test_seed_history_is_consistent(client):
    """Демонстрационная история ссылается только на существующие узлы и сотрудников и лежит в прошлом."""
    with db.SessionLocal() as session:
        codes = {(node.equipment_id, node.code) for node in session.scalars(select(Node))}
        findings = session.scalars(select(Finding)).all()
        records = session.scalars(select(MaintenanceRecord)).all()
        assert findings and records
        assert all((finding.equipment_id, finding.node_code) in codes for finding in findings)
        assert all((record.equipment_id, record.node_code) in codes for record in records if record.node_code)
        assert {finding.state for finding in findings} == {"open", "in_work", "resolved"}
        assert all(finding.status in FINDING_STATUSES and finding.source in FINDING_SOURCES for finding in findings)
        assert all(finding.severity in (1, 2, 3) for finding in findings if finding.status != "ok")
        assert all(record.at < datetime(2026, 11, 10) and record.user_id for record in records)
        for inspection in session.scalars(select(Inspection)):
            assert inspection.started_at < inspection.finished_at < datetime(2026, 11, 10)
            assert inspection.status == "finished" and inspection.summary["findings"] == len(inspection.findings)
            assert sum(inspection.summary["by_status"].values()) == len(inspection.findings)
        for card in cards_from_file():
            hours = {record.hours_at for record in records if record.equipment_id == card["id"]}
            assert all(entry["last_at_hours"] in hours for entry in card["maintenance"])


def test_seed_needs_equipment_file(client, monkeypatch, tmp_path):
    """Без файла карточек наполнение сообщает понятную ошибку."""
    monkeypatch.setattr(config, "EQUIPMENT_FILE", tmp_path / "нет.json")
    with db.SessionLocal() as session, pytest.raises(RuntimeError, match="Не найден файл карточек"):
        seed(session)


def test_database_constraints(client):
    """База не принимает неизвестные роли, режимы, состояния и виды работ, повторы и ссылки в никуда."""
    broken = [
        lambda: User(email="new@kst.demo", name="Новый", role="boss", password_hash="-"),
        lambda: User(email="engineer@kst.demo", name="Двойник", role="engineer", password_hash="-"),
        lambda: Equipment(id="X-1", name="Копия", type="pump", model="-", serial="2786107-0142", location="-",
                          mode="running", run_hours=0),
        lambda: Equipment(id="X-2", name="Насос", type="pump", model="-", serial="X-2", location="-",
                          mode="broken", run_hours=0),
        lambda: Node(equipment_id="N-101", code="seal", name="Повтор", data={}),
        lambda: Node(equipment_id="NOPE", code="seal", name="Чужой", data={}),
        lambda: Finding(inspection_id=1, equipment_id="N-101", source="manual", status="ok", title="-", state="closed"),
        lambda: Finding(inspection_id=1, equipment_id="N-101", source="manual", status="ok", title="-", severity=4),
        lambda: Finding(inspection_id=9999, equipment_id="N-101", source="manual", status="ok", title="-"),
        lambda: MaintenanceRecord(equipment_id="N-101", kind="painted"),
    ]
    for build in broken:
        with db.SessionLocal() as session:
            session.add(build())
            with pytest.raises(IntegrityError):
                session.commit()
    with db.SessionLocal() as session:
        session.add(Finding(inspection_id=1, equipment_id="N-101", source="manual", status="ok", title="Проверено"))
        session.commit()
        assert session.scalars(select(Finding).order_by(Finding.id.desc())).first().state == "open"
    with db.engine.connect() as connection:
        assert connection.execute(text("SELECT count(*) FROM findings WHERE evidence IS NULL")).scalar_one() > 0


def test_json_is_stored_readable(client):
    """Кириллица в столбцах JSON хранится как есть, чтобы по сохранённому тексту можно было искать."""
    with db.engine.connect() as connection:
        raw = connection.execute(text("SELECT data FROM equipment WHERE id = 'N-101'")).scalar_one()
    assert "Визуальный контроль уплотнений" in raw and "\\u04" not in raw


def test_secret_key_sources(tmp_path, monkeypatch):
    """Секрет подписи берётся из переменной KST_SECRET, а без неё создаётся один раз в файле рядом с базой."""
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    monkeypatch.setenv("KST_SECRET", "слишком короткий")
    with pytest.raises(RuntimeError, match="KST_SECRET"):
        config.secret_key()
    monkeypatch.setenv("KST_SECRET", SECRET)
    assert config.secret_key() == SECRET
    monkeypatch.delenv("KST_SECRET")
    generated = config.secret_key()
    stored = tmp_path / "secret.key"
    assert stored.read_text(encoding="ascii") == generated and len(generated) >= config.SECRET_MIN_LENGTH
    assert stat.S_IMODE(stored.stat().st_mode) == 0o600
    config._file_secret.cache_clear()
    assert config.secret_key() == generated


def test_database_path_follows_environment(client, tmp_path, monkeypatch):
    """Путь к базе читается из KST_DB при каждом init_db: новая база создаётся целиком, прежняя остаётся как была."""
    other = tmp_path / "вложенная папка" / "other.db"
    monkeypatch.setenv("KST_DB", str(other))
    db.init_db()
    assert table_counts() == {model.__tablename__: 0 for model in TABLES}
    assert other.is_file() and stat.S_IMODE(other.stat().st_mode) == 0o600
    db.init_db()
    with db.SessionLocal() as session:
        session.add(Role(code="engineer", title="Инженер", permissions=[]))
        session.add(User(email="new@kst.demo", name="Проверка", role="engineer", password_hash="-"))
        session.commit()
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    db.init_db()
    with db.SessionLocal() as session:
        emails = session.scalars(select(User.email).order_by(User.id)).all()
    assert emails == [email for email, _, _ in DEMO_USERS]
