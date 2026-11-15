"""Ассистент веб-панели (/webadmin/assistant): русская команда - план действия - подтверждение - выполнение.

Первый запрос с текстом команды только разбирает её: для действия возвращается план, ничего не выполняется;
на вопрос ассистент сразу отвечает. Второй запрос с confirm=true и тем же планом выполняет действие: сервер
заново разбирает текст, сверяет получившийся план с присланным (присланному плану не доверяет), проверяет права
сотрудника и вызывает те же функции, что и обычные маршруты панели, поэтому проверки, защита от потери
управления, политика паролей и журнал безопасности действуют как при ручном действии. Записи журнала,
сделанные через ассистента, помечены via = "assistant". Временный пароль возвращается один раз в result.secret
и нигде не записывается. Каждое действие выполняется с правами самого сотрудника.
"""

import hashlib
import json
import logging
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import timedelta
from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field, ValidationError
from sqlalchemy import func, select
from sqlalchemy import text as sql_text
from sqlalchemy.orm import Session

from server import admin, equipment, fingerprint, health, security, site, telemetry_api, webadmin_api, workflow
from server.assistant import commands as cmd
from server.assistant.search import distance, fold, id_keys, similar, stem
from server.auth import current_user, granted
from server.db import get_session
from server.inspections import service
from server.models import Equipment, FaultReport, InspectionTask, Role, User, now
from server.permissions import title as permission_title

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/webadmin", tags=["webadmin"], dependencies=[Depends(current_user)])

PAGE_PERMISSIONS = {
    "overview": ("system.manage",),
    "telemetry": ("system.manage",),
    "equipment": ("system.manage",),
    "models": ("system.manage",),
    "log": ("system.manage",),
    "users": ("users.manage",),
    "roles": ("users.manage", "roles.manage"),
    "seclog": ("security.log",),
    "policy": ("security.policy",),
    "summary": ("findings.view",),
    "profile": (),
}
PAGE_HELP = {
    "overview": "«Обзор системы» показывает состояние сервера: каналы /health, загрузку, базу, модели и отпечаток "
    "набора моделей. Красный канал - сначала проверьте его.",
    "telemetry": "«Телеметрия и сценарии»: выберите агрегат, включите сценарий неисправности или верните нормальный "
    "режим, переставьте время стенда. Показания и диагноз пересчитываются сразу.",
    "equipment": "«Оборудование»: список агрегатов с режимом, наработкой и незакрытыми замечаниями; карточка "
    "открывается по строке.",
    "models": "«Распознавание»: файлы моделей, лицензии, пороги, классы, отпечаток набора и замер времени на кадр.",
    "log": "«Журнал и резерв»: события сервера (осмотры, находки, звук) и резервные копии базы - кнопка создаёт копию "
    "без остановки сервера.",
    "users": "«Пользователи»: заведите учётную запись (временный пароль показывается один раз), смените роль, "
    "заблокируйте с причиной, сбросьте пароль или закройте сеансы. Удалять учётные записи нельзя - только "
    "блокировать.",
    "roles": "«Роли и права»: системные роли и свои роли с набором прав. Изменение прав действует сразу. Нельзя "
    "оставить систему без активного сотрудника с управлением учётными записями и ролями.",
    "seclog": "«Журнал безопасности»: входы, неудачные попытки, действия с учётными записями, ролями и политикой. "
    "Отбор по виду события, сотруднику и дате. Действия ассистента помечены «через ассистента».",
    "policy": "«Политика»: длина и состав пароля, число неудачных попыток до блокировки входа и её длительность, срок "
    "сеанса, вход по биометрии. Новые значения действуют с ближайшего входа.",
    "summary": "«Сводка смены»: текущий осмотр с полнотой обхода, замечания и решения по ним, записи звука, телеметрия "
    "и уведомления о заданиях.",
    "profile": "«Профиль»: ваша учётная запись, роль и права, смена собственного пароля.",
}
EXAMPLES = {
    "users.manage": [
        "Создай пользователя Ильина Кирилла",
        "Сбрось пароль Смирнову",
        "Кто заблокирован?",
        "У кого временные пароли?",
    ],
    "security.log": ["Покажи неудачные входы за сегодня"],
    "security.policy": ["Какая политика паролей?", "Поставь минимальную длину пароля 12"],
    "system.manage": ["Как сервер?", "Сделай резервную копию базы", "Покажи модели"],
    "telemetry.control": ["Включи перегрев обмоток на Н-101", "Верни нормальный режим"],
    "findings.view": ["Сводка смены", "Какие находки ждут подтверждения?"],
    "tasks.assign": ["Назначь осмотр Н-101 Смирнову"],
}
VIA = "assistant"
MODES = {"running": "в работе", "stopped": "остановлен"}
CHANNEL_TITLES = {
    "database": "База данных",
    "models": "Модель",
    "ocr": "Распознавание текста",
    "telemetry": "Телеметрия",
    "sound": "Анализ звука",
}
MAX_ROWS = 15


class AssistantBody(BaseModel):
    """Команда ассистенту; confirm=true с планом из прошлого ответа - выполнить действие."""

    text: str = Field(min_length=1, max_length=500)
    confirm: bool = False
    plan: dict | None = None


class AssistantPlan(BaseModel):
    """План действия: что будет сделано и с какими значениями; danger - действие меняет доступ или стенд."""

    id: str
    action: str
    title: str
    details: list[list[str]]
    danger: bool


class AssistantResult(BaseModel):
    """Итог: заголовок, строки «название - значение» и одноразовый секрет (временный пароль), если он есть."""

    title: str
    rows: list[list[str]]
    secret: str | None = None


class AssistantLink(BaseModel):
    """Переход в раздел панели по ключу маршрута."""

    label: str
    route: str


class AssistantReply(BaseModel):
    """Ответ ассистента: текст, план (если нужно подтверждение), признак выполнения, итог, ссылки, подсказки."""

    reply: str
    plan: AssistantPlan | None = None
    done: bool = False
    result: AssistantResult | None = None
    links: list[AssistantLink] = []
    suggestions: list[str] = []


@dataclass
class Ctx:
    """Окружение одной команды: текст, слова, сотрудник, его права, сеанс базы и запрос."""

    text: str
    tokens: list[str]
    actor: User
    rights: set[str]
    session: Session
    request: Request


