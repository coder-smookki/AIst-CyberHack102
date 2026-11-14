"""Проверки помощника: вопросы об оборудовании и истории, ссылки для приложения, переход на ответ поиска при сбое модели."""
import json
import re
import shutil
from datetime import date, datetime

import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select

from server import auth, db
from server import seed as seeding
from server.assistant import deeplink, intents, llm, router, search
from server.models import Finding, Inspection, User, now
from server.seed import seed
from server.telemetry import TelemetryDataError, get_player

TODAY = date(2026, 11, 14)
NORMAL_HOUR = datetime(2026, 11, 10, 17, 0)
SECRET = "k" * 48
LLM_URL = "http://127.0.0.1:11434"
N101, AMS1, AMS2 = "kstvizor://equipment/N-101", "kstvizor://equipment/AMS-1", "kstvizor://equipment/AMS-2"
LINK_FORMS = re.compile(
    r"kstvizor://(equipment/[^/]+(/history|/node/[^/]+|/chart/[^/]+)?|inspection/\d+|finding/\d+|rule/[A-Z]\d\d|document/[^/]+)")
LAST_INSPECTION = "Когда был последний осмотр Н-101?"
MODEL_TEXT = ("Последний осмотр насоса Н-101 прошёл 27.10.2026 с 14:05 до 14:31, его выполнил инженер Алексей Смирнов. "
              "Найдено 1 замечание \u2014 следы влаги у торцевого уплотнения.")


def forget_cached_hashes():
    """Сбрасывает запомненные хэши паролей, чтобы сниженная стоимость хэша не попала в другие проверки."""
    seeding._demo_hash.cache_clear()
    auth._decoy_hash.cache_clear()


@pytest.fixture(scope="module")
def seeded_database(tmp_path_factory):
    """Один раз создаёт базу с начальными данными; каждая проверка работает со своей копией файла."""
    path = tmp_path_factory.mktemp("assistant") / "kst.db"
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
def session(seeded_database, tmp_path, monkeypatch):
    """Сеанс отдельной временной базы с начальными данными; языковая модель выключена."""
    shutil.copyfile(seeded_database, tmp_path / "kst.db")
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    monkeypatch.setenv("KST_SECRET", SECRET)
    monkeypatch.delenv("KST_LLM_URL", raising=False)
    monkeypatch.delenv("KST_LLM_MODEL", raising=False)
    db.init_db()
    with db.SessionLocal() as opened:
        yield opened
    db.engine.dispose()


@pytest.fixture(autouse=True)
def player():
    """Ставит курсор телеметрии на спокойный час, чтобы ответы не зависели от других проверок; без баз заказчика - None."""
    try:
        shared = get_player("N-101")
    except (KeyError, TelemetryDataError):
        yield None
        return
    saved = shared.cursor
    shared.set_cursor(NORMAL_HOUR)
    yield shared
    shared.set_cursor(saved)


@pytest.fixture
def telemetry(player):
    """Проигрыватель телеметрии насоса Н-101; без баз заказчика проверка пропускается."""
    if player is None:
        pytest.skip("нет баз датчиков заказчика в data/customer")
    return player


@pytest.fixture
def app(session):
    """Приложение с маршрутом помощника на временной базе."""
    application = FastAPI(docs_url=None, redoc_url=None)
    application.include_router(router)
    return application


@pytest.fixture
def client(app, session):
    """Клиент, вошедший инженером: проверка токена заменена готовой учётной записью."""
    user = session.scalar(select(User).where(User.email == "engineer@kst.demo"))
    app.dependency_overrides[auth.current_user] = lambda: user
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def model(monkeypatch):
    """Включает языковую модель и подменяет её сервер: поведение задаётся функцией, запросы запоминаются."""
    monkeypatch.setenv("KST_LLM_URL", LLM_URL)
    monkeypatch.setenv("KST_LLM_MODEL", "qwen-demo")
    state = {"requests": [], "handler": lambda request: httpx.Response(200, json={"message": {"content": MODEL_TEXT}})}

    def handle(request):
        """Запоминает запрос и отвечает так, как задано в проверке."""
        state["requests"].append(request)
        return state["handler"](request)

    monkeypatch.setattr(llm, "make_client", lambda: httpx.Client(transport=httpx.MockTransport(handle)))
    return state


def ask(session, question, equipment_id=None):
    """Задаёт вопрос помощнику напрямую, с фиксированной датой для агрегатов без телеметрии."""
    return intents.answer(session, question, equipment_id, today=TODAY)


def targets(reply):
    """Возвращает адреса ссылок ответа по порядку."""
    return [link["deeplink"] for link in reply.links]


def finding_link(session, title):
    """Возвращает ссылку на замечание с заданным названием."""
    return f"kstvizor://finding/{session.scalar(select(Finding.id).where(Finding.title == title))}"


def inspection_links(session, equipment_id):
    """Возвращает ссылки на осмотры агрегата, сначала новые."""
    found = session.scalars(select(Inspection.id).where(Inspection.equipment_id == equipment_id)
                            .order_by(Inspection.started_at.desc()))
    return [f"kstvizor://inspection/{entry}" for entry in found]


def test_history_by_unit_name(session):
    """История по названию агрегата: число осмотров и работ, события из базы, ссылки на историю и осмотры."""
    reply = ask(session, "Покажи историю насоса Н-101")
    assert reply.intent == "history" and reply.found
    assert reply.facts[0] == "Насос Н-101 (N-101): в истории 2 осмотра и 5 записей о работах."
    assert "27.10.2026 14:05 - осмотр, Алексей Смирнов (инженер): 1 замечание - Следы влаги у торцевого уплотнения" in reply.answer
    assert "25.08.2026 15:40 - обслуживание, узел «Корпус насоса и рабочее колесо»: Очаг коррозии на корпусе зачищен" in reply.answer
    assert "Наработка 18560 ч. Выполнил: Алексей Смирнов (инженер)." in reply.answer
    assert "Показаны последние 6 из 7 событий" in reply.answer
    assert "10.06.2022" not in reply.answer
    assert targets(reply) == [f"{N101}/history", *inspection_links(session, "N-101")]
    assert reply.links[0] == {"title": "История: Насос Н-101", "deeplink": f"{N101}/history", "kind": "history"}
    assert [link["kind"] for link in reply.links[1:]] == ["inspection", "inspection"]


