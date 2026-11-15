"""Проверки ассистента веб-панели: разбор русских команд, план и подтверждение, права, сверка плана,
защита от потери управления и то, что временный пароль не попадает в журналы.

Сервер собирается целиком на копии базы, детектор подменён, стоимость хэша пароля снижена.
"""
import logging
import shutil

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from server import auth, db
from server import seed as seeding
from server.app import create_app
from server.assistant import commands
from server.inspections import service
from server.models import SecurityEvent, User
from server.telemetry_api import find_player

SECRET = "a" * 48
PASSWORD = "demo12345"
SECURITY = "security@kst.demo"
ADMIN = "admin@kst.demo"
MASTER = "master@kst.demo"
ENGINEER = "engineer@kst.demo"
OPERATOR = "operator@kst.demo"


class FakeDetector:
    """Подменный детектор: рамок нет, две модели считаются загруженными."""

    defect_classes = ("leak",)

    def detect(self, frame):
        """Возвращает пустой список рамок."""
        return []

    def info(self):
        """Состояние моделей как у настоящего детектора."""
        return {"ready": True, "loaded": True, "models": ["detector.onnx", "defects.onnx"], "missing": [], "note": None}


def forget_caches():
    """Сбрасывает запомненные хэши демонстрационных паролей и счётчик неудачных входов."""
    seeding._demo_hash.cache_clear()
    auth._decoy_hash.cache_clear()
    auth._failures.clear()


@pytest.fixture(scope="module")
def seeded_database(tmp_path_factory):
    """Один раз создаёт базу с начальными данными; каждая проверка работает со своей копией."""
    path = tmp_path_factory.mktemp("assistant") / "kst.db"
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


def headers(client, email, password=PASSWORD):
    """Заголовок авторизации сотрудника после входа по паролю."""
    response = client.post("/auth/login", json={"email": email, "password": password})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


def say(client, who, text, confirm=False, plan=None):
    """Отправляет команду ассистенту и возвращает ответ."""
    response = client.post("/webadmin/assistant", headers=who, json={"text": text, "confirm": confirm, "plan": plan})
    assert response.status_code == 200, response.text
    return response.json()


def run(client, who, text):
    """Команда с планом и подтверждение того же плана."""
    first = say(client, who, text)
    assert first["plan"] is not None, first
    assert first["done"] is False and first["result"] is None
    return first, say(client, who, text, confirm=True, plan=first["plan"])


def events(kind=None):
    """Записи журнала безопасности из текущей базы."""
    with db.SessionLocal() as session:
        query = select(SecurityEvent).order_by(SecurityEvent.id)
        if kind:
            query = query.where(SecurityEvent.event == kind)
        return [(row.event, row.details or {}, row.target_user_id) for row in session.scalars(query)]


def user_by_email(email):
    """Учётная запись из текущей базы."""
    with db.SessionLocal() as session:
        return session.scalar(select(User).where(User.email == email))


