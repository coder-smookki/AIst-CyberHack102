"""Описание API (OpenAPI) и интерактивная страница /docs, работающая без интернета.

Схема строится из маршрутов сервера и дополняется: русские названия разделов и краткие названия операций
(первая фраза описания маршрута), схема входа по токену Bearer, описание обмена по WebSocket и схемы
ответов основных запросов. Схемы ответов - только документация: на работу маршрутов они не влияют.
Страница /docs использует файлы Swagger UI из папки apidocs_static (лицензия Apache-2.0 лежит рядом),
внешних адресов на странице нет. Команда python -m server.apidocs записывает схему в server/openapi.json.
"""

import json
import re
from pathlib import Path
from typing import Any

from fastapi import FastAPI
from fastapi.openapi.docs import get_swagger_ui_html
from fastapi.openapi.utils import get_openapi
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict

STATIC_DIR = Path(__file__).resolve().parent / "apidocs_static"
SCHEMA_FILE = Path(__file__).resolve().parent / "openapi.json"
API_TITLE = "КСТ Визор - API сервера"
API_VERSION = "0.1.1"
ASSETS_URL = "/docs-assets"
FAVICON_URL = "/web/assets/kst_mark_180.png"
OPEN_PATHS = ("/auth/login", "/auth/refresh", "/health")
SUMMARY_LIMIT = 110
METHODS = ("get", "post", "put", "patch", "delete")
DESCRIPTION = (
    "Локальный сервер «КСТ Визор»: вход сотрудников, цифровые карточки оборудования, телеметрия и диагностика "
    "по правилам, осмотры с находками и записью звука, отчёты PDF и Excel, администрирование.\n\n"
    "**Вход.** `POST /auth/login` возвращает `access_token`; нажмите «Authorize» и вставьте его - запросы пойдут "
    "с заголовком `Authorization: Bearer ...`. Права определяет роль сотрудника; без нужного права ответ 403.\n\n"
    "**Демонстрационный стенд.** Перед сервером стоит пароль площадки; приложение вместо него передаёт "
    "заголовок `X-KST-App`. В локальной сети цеха этот заголовок не нужен.\n\n"
    "**Правила работы.** Распознавание принимает только кадры камеры. Статусы и диагнозы - подсказка системы: "
    'решение принимает инженер. Ответы об ошибках имеют вид `{"detail": "текст по-русски"}`.'
)
WS_TEXT = (
    "OpenAPI не описывает WebSocket, поэтому обмен приведён здесь. Токен доступа передаётся параметром `token`.\n\n"
    "**`WS /ws/detect?token=...`** - распознавание без осмотра. Клиент шлёт кадры JPEG двоичными сообщениями; "
    "на каждый кадр сервер отвечает JSON с рамками `boxes: [{cls, conf, x1, y1, x2, y2, status, node}]` и "
    "размером кадра. Текстовое сообщение `ping` - проверка связи.\n\n"
    "**`WS /ws/inspect/{inspection_id}?token=...`** - распознавание в идущем осмотре. После подключения сервер "
    'присылает текущее состояние (`type: "state"`), затем на каждый кадр JPEG - сообщение `type: "frame"` с '
    "полями `boxes`, `coverage` (полнота обхода: процент, узлы, подсказка), `diagnosis_changed` и `findings`. "
    "Текстовые команды: `ping` и `state` (повторить состояние). Признаки дефектов с камеры становятся "
    "замечаниями только после подтверждения инженером.\n\n"
    "Сервер закрывает соединение с кодом и причиной: неверный или просроченный токен, нет права, осмотр не "
    "найден, чужой или завершённый осмотр."
)
TAGS = {
    "auth": ("Вход и сеанс", "Вход по почте и паролю, обновление токенов (в том числе по биометрии), выход, смена пароля."),
    "equipment": ("Оборудование", "Реестр оборудования, цифровая карточка, узлы, история осмотров и работ, режим агрегата."),
    "telemetry": (
        "Телеметрия и диагностика",
        "Показания датчиков с уставками, ряды для графиков, прогноз, сценарии стенда, "
        "диагноз по правилам, маршрут осмотра и оценки ресурса.",
    ),
    "rules": ("Правила диагностики", "Справочник правил и разбор одного правила для агрегата на текущий момент."),
    "inspections": (
        "Осмотры, находки и звук",
        "Осмотр агрегата, записи и замечания, их подтверждение и отклонение, " "записи звука, отчёты PDF и Excel.",
    ),
    "site": ("Площадка", "Название объекта, текущая смена, имя сервера и часовой пояс."),
    "assistant": ("Помощник", "Вопросы об оборудовании и истории с ссылками для приложения."),
    "workflow": ("Задания и уведомления", "Сообщения оператора о неисправностях, задания на осмотр, лента уведомлений."),
    "admin": ("Учётные записи и безопасность", "Сотрудники, роли и права, журнал безопасности, политика."),
    "system": ("Состояние системы", "Состояние сервера, базы данных и моделей распознавания."),
    "webadmin": ("Веб-панель", "Метрики сервера, журнал событий, резервные копии и блокировка для веб-панели."),
    "recognition": ("Распознавание", "Готовность сервера, чтение шильдика и стрелочного манометра по кадру камеры."),
    "ws": ("Распознавание в реальном времени (WebSocket)", WS_TEXT),
}
TAG_ORDER = (
    "auth",
    "equipment",
    "telemetry",
    "rules",
    "inspections",
    "recognition",
    "ws",
    "site",
    "workflow",
    "assistant",
    "admin",
    "system",
    "webadmin",
)


