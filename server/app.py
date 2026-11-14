"""Сервер «КСТ Визор»: вход, оборудование, телеметрия, осмотры, отчёты, помощник и распознавание кадров камеры,
сообщения о неисправностях и задания на осмотр, администрирование учётных записей и ролей.

Доступ к каждому разделу определяется правами роли сотрудника (server/permissions.py), а не названием роли.

Приложение собирает маршруты всех разделов, при запуске создаёт таблицы базы и заполняет её начальными
данными, раздаёт пульт демонстрации по адресу /panel/. Кадры камеры приходят по WebSocket: /ws/detect
находит узлы и дефекты на отдельном кадре, /ws/inspect/{номер осмотра} ведёт осмотр - копит полноту обхода и
пересчитывает диагноз агрегата. Следующий кадр телефон отправляет только после ответа на предыдущий, поэтому
очередь кадров не копится. Сервер работает в локальной сети цеха и не обращается к внешним адресам.
"""
import asyncio
import logging
from collections import deque
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
import numpy as np
from sqlalchemy import func, select, text
from sqlalchemy.orm import Session

from server import admin, assistant, auth, config, db, equipment, inspections, recognition, telemetry_api, webadmin_api, workflow
from server.auth import require_permission
from server.db import get_session
from server.equipment import equipment_card, get_equipment
from server.inspections import can_edit, current_diagnosis, get_inspection, note_gauge_reading, tracker_for
from server.inspections.service import FOREIGN_INSPECTION
from server.models import Equipment, Inspection, User, now
from server.rules import gauge_difference_percent
from server.seed import seed

PANEL_DIR = Path(__file__).resolve().parent / "panel"
WEBADMIN_DIR = Path(__file__).resolve().parent / "webadmin"
TITLE = "КСТ Визор"
GAUGE_LIMIT_PERCENT = 15.0
GAUGE_RULE = "R05"
CLOSE_UNAUTHORIZED = 4401
CLOSE_FORBIDDEN = 4403
CLOSE_NOT_FOUND = 4404
CLOSE_FINISHED = 4409
INSPECT = "inspect.run"
NO_FRAME = "Ожидается кадр камеры в формате JPEG"
NO_TOKEN = "Требуется вход: передайте токен доступа в параметре token"

PIPELINE_DEPTH = 2

logger = logging.getLogger(__name__)


class SocketClosed(Exception):
    """Соединение WebSocket нужно закрыть: сеанс истёк, нет прав, осмотр не найден или уже завершён."""

    def __init__(self, code: int, detail: str):
        """Запоминает код закрытия соединения и русское объяснение причины."""
        super().__init__(detail)
        self.code = code
        self.detail = detail


def _summary(item: Equipment) -> dict:
    """Краткое описание агрегата для ответа распознавания: обозначение, название, модель, номер и место."""
    return {"id": item.id, "name": item.name, "model": item.model, "serial": item.serial, "location": item.location}


async def _read_image(upload: UploadFile) -> np.ndarray:
    """Читает кадр из формы не больше допустимого размера и превращает его в изображение.

    Пустой, слишком большой, не JPEG или повреждённый кадр отклоняется ответом с понятной причиной.
    """
    data = await upload.read(recognition.MAX_FRAME_BYTES + 1)
    try:
        return recognition.decode_frame(data)
    except recognition.FrameError as error:
        raise HTTPException(status_code=error.status, detail=str(error)) from None


def _sensor_value(card: dict, parameter: str) -> tuple[float | None, str | None, str | None]:
    """Показание электронного датчика, с которым сравнивается манометр, момент ленты и причина отсутствия."""
    feed = telemetry_api.feed_for(card["id"])
    if feed.player is None:
        return None, None, feed.reason
    value = feed.readings.get(parameter)
    if value is None:
        return None, telemetry_api.stamp(feed.at), f"Нет показаний параметра {parameter}"
    return float(value), telemetry_api.stamp(feed.at), None