@dataclass
class Draft:
    """Разобранная команда: план с параметрами для выполнения или готовый ответ без действия."""

    reply: str
    params: dict | None = None
    details: list[list[str]] = field(default_factory=list)
    done: bool = False
    result: dict | None = None
    links: list[dict] = field(default_factory=list)
    suggestions: list[str] = field(default_factory=list)


class Ask(Exception):
    """Команду нельзя выполнить без уточнения: текст вопроса и подсказки."""

    def __init__(self, reply: str, suggestions: list[str] | None = None):
        super().__init__(reply)
        self.reply, self.suggestions = reply, suggestions or []


def link(route: str) -> dict:
    """Ссылка на раздел панели с его названием."""
    return {"label": cmd.PAGES[route][0], "route": route}


def stamp(moment) -> str:
    """Время для человека: 15.11.2026 04:30."""
    return moment.strftime("%d.%m.%Y %H:%M") if moment else "-"


def ip(request: Request) -> str:
    """Адрес устройства, с которого пришла команда."""
    return request.client.host if request.client else ""


def audit(ctx: Ctx, action: str, details: dict) -> None:
    """Пишет в журнал безопасности действие ассистента, у которого нет собственной записи журнала."""
    security.record(ctx.session, "assistant_action", actor=ctx.actor, ip=ip(ctx.request), details={"action": action, **details})
    ctx.session.commit()


def roles_of(session: Session) -> list[Role]:
    """Роли базы: сначала системные."""
    return sorted(session.scalars(select(Role)), key=lambda role: (not role.is_system, role.title))


def role_title(session: Session, code: str) -> str:
    """Название роли по коду."""
    role = session.get(Role, code)
    return role.title if role else code


def find_users(ctx: Ctx, only: Callable[[User], bool] | None = None) -> list[User]:
    """Сотрудники, названные в команде: по почте, полному имени или фамилии; падеж и одна опечатка не мешают."""
    users = [user for user in ctx.session.scalars(select(User).order_by(User.name)) if not only or only(user)]
    mails = cmd.emails(ctx.text)
    if mails:
        return [user for user in users if user.email.lower() in mails]
    wanted = [stem(fold(word)) for word in cmd.name_words(ctx.text) if len(word) > 1]
    if not wanted:
        return []

    def score(user: User, typo: bool) -> int:
        """Сколько слов команды совпало с частями имени сотрудника."""
        parts = [stem(fold(part)) for part in user.name.split()] + [fold(user.email.split("@")[0])]
        hits = 0
        for word in wanted:
            if any(similar(word, part) or (typo and len(word) >= 5 and distance(word, part) <= 1) for part in parts):
                hits += 1
        return hits

    for typo in (False, True):
        scored = [(score(user, typo), user) for user in users]
        best = max((value for value, _ in scored), default=0)
        if best:
            return [user for value, user in scored if value == best]
    raise Ask(
        f"Не нашёл сотрудника «{' '.join(cmd.name_words(ctx.text))}». Укажите фамилию, полное имя или почту.",
        ["Покажи пользователей"],
    )


def one_user(ctx: Ctx, phrase: str, only: Callable[[User], bool] | None = None) -> User:
    """Ровно один сотрудник из команды; несколько совпадений или никого - уточняющий вопрос с подсказками."""
    found = find_users(ctx, only)
    if len(found) == 1:
        return found[0]
    if not found:
        raise Ask(f"Кого именно? Назовите сотрудника, например: «{phrase} Смирнову».", ["Покажи пользователей"])
    names = "; ".join(f"{user.name} ({user.email})" for user in found[:6])
    raise Ask(
        f"Подходят несколько сотрудников: {names}. Кого именно?",
        [f"{ctx.text.split(':')[0].strip()} {user.email}" for user in found[:4]],
    )


def find_unit(ctx: Ctx, telemetry_only: bool = False) -> Equipment:
    """Агрегат из команды по обозначению («Н-101», «N101», «н101»); если агрегат с телеметрией один - он."""
    items = list(ctx.session.scalars(select(Equipment).order_by(Equipment.id)))
    pool = [item for item in items if item.data.get("telemetry")] if telemetry_only else items
    keys = set()
    for word in ctx.tokens:
        keys |= id_keys(word)
    found = [item for item in items if id_keys(item.id) & keys or id_keys(item.name.split()[-1]) & keys]
    if found:
        if telemetry_only and not found[0].data.get("telemetry"):
            raise Ask(f"У агрегата {found[0].name} нет телеметрии. Сценарии есть у: " f"{', '.join(item.name for item in pool)}.")
        return found[0]
    if telemetry_only and len(pool) == 1:
        return pool[0]
    raise Ask(
        "Какой агрегат? Есть: " + ", ".join(f"{item.name}" for item in pool) + ".",
        [f"{ctx.text} {pool[0].name.split()[-1]}"] if pool else [],
    )


def player_of(item: Equipment):
    """Лента телеметрии агрегата или уточнение, если её нет."""
    player, reason = telemetry_api.find_player(item.id)
    if player is None:
        raise Ask(f"Лента телеметрии {item.name} недоступна: {reason}.")
    return player


def call(executor: Callable, *args):
    """Вызывает функцию маршрута; отказ маршрута становится понятным текстом, а не страницей ошибки."""
    try:
        return executor(*args)
    except HTTPException as error:
        raise Ask(f"Не выполнено: {error.detail}") from None