class Doc(BaseModel):
    """Основа схем ответов: перечислены главные поля, остальные поля ответа допускаются."""

    model_config = ConfigDict(extra="allow")


class Person(Doc):
    """Сотрудник в записях осмотров и журналов."""

    id: int
    name: str
    role: str | None = None
    role_title: str | None = None


class UserView(Doc):
    """Вошедший сотрудник: роль и права."""

    id: int
    email: str
    name: str
    role: str
    role_title: str
    permissions: list[str]
    must_change_password: bool


class Tokens(Doc):
    """Пара токенов после входа или обновления."""

    access_token: str
    refresh_token: str
    token_type: str
    expires_in: int
    user: UserView | None = None
    must_change_password: bool | None = None
    permissions: list[str] | None = None
    biometrics_allowed: bool | None = None


class Health(Doc):
    """Готовность сервера: база, число единиц оборудования, детектор."""

    ok: bool
    service: str
    time: str
    database: str
    equipment: int
    detector: dict | None = None
    channels: dict | None = None
    models_fingerprint: str | None = None


class NameplateResult(Doc):
    """Результат чтения шильдика: найденный агрегат, кандидаты той же модели, способ опознания (шильдик или QR)."""

    found: bool
    match: dict | None = None
    candidates: list[dict]
    fields: dict
    lines: list
    message: str
    identified_by: str | None = None
    qr: str | None = None


class Site(Doc):
    """Сведения об объекте и текущей смене."""

    name: str
    shift: str
    shift_code: str
    shift_title: str
    shift_start: str
    shift_end: str
    server_name: str
    timezone: str
    local_time: str


class EquipmentBrief(Doc):
    """Единица оборудования в списке."""

    id: str
    name: str
    type: str
    model: str
    serial: str
    location: str
    mode: str
    run_hours: float
    manufacturer: str | None = None
    telemetry: bool
    open_findings: int
    last_inspection_at: str | None = None


class NodeCard(Doc):
    """Узел оборудования: наработка, нормативы, классы детектора."""

    id: str
    code: str
    name: str
    hours: float | None = None
    installed: str | None = None
    replaced: str | None = None
    classes: list[str] | None = None
    norm_hours: float | None = None
    norm_years: float | None = None
    source: str | None = None
    parameters: list[str] | None = None


class EquipmentCard(EquipmentBrief):
    """Цифровая карточка оборудования с узлами, характеристиками, регламентом и документами."""

    commissioned: str | None = None
    specs: dict | None = None
    maintenance: list[dict] | None = None
    documents: list[dict] | None = None
    nodes: list[NodeCard]


class Parameter(Doc):
    """Параметр телеметрии: значение, уставки, уровень и тренд."""

    code: str
    name: str
    unit: str | None = None
    value: float | None = None
    warn: float | None = None
    alarm: float | None = None
    direction: str | None = None
    level: str | None = None
    level_title: str | None = None
    trend: float | None = None
    source: str | None = None


class Telemetry(Doc):
    """Показания агрегата на текущий момент ленты; без телеметрии available = false и причина."""

    equipment_id: str
    available: bool
    reason: str | None = None
    at: str | None = None
    bounds: dict | None = None
    level: str | None = None
    level_title: str | None = None
    labels: dict | None = None
    parameters: list[Parameter]