def test_history_by_serial_number_fragment(session):
    """Агрегат находится по обрывку серийного номера, а полный номер отличает один винтовой агрегат от другого."""
    by_fragment = ask(session, "Что делали с агрегатом, серийный номер 2786107?")
    assert by_fragment.intent == "history"
    assert by_fragment.facts[0].startswith("Насос Н-101 (N-101): в истории 2 осмотра")
    assert targets(by_fragment)[0] == f"{N101}/history"
    exact = ask(session, "история агрегата 21031004-2")
    assert exact.facts[0] == "Агрегат насосный винтовой №2 (AMS-2): в истории 1 осмотр и 1 запись о работах."
    assert "15.08.2024 12:00 - замена, узел «Торцевое уплотнение»: Заменено торцевое уплотнение. Наработка 3250 ч." in exact.answer
    assert targets(exact) == [f"{AMS2}/history", *inspection_links(session, "AMS-2")]
    both = ask(session, "история по серийному номеру 21031004")
    assert targets(both)[0] == f"{AMS1}/history" and f"{AMS2}/history" in targets(both)
    assert all("N-101" not in line for line in both.facts)


def test_history_by_location(session):
    """Агрегат находится по месту установки; общее место двух агрегатов даёт историю обоих."""
    single = ask(session, "Какие работы проводились на насосе в насосной станции, зал 2?")
    assert single.intent == "history"
    assert "05.03.2024 09:00 - обслуживание: ТО-2: проверены зазор муфты" in single.answer
    assert targets(single) == [f"{N101}/history", *inspection_links(session, "N-101")]
    shared = ask(session, "История агрегатов на узле откачки")
    assert "Агрегат насосный винтовой №1 (AMS-1): в истории 1 осмотр и 2 записи о работах." in shared.facts
    assert "Агрегат насосный винтовой №2 (AMS-2): в истории 1 осмотр и 1 запись о работах." in shared.facts
    assert "06.10.2026 10:20 - осмотр, Алексей Смирнов (инженер): замечаний нет." in shared.answer
    assert targets(shared) == [f"{AMS1}/history", *inspection_links(session, "AMS-1"),
                               f"{AMS2}/history", *inspection_links(session, "AMS-2")]


def test_last_inspection(session):
    """Последний осмотр: время, исполнитель, итог и ссылки на осмотр, замечание и историю."""
    reply = ask(session, LAST_INSPECTION)
    assert reply.intent == "last_inspection"
    assert reply.facts[0] == ("Насос Н-101 (N-101): последний осмотр 27.10.2026 14:05-14:31, "
                              "выполнил Алексей Смирнов (инженер), осмотр завершён.")
    assert reply.facts[1] == "Записей осмотра: 2, из них с замечаниями - 1, без замечаний - 1."
    assert "Следы влаги у торцевого уплотнения, узел «Торцевое уплотнение», правило R01: требует проверки, открыто" in reply.facts[2]
    assert "18.08.2026" not in reply.answer
    assert targets(reply) == [inspection_links(session, "N-101")[0],
                              finding_link(session, "Следы влаги у торцевого уплотнения"), f"{N101}/history"]


def test_last_inspection_reads_fresh_records(session):
    """Ответ берётся из базы на момент вопроса: новый незавершённый осмотр становится последним."""
    engineer = session.scalar(select(User).where(User.email == "master@kst.demo"))
    fresh = Inspection(equipment_id="AMS-1", user_id=engineer.id, started_at=now(), status="active")
    session.add(fresh)
    session.commit()
    reply = ask(session, "кто проводил последний обход АМС-1")
    assert "выполнил Марина Орлова (мастер), осмотр не завершён." in reply.facts[0]
    assert reply.facts[1] == "Записей осмотра: 0, из них с замечаниями - 0, без замечаний - 0."
    assert targets(reply) == [f"kstvizor://inspection/{fresh.id}", f"{AMS1}/history"]


def test_open_findings(session):
    """Открытые замечания: по одному агрегату и по всем; устранённые и отметки «проверено» в список не попадают."""
    moisture = finding_link(session, "Следы влаги у торцевого уплотнения")
    corrosion = finding_link(session, "Коррозия рамы у анкерного болта")
    reply = ask(session, "Какие открытые замечания по Н-101?")
    assert reply.intent == "open_findings"
    assert reply.facts[0] == "Насос Н-101 (N-101): незакрытых замечаний - 1."
    assert "требует проверки, открыто, запись от 27.10.2026." in reply.facts[1]
    assert "Рекомендация: Повторно осмотреть зону уплотнения вала, проверить вибрацию и температуру подшипника." in reply.facts[1]
    assert reply.facts[2] == "Устранённых замечаний в истории агрегата: 1."
    assert "Коррозия на корпусе насоса" not in reply.answer and "замечаний нет" not in reply.answer
    assert targets(reply) == [moisture, N101]
    everywhere = ask(session, "Какие дефекты ещё не устранены?")
    assert everywhere.facts[0] == "Всего незакрытых замечаний: 2, агрегатов с замечаниями: 2 из 3."
    assert "Агрегат насосный винтовой №1 (AMS-1): незакрытых замечаний нет." in everywhere.facts
    assert "Коррозия рамы у анкерного болта, узел «Рама и анкерные болты», правило R02: требует проверки, в работе" in everywhere.answer
    assert targets(everywhere) == [corrosion, moisture, AMS1, AMS2, N101]