def plan_create_user(ctx: Ctx) -> Draft:
    """Новая учётная запись: имя в именительном падеже, роль (по умолчанию инженер), почта."""
    roles = roles_of(ctx.session)
    role = cmd.role_of(ctx.tokens, [(item.code, item.title) for item in roles]) or "engineer"
    words = cmd.name_words(ctx.text)
    variants = cmd.nominative_variants(words)
    if not words:
        raise Ask("Как зовут сотрудника? Например: «Создай пользователя Ильина Кирилла».")
    if len(variants) != 1:
        given = " ".join(words)
        if variants:
            raise Ask(
                f"Как правильно записать имя: {' или '.join('«' + item + '»' for item in variants)}?",
                [f"Создай пользователя {item}" for item in variants],
            )
        raise Ask(
            f"Не уверен, как записать «{given}» в именительном падеже. Напишите так: «Создай пользователя "
            f"Фамилия Имя», например «Создай пользователя Ильин Кирилл».",
            [f"Создай пользователя {given}"],
        )
    name = variants[0]
    domain = ctx.actor.email.split("@")[-1] or "kst.demo"
    given_mail = cmd.emails(ctx.text)
    email = given_mail[0] if given_mail else cmd.email_from_name(name, domain)
    if ctx.session.scalar(select(User.id).where(User.email == email)) is not None:
        raise Ask(
            f"Учётная запись с почтой {email} уже есть. Укажите другую почту в команде.",
            [f"Создай пользователя {name} почта {email.split('@')[0]}2@{domain}"],
        )
    title = role_title(ctx.session, role)
    note = "Пароль придумаю сам: временный, по политике безопасности; сотрудник сменит его при первом входе."
    if cmd.has(ctx.tokens, "парол") and not cmd.has(
        ctx.tokens, "безопасн", "надежн", "сложн", "придума", "сгенер", "случайн", "временн"
    ):
        note = "Свой пароль через ассистента не задаётся - выдам временный по политике; при входе его нужно сменить."
    return Draft(
        f"Создать учётную запись «{name}» с ролью «{title}»? Почта {email} - чтобы указать другую, "
        f"добавьте её в команду. {note}",
        params={"name": name, "email": email, "role": role},
        details=[["Сотрудник", name], ["Почта", email], ["Роль", title], ["Пароль", "временный, будет показан один раз"]],
    )


def run_create_user(ctx: Ctx, params: dict) -> Draft:
    """Заводит учётную запись тем же кодом, что кнопка панели."""
    body = admin.UserCreateBody(email=params["email"], name=params["name"], role=params["role"])
    created = call(admin.create_user, body, ctx.request, ctx.actor, ctx.session)
    user = created["user"]
    return Draft(
        f"Учётная запись «{user['name']}» создана. Передайте сотруднику временный пароль - он показан один "
        f"раз; при первом входе пароль нужно сменить.",
        result={
            "title": "Учётная запись создана",
            "secret": created["temporary_password"],
            "rows": [
                ["Сотрудник", user["name"]],
                ["Почта", user["email"]],
                ["Роль", user["role_title"]],
                ["Пароль", "временный, сменить при первом входе"],
            ],
        },
        links=[link("users")],
    )


def plan_user_action(ctx: Ctx, action: str) -> Draft:
    """План действия над учётной записью: сброс пароля, блокировка, разблокировка, смена роли, закрытие сеансов."""
    phrase = PHRASES[action]
    user = one_user(ctx, phrase)
    details = [["Сотрудник", user.name], ["Почта", user.email], ["Роль", role_title(ctx.session, user.role)]]
    params: dict[str, Any] = {"user_id": user.id}
    if action == "block_user":
        if user.id == ctx.actor.id:
            raise Ask("Нельзя заблокировать собственную учётную запись.")
        if not user.is_active:
            raise Ask(f"{user.name} уже заблокирован(а).", [f"Разблокируй {user.email}"])
        reason = cmd.reason_of(ctx.text)
        if not reason:
            raise Ask(
                f"Укажите причину блокировки {user.name}.",
                [f"Заблокируй {user.email}, причина: увольнение", f"Заблокируй {user.email}, причина: утеря телефона"],
            )
        params["reason"] = reason
        details.append(["Причина", reason])
        reply = f"Заблокировать учётную запись {user.name}? Все сеансы сотрудника закроются сразу."
    elif action == "unblock_user":
        if user.is_active:
            raise Ask(f"{user.name} не заблокирован(а) - разблокировать нечего.")
        reply = f"Разблокировать учётную запись {user.name}?"
    elif action == "reset_password":
        reply = (
            f"Выдать новый временный пароль сотруднику {user.name}? Все его сеансы закроются, при входе пароль " f"нужно сменить."
        )
        details.append(["Новый пароль", "временный, будет показан один раз"])
    elif action == "close_sessions":
        reply = f"Закрыть все сеансы сотрудника {user.name}? Ему придётся войти заново."
    else:
        roles = roles_of(ctx.session)
        code = cmd.role_of(ctx.tokens, [(item.code, item.title) for item in roles])
        if code is None:
            raise Ask(
                "Какую роль назначить? Есть роли: " + ", ".join(f"«{item.title}»" for item in roles) + ".",
                [f"Смени роль {user.email} на {item.title.lower()}" for item in roles[:4]],
            )
        if code == user.role:
            raise Ask(f"У сотрудника {user.name} уже роль «{role_title(ctx.session, code)}».")
        params["role"] = code
        details.append(["Новая роль", role_title(ctx.session, code)])
        reply = f"Сменить роль сотрудника {user.name} на «{role_title(ctx.session, code)}»? Новые права действуют сразу."
    return Draft(reply, params=params, details=details)


def run_user_action(ctx: Ctx, params: dict, action: str) -> Draft:
    """Выполняет действие над учётной записью функцией соответствующего маршрута."""
    user_id = params["user_id"]
    secret = None
    if action == "block_user":
        view = call(
            webadmin_api.block_with_reason,
            user_id,
            webadmin_api.BlockBody(reason=params["reason"]),
            ctx.request,
            ctx.actor,
            ctx.session,
        )
        text = f"{view['name']} заблокирован(а), сеансы закрыты."
    elif action == "unblock_user":
        view = call(admin.unblock_user, user_id, ctx.request, ctx.actor, ctx.session)
        text = f"{view['name']} разблокирован(а)."
    elif action == "reset_password":
        answer = call(admin.reset_password, user_id, ctx.request, ctx.actor, ctx.session)
        view, secret = answer["user"], answer["temporary_password"]
        text = f"Новый временный пароль для {view['name']} готов - он показан один раз. Сеансы сотрудника закрыты."
    elif action == "close_sessions":
        answer = call(admin.revoke_all_sessions, user_id, ctx.request, ctx.actor, ctx.session)
        view = admin.get_user(user_id, ctx.session)
        text = f"Закрыто сеансов {view['name']}: {answer['revoked']}."
    else:
        view = call(admin.change_role, user_id, admin.RoleAssignBody(role=params["role"]), ctx.request, ctx.actor, ctx.session)
        text = f"Роль {view['name']} изменена на «{view['role_title']}»."
    rows = [
        ["Сотрудник", view["name"]],
        ["Почта", view["email"]],
        ["Роль", view["role_title"]],
        ["Состояние", view["status_title"]],
    ]
    return Draft(text, result={"title": ACTIONS[action].title, "rows": rows, "secret": secret}, links=[link("users")])