def _active_inspection(session: Session, inspection_id: int, equipment_id: str, user: User) -> Inspection:
    """Проверяет, что осмотр идёт, относится к этому агрегату и сотрудник может его изменять."""
    inspection = get_inspection(session, inspection_id)
    if inspection.equipment_id != equipment_id:
        raise HTTPException(status_code=422, detail="Осмотр относится к другому оборудованию")
    if not can_edit(inspection, user):
        raise HTTPException(status_code=403, detail=FOREIGN_INSPECTION)
    if inspection.status != "active":
        raise HTTPException(status_code=409, detail="Осмотр уже завершён - начните новый осмотр")
    return inspection


def _diagnosis_signature(result: dict) -> tuple:
    """Отпечаток диагноза для сравнения кадров: общий статус и набор сработавших правил по узлам."""
    return result["status"], tuple(sorted((found["rule_id"], found["node_id"], found["status"], found["severity"])
                                          for found in result["findings"]))


def _live_view(session: Session, inspection: Inspection, coverage: dict) -> tuple[dict, tuple]:
    """Диагноз идущего осмотра для телефона с серыми неосмотренными узлами и отпечатком для сравнения."""
    result = current_diagnosis(session, inspection)
    card = equipment_card(inspection.equipment)
    result = {**result, "nodes": telemetry_api.mark_unwalked(result["nodes"], card, coverage)}
    view = telemetry_api.diagnosis_view(result, telemetry_api.node_names(inspection.equipment))
    return view, _diagnosis_signature(result)


def _socket_user(session: Session, token: str | None) -> User:
    """Сотрудник по токену из адреса соединения с правом проводить осмотры; иначе соединение закрывается."""
    user = auth.user_from_token(session, token) if token else None
    if user is None:
        raise SocketClosed(CLOSE_UNAUTHORIZED, "Сеанс завершён или токен истёк - войдите заново")
    if user.must_change_password:
        raise SocketClosed(CLOSE_FORBIDDEN, auth.CHANGE_PASSWORD)
    if INSPECT not in auth.granted(session, user):
        raise SocketClosed(CLOSE_FORBIDDEN, "Недостаточно прав - нужно право «Проведение осмотров»")
    return user


def _socket_inspection(session: Session, inspection_id: int, user: User) -> Inspection:
    """Идущий осмотр, который сотрудник может вести; иначе соединение закрывается с причиной."""
    inspection = session.get(Inspection, inspection_id)
    if inspection is None:
        raise SocketClosed(CLOSE_NOT_FOUND, "Осмотр не найден")
    if not can_edit(inspection, user):
        raise SocketClosed(CLOSE_FORBIDDEN, FOREIGN_INSPECTION)
    if inspection.status != "active":
        raise SocketClosed(CLOSE_FINISHED, "Осмотр уже завершён - начните новый осмотр")
    return inspection


def _error(status: int, detail: str) -> dict:
    """Сообщение об ошибке обработки кадра; соединение при этом остаётся открытым."""
    return {"type": "error", "status": status, "detail": detail}


def _detect(detector, data: bytes) -> dict:
    """Находит узлы и дефекты на кадре; негодный кадр или отсутствие модели дают сообщение об ошибке."""
    try:
        return recognition.detect_frame(detector, data)
    except recognition.FrameError as error:
        return _error(error.status, str(error))
    except recognition.DetectorUnavailable as error:
        return _error(503, str(error))


def _with_status(boxes: list[dict], defects: set[str], node_for=None) -> list[dict]:
    """Дополняет рамки статусом (defect, check, ok, unsure) и, если известен агрегат, кодом узла."""
    marked = []
    for box in boxes:
        entry = {**box, "status": recognition.box_status(box["cls"], box["conf"], defects)}
        if node_for is not None:
            entry["node"] = node_for(box["cls"])
        marked.append(entry)
    return marked


def check_token(token: str | None) -> None:
    """Проверяет токен доступа при подключении; недействительный токен закрывает соединение."""
    with db.SessionLocal() as session:
        _socket_user(session, token)