def test_resolved_findings_on_request(session):
    """Об устранённых замечаниях помощник отвечает отдельно; «не устранены» - это вопрос об открытых."""
    solved = finding_link(session, "Коррозия на корпусе насоса")
    reply = ask(session, "Какие замечания по Н-101 уже устранены?")
    assert reply.intent == "resolved_findings"
    assert reply.facts == ["Насос Н-101 (N-101): последние устранённые замечания - 1.",
                           "- Коррозия на корпусе насоса, узел «Корпус насоса и рабочее колесо»: признаки возможного дефекта, "
                           "устранено, запись от 18.08.2026."]
    assert targets(reply) == [solved, f"{N101}/history"]
    opened = ask(session, "Какие замечания по Н-101 ещё не устранены?")
    assert opened.intent == "open_findings" and solved not in targets(opened)
    assert ask(session, "закрытые замечания по АМС-1").facts == ["Агрегат насосный винтовой №1 (AMS-1): устранённых замечаний нет."]


def test_findings_of_named_node(session):
    """Вопрос о замечаниях по узлу отвечает только об этом узле: незакрытые, устранённые и честное «замечаний нет»."""
    corrosion = finding_link(session, "Коррозия рамы у анкерного болта")
    solved = finding_link(session, "Коррозия на корпусе насоса")
    frame = ask(session, "Есть дефекты на раме?")
    assert frame.intent == "node_findings" and frame.found
    assert frame.facts[0] == ("Агрегат насосный винтовой №2 (AMS-2), узел «Рама и анкерные болты»: "
                              "незакрытых замечаний - 1, устранённых - 0.")
    assert frame.facts[1].startswith("- Коррозия рамы у анкерного болта, правило R02: требует проверки, в работе")
    assert frame.facts[2] == "Агрегат насосный винтовой №1 (AMS-1), узел «Рама и анкерные болты»: замечаний в базе нет."
    assert "Следы влаги" not in frame.answer
    assert targets(frame) == [corrosion, f"{AMS2}/node/frame", f"{AMS1}/node/frame", f"{AMS2}/history", f"{AMS1}/history"]
    casing = ask(session, "Были ли дефекты корпуса?")
    assert casing.facts == [
        "Насос Н-101 (N-101), узел «Корпус насоса и рабочее колесо»: незакрытых замечаний - 0, устранённых - 1.",
        "- Коррозия на корпусе насоса: признаки возможного дефекта, устранено, запись от 18.08.2026."]
    assert targets(casing) == [solved, f"{N101}/node/casing", f"{N101}/history"]
    coupling = ask(session, "Покажи замечания по муфте", "N-101")
    assert coupling.facts == ["Насос Н-101 (N-101), узел «Муфта и защита муфты»: замечаний в базе нет."]
    assert targets(coupling) == [f"{N101}/node/coupling", f"{N101}/history"]


def test_resolved_finding_leaves_the_list(session):
    """После устранения замечание перестаёт быть открытым и считается устранённым."""
    finding = session.scalar(select(Finding).where(Finding.title == "Коррозия рамы у анкерного болта"))
    finding.state = "resolved"
    session.commit()
    reply = ask(session, "открытые замечания по второму винтовому агрегату")
    assert reply.facts == ["Агрегат насосный винтовой №2 (AMS-2): незакрытых замечаний нет.",
                           "Устранённых замечаний в истории агрегата: 1."]
    assert targets(reply) == [AMS2]


def test_node_state_from_sensors(session, telemetry):
    """Состояние узла: фактическое по датчикам, норматив и расчётный ресурс отдельными строками, графики параметров узла."""
    reply = ask(session, "В каком состоянии подшипники Н-101?")
    assert reply.intent == "node_state"
    assert reply.facts[0] == "Подшипники двигателя - Насос Н-101 (N-101)."
    assert reply.facts[1] == "Фактическое состояние по датчикам на 10.11.2026 17:00: отклонений по датчикам нет."
    assert reply.facts[2] == ("Показания: ВЧ шум 0,15 g - норма; СКЗ виброскорости общее 1,07 мм/с - норма; "
                              "Температура подшипника насоса 49,9 °C - норма.")
    assert reply.facts[3].startswith("Норматив: 20000 ч. Источник: Документация производителя")
    assert reply.facts[4].startswith("Расчётный ресурс: срок приближается: израсходовано 96 % (по наработке). Остаток около 801 ч")
    assert reply.facts[-1] == "Решение принимает инженер."
    assert targets(reply) == [f"{N101}/node/motor_bearings", f"{N101}/chart/vib_hf", f"{N101}/chart/vib_rms",
                              f"{N101}/chart/temp_bearing", f"{N101}/history"]
    assert reply.links[1] == {"title": "График: ВЧ шум", "deeplink": f"{N101}/chart/vib_hf", "kind": "chart"}


def test_node_state_during_bearing_wear(session, telemetry):
    """На пике износа подшипника ответ называет сработавшие правила, показания выше уставок и даёт ссылки на правила."""
    telemetry.select_scenario("bearing_wear")
    reply = ask(session, "Что с подшипниками насоса Н-101?")
    assert "Фактическое состояние по датчикам на 27.11.2026 19:00: обнаружены признаки возможного дефекта" in reply.facts[1]
    assert "Проблема смазки или износ подшипников (R08)" in reply.facts[1]
    assert "Рекомендация: Проверить смазку подшипникового узла, запланировать замену подшипника." in reply.answer
    assert "ВЧ шум 5,96 g - выше уставки тревоги" in reply.answer
    assert "Температура подшипника насоса 95,3 °C - выше уставки тревоги" in reply.answer
    assert targets(reply)[0] == f"{N101}/node/motor_bearings"
    assert "kstvizor://rule/R08" in targets(reply) and f"{N101}/chart/temp_bearing" in targets(reply)
    attention = ask(session, "Какое оборудование требует внимания?")
    assert "По датчикам на 27.11.2026 19:00: Проблема смазки или износ подшипников (правило R08)" in attention.answer
    assert attention.facts[1].startswith("Насос Н-101 (N-101), Насосная станция, зал 2, в работе")