def answer_user_list(ctx: Ctx, action: str) -> Draft:
    """Список учётных записей: с временным паролем или заблокированных."""
    blocked = action == "list_blocked"
    users = admin.list_users(ctx.session, None, None, "blocked" if blocked else None)
    if not blocked:
        users = [user for user in users if user["must_change_password"]]
    title = "Заблокированные учётные записи" if blocked else "Учётные записи с временным паролем"
    if not users:
        return Draft(
            "Заблокированных учётных записей нет." if blocked else "Временных паролей ни у кого нет.",
            done=True,
            links=[link("users")],
        )
    rows = [[user["name"], f"{user['email']} · {user['role_title']}"] for user in users[:MAX_ROWS]]
    lines = "\n".join(f"• {name} - {info}" for name, info in rows)
    return Draft(
        f"{title}: {len(users)}.\n{lines}",
        done=True,
        result={"title": title, "rows": rows},
        links=[link("users")],
        suggestions=[f"{'Разблокируй' if blocked else 'Сбрось пароль'} {users[0]['email']}"],
    )


def answer_security_events(ctx: Ctx) -> Draft:
    """Последние события журнала безопасности: неудачные входы, за сегодня, по сотруднику."""
    event = None
    if cmd.has(ctx.tokens, "неудач", "ошиб", "неуспеш", "провал"):
        event = "login_failure"
    elif cmd.has(ctx.tokens, "блокир") and cmd.has(ctx.tokens, "вход"):
        event = "login_locked"
    since = None
    if cmd.has(ctx.tokens, "сегодня"):
        since = now().replace(hour=0, minute=0, second=0, microsecond=0)
    elif cmd.has(ctx.tokens, "вчера"):
        since = now().replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=1)
    user = None
    if cmd.name_words(ctx.text) or cmd.emails(ctx.text):
        user = one_user(ctx, "Покажи события")
    rows = admin.security_log(ctx.session, event, user.id if user else None, since, None, 10)
    period = None
    if since:
        period = "с вчерашнего дня" if cmd.has(ctx.tokens, "вчера") else "за сегодня"
    failures = "неудачные входы" if event == "login_failure" else None
    scope = ", ".join(part for part in (failures, period, user.name if user else None) if part)
    if not rows:
        return Draft("Событий не найдено" + (f" ({scope})." if scope else "."), done=True, links=[link("seclog")])
    table = []
    for row in rows:
        who = (row["target_user"] or row["actor"] or {}).get("name") or row.get("email") or ""
        via = (row["details"] or {}).get("via") == VIA or row["event"] == "assistant_action"
        mark = " · через ассистента" if via else ""
        table.append([row["at"].replace("T", " ")[:16], f"{row['title']}{' · ' + who if who else ''}{mark}"])
    lines = "\n".join(f"• {at} - {what}" for at, what in table)
    return Draft(
        f"Последние события{' (' + scope + ')' if scope else ''}:\n{lines}",
        done=True,
        result={"title": "Журнал безопасности", "rows": table},
        links=[link("seclog")],
    )


def policy_value(field_name: str, value) -> str:
    """Значение поля политики для человека."""
    if isinstance(value, bool):
        return "да" if value else "нет"
    return str(value)


def answer_policy(ctx: Ctx) -> Draft:
    """Политика безопасности целиком или одно её значение."""
    view = admin.get_policy(ctx.session)
    wanted = cmd.policy_field(ctx.tokens)
    fields = [wanted] if wanted else list(cmd.POLICY_FIELDS)
    rows = [[cmd.POLICY_FIELDS[name], policy_value(name, view[name])] for name in fields]
    if wanted:
        return Draft(
            f"{rows[0][0]}: {rows[0][1]}.",
            done=True,
            result={"title": "Политика безопасности", "rows": rows},
            links=[link("policy")],
        )
    lines = "\n".join(f"• {label}: {value}" for label, value in rows)
    return Draft(
        f"Политика безопасности:\n{lines}",
        done=True,
        result={"title": "Политика безопасности", "rows": rows},
        links=[link("policy")],
        suggestions=["Поставь минимальную длину пароля 12"],
    )


def plan_policy(ctx: Ctx) -> Draft:
    """Изменение одного значения политики безопасности с проверкой допустимых границ."""
    name = cmd.policy_field(ctx.tokens)
    if name is None:
        raise Ask(
            "Какое значение политики изменить? " + "; ".join(cmd.POLICY_FIELDS.values()) + ".",
            ["Поставь минимальную длину пароля 12", "Запрети вход по биометрии"],
        )
    value: Any
    if name in ("require_letters_digits", "biometrics_allowed"):
        value = cmd.switch_value(ctx.tokens)
        if value is None:
            raise Ask(f"Включить или выключить «{cmd.POLICY_FIELDS[name]}»?")
    else:
        value = cmd.number_in(ctx.text)
        if value is None:
            raise Ask(f"Какое значение поставить для «{cmd.POLICY_FIELDS[name]}»? Назовите число.")
    try:
        admin.PolicyBody(**{name: value})
    except ValidationError:
        bounds = {
            "min_password_length": "от 6 до 128",
            "lockout_attempts": "от 3 до 100",
            "lockout_minutes": "от 1 до 1440",
            "session_hours": "от 1 до 8760",
        }.get(name, "")
        raise Ask(f"Значение {value} не подходит для «{cmd.POLICY_FIELDS[name]}»: допустимо {bounds}.") from None
    current = admin.get_policy(ctx.session)[name]
    if current == value:
        raise Ask(f"«{cmd.POLICY_FIELDS[name]}» уже {policy_value(name, value)}.")
    return Draft(
        f"Изменить «{cmd.POLICY_FIELDS[name]}» с {policy_value(name, current)} на "
        f"{policy_value(name, value)}? Действует с ближайшего входа.",
        params={"field": name, "value": value},
        details=[
            ["Параметр", cmd.POLICY_FIELDS[name]],
            ["Было", policy_value(name, current)],
            ["Станет", policy_value(name, value)],
        ],
    )