PARSING = [
    ("создай юзера Ильина Кирилла, пароль безопасный придумать", "create_user"),
    ("Создай пользователя Ильин Кирилл", "create_user"),
    ("заведи Петрову Анну мастером", "create_user"),
    ("добавь нового инженера Кирилла Ильина", "create_user"),
    ("зарегистрируй сотрудника Кузьмина Олега оператором", "create_user"),
    ("Добавь пользователя Сидорова Петра с ролью оператор", "create_user"),
    ("созадй пользователя Ильина Кирилла", "create_user"),
    ("сбрось пароль Смирнову", "reset_password"),
    ("сгенерируй новый пароль для Орловой", "reset_password"),
    ("Смирнов забыл пароль, выдай новый", "reset_password"),
    ("заблокируй Смирнова, причина: увольнение", "block_user"),
    ("забанить Орлову по причине утеря телефона", "block_user"),
    ("разблокируй Смирнова", "unblock_user"),
    ("сними блокировку с Орловой", "unblock_user"),
    ("смени роль Смирнову на мастера", "change_role"),
    ("сделай Орлову инженером", "change_role"),
    ("переведи Смирнова в мастера", "change_role"),
    ("закрой сеансы Смирнова", "close_sessions"),
    ("выкинь Смирнова из системы", "close_sessions"),
    ("у кого временные пароли", "list_temp"),
    ("кто не сменил пароль", "list_temp"),
    ("кто заблокирован", "list_blocked"),
    ("заблокированные пользователи", "list_blocked"),
    ("покажи неудачные входы за сегодня", "security_events"),
    ("последние события безопасности", "security_events"),
    ("кто входил сегодня", "security_events"),
    ("события Смирнова", "security_events"),
    ("какая политика паролей", "policy_show"),
    ("какая минимальная длина пароля", "policy_show"),
    ("сколько неудачных попыток до блокировки", "policy_show"),
    ("поставь минимальную длину пароля 12", "policy_set"),
    ("запрети вход по биометрии", "policy_set"),
    ("срок сеанса 24 часа", "policy_set"),
    ("включи перегрев обмоток на Н-101", "scenario_switch"),
    ("верни нормальный режим", "scenario_switch"),
    ("запусти сценарий кавитация", "scenario_switch"),
    ("какие сценарии есть", "scenario_switch"),
    ("перемотай время стенда на 3 часа вперёд", "move_time"),
    ("сдвинь время ленты назад на сутки", "move_time"),
    ("сделай резервную копию базы", "backup"),
    ("создай бэкап", "backup"),
    ("как сервер?", "server_state"),
    ("состояние системы", "server_state"),
    ("покажи модели", "models"),
    ("отпечаток моделей", "models"),
    ("покажи оборудование", "equipment_list"),
    ("какие агрегаты есть", "equipment_list"),
    ("открой Н-101", "open_unit"),
    ("что с N101", "open_unit"),
    ("сводка смены", "shift_summary"),
    ("как прошла смена", "shift_summary"),
    ("какие находки ждут подтверждения", "findings_pending"),
    ("новые замечания на проверку", "findings_pending"),
    ("назначь осмотр Н-101 Смирнову", "assign_task"),
    ("поручи Смирнову осмотреть Н-101 срочно", "assign_task"),
    ("что ты умеешь", "help"),
    ("помощь", "help"),
    ("открой журнал безопасности", "navigate"),
    ("покажи роли", "navigate"),
    ("перейди в профиль", "navigate"),
    ("помощь по странице политика", "page_help"),
    ("как пользоваться журналом безопасности", "page_help"),
    ("удали пользователя Смирнова", "unsupported_delete"),
]

NOT_ACTIONS = ["привет", "как дела", "сбрось базу", "покажи погоду", "спасибо", "сколько времени", "выключи свет",
               "переведи текст на английский", "напиши стих"]


@pytest.mark.parametrize("text,action", PARSING)
def test_parsing_table(text, action):
    assert commands.detect(text) == action


@pytest.mark.parametrize("text", NOT_ACTIONS)
def test_unknown_commands_trigger_nothing(text):
    assert commands.detect(text) is None


def test_backup_and_create_user_do_not_mix():
    assert commands.detect("создай резервную копию") == "backup"
    assert commands.detect("создай задание на осмотр Н-101 Смирнову") == "assign_task"


@pytest.mark.parametrize("words,expected", [
    (["Ильина", "Кирилла"], ["Ильин Кирилл"]),
    (["Кирилла", "Ильина"], ["Кирилл Ильин"]),
    (["Ильин", "Кирилл"], ["Ильин Кирилл"]),
    (["Петрову", "Анну"], ["Петрова Анна"]),
    (["Шевчука", "Кирилла"], ["Шевчук Кирилл"]),
    (["Римского-Корсакова", "Николая"], ["Римский-Корсаков Николай"]),
    (["Иванова", "Дмитрия", "Сергеевича"], ["Иванов Дмитрий Сергеевич"]),
    (["Смирновой", "Ольги"], ["Смирнова Ольга"]),
    (["Петрова", "Александра"], ["Петров Александр", "Петрова Александра"]),
    (["Сидорова", "Петра"], ["Сидоров Пётр"]),
    (["Сидоров", "Петр"], ["Сидоров Петр"]),
    (["Иванов"], []),
    (["Шоу", "Кирилла"], []),
])
def test_name_to_nominative(words, expected):
    assert commands.nominative_variants(words) == expected