def test_node_state_without_telemetry(session):
    """Для агрегата без датчиков помощник не выдумывает показания: говорит, что телеметрии нет, и даёт ресурс и работы."""
    reply = ask(session, "Как торцевое уплотнение на АМС-2?")
    assert reply.facts == [
        "Торцевое уплотнение - Агрегат насосный винтовой №2 (AMS-2).",
        "Фактическое состояние по датчикам: телеметрия не подключена, показаний датчиков нет.",
        "Норматив: 1 год. Источник: Инструкция, п. 8.1.5: гарантия 12 месяцев с пуска.",
        "Расчётный ресурс: срок наступил: израсходовано 224,8 % (по календарному сроку), превышение 455 сут. Оценка расчётная.",
        "Незакрытых замечаний по узлу нет.",
        "Последняя работа на узле: 15.08.2024 12:00 - замена: Заменено торцевое уплотнение. Наработка 3250 ч. "
        "Выполнил: Марина Орлова (мастер).",
    ]
    assert targets(reply) == [f"{AMS2}/node/seal", f"{AMS2}/history"]
    missing = ask(session, "что с подшипниками АМС-1")
    assert not missing.found and "узла, названного в вопросе, в карточке нет" in missing.answer
    assert "Редуктор" in missing.answer and targets(missing) == [AMS1]


def test_maintenance_due_with_run_hours_counter(session, telemetry):
    """Срок обслуживания считается от счётчика наработки телеметрии и меняется вместе с ним."""
    reply = ask(session, "Когда следующее ТО у Н-101?")
    assert reply.intent == "maintenance_due"
    assert reply.facts[0] == "Насос Н-101 (N-101): наработка 19199 ч, расчёт на 10.11.2026."
    assert reply.facts[1] == "- ТО-1: интервал 4000 ч, после последнего обслуживания 3999 ч, осталось 1 ч - срок приближается."
    assert reply.facts[2].startswith("  Состав работ: Визуальный контроль уплотнений")
    assert "- Ревизия: интервал 16000 ч, после последнего обслуживания 13199 ч, осталось 2801 ч - срок приближается." in reply.facts
    assert targets(reply) == [N101, f"{N101}/node/motor_bearings", f"{N101}/node/seal", f"{N101}/node/gauge", f"{N101}/history"]
    telemetry.select_scenario("maintenance_due")
    due = ask(session, "сколько осталось до техобслуживания Н-101")
    assert due.facts[0] == "Насос Н-101 (N-101): наработка 19200 ч, расчёт на 10.11.2026."
    assert due.facts[1] == "- ТО-1: интервал 4000 ч, после последнего обслуживания 4000 ч - срок наступил, превышение 0 ч."


def test_maintenance_due_without_schedule(session):
    """Если регламента ТО в карточке нет, помощник так и говорит и показывает узлы с ресурсом на исходе."""
    reply = ask(session, "Когда обслуживание АМС-1?")
    assert reply.facts[0] == "Агрегат насосный винтовой №1 (AMS-1): наработка 9800 ч, расчёт на 14.11.2026."
    assert reply.facts[1] == "Регламент технического обслуживания в карточке агрегата не задан."
    assert any(line.startswith("- Ресурс узла «Термопреобразователь»: срок наступил") for line in reply.facts)
    assert any(line.startswith("- Ресурс узла «Торцевое уплотнение»: срок приближается: израсходовано 95,3 %") for line in reply.facts)
    assert reply.facts[-1].startswith("Последняя запись о работах: 02.09.2026 10:10 - обслуживание, узел «Рама и анкерные болты»")
    assert targets(reply) == [AMS1, f"{AMS1}/node/unit", f"{AMS1}/node/seal", f"{AMS1}/node/temp_sensor", f"{AMS1}/history"]


def test_document_location(session):
    """Где документ: название, файл и ссылка на документ; выбирается подходящий по словам вопроса."""
    reply = ask(session, "Где паспорт насоса Н-101?")
    assert reply.intent == "document"
    assert reply.facts == ["Паспорт и инструкция по монтажу и эксплуатации - Насос Н-101 (N-101), файл "
                           "«Документация/Паспорта Насосов/Паспорт и инструкция по монтажу и эксплуатации.pdf»."]
    assert reply.links == [
        {"title": "Паспорт и инструкция по монтажу и эксплуатации", "deeplink": "kstvizor://document/wilo-passport", "kind": "document"},
        {"title": "Насос Н-101", "deeplink": N101, "kind": "equipment"}]
    manual = ask(session, "где лежит руководство по монтажу?")
    assert targets(manual)[0] == "kstvizor://document/wilo-manual" and "kstvizor://document/wilo-passport" not in targets(manual)
    second = ask(session, "паспорт второго винтового агрегата")
    assert "файл «Документация/Паспорта Насосов/1) Насос №2 ПС.pdf»" in second.answer
    assert targets(second) == ["kstvizor://document/ams-passport-2", AMS2]
    everything = ask(session, "какие документы есть по АМС-1")
    assert targets(everything) == ["kstvizor://document/ams-passport-1", "kstvizor://document/ams-manual", AMS1]