def run_policy(ctx: Ctx, params: dict) -> Draft:
    """Меняет политику функцией маршрута PATCH /admin/policy."""
    view = call(admin.update_policy, admin.PolicyBody(**{params["field"]: params["value"]}), ctx.request, ctx.actor, ctx.session)
    label = cmd.POLICY_FIELDS[params["field"]]
    value = policy_value(params["field"], view[params["field"]])
    return Draft(
        f"Готово: «{label}» - {value}.", result={"title": "Политика изменена", "rows": [[label, value]]}, links=[link("policy")]
    )


def plan_scenario(ctx: Ctx) -> Draft:
    """Сценарий демонстрации на агрегате: по словам названия сценария; без совпадения - перечень сценариев."""
    item = find_unit(ctx, telemetry_only=True)
    player = player_of(item)
    options = player.scenarios()
    wanted = {stem(word) for word in ctx.tokens if len(word) > 2}
    named = any(cmd.has(ctx.tokens, word[:5]) for option in options for word in cmd.words(option["title"]) if len(word) > 4)
    normal = cmd.has(ctx.tokens, "нормальн", "норм") or (
        cmd.has(ctx.tokens, "сброс", "верн", "убер", "выключ", "отключ") and not named
    )

    def score(option: dict) -> int:
        """Сколько слов названия сценария есть в команде."""
        return sum(
            1
            for word in cmd.words(option["title"])
            if len(word) > 3
            and any(similar(stem(word), other) or (len(other) >= 5 and distance(stem(word), other) <= 1) for other in wanted)
        )

    if normal:
        chosen = [option for option in options if option["id"] == "normal"]
    else:
        scored = [(score(option), option) for option in options]
        best = max((value for value, _ in scored), default=0)
        chosen = [option for value, option in scored if value == best] if best else []
    unit = item.name.split()[-1]
    if len(chosen) != 1:
        titles = ", ".join(f"«{option['title']}»" for option in (chosen or options))
        lead = "Какой именно сценарий? Подходят: " if chosen else f"Сценарии {item.name}: "
        return Draft(
            lead + titles + ".",
            done=not chosen,
            links=[link("telemetry")],
            suggestions=[f"Включи {option['title'].lower()} на {unit}" for option in (chosen or options)[:4]],
        )
    option = chosen[0]
    rules = ", ".join(option.get("expected_rules") or []) or "-"
    return Draft(
        f"Включить на {item.name} сценарий «{option['title']}»? Лента встанет на час наибольшего отклонения, "
        f"показания и диагноз пересчитаются.",
        params={"equipment_id": item.id, "scenario": option["id"]},
        details=[["Агрегат", item.name], ["Сценарий", option["title"]], ["Ожидаемые правила", rules]],
    )


def run_scenario(ctx: Ctx, params: dict) -> Draft:
    """Включает сценарий функцией маршрута пульта и пишет действие в журнал."""
    answer = call(telemetry_api.select_scenario, params["equipment_id"], params["scenario"], ctx.session)
    audit(ctx, "scenario_switch", {"equipment_id": params["equipment_id"], "scenario": params["scenario"]})
    scenario = answer["scenario"]
    return Draft(
        f"Сценарий «{scenario['title']}» включён на {params['equipment_id']}.",
        result={
            "title": "Сценарий включён",
            "rows": [
                ["Агрегат", params["equipment_id"]],
                ["Сценарий", scenario["title"]],
                ["Время ленты", answer["at"].replace("T", " ")[:16]],
            ],
        },
        links=[link("telemetry")],
    )


def plan_time(ctx: Ctx) -> Draft:
    """Новый момент ленты телеметрии: относительный сдвиг, дата и время, начало или конец записи."""
    item = find_unit(ctx, telemetry_only=True)
    player = player_of(item)
    first, last = player.bounds()
    target = cmd.target_time(ctx.text, player.cursor, first, last)
    if target is None:
        raise Ask(
            f"На какое время поставить ленту {item.name}? Сейчас {stamp(player.cursor)}, запись с {stamp(first)} "
            f"по {stamp(last)}.",
            ["Перемотай время стенда на 3 часа вперёд", "Перемотай время стенда в начало"],
        )
    if not first <= target <= last:
        raise Ask(f"Время {stamp(target)} вне записи: доступно с {stamp(first)} по {stamp(last)}.")
    return Draft(
        f"Переставить время стенда {item.name} с {stamp(player.cursor)} на {stamp(target)}?",
        params={"equipment_id": item.id, "at": target.isoformat(timespec="minutes")},
        details=[["Агрегат", item.name], ["Сейчас", stamp(player.cursor)], ["Станет", stamp(target)]],
    )


def run_time(ctx: Ctx, params: dict) -> Draft:
    """Переставляет ленту функцией маршрута пульта и пишет действие в журнал."""
    body = telemetry_api.CursorBody(at=params["at"])
    answer = call(telemetry_api.set_cursor, params["equipment_id"], body, ctx.session)
    audit(ctx, "move_time", {"equipment_id": params["equipment_id"], "at": answer["at"]})
    return Draft(
        f"Время стенда {params['equipment_id']}: {answer['at'].replace('T', ' ')[:16]}.",
        result={
            "title": "Время стенда",
            "rows": [["Агрегат", params["equipment_id"]], ["Время ленты", answer["at"].replace("T", " ")[:16]]],
        },
        links=[link("telemetry")],
    )


def plan_backup(ctx: Ctx) -> Draft:
    """Резервная копия базы."""
    return Draft(
        "Сделать резервную копию базы? Сервер не останавливается.",
        params={},
        details=[["Что", "Копия базы SQLite"], ["Куда", "папка backups рядом с базой"]],
    )


def run_backup(ctx: Ctx, params: dict) -> Draft:
    """Создаёт копию функцией маршрута POST /webadmin/backups и пишет действие в журнал."""
    view = call(webadmin_api.create_backup)
    audit(ctx, "backup", {"file": view["file"]})
    size = f"{round(view['size_bytes'] / 1048576, 1)} МБ"
    return Draft(
        f"Резервная копия создана: {view['file']}.",
        result={"title": "Резервная копия", "rows": [["Файл", view["file"]], ["Размер", size]]},
        links=[link("log")],
    )