class Evidence(Doc):
    """Основание находки: источник, условие, значение, уставка и выполнено ли условие."""

    source: str
    what: str
    value: str | None = None
    threshold: str | None = None
    met: bool


class DiagnosisFinding(Doc):
    """Находка диагностики по правилу с основаниями."""

    rule_id: str
    title: str
    node_id: str
    node_name: str | None = None
    status: str
    severity: int
    diagnosis: str
    recommendation: str
    confidence: float
    evidence: list[Evidence]
    missing: list[str]


class Diagnosis(Doc):
    """Диагноз агрегата: общий статус, находки и состояние каждого узла."""

    equipment_id: str
    inspection_id: int | None = None
    at: str | None = None
    telemetry: bool
    status: str
    status_title: str
    status_note: str | None = None
    findings: list[DiagnosisFinding]
    nodes: dict


class Resource(Doc):
    """Три раздельные оценки по узлам и состояние регламента обслуживания."""

    equipment_id: str
    run_hours: float
    estimates_on: str
    telemetry_at: str | None = None
    telemetry: bool
    nodes: list[dict]
    maintenance: list[dict]


class RuleItem(Doc):
    """Правило диагностики в справочнике."""

    id: str
    title: str
    group: str
    group_title: str | None = None
    applies_to: list[str]
    node: str
    camera: dict
    sensor: dict
    sound: dict | None = None
    status: dict
    severity: int
    recommendation: str
    source: dict


class RuleCondition(Doc):
    """Условие правила: значение, порог, выполнено ли и хватает ли данных."""

    kind: str
    source: str
    what: str
    value: str | None = None
    threshold: str | None = None
    state: str
    met: bool
    missing: bool


class RuleEvaluation(Doc):
    """Разбор одного правила для агрегата на текущий момент."""

    equipment_id: str
    rule_id: str
    title: str
    applies: bool
    status: str
    status_title: str
    node_id: str
    node_name: str | None = None
    severity: int | None = None
    diagnosis: str | None = None
    recommendation: str | None = None
    conditions: list[RuleCondition]
    parts: list[dict]
    evidence: list[Evidence]
    missing: list[str]


class FindingView(Doc):
    """Запись осмотра: замечание, проверка или работа; состояние устранения, отклонение и комментарии."""

    id: int
    inspection_id: int
    equipment_id: str
    node_code: str | None = None
    node_name: str | None = None
    kind: str
    source: str
    rule_id: str | None = None
    status: str
    status_title: str | None = None
    severity: int | None = None
    title: str
    diagnosis: str | None = None
    recommendation: str | None = None
    confidence: float | None = None
    evidence: list[dict]
    comment: str | None = None
    has_photo: bool
    photo_url: str | None = None
    state: str
    state_title: str | None = None
    created_at: str
    rejected: bool
    rejected_at: str | None = None
    rejected_by: dict | None = None
    reject_reason: str | None = None
    notes: list[dict]


class InspectionBrief(Doc):
    """Осмотр в списке: кто, когда, какой агрегат и с каким итогом."""

    id: int
    equipment_id: str
    equipment: dict
    user: Person | None = None
    started_at: str
    finished_at: str | None = None
    status: str
    status_title: str
    summary: dict | None = None
    identified_by: str | None = None
    identified_title: str | None = None


class InspectionView(InspectionBrief):
    """Осмотр с записями и полнотой обхода."""

    coverage: dict | None = None
    findings: list[FindingView]
    resumed: bool | None = None


class SoundRecordView(Doc):
    """Запись звука агрегата с показателями и признаками-кандидатами."""

    id: int
    inspection_id: int
    equipment_id: str
    created_at: str
    normal: bool
    audio_url: str | None = None
    duration_s: float
    sample_rate: int
    level_dbfs: float
    peak_dbfs: float
    crest_factor: float
    kurtosis: float
    centroid_hz: float
    bands: list[dict]
    peaks: list[dict]
    spectrum: list[dict]
    baseline: dict
    candidates: list[dict]
    note: str | None = None


class Notification(Doc):
    """Уведомление ленты сотрудника."""

    id: str
    kind: str
    at: str | None = None
    title: str
    text: str


class SecurityEventView(Doc):
    """Запись журнала безопасности."""

    id: int
    at: str
    event: str
    title: str
    actor: dict | None = None
    target_user: dict | None = None
    target_role: str | None = None
    email: str | None = None
    ip: str | None = None
    details: dict | None = None