def detect_step(detector, token: str | None, data: bytes) -> dict:
    """Один кадр без осмотра: проверка сеанса, рамки со статусами и время работы детектора."""
    with db.SessionLocal() as session:
        _socket_user(session, token)
    found = _detect(detector, data)
    if found.get("type") == "error":
        return found
    return {"type": "frame", **found, "boxes": _with_status(found["boxes"], recognition.defect_classes(detector))}


def inspect_step(detector, token: str | None, inspection_id: int, data: bytes | None, previous: tuple | None) -> dict:
    """Один шаг осмотра: кадр учитывается в полноте обхода, диагноз агрегата пересчитывается.

    Права и состояние осмотра проверяются до работы детектора, чтобы закрытый сеанс не тратил время сервера.
    Без кадра (data = None) возвращается текущее состояние осмотра. Ответ: рамки со статусом и узлом,
    состояние обхода, диагноз с находками и признак diagnosis_changed - изменился ли набор сработавших правил
    с прошлого ответа. Ключ signature служит только для сравнения и клиенту не отправляется.
    """
    found = None
    if data is not None:
        found = inspect_detect(detector, token, inspection_id, data)
        if found.get("type") == "error":
            return found
    return inspect_apply(detector, token, inspection_id, found, previous)


def inspect_detect(detector, token: str | None, inspection_id: int, data: bytes) -> dict:
    """Распознавание кадра осмотра без изменения его состояния; кадры можно распознавать параллельно.

    Права и состояние осмотра проверяются до работы детектора, чтобы закрытый сеанс не тратил время сервера.
    """
    with db.SessionLocal() as session:
        _socket_inspection(session, inspection_id, _socket_user(session, token))
    return _detect(detector, data)


def inspect_apply(detector, token: str | None, inspection_id: int, found: dict | None, previous: tuple | None) -> dict:
    """Учитывает распознанный кадр в полноте обхода и диагнозе; вызывается строго в порядке кадров.

    Без кадра (found = None) возвращает текущее состояние осмотра.
    """
    with db.SessionLocal() as session:
        user = _socket_user(session, token)
        inspection = _socket_inspection(session, inspection_id, user)
        try:
            tracker = tracker_for(session, inspection)
            coverage = tracker.observe(found["boxes"], found["w"], found["h"]) if found else tracker.state()
            view, signature = _live_view(session, inspection, coverage)
        except HTTPException as error:
            raise SocketClosed(CLOSE_FINISHED if error.status_code == 409 else CLOSE_NOT_FOUND, str(error.detail)) from None
    reply = {"type": "frame" if found else "state", "inspection_id": inspection_id}
    if found:
        reply.update(w=found["w"], h=found["h"], ms=found["ms"],
                     boxes=_with_status(found["boxes"], recognition.defect_classes(detector), tracker.node_for))
    else:
        reply["boxes"] = []
    reply.update(coverage=coverage, diagnosis_changed=signature != previous, status=view["status"],
                 status_title=view["status_title"], status_note=view["status_note"], findings=view["findings"],
                 nodes=view["nodes"], signature=signature)
    return reply


async def _close(socket: WebSocket, code: int, detail: str) -> None:
    """Сообщает причину и закрывает соединение; причина в кадре закрытия укорачивается до допустимой длины."""
    try:
        await socket.send_json({"type": "closed", "status": code, "detail": detail})
        await socket.close(code=code, reason=detail.encode("utf-8")[:120].decode("utf-8", "ignore"))
    except (WebSocketDisconnect, RuntimeError):
        pass