def answer_server(ctx: Ctx) -> Draft:
    """Состояние сервера по каналам /health."""
    try:
        ctx.session.execute(sql_text("SELECT 1"))
        database = "ok"
    except Exception:
        database = "error"
    detector = getattr(ctx.request.app.state, "detector", None)
    channels = health.channels(detector, database)
    rows, bad = [], []
    for key, value in channels.items():
        for entry in value if isinstance(value, list) else [value]:
            label = CHANNEL_TITLES.get(key, key) + (f" · {entry['file']}" if entry.get("file") else "")
            state = entry.get("title") or entry.get("state") or "-"
            rows.append([label, state + (f" · {entry['detail']}" if entry.get("detail") else "")])
            if entry.get("state") != "ok":
                bad.append(label)
    rows.append(["Отпечаток моделей", fingerprint.short() or "-"])
    lead = "Все каналы сервера в порядке." if not bad else "Требуют внимания: " + ", ".join(bad) + "."
    lines = "\n".join(f"• {label}: {value}" for label, value in rows)
    return Draft(f"{lead}\n{lines}", done=True, result={"title": "Состояние сервера", "rows": rows}, links=[link("overview")])


def answer_models(ctx: Ctx) -> Draft:
    """Модели распознавания и отпечаток набора."""
    view = webadmin_api.models(ctx.request)
    rows = []
    for entry in view["models"]:
        state = "загружена" if entry["loaded"] else ("есть" if entry["present"] else "нет файла")
        rows.append([entry["file"], f"{entry.get('role') or ''} · {state}"])
    mark = view["fingerprint"]
    rows.append(["Отпечаток набора", (mark.get("fingerprint") if isinstance(mark, dict) else mark) or "-"])
    lines = "\n".join(f"• {label}: {value}" for label, value in rows)
    return Draft(
        f"Модели распознавания ({len(view['models'])}):\n{lines}",
        done=True,
        result={"title": "Модели распознавания", "rows": rows},
        links=[link("models")],
    )


def answer_equipment(ctx: Ctx) -> Draft:
    """Список оборудования с режимом и незакрытыми замечаниями."""
    items = equipment.list_equipment(ctx.session, None, None, None)
    rows = [[item["name"], f"{MODES.get(item['mode'], item['mode'])} · замечаний: {item['open_findings']}"] for item in items]
    lines = "\n".join(f"• {label}: {value}" for label, value in rows)
    return Draft(
        f"Оборудование ({len(items)}):\n{lines}",
        done=True,
        result={"title": "Оборудование", "rows": rows},
        links=[link("equipment")],
        suggestions=[f"Открой {items[0]['name'].split()[-1]}"] if items else [],
    )


def answer_unit(ctx: Ctx) -> Draft:
    """Краткая карточка агрегата и переход в раздел оборудования."""
    item = find_unit(ctx)
    summary = next(entry for entry in equipment.list_equipment(ctx.session, None, None, None) if entry["id"] == item.id)
    rows = [
        ["Агрегат", summary["name"]],
        ["Модель", summary.get("model") or "-"],
        ["Серийный номер", summary.get("serial") or "-"],
        ["Место", summary.get("location") or "-"],
        ["Режим", MODES.get(summary["mode"], summary["mode"])],
        ["Наработка, ч", str(summary.get("run_hours") or "-")],
        ["Незакрытых замечаний", str(summary["open_findings"])],
        ["Телеметрия", "есть" if summary["telemetry"] else "нет"],
    ]
    return Draft(
        f"{summary['name']}: {rows[4][1]}, незакрытых замечаний {summary['open_findings']}.",
        done=True,
        result={"title": summary["name"], "rows": rows},
        links=[{"label": f"{summary['name']} · Оборудование", "route": "equipment"}],
    )


def answer_summary(ctx: Ctx) -> Draft:
    """Сводка смены словами: идущие осмотры, незакрытые замечания, агрегаты, требующие внимания."""
    active = service.list_inspections(ctx.session, None, "active", 50)
    findings = service.list_findings(ctx.session, limit=500)
    unresolved = [entry for entry in findings if entry["state"] in ("open", "in_work")]
    waiting = [entry for entry in unresolved if entry["state"] == "open"]
    attention: dict[str, list[str]] = {}
    for entry in unresolved:
        attention.setdefault(entry["equipment_id"], []).append(entry["status"])
    alarms = {}
    for item in ctx.session.scalars(select(Equipment).order_by(Equipment.id)):
        if item.data.get("telemetry"):
            feed = telemetry_api.telemetry(item.id, ctx.session)
            if feed.get("level") in ("warn", "alarm"):
                alarms[item.id] = feed["level_title"].lower()
    tasks = ctx.session.scalar(select(func.count()).select_from(InspectionTask).where(InspectionTask.status == "open"))
    reports = ctx.session.scalar(select(func.count()).select_from(FaultReport).where(FaultReport.status == "new"))
    shift = site.site_info()
    units = sorted(set(attention) | set(alarms))
    names = {item.id: item.name for item in ctx.session.scalars(select(Equipment))}
    notes = []
    for unit in units:
        parts = []
        if unit in alarms:
            parts.append(f"телеметрия: {alarms[unit]}")
        if unit in attention:
            parts.append(f"замечаний: {len(attention[unit])}")
        notes.append(f"{names.get(unit, unit)} ({', '.join(parts)})")
    rows = [
        ["Смена", f"{shift['shift_title']} {shift['shift']}"],
        [
            "Идут осмотры",
            ", ".join(f"№ {entry['id']} {entry['equipment_id']} · {(entry['user'] or {}).get('name')}" for entry in active)
            or "нет",
        ],
        ["Незакрытых замечаний", str(len(unresolved))],
        ["Ждут подтверждения", str(len(waiting))],
        ["Требуют внимания", "; ".join(notes) or "нет"],
        ["Открытых заданий", str(tasks)],
        ["Новых сообщений о неисправности", str(reports)],
    ]
    text = (
        f"Сейчас идёт осмотров: {len(active)}. Незакрытых замечаний: {len(unresolved)}, из них ждут подтверждения "
        f"{len(waiting)}. "
        + (f"Требуют внимания: {'; '.join(notes)}. " if notes else "Агрегатов, требующих внимания, нет. ")
        + f"Открытых заданий: {tasks}, новых сообщений о неисправности: {reports}."
    )
    return Draft(
        text,
        done=True,
        result={"title": "Сводка смены", "rows": rows},
        links=[link("summary")],
        suggestions=["Какие находки ждут подтверждения?"] if waiting else [],
    )