class Metrics(Doc):
    """Метрики сервера для веб-панели."""

    time: str
    uptime_s: int
    cpu: dict
    memory: dict
    disk: dict | None = None
    database: dict
    host: str
    platform: str
    python: str


class ServerEvent(Doc):
    """Событие журнала сервера: осмотры, находки, решения по ним, звук."""

    at: str
    level: str
    kind: str
    title: str
    text: str | None = None


RESPONSES: dict[tuple[str, str], Any] = {
    ("post", "/auth/login"): Tokens,
    ("post", "/auth/refresh"): Tokens,
    ("get", "/auth/me"): UserView,
    ("get", "/health"): Health,
    ("post", "/recognize/nameplate"): NameplateResult,
    ("get", "/site"): Site,
    ("get", "/equipment"): [EquipmentBrief],
    ("get", "/equipment/{equipment_id}"): EquipmentCard,
    ("get", "/equipment/by-serial/{serial}"): EquipmentCard,
    ("get", "/equipment/{equipment_id}/telemetry"): Telemetry,
    ("get", "/equipment/{equipment_id}/diagnosis"): Diagnosis,
    ("get", "/equipment/{equipment_id}/resource"): Resource,
    ("get", "/rules"): [RuleItem],
    ("get", "/equipment/{equipment_id}/rules/{rule_id}"): RuleEvaluation,
    ("post", "/inspections"): InspectionView,
    ("get", "/inspections"): [InspectionBrief],
    ("get", "/inspections/{inspection_id}"): InspectionView,
    ("post", "/inspections/{inspection_id}/finish"): InspectionView,
    ("get", "/inspections/findings"): [FindingView],
    ("get", "/inspections/findings/{finding_id}"): FindingView,
    ("get", "/inspections/{inspection_id}/findings"): [FindingView],
    ("post", "/inspections/{inspection_id}/findings"): FindingView,
    ("post", "/inspections/findings/{finding_id}/state"): FindingView,
    ("post", "/inspections/findings/{finding_id}/comment"): FindingView,
    ("post", "/inspections/{inspection_id}/sound"): SoundRecordView,
    ("get", "/inspections/{inspection_id}/sound"): [SoundRecordView],
    ("get", "/inspections/sound/recent"): [SoundRecordView],
    ("get", "/notifications"): [Notification],
    ("get", "/admin/security-log"): [SecurityEventView],
    ("get", "/webadmin/metrics"): Metrics,
    ("get", "/webadmin/events"): [ServerEvent],
}
FILES = {
    ("get", "/inspections/{inspection_id}/report.pdf"): ("application/pdf", "Отчёт об осмотре в формате PDF"),
    ("get", "/inspections/{inspection_id}/report.xlsx"): (
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "Отчёт об осмотре в формате Excel",
    ),
    ("get", "/inspections/findings/{finding_id}/photo"): ("image/jpeg", "Стоп-кадр камеры к замечанию"),
    ("get", "/inspections/sound/{record_id}/audio"): ("audio/wav", "Запись звука в формате WAV"),
}


def summary_of(description: str | None, fallback: str) -> str:
    """Краткое название операции: первая фраза описания маршрута, не длиннее предела."""
    text = " ".join((description or "").split())
    if not text:
        return fallback
    first = re.split(r"(?<=[^А-ЯЁA-Z])[.;:](?:\s|$)", text, maxsplit=1)[0].strip().rstrip(".")
    if len(first) > SUMMARY_LIMIT:
        first = first[:SUMMARY_LIMIT].rsplit(" ", 1)[0].rstrip(",") + "…"
    return first


def _tag_for(path: str, tags: list[str]) -> str:
    """Раздел операции: по разделу маршрутизатора, а для маршрутов приложения - распознавание."""
    known = [tag for tag in tags if tag in TAGS]
    return known[0] if known else "recognition"


def _ref(model: type[BaseModel], schemas: dict) -> dict:
    """Добавляет схему модели в общий перечень и возвращает ссылку на неё."""
    schema = model.model_json_schema(ref_template="#/components/schemas/{model}")
    for name, nested in (schema.pop("$defs", None) or {}).items():
        schemas.setdefault(name, nested)
    schemas.setdefault(model.__name__, schema)
    return {"$ref": f"#/components/schemas/{model.__name__}"}