def test_rule_meaning(session):
    """Что означает правило: признаки, диагноз и рекомендация из перечня правил и ссылка на правило."""
    reply = ask(session, "Что означает правило R08?")
    assert reply.intent == "rule"
    assert reply.facts == [
        "Правило R08 «Проблема смазки или износ подшипников».",
        "Что видит камера: не требуется. Данные датчиков: вибрация и температура растут, ток в норме.",
        "Диагноз: Проблема смазки или износ подшипников: вибрация и температура подшипника растут при нормальном токе двигателя.",
        "Рекомендация: Проверить смазку подшипникового узла, запланировать замену подшипника.",
        "Узел: Подшипники двигателя. При срабатывании: признаки возможного дефекта, критичность 2 из 3.",
    ]
    assert reply.links == [{"title": "Правило R08: Проблема смазки или износ подшипников", "deeplink": "kstvizor://rule/R08", "kind": "rule"}]
    by_number = ask(session, "о чём правило №6")
    assert "Эксплуатация запрещена." in by_number.answer and targets(by_number) == ["kstvizor://rule/R06"]
    cyrillic = ask(session, "правило Р-5")
    assert "расходятся более чем на 15 %" in cyrillic.answer and targets(cyrillic) == ["kstvizor://rule/R05"]
    interval = ask(session, "что значит R11")
    assert "Диагноз: Достигнут межремонтный интервал." in interval.facts and "{" not in interval.answer
    by_words = ask(session, "Что делать при течи уплотнения?")
    assert by_words.intent == "rule" and targets(by_words)[0] == "kstvizor://rule/R01"
    assert "Рекомендация: Перевести насос в резерв." in by_words.answer
    about_unit = ask(session, "Что делать с течью уплотнения на Н-101?")
    assert about_unit.intent == "node_state" and targets(about_unit)[0] == f"{N101}/node/seal"
    assert "Незакрытое замечание: Следы влаги у торцевого уплотнения, правило R01: требует проверки, открыто" in about_unit.answer
    assert "Рекомендация: Повторно осмотреть зону уплотнения вала" in about_unit.answer
    assert finding_link(session, "Следы влаги у торцевого уплотнения") in targets(about_unit)
    listing = ask(session, "какие правила есть?")
    assert targets(listing) == [f"kstvizor://rule/R{number:02d}" for number in range(1, 13)]
    absent = ask(session, "правило R77")
    assert not absent.found and absent.facts[0] == "Правила R77 в перечне нет." and absent.links == []


def test_units_needing_attention(session):
    """Какие агрегаты требуют внимания: причины из замечаний и сроков, сначала самые срочные."""
    reply = ask(session, "Какое оборудование требует внимания?")
    assert reply.intent == "attention"
    assert reply.facts[0] == "Внимания требуют 3 из 3 агрегатов."
    assert reply.facts[1] == "Агрегат насосный винтовой №2 (AMS-2), Узел откачки, площадка 1, остановлен - 3 причины:"
    assert reply.facts[2].startswith("- Незакрытое замечание: Коррозия рамы у анкерного болта")
    assert reply.facts[3].startswith("- Ресурс узла «Торцевое уплотнение»: срок наступил: израсходовано 224,8 %")
    order = [reply.answer.index(name) for name in ("(AMS-2)", "(N-101)", "(AMS-1)")]
    assert order == sorted(order)
    assert "- Незакрытое замечание: Следы влаги у торцевого уплотнения" in reply.answer
    assert "- Ресурс узла «Термопреобразователь»: срок наступил" in reply.answer
    assert targets(reply) == [
        AMS2, N101, AMS1,
        finding_link(session, "Коррозия рамы у анкерного болта"), f"{AMS2}/node/seal", f"{AMS2}/node/unit",
        finding_link(session, "Следы влаги у торцевого уплотнения"), f"{N101}/node/motor_bearings",
        f"{AMS1}/node/temp_sensor", f"{AMS1}/node/unit", f"{AMS1}/node/seal"]
    one = ask(session, "Есть ли проблемы у AMS-1?")
    assert one.facts[0] == "Агрегат насосный винтовой №1 (AMS-1), Узел откачки, площадка 1, в работе - 3 причины:"
    assert targets(one)[0] == AMS1 and all("AMS-2" not in line and "N-101" not in line for line in one.facts)


def test_equipment_card(session):
    """Вопрос об агрегате без уточнений даёт карточку: модель, номер, место, режим и последний осмотр."""
    reply = ask(session, "Где находится второй винтовой агрегат?")
    assert reply.intent == "equipment"
    assert reply.facts[0] == ("Агрегат насосный винтовой №2 (AMS-2): модель PCP60S12/3 01 Ex B1 HNBR DTS, "
                              "серийный номер 21031004-2, производитель AMS.")
    assert reply.facts[1] == "Место установки: Узел откачки, площадка 1. Режим: остановлен. Наработка: 10650 ч."
    assert reply.facts[2] == "Последний осмотр: 15.09.2026 11:00."
    assert targets(reply)[0] == AMS2 and targets(reply)[-1] == f"{AMS2}/history"
    by_model = ask(session, "IL 65/160")
    assert by_model.facts[0].startswith("Насос Н-101 (N-101): модель IL 65/160-5,5/2, серийный номер 2786107-0142")
    state = ask(session, "В каком состоянии Н-101?")
    assert state.intent == "equipment" and state.facts[3] == "Требует внимания:"
    assert state.facts[4].startswith("- Незакрытое замечание: Следы влаги у торцевого уплотнения")
    assert ask(session, "Каково состояние оборудования?").intent == "attention"