def test_email_from_name():
    assert commands.email_from_name("Ильин Кирилл", "kst.demo") == "kirill.ilin@kst.demo"
    assert commands.email_from_name("Петрова Анна Сергеевна", "kst.demo") == "anna.petrova@kst.demo"


def test_create_user_full_flow_and_secret_not_logged(client, caplog):
    who = headers(client, SECURITY)
    text = "создай юзера Ильина Кирилла, пароль безопасный придумать"
    with caplog.at_level(logging.DEBUG):
        first, second = run(client, who, text)
    plan = first["plan"]
    assert plan["action"] == "create_user" and plan["danger"] is False
    assert ["Сотрудник", "Ильин Кирилл"] in plan["details"]
    assert ["Почта", "kirill.ilin@kst.demo"] in plan["details"]
    assert ["Роль", "Инженер"] in plan["details"]
    assert user_by_email("kirill.ilin@kst.demo") is not None and second["done"] is True
    secret = second["result"]["secret"]
    assert secret and len(secret) >= 12
    assert secret not in second["reply"]
    assert all(secret not in value for row in second["result"]["rows"] for value in row)
    assert secret not in caplog.text
    created = events("user_created")[-1]
    assert created[1]["via"] == "assistant" and secret not in str(events())
    assert {"label": "Пользователи", "route": "users"} in second["links"]
    login = client.post("/auth/login", json={"email": "kirill.ilin@kst.demo", "password": secret})
    assert login.status_code == 200 and login.json()["must_change_password"] is True
    again = say(client, who, text)
    assert again["plan"] is None and "уже есть" in again["reply"]


def test_create_user_with_role_and_email(client):
    who = headers(client, SECURITY)
    first, _second = run(client, who, "заведи Петрову Анну мастером, почта anna@kst.demo")
    assert ["Роль", "Мастер"] in first["plan"]["details"] and ["Почта", "anna@kst.demo"] in first["plan"]["details"]
    assert user_by_email("anna@kst.demo").role == "master" and user_by_email("anna@kst.demo").name == "Петрова Анна"


def test_ambiguous_name_asks(client):
    who = headers(client, SECURITY)
    answer = say(client, who, "создай пользователя Петрова Александра")
    assert answer["plan"] is None and answer["done"] is False
    assert "Создай пользователя Петров Александр" in answer["suggestions"]
    assert "Создай пользователя Петрова Александра" in answer["suggestions"]
    unknown = say(client, who, "создай пользователя Иванов")
    assert unknown["plan"] is None and "именительном" in unknown["reply"]


def test_nothing_executes_without_confirm(client):
    who = headers(client, SECURITY)
    before = len(events())
    for text in ("сбрось пароль Смирнову", "заблокируй Смирнова, причина: увольнение", "смени роль Смирнову на мастера",
                 "создай пользователя Ильина Кирилла", "поставь минимальную длину пароля 12"):
        answer = say(client, who, text)
        assert answer["plan"] is not None and answer["done"] is False, text
    assert len(events()) == before
    assert user_by_email(ENGINEER).is_active and user_by_email(ENGINEER).role == "engineer"