def _success(operation: dict) -> dict:
    """Ответ успешного выполнения операции: 200 или 201."""
    responses = operation.setdefault("responses", {})
    code = "201" if "201" in responses else "200"
    return responses.setdefault(code, {"description": "Успешный ответ"})


def build_schema(app: FastAPI) -> dict:
    """Строит схему OpenAPI по маршрутам приложения и дополняет её для страницы /docs."""
    schema = get_openapi(title=API_TITLE, version=API_VERSION, description=DESCRIPTION, routes=app.routes)
    components = schema.setdefault("components", {})
    schemas = components.setdefault("schemas", {})
    components["securitySchemes"] = {
        "bearerAuth": {
            "type": "http",
            "scheme": "bearer",
            "bearerFormat": "JWT",
            "description": "Токен доступа из ответа POST /auth/login",
        },
        "appKey": {
            "type": "apiKey",
            "in": "header",
            "name": "X-KST-App",
            "description": "Ключ приложения: нужен только на демонстрационном стенде вместо пароля площадки",
        },
    }
    for path, item in schema.get("paths", {}).items():
        for method in METHODS:
            operation = item.get(method)
            if operation is None:
                continue
            operation["tags"] = [TAGS[_tag_for(path, operation.get("tags") or [])][0]]
            operation["summary"] = summary_of(operation.get("description"), operation.get("summary") or path)
            if path not in OPEN_PATHS:
                operation["security"] = [{"bearerAuth": []}]
            target = RESPONSES.get((method, path))
            if target is not None:
                success = _success(operation)
                if isinstance(target, list):
                    body = {"type": "array", "items": _ref(target[0], schemas)}
                else:
                    body = _ref(target, schemas)
                success["content"] = {"application/json": {"schema": body}}
            if (method, path) in FILES:
                kind, text = FILES[(method, path)]
                success = _success(operation)
                success["description"] = text
                success["content"] = {kind: {"schema": {"type": "string", "format": "binary"}}}
    schema["tags"] = [{"name": TAGS[code][0], "description": TAGS[code][1]} for code in TAG_ORDER]
    return schema


def docs_page() -> HTMLResponse:
    """Страница Swagger UI на локальных файлах: без внешних адресов и проверки схемы сторонним сервисом."""
    return get_swagger_ui_html(
        openapi_url="/openapi.json",
        title=f"{API_TITLE} - описание",
        swagger_js_url=f"{ASSETS_URL}/swagger-ui-bundle.js",
        swagger_css_url=f"{ASSETS_URL}/swagger-ui.css",
        swagger_favicon_url=FAVICON_URL,
        swagger_ui_parameters={
            "validatorUrl": None,
            "persistAuthorization": True,
            "docExpansion": "list",
            "defaultModelsExpandDepth": 0,
            "displayRequestDuration": True,
            "filter": True,
            "tryItOutEnabled": True,
        },
    )


def install(app: FastAPI) -> None:
    """Подключает к приложению схему /openapi.json и страницу /docs с локальными файлами Swagger UI."""

    def openapi() -> dict:
        """Возвращает схему, построенную при первом обращении."""
        if app.openapi_schema is None:
            app.openapi_schema = build_schema(app)
        return app.openapi_schema

    app.openapi = openapi

    @app.get("/openapi.json", include_in_schema=False)
    def schema() -> JSONResponse:
        """Схема OpenAPI сервера."""
        return JSONResponse(app.openapi())

    @app.get("/docs", include_in_schema=False)
    def docs() -> HTMLResponse:
        """Интерактивное описание API."""
        return docs_page()

    if STATIC_DIR.is_dir():
        app.mount(ASSETS_URL, StaticFiles(directory=STATIC_DIR), name="apidocs")


def schema_text(schema: dict) -> str:
    """Текст схемы для файла: постоянный порядок ключей, кириллица без экранирования."""
    return json.dumps(schema, ensure_ascii=False, indent=1, sort_keys=True) + "\n"


class _NoDetector:
    """Заглушка детектора для построения схемы без файлов моделей."""

    def detect(self, frame) -> list:
        """Рамок нет."""
        return []


def main() -> None:
    """Записывает схему OpenAPI в server/openapi.json."""
    from server.app import create_app

    SCHEMA_FILE.write_text(schema_text(create_app(_NoDetector()).openapi()), encoding="utf-8")
    print(f"Схема записана: {SCHEMA_FILE}")


if __name__ == "__main__":
    main()