def test_equipment_list_and_modes(session):
    """Список оборудования и вопрос о режиме: перечень из базы с местом, режимом и наработкой."""
    listing = ask(session, "Покажи список оборудования")
    assert listing.intent == "equipment_list" and listing.facts[0] == "В базе 3 единицы оборудования."
    assert "- Агрегат насосный винтовой №1 (AMS-1): Узел откачки, площадка 1, в работе, наработка 9800 ч." in listing.facts
    assert targets(listing) == [AMS1, AMS2, N101]
    stopped = ask(session, "Какие агрегаты остановлены?", "N-101")
    assert stopped.facts == ["Остановлено 1 из 3 единиц оборудования.",
                             "- Агрегат насосный винтовой №2 (AMS-2): Узел откачки, площадка 1, остановлен, наработка 10650 ч."]
    assert targets(stopped) == [AMS2]
    assert targets(ask(session, "что сейчас в работе?")) == [AMS1, N101]
    maker = ask(session, "Какой производитель у Н-101?")
    assert maker.intent == "equipment" and "производитель KST DEMO PUMPS." in maker.facts[0]


def test_unknown_unit(session):
    """Вопрос о несуществующем агрегате: честное «не нашёл» без чужой истории и список известного оборудования."""
    reply = ask(session, "История насоса Н-999")
    assert reply.intent == "unknown_equipment" and not reply.found
    assert reply.facts[0] == "Не нашёл в базе оборудование или запись с обозначением «Н-999»."
    assert reply.facts[1] == ("В базе есть: Агрегат насосный винтовой №1 (AMS-1), Агрегат насосный винтовой №2 (AMS-2), "
                              "Насос Н-101 (N-101).")
    assert "осмотр" not in reply.answer
    assert targets(reply) == [AMS1, AMS2, N101]
    with_context = ask(session, "история Н-999", "N-101")
    assert not with_context.found and "«Н-999»" in with_context.answer
    by_serial = ask(session, "последний осмотр агрегата с номером 99999999")
    assert not by_serial.found and "«99999999»" in by_serial.answer


def test_unknown_question_suggests_examples(session):
    """На вопрос не по теме помощник отвечает «не нашёл» и предлагает три примера, на каждый из которых умеет ответить."""
    reply = ask(session, "Сколько стоит биткоин?")
    assert reply.intent == "unknown" and not reply.found and reply.links == []
    assert reply.facts[0].startswith("Не нашёл ответа на этот вопрос")
    suggested = [line[2:] for line in reply.facts if line.startswith("- ")]
    assert len(suggested) == 3
    for question in suggested:
        assert ask(session, question).found, question
    for empty in ("???", "привет", "насос", "1", "101", "'; DROP TABLE users; --"):
        assert not ask(session, empty).found


@pytest.mark.parametrize("question, intent, first_link", [
    ("истроия насоса н101", "history", f"{N101}/history"),
    ("об истории насосов Н-101", "history", f"{N101}/history"),
    ("подшипнеки n-101", "node_state", f"{N101}/node/motor_bearings"),
    ("в каком сотоянии подшипниками Н-101", "node_state", f"{N101}/node/motor_bearings"),
    ("кокое оборудование требует внемания", "attention", AMS2),
    ("когда слидующее обслуживане АМС-1", "maintenance_due", AMS1),
    ("ПАСПОРТОМ НАСОСА H-101", "document", "kstvizor://document/wilo-passport"),
    ("последним осмотром первого винтового агрегата", "last_inspection", "kstvizor://inspection/3"),
])
def test_typos_and_word_endings(session, question, intent, first_link):
    """Опечатки, другие окончания, регистр и латинские буквы в обозначении не мешают понять вопрос."""
    reply = ask(session, question)
    assert reply.intent == intent and reply.found
    assert targets(reply)[0] == first_link


def test_empty_database(tmp_path, monkeypatch):
    """В пустой базе помощник не падает: об оборудовании отвечает «нет данных», о правилах - по перечню правил."""
    monkeypatch.setenv("KST_DB", str(tmp_path / "empty.db"))
    db.init_db()
    try:
        with db.SessionLocal() as empty:
            for question in ("Какое оборудование требует внимания?", "история насоса", "Сколько стоит биткоин?"):
                reply = ask(empty, question)
                assert not reply.found and reply.links == [] and reply.answer
            assert targets(ask(empty, "что означает правило R06")) == ["kstvizor://rule/R06"]
            assert not ask(empty, "история Н-101").found
    finally:
        db.engine.dispose()


def test_typo_in_findings_question(session):
    """Вопрос с двумя опечатками находит замечание нужного агрегата."""
    reply = ask(session, "откртые замечаня по агрегату №2")
    assert reply.intent == "open_findings"
    assert targets(reply) == [finding_link(session, "Коррозия рамы у анкерного болта"), AMS2]


def test_similar_word_is_not_treated_as_typo(session):
    """Обычное слово, похожее на слово из словаря, не подменяется: «находились» - не «находки»."""
    vocabulary = frozenset(("находк", "замечан", "истори"))
    assert search.parse("где находились насосы", vocabulary).stems == ["где", "находилис", "насос"]
    assert search.parse("замичания и истроия", vocabulary).stems == ["замечан", "и", "истори"]