async def _frame_pipeline(socket: WebSocket, on_text, start, finish) -> None:
    """Принимает кадры соединения и распознаёт до PIPELINE_DEPTH кадров одновременно.

    start(кадр) распознаёт кадр, finish(результат) готовит ответ; ответы уходят строго в порядке кадров и
    несут номер кадра seq. Пока распознаются PIPELINE_DEPTH кадров, следующий кадр не принимается - телефон
    ждёт, и очередь на сервере не растёт. Текстовые команды обрабатывает on_text. При разрыве соединения
    незавершённые задачи отменяются.
    """
    pending = deque()
    receiving = None
    number = 0
    try:
        while True:
            if receiving is None and len(pending) < PIPELINE_DEPTH:
                receiving = asyncio.ensure_future(_next_frame(socket))
            waits = {receiving} if receiving is not None else set()
            if pending:
                waits.add(pending[0][1])
            await asyncio.wait(waits, return_when=asyncio.FIRST_COMPLETED)
            if pending and pending[0][1].done():
                sequence, task = pending.popleft()
                reply = await finish(task.result())
                if reply.get("type") != "error":
                    reply["seq"] = sequence
                await socket.send_json(reply)
                continue
            if receiving is not None and receiving.done():
                data = receiving.result()
                receiving = None
                if data is None:
                    return
                if isinstance(data, str):
                    await on_text(data)
                    continue
                number += 1
                pending.append((number, asyncio.ensure_future(start(data))))
    finally:
        for task in [receiving, *(task for _, task in pending)]:
            if task is not None and not task.done():
                task.cancel()


async def _next_frame(socket: WebSocket) -> bytes | str | None:
    """Ждёт следующее сообщение: байты кадра, текстовую команду или None при разрыве соединения."""
    message = await socket.receive()
    if message["type"] == "websocket.disconnect":
        return None
    if message.get("bytes") is not None:
        return message["bytes"]
    return (message.get("text") or "").strip()