def test_reset_password(client):
    who = headers(client, SECURITY)
    first, second = run(client, who, "сбрось пароль Смирнову")
    assert first["plan"]["danger"] is True and ["Сотрудник", "Алексей Смирнов"] in first["plan"]["details"]
    secret = second["result"]["secret"]
    assert second["done"] and secret
    assert client.post("/auth/login", json={"email": ENGINEER, "password": PASSWORD}).status_code == 401
    assert client.post("/auth/login", json={"email": ENGINEER, "password": secret}).status_code == 200
    reset = events("password_reset")[-1]
    assert reset[1]["via"] == "assistant" and secret not in str(events())


def test_block_needs_reason_then_blocks_and_unblocks(client):
    who = headers(client, SECURITY)
    asked = say(client, who, "заблокируй Смирнова")
    assert asked["plan"] is None and "причин" in asked["reply"] and asked["suggestions"]
    first, second = run(client, who, "заблокируй Смирнова, причина: утеря телефона")
    assert first["plan"]["danger"] is True and ["Причина", "утеря телефона"] in first["plan"]["details"]
    assert second["done"] and not user_by_email(ENGINEER).is_active
    blocked = events("user_blocked")[-1]
    assert blocked[1]["reason"] == "утеря телефона" and blocked[1]["via"] == "assistant"
    listed = say(client, who, "кто заблокирован")
    assert listed["done"] and "Алексей Смирнов" in listed["reply"]
    first, second = run(client, who, "разблокируй Смирнова")
    assert first["plan"]["danger"] is False and second["done"] and user_by_email(ENGINEER).is_active
    assert events("user_unblocked")[-1][1]["via"] == "assistant"


def test_change_role_and_close_sessions(client):
    who = headers(client, SECURITY)
    headers(client, ENGINEER)
    first, second = run(client, who, "смени роль Смирнову на мастера")
    assert ["Новая роль", "Мастер"] in first["plan"]["details"] and second["done"]
    assert user_by_email(ENGINEER).role == "master"
    first, second = run(client, who, "закрой сеансы Смирнова")
    assert second["done"] and "Закрыто сеансов" in second["reply"]
    assert events("sessions_revoked")[-1][1]["via"] == "assistant"
    unknown = say(client, who, "смени роль Смирнову на космонавта")
    assert unknown["plan"] is None and "Мастер" in unknown["reply"]


def test_last_admin_guard_via_assistant(client):
    who = headers(client, SECURITY)
    _first, second = run(client, who, "смени роль Захарову на инженера")
    assert second["done"] is False and second["result"] is None
    assert "ни одной активной учётной записи" in second["reply"]
    assert user_by_email(SECURITY).role == "security_admin"
    own = say(client, who, "заблокируй Захарова, причина: проверка")
    assert own["plan"] is None and "собственную" in own["reply"]


def test_plan_tampering_is_refused(client):
    who = headers(client, SECURITY)
    text = "заблокируй Смирнова, причина: увольнение"
    plan = say(client, who, text)["plan"]
    for change in ({"details": [["Сотрудник", "Марина Орлова"]]}, {"action": "unblock_user"}, {"id": "0" * 16},
                   {"danger": False}):
        tampered = {**plan, **change}
        answer = say(client, who, text, confirm=True, plan=tampered)
        assert answer["done"] is False and "не совпадает" in answer["reply"] and answer["plan"] == plan
    other = say(client, who, "заблокируй Орлову, причина: увольнение", confirm=True, plan=plan)
    assert other["done"] is False and "не совпадает" in other["reply"]
    assert user_by_email(ENGINEER).is_active and user_by_email(MASTER).is_active
    assert not events("user_blocked")


def test_ambiguous_user_asks_with_suggestions(client):
    who = headers(client, SECURITY)
    run(client, who, "создай пользователя Смирнова Олега, почта oleg@kst.demo")
    answer = say(client, who, "сбрось пароль Смирнову")
    assert answer["plan"] is None and "несколько" in answer["reply"]
    assert any(ENGINEER in item for item in answer["suggestions"])
    picked = say(client, who, f"сбрось пароль {ENGINEER}")
    assert picked["plan"] and ["Почта", ENGINEER] in picked["plan"]["details"]
    nobody = say(client, who, "сбрось пароль Пупкину")
    assert nobody["plan"] is None and "Не нашёл" in nobody["reply"]