def answer_pending(ctx: Ctx) -> Draft:
    """Находки, ждущие подтверждения мастером (состояние «открыто»)."""
    found = service.list_findings(ctx.session, state="open", limit=100)
    if not found:
        return Draft("Находок, ждущих подтверждения, нет.", done=True, links=[link("summary")])
    rows = [
        [f"№ {entry['id']} · {entry['equipment_id']}", f"{entry['title']} · {entry['status_title']}"]
        for entry in found[:MAX_ROWS]
    ]
    lines = "\n".join(f"• {label}: {value}" for label, value in rows)
    return Draft(
        f"Ждут подтверждения: {len(found)}.\n{lines}",
        done=True,
        result={"title": "Находки на подтверждение", "rows": rows},
        links=[link("summary")],
    )


def plan_task(ctx: Ctx) -> Draft:
    """Задание инженеру осмотреть агрегат: агрегат, исполнитель с правом осмотра, причина, срочность."""
    item = find_unit(ctx)
    engineer = one_user(
        ctx,
        f"Назначь осмотр {item.name.split()[-1]}",
        only=lambda user: user.is_active and "inspect.run" in granted(ctx.session, user),
    )
    reason = cmd.reason_of(ctx.text) or "Осмотр по поручению мастера"
    priority = "normal"
    if cmd.has(ctx.tokens, "срочн"):
        priority = "urgent"
    elif cmd.has(ctx.tokens, "высок", "приоритет"):
        priority = "high"
    due = None
    if cmd.has(ctx.tokens, "сегодня"):
        due = now().date()
    elif cmd.has(ctx.tokens, "завтра"):
        due = now().date() + timedelta(days=1)
    details = [
        ["Агрегат", item.name],
        ["Исполнитель", engineer.name],
        ["Причина", reason],
        ["Срочность", workflow.PRIORITY_TITLES[priority]],
    ]
    if due:
        details.append(["Срок", due.strftime("%d.%m.%Y")])
    return Draft(
        f"Назначить осмотр «{item.name}» исполнителю {engineer.name}?",
        params={
            "equipment_id": item.id,
            "assignee_id": engineer.id,
            "reason": reason,
            "priority": priority,
            "due_date": due.isoformat() if due else None,
        },
        details=details,
    )


def run_task(ctx: Ctx, params: dict) -> Draft:
    """Создаёт задание функцией маршрута POST /tasks и пишет действие в журнал."""
    body = workflow.TaskBody(**params)
    task = call(workflow.create_task, body, ctx.actor, ctx.session)
    audit(ctx, "assign_task", {"task": task["id"], "equipment_id": params["equipment_id"], "assignee_id": params["assignee_id"]})
    rows = [
        ["Задание", f"№ {task['id']}"],
        ["Агрегат", params["equipment_id"]],
        ["Исполнитель", (task.get("assignee") or {}).get("name", "")],
        ["Причина", params["reason"]],
    ]
    return Draft(
        f"Задание № {task['id']} назначено.", result={"title": "Задание на осмотр", "rows": rows}, links=[link("summary")]
    )


def answer_help(ctx: Ctx) -> Draft:
    """Что умеет ассистент - с примерами только тех команд, на которые у сотрудника есть права."""
    examples = [example for code, items in EXAMPLES.items() if code in ctx.rights for example in items]
    lines = "\n".join(f"• {example}" for example in examples)
    pages = [link(route) for route, codes in PAGE_PERMISSIONS.items() if allowed(ctx, codes) and route != "profile"]
    text = "Я выполняю команды панели с вашими правами и перед каждым действием показываю план на подтверждение."
    if examples:
        text += f" Например:\n{lines}"
    text += "\nЕщё могу открыть раздел («открой журнал безопасности») и рассказать о странице " "(«помощь по странице политика»)."
    return Draft(text, done=True, links=pages[:6], suggestions=examples[:4] or ["Открой профиль"])


def allowed(ctx: Ctx, codes: tuple[str, ...]) -> bool:
    """Доступен ли раздел: хватает одного из прав, раздел без прав доступен всем."""
    return not codes or any(code in ctx.rights for code in codes)


def answer_navigate(ctx: Ctx) -> Draft:
    """Переход в раздел панели; недоступный раздел - объяснение, каких прав не хватает."""
    route = cmd.page_of(ctx.tokens)
    codes = PAGE_PERMISSIONS[route]
    if not allowed(ctx, codes):
        return Draft(f"Раздел «{cmd.PAGES[route][0]}» вам недоступен - нужно право «{permission_title(codes[0])}».", done=True)
    return Draft(f"Открываю «{cmd.PAGES[route][0]}».", done=True, links=[link(route)])


def answer_page_help(ctx: Ctx) -> Draft:
    """Подсказка по странице панели."""
    route = cmd.page_of(ctx.tokens)
    return Draft(PAGE_HELP[route], done=True, links=[link(route)] if allowed(ctx, PAGE_PERMISSIONS[route]) else [])


def answer_delete(ctx: Ctx) -> Draft:
    """Удаление через ассистента не предусмотрено."""
    return Draft(
        "Удалять учётные записи и данные я не могу - в панели это не предусмотрено. Учётную запись можно "
        "заблокировать с причиной.",
        done=True,
        suggestions=["Заблокируй Смирнова, причина: увольнение"],
    )


@dataclass(frozen=True)
class Action:
    """Действие ассистента: право, название, опасность и функции разбора и выполнения."""

    permission: str | None
    title: str
    plan: Callable[[Ctx], Draft]
    run: Callable[[Ctx, dict], Draft] | None = None
    danger: bool = False


PHRASES = {
    "block_user": "Заблокируй",
    "unblock_user": "Разблокируй",
    "reset_password": "Сбрось пароль",
    "close_sessions": "Закрой сеансы",
    "change_role": "Смени роль",
}