def create_app(detector=None) -> FastAPI:
    """Собирает приложение сервера.

    detector - объект с методом detect(кадр) -> рамки {cls, conf, x1, y1, x2, y2}; по умолчанию детектор из
    папки models с отложенной загрузкой. Проверки передают сюда подменный детектор, поэтому сервер
    запускается и без файла модели.
    """
    detector = detector if detector is not None else recognition.Detector()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        """При запуске создаёт таблицы, заполняет базу начальными данными и начинает загрузку моделей в фоне."""
        db.init_db()
        with db.SessionLocal() as session:
            seed(session)
        app.state.started_at = now()
        warm_up = getattr(detector, "warm_up", None)
        if callable(warm_up):
            warm_up()
        yield
        db.engine.dispose()

    app = FastAPI(title=TITLE, docs_url=None, redoc_url=None, lifespan=lifespan)
    origins = config.cors_origin_regex()
    if origins is not None:
        app.add_middleware(CORSMiddleware, allow_origin_regex=origins, allow_methods=["GET", "POST"],
                           allow_headers=["Authorization", "Content-Type"], allow_credentials=False, max_age=600)
    app.state.detector = detector
    app.include_router(auth.router)
    app.include_router(equipment.router)
    app.include_router(telemetry_api.router)
    app.include_router(inspections.router)
    app.include_router(assistant.router)
    app.include_router(workflow.router)
    app.include_router(admin.router)
    app.include_router(admin.system_router)
    app.include_router(webadmin_api.router)

    @app.get("/health")
    def health(session: Annotated[Session, Depends(get_session)]) -> dict:
        """Готовность сервера: база данных, число агрегатов и состояние детектора; вход не нужен."""
        try:
            session.execute(text("SELECT 1"))
            units = session.scalar(select(func.count()).select_from(Equipment))
            database = "ok"
        except Exception as error:
            logger.warning("База данных недоступна: %s", type(error).__name__)
            units, database = None, "error"
        info = getattr(detector, "info", None)
        state = info() if callable(info) else {"ready": True, "loaded": True, "models": [], "missing": [], "note": None}
        return {"ok": database == "ok", "service": TITLE, "time": now().isoformat(timespec="seconds"),
                "database": database, "equipment": units, "detector": state}

    @app.post("/recognize/nameplate", dependencies=[Depends(require_permission("equipment.view"))])
    async def recognize_nameplate(frame: Annotated[UploadFile, File()],
                                  session: Annotated[Session, Depends(get_session)]) -> dict:
        """Читает заводской шильдик со стоп-кадра камеры и находит оборудование по серийному номеру или модели.

        Если однозначного совпадения нет, в candidates перечислены агрегаты той же модели: выбирает инженер.
        """
        image = await _read_image(frame)
        items = list(session.scalars(select(Equipment).order_by(Equipment.id)))
        cards = [equipment_card(item) for item in items]
        try:
            found = await run_in_threadpool(recognition.read_nameplate, image, cards)
        except (ImportError, OSError) as error:
            logger.warning("Распознавание текста недоступно: %s", type(error).__name__)
            raise HTTPException(status_code=503, detail="Распознавание текста недоступно на сервере") from None
        by_id = {item.id: item for item in items}
        match = found["match"]
        matched = None
        if match:
            item = by_id[match["card"]["id"]]
            matched = {"equipment_id": item.id, "by": match["by"], "ratio": match["ratio"], "equipment": _summary(item)}
        candidates = [_summary(by_id[card["id"]]) for card in found["candidates"]]
        if matched:
            message = f"Найдено оборудование {matched['equipment']['id']} - {matched['equipment']['name']}"
        elif candidates:
            message = "Однозначно определить агрегат не удалось - выберите его из списка"
        else:
            message = "Оборудование по шильдику не найдено - снимите табличку ближе или введите номер вручную"
        return {"found": matched is not None, "match": matched, "candidates": candidates,
                "fields": {"serial": found["fields"].get("serial"), "model": found["fields"].get("model")},
                "lines": found["lines"], "message": message}

    @app.post("/recognize/gauge")
    async def recognize_gauge(frame: Annotated[UploadFile, File()],
                              equipment_id: Annotated[str, Form(min_length=1, max_length=32)],
                              user: Annotated[User, Depends(require_permission(INSPECT))],
                              session: Annotated[Session, Depends(get_session)],
                              inspection_id: Annotated[int | None, Form(ge=1)] = None) -> dict:
        """Читает стрелочный манометр по вырезанному кадру прибора и сравнивает с электронным датчиком.

        Шкала берётся из карточки оборудования. Расхождение больше 15 % - признак правила R05. С номером
        идущего осмотра надёжное показание запоминается в осмотре и входит в его диагноз; ненадёжное
        показание (ok = false) в диагностику не передаётся.
        """
        item = get_equipment(session, equipment_id)
        card = equipment_card(item)
        scale = card.get("gauge")
        if not scale:
            raise HTTPException(status_code=422, detail="В карточке оборудования нет стрелочного манометра")
        inspection = _active_inspection(session, inspection_id, item.id, user) if inspection_id is not None else None
        image = await _read_image(frame)
        reading = await run_in_threadpool(recognition.read_gauge, image, scale)
        parameter = scale.get("parameter") or "press_out"
        sensor, at, sensor_reason = _sensor_value(card, parameter)
        value = reading["value"] if reading["ok"] else None
        difference = None
        if value is not None and sensor is not None:
            difference = round(gauge_difference_percent(value, sensor), 1)
        answer = {"equipment_id": item.id, "ok": reading["ok"], "value": value, "unit": scale.get("unit"),
                  "reason": reading["reason"], "angle_deg": reading["angle_deg"], "parameter": parameter,
                  "sensor_value": sensor, "sensor_at": at, "sensor_reason": sensor_reason,
                  "difference_percent": difference, "limit_percent": GAUGE_LIMIT_PERCENT,
                  "exceeds": None if difference is None else difference > GAUGE_LIMIT_PERCENT,
                  "inspection_id": inspection_id, "finding": None}
        if inspection is not None and value is not None:
            note_gauge_reading(session, inspection, value)
            result = current_diagnosis(session, inspection)
            names = telemetry_api.node_names(item)
            findings = telemetry_api.diagnosis_view(result, names)["findings"]
            answer["finding"] = next((found for found in findings if found["rule_id"] == GAUGE_RULE), None)
        return answer

    @app.websocket("/ws/detect")
    async def ws_detect(socket: WebSocket) -> None:
        """Поток кадров без осмотра: на каждый кадр JPEG - рамки узлов и дефектов со статусами.

        Токен доступа передаётся в параметре token адреса соединения.
        """
        await socket.accept()
        token = socket.query_params.get("token")
        if not token:
            await _close(socket, CLOSE_UNAUTHORIZED, NO_TOKEN)
            return
        async def on_text(text: str) -> None:
            """Отвечает на текстовую команду: ping - проверка связи, остальное - ошибка формата."""
            await socket.send_json({"type": "pong"} if text == "ping" else _error(415, NO_FRAME))

        async def start(data: bytes) -> dict:
            """Распознаёт кадр в пуле потоков."""
            return await run_in_threadpool(detect_step, detector, token, data)

        async def finish(found: dict) -> dict:
            """Ответ на кадр - результат распознавания без изменений."""
            return found

        try:
            await run_in_threadpool(check_token, token)
            await _frame_pipeline(socket, on_text, start, finish)
        except SocketClosed as closed:
            await _close(socket, closed.code, closed.detail)
        except (WebSocketDisconnect, OSError):
            return

    @app.websocket("/ws/inspect/{inspection_id}")
    async def ws_inspect(socket: WebSocket, inspection_id: int) -> None:
        """Поток кадров идущего осмотра.

        После подключения сервер присылает текущее состояние (type = state), затем на каждый кадр JPEG -
        рамки со статусом и узлом, полноту обхода, диагноз агрегата и признак diagnosis_changed. Текстовая
        команда state повторяет текущее состояние, ping - проверка связи. Токен доступа - параметр token;
        при истёкшем сеансе или завершённом осмотре соединение закрывается с кодом 4401, 4403, 4404 или 4409.
        """
        await socket.accept()
        token = socket.query_params.get("token")
        if not token:
            await _close(socket, CLOSE_UNAUTHORIZED, NO_TOKEN)
            return
        previous = None

        async def apply(found: dict | None) -> dict:
            """Учитывает кадр или запрос состояния в осмотре; вызывается строго по порядку кадров."""
            nonlocal previous
            if found is not None and found.get("type") == "error":
                return found
            reply = await run_in_threadpool(inspect_apply, detector, token, inspection_id, found, previous)
            if "signature" in reply:
                previous = reply.pop("signature")
            return reply

        async def on_text(text: str) -> None:
            """Отвечает на текстовую команду: ping - проверка связи, state - текущее состояние осмотра."""
            if text == "ping":
                await socket.send_json({"type": "pong"})
            elif text == "state":
                await socket.send_json(await apply(None))
            else:
                await socket.send_json(_error(415, NO_FRAME))

        async def start(data: bytes) -> dict:
            """Распознаёт кадр осмотра в пуле потоков, не меняя состояние осмотра."""
            return await run_in_threadpool(inspect_detect, detector, token, inspection_id, data)

        try:
            await socket.send_json(await apply(None))
            await _frame_pipeline(socket, on_text, start, apply)
        except SocketClosed as closed:
            await _close(socket, closed.code, closed.detail)
        except (WebSocketDisconnect, OSError):
            return

    @app.get("/", include_in_schema=False)
    def root() -> RedirectResponse:
        """Открывает пульт демонстрации."""
        return RedirectResponse("/panel/")

    @app.get("/panel", include_in_schema=False)
    def panel_root() -> RedirectResponse:
        """Добавляет косую черту к адресу пульта, чтобы относительные ссылки на стили и скрипт работали."""
        return RedirectResponse("/panel/")

    @app.get("/web", include_in_schema=False)
    def web_root() -> RedirectResponse:
        """Добавляет косую черту к адресу веб-панели администратора."""
        return RedirectResponse("/web/")

    if PANEL_DIR.is_dir():
        app.mount("/panel", StaticFiles(directory=PANEL_DIR, html=True), name="panel")
    if WEBADMIN_DIR.is_dir():
        app.mount("/web", StaticFiles(directory=WEBADMIN_DIR, html=True), name="webadmin")
    return app