def test_lists_events_and_policy(client):
    who = headers(client, SECURITY)
    client.post("/auth/login", json={"email": ENGINEER, "password": "wrong-password1"})
    failures = say(client, who, "покажи неудачные входы за сегодня")
    assert failures["done"] and "Неудачная попытка входа" in failures["reply"]
    assert {"label": "Журнал безопасности", "route": "seclog"} in failures["links"]
    temp = say(client, who, "у кого временные пароли")
    assert temp["done"] and temp["plan"] is None
    policy = say(client, who, "какая политика паролей")
    assert policy["done"] and ["Минимальная длина пароля", "10"] in policy["result"]["rows"]
    one = say(client, who, "какая минимальная длина пароля")
    assert one["reply"] == "Минимальная длина пароля: 10."
    first, second = run(client, who, "поставь минимальную длину пароля 12")
    assert first["plan"]["danger"] is True and ["Станет", "12"] in first["plan"]["details"]
    assert second["done"] and events("policy_changed")[-1][1]["via"] == "assistant"
    wrong = say(client, who, "поставь минимальную длину пароля 3")
    assert wrong["plan"] is None and "от 6 до 128" in wrong["reply"]
    first, second = run(client, who, "запрети вход по биометрии")
    assert second["done"] and say(client, who, "вход по биометрии разрешён?")["done"]


def test_permission_refusals(client):
    master = headers(client, MASTER)
    for text in ("создай пользователя Ильина Кирилла", "сбрось пароль Смирнову", "сделай резервную копию базы",
                 "поставь минимальную длину пароля 12", "покажи неудачные входы"):
        answer = say(client, master, text)
        assert answer["plan"] is None and answer["done"] is False and answer["reply"].startswith("Не могу"), text
    security = headers(client, SECURITY)
    for text in ("включи перегрев обмоток на Н-101", "назначь осмотр Н-101 Смирнову", "сводка смены", "как сервер?"):
        answer = say(client, security, text)
        assert answer["reply"].startswith("Не могу"), text
    admin = headers(client, ADMIN)
    refused = say(client, admin, "заблокируй Смирнова, причина: увольнение")
    assert refused["reply"].startswith("Не могу") and "Управление учётными записями" in refused["reply"]
    plan = say(client, security, "заблокируй Смирнова, причина: увольнение")["plan"]
    forged = say(client, admin, "заблокируй Смирнова, причина: увольнение", confirm=True, plan=plan)
    assert forged["done"] is False and user_by_email(ENGINEER).is_active
    denied = say(client, master, "открой журнал безопасности")
    assert denied["links"] == [] and "недоступен" in denied["reply"]


def test_operator_and_engineer_can_only_ask(client):
    who = headers(client, OPERATOR)
    help_answer = say(client, who, "что ты умеешь")
    assert help_answer["done"] and "Создай пользователя" not in help_answer["reply"]
    assert say(client, who, "заблокируй Смирнова, причина: тест")["reply"].startswith("Не могу")
    assert say(client, who, "открой профиль")["links"] == [{"label": "Профиль", "route": "profile"}]


def test_unauthenticated_is_rejected(client):
    assert client.post("/webadmin/assistant", json={"text": "что ты умеешь"}).status_code == 401


def test_admin_queries_and_backup(client, tmp_path):
    who = headers(client, ADMIN)
    state = say(client, who, "как сервер?")
    assert state["done"] and state["result"]["rows"]
    assert state["links"] == [{"label": "Обзор системы", "route": "overview"}]
    models = say(client, who, "покажи модели")
    assert models["done"] and any(row[0] == "Отпечаток набора" for row in models["result"]["rows"])
    units = say(client, who, "покажи оборудование")
    assert units["done"] and "Н-101" in units["reply"]
    unit = say(client, who, "открой Н-101")
    assert unit["done"] and unit["links"][0]["route"] == "equipment"
    _first, second = run(client, who, "сделай резервную копию базы")
    assert second["done"] and (tmp_path / "backups" / second["result"]["rows"][0][1]).is_file()
    audit = events("assistant_action")[-1]
    assert audit[1]["action"] == "backup" and audit[1]["via"] == "assistant"