def _user_action(action: str) -> tuple[Callable, Callable]:
    """Пара функций разбора и выполнения для действия над учётной записью."""
    return (lambda ctx: plan_user_action(ctx, action)), (lambda ctx, params: run_user_action(ctx, params, action))


ACTIONS: dict[str, Action] = {
    "create_user": Action("users.manage", "Создание учётной записи", plan_create_user, run_create_user),
    "reset_password": Action("users.manage", "Сброс пароля", *_user_action("reset_password"), danger=True),
    "block_user": Action("users.manage", "Блокировка учётной записи", *_user_action("block_user"), danger=True),
    "unblock_user": Action("users.manage", "Разблокировка учётной записи", *_user_action("unblock_user")),
    "change_role": Action("users.manage", "Смена роли", *_user_action("change_role"), danger=True),
    "close_sessions": Action("users.manage", "Закрытие сеансов", *_user_action("close_sessions")),
    "list_temp": Action("users.manage", "Список временных паролей", lambda ctx: answer_user_list(ctx, "list_temp")),
    "list_blocked": Action("users.manage", "Список заблокированных", lambda ctx: answer_user_list(ctx, "list_blocked")),
    "security_events": Action("security.log", "Журнал безопасности", answer_security_events),
    "policy_show": Action("security.policy", "Политика безопасности", answer_policy),
    "policy_set": Action("security.policy", "Изменение политики безопасности", plan_policy, run_policy, danger=True),
    "scenario_switch": Action("telemetry.control", "Сценарий телеметрии", plan_scenario, run_scenario, danger=True),
    "move_time": Action("telemetry.control", "Время стенда", plan_time, run_time),
    "backup": Action("system.manage", "Резервная копия базы", plan_backup, run_backup),
    "server_state": Action("system.manage", "Состояние сервера", answer_server),
    "models": Action("system.manage", "Модели распознавания", answer_models),
    "equipment_list": Action("equipment.view", "Список оборудования", answer_equipment),
    "open_unit": Action("equipment.view", "Карточка агрегата", answer_unit),
    "shift_summary": Action("findings.view", "Сводка смены", answer_summary),
    "findings_pending": Action("findings.view", "Находки на подтверждение", answer_pending),
    "assign_task": Action("tasks.assign", "Задание на осмотр", plan_task, run_task),
    "help": Action(None, "Что я умею", answer_help),
    "navigate": Action(None, "Переход в раздел", answer_navigate),
    "page_help": Action(None, "Помощь по странице", answer_page_help),
    "unsupported_delete": Action(None, "Удаление", answer_delete),
}


def plan_id(actor: User, action: str, params: dict, details: list[list[str]]) -> str:
    """Отпечаток плана: сотрудник, действие, параметры и показанные значения; любая правка плана меняет его."""
    raw = json.dumps([actor.id, action, params, details], ensure_ascii=False, sort_keys=True, default=str)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def reply_of(draft: Draft, plan: dict | None = None) -> dict:
    """Ответ по контракту из разобранной команды."""
    return {
        "reply": draft.reply,
        "plan": plan,
        "done": draft.done,
        "result": draft.result,
        "links": draft.links,
        "suggestions": draft.suggestions,
    }


def unknown_reply(ctx: Ctx) -> dict:
    """Команда не узнана: ассистент ничего не делает и подсказывает, что умеет."""
    examples = [example for code, items in EXAMPLES.items() if code in ctx.rights for example in items]
    return reply_of(
        Draft(
            "Не понял команду, поэтому ничего не делаю. Скажите «что ты умеешь» - покажу список команд.",
            suggestions=["Что ты умеешь?", *examples[:3]],
        )
    )


def handle(ctx: Ctx, confirm: bool, submitted: dict | None) -> dict:
    """Разбирает команду, проверяет права и при подтверждении выполняет действие."""
    name = cmd.detect(ctx.text)
    if name is None:
        return unknown_reply(ctx)
    action = ACTIONS[name]
    if action.permission and action.permission not in ctx.rights:
        return reply_of(
            Draft(
                f"Не могу: для действия «{action.title.lower()}» нужно право "
                f"«{permission_title(action.permission)}», а у вашей роли его нет. Обратитесь к "
                f"администратору ИБ."
            )
        )
    try:
        draft = action.plan(ctx)
    except Ask as question:
        return reply_of(Draft(question.reply, suggestions=question.suggestions))
    draft.links = [item for item in draft.links if allowed(ctx, PAGE_PERMISSIONS.get(item["route"], ()))]
    if draft.params is None or action.run is None:
        return reply_of(draft)
    plan = {
        "id": plan_id(ctx.actor, name, draft.params, draft.details),
        "action": name,
        "title": action.title,
        "details": draft.details,
        "danger": action.danger,
    }
    if not confirm or submitted is None:
        return reply_of(draft, plan)
    keys = ("id", "action", "title", "details", "danger")
    if any(submitted.get(key) != plan[key] for key in keys):
        return reply_of(
            Draft(
                "План не совпадает с командой - ничего не выполнено. Проверьте новый план и подтвердите " "его ещё раз.",
                details=draft.details,
            ),
            plan,
        )
    token = security.VIA.set(VIA)
    try:
        done = action.run(ctx, draft.params)
    except Ask as problem:
        return reply_of(Draft(problem.reply, suggestions=problem.suggestions))
    finally:
        security.VIA.reset(token)
    logger.info("Ассистент выполнил действие %s для сотрудника %s", name, ctx.actor.id)
    done.done = True
    done.links = [item for item in done.links if allowed(ctx, PAGE_PERMISSIONS.get(item["route"], ()))]
    return reply_of(done)


@router.post("/assistant", response_model=AssistantReply)
def assistant(
    body: AssistantBody,
    request: Request,
    actor: Annotated[User, Depends(current_user)],
    session: Annotated[Session, Depends(get_session)],
) -> dict:
    """Ассистент панели: команда по-русски - план или ответ; confirm=true с планом - выполнение с правами сотрудника.

    Без confirm ничего не меняется. При подтверждении текст разбирается заново и план сверяется с присланным;
    расхождение - ничего не выполняется, возвращается новый план. Временный пароль - только в result.secret.
    """
    ctx = Ctx(body.text.strip(), cmd.words(body.text), actor, granted(session, actor), session, request)
    return handle(ctx, body.confirm, body.plan)