def test_equipment_context_narrows_search(session):
    """Агрегат, открытый в приложении, подразумевается в вопросе без названия; названный в вопросе агрегат важнее."""
    corrosion = finding_link(session, "Коррозия рамы у анкерного болта")
    in_context = ask(session, "Какие открытые замечания?", "AMS-2")
    assert in_context.facts[0] == "Агрегат насосный винтовой №2 (AMS-2): незакрытых замечаний - 1."
    assert targets(in_context) == [corrosion, AMS2]
    without = ask(session, "Какие открытые замечания?")
    assert finding_link(session, "Следы влаги у торцевого уплотнения") in targets(without) and corrosion in targets(without)
    last = ask(session, "когда был последний осмотр?", "AMS-1")
    assert last.facts[0].startswith("Агрегат насосный винтовой №1 (AMS-1): последний осмотр 06.10.2026 10:20-10:38")
    assert targets(last) == [inspection_links(session, "AMS-1")[0], f"{AMS1}/history"]
    ambiguous = ask(session, "история винтового агрегата", "AMS-2")
    assert targets(ambiguous) == [f"{AMS2}/history", *inspection_links(session, "AMS-2")]
    plural = ask(session, "история агрегатов на узле откачки", "AMS-2")
    assert targets(plural)[0] == f"{AMS1}/history" and f"{AMS2}/history" in targets(plural)
    everywhere = ask(session, "Какое оборудование требует внимания?", "AMS-1")
    assert everywhere.facts[0] == "Внимания требуют 3 из 3 агрегатов." and targets(everywhere)[:3] == [AMS2, N101, AMS1]
    named = ask(session, "история Н-101", "AMS-2")
    assert targets(named)[0] == f"{N101}/history" and all("AMS-2" not in line for line in named.facts)
    seal = ask(session, "когда меняли уплотнение?", "AMS-1")
    assert "Последняя работа на узле: 01.12.2025 13:00 - замена: Заменено торцевое уплотнение." in seal.answer
    assert targets(seal) == [f"{AMS1}/node/seal", f"{AMS1}/history"]


def test_sensor_readings(session, telemetry):
    """Показание датчика: значение с единицей, оценка по уставкам, происхождение данных и ссылка на график."""
    reply = ask(session, "Какая температура подшипника на Н-101?")
    assert reply.intent == "parameter"
    assert reply.facts[0] == "Насос Н-101 (N-101), показания датчиков на 10.11.2026 17:00:"
    assert reply.facts[1] == ("- Температура подшипника насоса 49,9 °C - норма (предупреждение выше 75 °C, "
                              "тревога выше 90 °C). Источник: база заказчика.")
    assert reply.facts[2] == "Диагноз заказчика в его базе на этот час: по вибрации - «Норма»; по температуре - «Норма»."
    assert targets(reply) == [N101, f"{N101}/chart/temp_bearing"]
    inlet = ask(session, "давление на входе", "N-101")
    assert "Давление на входе 1,51 бар - норма (предупреждение ниже 1 бар, тревога ниже 0,5 бар). Источник: модельный ряд." in inlet.answer
    assert targets(inlet) == [N101, f"{N101}/chart/press_in"]
    vibration = ask(session, "покажи вибрацию")
    assert targets(vibration) == [N101, *(f"{N101}/chart/{code}" for code in ("vib_rms", "vib_1x", "vib_2x", "vib_hf", "vib_axial"))]


def test_sensor_readings_without_telemetry(session):
    """Для агрегата без датчиков показания не выдумываются."""
    reply = ask(session, "какой ток двигателя на AMS-1?")
    assert reply.facts == ["Агрегат насосный винтовой №1 (AMS-1): телеметрия не подключена, показаний датчиков нет."]
    assert targets(reply) == [AMS1]


def test_free_search_over_records(session):
    """Свободный вопрос ищется по замечаниям, работам и правилам; каждая найденная запись получает свою ссылку."""
    reply = ask(session, "Где была коррозия?")
    assert reply.intent == "search"
    assert reply.facts[0] == "Найдено записей: 4."
    assert reply.facts[1].startswith("- Замечание: Коррозия рамы у анкерного болта")
    assert "- Запись о работах: 25.08.2026 15:40 - обслуживание, узел «Корпус насоса и рабочее колесо»: Очаг коррозии" in reply.answer
    assert targets(reply) == [finding_link(session, "Коррозия рамы у анкерного болта"),
                              finding_link(session, "Коррозия на корпусе насоса"), f"{N101}/history", "kstvizor://rule/R02"]
    assert [link["kind"] for link in reply.links] == ["finding", "finding", "history", "rule"]


def test_links_are_well_formed(session):
    """Все ссылки имеют один из восьми видов адресов приложения, а в ответах нет длинных тире."""
    questions = ("Покажи историю насоса Н-101", LAST_INSPECTION, "Какие открытые замечания?", "состояние муфты Н-101",
                 "Когда следующее ТО?", "где инструкция по эксплуатации", "какие правила есть про муфту",
                 "Какое оборудование требует внимания?", "покажи вибрацию", "Где была коррозия?", "Что за насос N-101?")
    kinds = set()
    for question in questions:
        reply = ask(session, question)
        assert reply.links, question
        assert "\u2014" not in reply.answer and "\u2013" not in reply.answer
        for link in reply.links:
            assert set(link) == {"title", "deeplink", "kind"} and link["title"]
            assert LINK_FORMS.fullmatch(link["deeplink"]), link
            kinds.add(link["kind"])
        assert len(targets(reply)) == len(set(targets(reply))) <= intents.MAX_LINKS
    assert {"equipment", "node", "history", "inspection", "finding", "rule", "document"} <= kinds
    assert deeplink("equipment", "A/B 1", "node", "seal") == "kstvizor://equipment/A%2FB%201/node/seal"


def test_api_answer_shape(client, session):
    """Маршрут отвечает полями answer, links и mode; без модели ответ собран поиском."""
    response = client.post("/assistant/ask", json={"question": "  Какие открытые замечания?  ", "equipment_id": "AMS-2"})
    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body) == {"answer", "links", "mode"} and body["mode"] == "search"
    assert body["answer"].startswith("Агрегат насосный винтовой №2 (AMS-2): незакрытых замечаний - 1.")
    assert body["links"] == [
        {"title": "Коррозия рамы у анкерного болта", "deeplink": finding_link(session, "Коррозия рамы у анкерного болта"),
         "kind": "finding"},
        {"title": "Агрегат насосный винтовой №2", "deeplink": AMS2, "kind": "equipment"}]
    blank_context = client.post("/assistant/ask", json={"question": "Покажи историю насоса Н-101", "equipment_id": ""})
    assert blank_context.status_code == 200 and blank_context.json()["links"][0]["deeplink"] == f"{N101}/history"