def test_scenario_switch_and_time(client):
    player, _ = find_player("N-101")
    if player is None:
        pytest.skip("нет баз телеметрии заказчика")
    who = headers(client, ADMIN)
    cursor = player.cursor
    try:
        first, second = run(client, who, "включи перегрев обмоток на Н-101")
        assert first["plan"]["danger"] is True
        assert ["Сценарий", "Перегрев обмоток двигателя"] in first["plan"]["details"]
        assert second["done"] and events("assistant_action")[-1][1]["scenario"] == "winding_overheat"
        first, second = run(client, who, "верни нормальный режим")
        assert ["Сценарий", "Нормальный режим"] in first["plan"]["details"] and second["done"]
        ask = say(client, who, "включи износ на Н-101")
        assert ask["plan"] is None and len(ask["suggestions"]) == 2
        listed = say(client, who, "какие сценарии есть")
        assert listed["done"] and "Кавитация" in listed["reply"]
        start = player.cursor
        first, second = run(client, who, "перемотай время стенда на 3 часа вперёд")
        assert second["done"] and (player.cursor - start).total_seconds() == 3 * 3600
        assert first["plan"]["danger"] is False
    finally:
        player.set_cursor(cursor)


def test_master_summary_pending_and_task(client):
    who = headers(client, MASTER)
    summary = say(client, who, "сводка смены")
    assert summary["done"] and "Незакрытых замечаний" in summary["reply"]
    pending = say(client, who, "какие находки ждут подтверждения")
    assert pending["done"] and pending["plan"] is None
    first, second = run(client, who, "назначь осмотр Н-101 Смирнову срочно, причина: вибрация")
    assert ["Исполнитель", "Алексей Смирнов"] in first["plan"]["details"]
    assert ["Срочность", "Срочно"] in first["plan"]["details"] and ["Причина", "вибрация"] in first["plan"]["details"]
    assert second["done"] and second["result"]["rows"][2] == ["Исполнитель", "Алексей Смирнов"]
    tasks = client.get("/tasks", headers=who).json()
    assert any(task["reason"] == "вибрация" and task["priority"] == "urgent" for task in tasks)
    assert events("assistant_action")[-1][1]["action"] == "assign_task"
    nobody = say(client, who, "назначь осмотр Н-101 Кузнецовой")
    assert nobody["plan"] is None


def test_help_navigation_and_unknown(client):
    who = headers(client, SECURITY)
    help_answer = say(client, who, "что ты умеешь")
    assert help_answer["done"] and "Создай пользователя Ильина Кирилла" in help_answer["suggestions"]
    nav = say(client, who, "открой журнал безопасности")
    assert nav["links"] == [{"label": "Журнал безопасности", "route": "seclog"}] and nav["done"]
    roles = say(client, who, "покажи роли")
    assert roles["links"] == [{"label": "Роли и права", "route": "roles"}]
    page = say(client, who, "помощь по странице политика")
    assert page["done"] and "биометрии" in page["reply"]
    unknown = say(client, who, "напиши стих")
    assert unknown["done"] is False and unknown["plan"] is None and "ничего не делаю" in unknown["reply"]
    deleting = say(client, who, "удали пользователя Смирнова")
    assert deleting["plan"] is None and "заблокировать" in deleting["reply"] and user_by_email(ENGINEER) is not None


def test_route_in_openapi(client):
    schema = client.get("/openapi.json").json()
    operation = schema["paths"]["/webadmin/assistant"]["post"]
    assert "requestBody" in operation and "200" in operation["responses"]