def test_api_rejects_bad_requests(app, client):
    """Пустой или слишком длинный вопрос - 422, неизвестный агрегат в контексте - 404, без входа - 401."""
    assert client.post("/assistant/ask", json={"question": "   "}).status_code == 422
    assert client.post("/assistant/ask", json={"question": "а" * 501}).status_code == 422
    assert client.post("/assistant/ask", json={}).status_code == 422
    unknown = client.post("/assistant/ask", json={"question": "история", "equipment_id": "X-1"})
    assert unknown.status_code == 404 and unknown.json()["detail"] == "Оборудование не найдено"
    app.dependency_overrides.clear()
    assert client.post("/assistant/ask", json={"question": "история"}).status_code == 401


def test_model_rephrases_only_retrieved_facts(client, session, model):
    """С включённой моделью текст приходит от неё, ссылки остаются прежними, а в запросе - только вопрос и факты."""
    plain = intents.answer(session, LAST_INSPECTION)
    response = client.post("/assistant/ask", json={"question": LAST_INSPECTION})
    body = response.json()
    assert body["mode"] == "llm"
    assert body["answer"] == MODEL_TEXT.replace("\u2014", "-")
    assert body["links"] == plain.links
    request = model["requests"][0]
    assert len(model["requests"]) == 1 and str(request.url) == f"{LLM_URL}/api/chat"
    sent = json.loads(request.content)
    assert sent["model"] == "qwen-demo" and sent["stream"] is False
    assert [message["role"] for message in sent["messages"]] == ["system", "user"]
    assert sent["messages"][1]["content"] == f"Вопрос: {LAST_INSPECTION}\n\nФакты:\n" + plain.answer
    assert "kstvizor" not in request.content.decode("utf-8")


def raise_connect_error(request):
    """Сервер модели не запущен."""
    raise httpx.ConnectError("нет соединения", request=request)


def raise_timeout(request):
    """Сервер модели не уложился в отведённое время."""
    raise httpx.ReadTimeout("слишком долго", request=request)


@pytest.mark.parametrize("handler", [
    raise_connect_error,
    raise_timeout,
    lambda request: httpx.Response(500, text="internal error"),
    lambda request: httpx.Response(200, text="не JSON"),
    lambda request: httpx.Response(200, json={"response": "другой вид ответа"}),
    lambda request: httpx.Response(200, json={"message": {"content": "   "}}),
    lambda request: httpx.Response(200, json={"message": {"content": None}}),
    lambda request: httpx.Response(200, json={"message": {"content": "<think>27.10.2026</think>"}}),
    lambda request: httpx.Response(200, json={"message": {"content": "Осмотр был 27.10.2026, следующий через 77 дней."}}),
    lambda request: httpx.Response(200, json={"message": {"content": "Осмотр 27.10.2026. " * 400}}),
], ids=["connect", "timeout", "http500", "not_json", "wrong_shape", "blank", "null", "only_thinking", "invented_number",
        "too_long"])
def test_model_failure_falls_back_to_search(client, session, model, handler):
    """Любой сбой модели, пустой, раздутый или недостоверный ответ - незаметный переход на ответ поиска."""
    plain = intents.answer(session, LAST_INSPECTION)
    model["handler"] = handler
    response = client.post("/assistant/ask", json={"question": LAST_INSPECTION})
    assert response.status_code == 200
    assert response.json() == {"answer": plain.answer, "links": plain.links, "mode": "search"}
    assert len(model["requests"]) == 1


def test_model_is_not_asked_without_facts_or_outside_local_network(client, model, monkeypatch):
    """Модель не вызывается, когда ответа нет, когда она выключена и когда адрес не локальный."""
    assert client.post("/assistant/ask", json={"question": "Сколько стоит биткоин?"}).json()["mode"] == "search"
    monkeypatch.setenv("KST_LLM_URL", "https://example.com")
    assert client.post("/assistant/ask", json={"question": LAST_INSPECTION}).json()["mode"] == "search"
    monkeypatch.setenv("KST_LLM_URL", LLM_URL)
    monkeypatch.setenv("KST_LLM_MODEL", "")
    assert client.post("/assistant/ask", json={"question": LAST_INSPECTION}).json()["mode"] == "search"
    assert model["requests"] == []


@pytest.mark.parametrize("url, local", [
    ("http://127.0.0.1:11434", True),
    ("http://localhost:11434/api/chat", True),
    ("http://[::1]:11434", True),
    ("http://192.168.1.20:11434", True),
    ("https://example.com", False),
    ("http://8.8.8.8:11434", False),
    ("http://localhost.example.com", False),
    ("ftp://127.0.0.1", False),
    ("127.0.0.1:11434", False),
    ("", False),
])
def test_only_local_model_addresses_are_allowed(url, local):
    """Адрес модели принимается, только если он ведёт на этот компьютер или в локальную сеть."""
    assert llm.is_local(url) is local


def test_model_client_ignores_proxy_and_endpoint_is_built_once(monkeypatch):
    """Клиент модели не берёт прокси из окружения, а путь /api/chat добавляется к адресу только при необходимости."""
    monkeypatch.setenv("HTTP_PROXY", "http://proxy.example.com:3128")
    monkeypatch.setenv("KST_LLM_MODEL", "qwen-demo")
    with llm.make_client() as made:
        assert made.trust_env is False and made.follow_redirects is False
        assert made.timeout.connect + made.timeout.write + made.timeout.read <= 5.0
    for url in (LLM_URL, f"{LLM_URL}/", f"{LLM_URL}/api/chat"):
        monkeypatch.setenv("KST_LLM_URL", url)
        assert llm.configured() == (f"{LLM_URL}/api/chat", "qwen-demo")
