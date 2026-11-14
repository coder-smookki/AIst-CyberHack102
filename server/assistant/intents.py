"""Ответы помощника: намерение вопроса и ответ, собранный только из найденных данных.

Каждая строка ответа строится из записей: карточек оборудования, осмотров, замечаний, работ, документов,
правил диагностики и показаний датчиков. Если данных нет, помощник так и отвечает и предлагает примеры
вопросов. Ссылки вида kstvizor://... открывает мобильное приложение.
"""
import json
import re
from dataclasses import dataclass, field
from datetime import date, datetime
from functools import cached_property
from urllib.parse import quote

from sqlalchemy import func, select
from sqlalchemy.orm import Session, joinedload, selectinload

from server.assistant import search
from server.auth import role_title
from server.equipment import equipment_card
from server.models import Equipment, Finding, Inspection, MaintenanceRecord
from server.rules import diagnose, load_rules, maintenance_intervals, resource_estimates
from server.telemetry import CODES, TelemetryDataError, get_player

SCHEME = "kstvizor://"
MAX_LINKS = 12
MAX_UNITS = 3
MAX_EVENTS = 6
MAX_REASONS = 5
MAX_RULES = 3
TREND_HOURS = 12
RECORD_LIMIT = 500
NO_TELEMETRY = "телеметрия не подключена, показаний датчиков нет"
TELEMETRY_DOWN = "данные телеметрии сейчас недоступны"
DECISION_LINE = "Решение принимает инженер."

RULE_ID = re.compile(r"(?<![a-zа-я0-9])([rрsv])-?(\d{1,2})(?![a-zа-я0-9])")
RULE_NUMBER = re.compile(r"правил[а-я]*\s+№?(\d{1,2})(?!\d)")
RULE_LETTERS = {"r": "R", "р": "R", "s": "S", "v": "V"}
PLACEHOLDER = re.compile(r"[:.,]?\s*\{[a-z_]+\}")
DECIMAL_POINT = re.compile(r"(\d)\.(\d+)(?= (?:%|ч|сут))")

RULE_WORDS = ("правил",)
DOCUMENT_WORDS = ("документ", "паспорт", "инструкц", "руководств", "мануал")
ATTENTION_WORDS = ("вниман", "проблем", "срочн", "критич", "приоритет", "тревог", "авари")
STATE_WORDS = ("состоян", "статус")
FINDING_WORDS = ("замечан", "дефект", "находк", "неисправност", "нарушен", "поломк", "открыт", "незакрыт", "неустран")
JOURNAL_WORDS = ("истор", "хронолог", "журнал", "событи")
INSPECTION_WORDS = ("осмотр", "обход", "осматрив")
WORK_WORDS = ("проводил", "выполнял", "делал", "ремонтировал")
WORK_TOKENS = frozenset(("работы", "работ", "работах"))
WORK_PHRASES = ("что было", "что происходило", "что случилось")
MAINTENANCE_WORDS = ("обслуживан", "техобслуживан", "регламент", "ревизи", "ремонт", "ресурс", "замен", "менять",
                     "менял", "поменя", "межремонтн", "наработк", "моточас", "срок")
MAINTENANCE_TOKENS = frozenset(("то", "то1", "то2", "тр"))
TELEMETRY_WORDS = ("телеметри", "показани", "график", "тренд")
RESOLVED_WORDS = ("устранен", "закрыт", "исправлен")
CARD_WORDS = ("производител", "изготовител", "модел", "серийн", "заводск", "расположен", "установлен", "режим")
LIST_WORDS = ("список", "перечень", "перечисл")
STOPPED_WORDS = ("остановлен", "простаива")
RUNNING_PHRASES = ("в работе", "работают", "работает", "запущен")
EVERYWHERE_TOKENS = frozenset(("агрегаты", "агрегатов", "агрегатам", "агрегатах", "насосы", "насосов", "насосам",
                               "насосах", "везде"))
EVERYWHERE_PHRASES = ("какое оборудование", "все оборудование", "всего оборудования", "всему оборудованию")
TYPO_WORDS = ("истори", "уставк", "серийн", "последн", "следующ", "оборудован", "находит", "расположен", "работает",
              "требует", "показат", "сколько")
EXPLAIN_PHRASES = ("что делать", "как устранить", "как исправить", "что значит", "что означает", "что такое",
                   "о чем говорит", "почему", "причин")
EXPLAIN_SKIP = frozenset(search.stem(word) for word in ("устранить", "исправить", "причина", "причины", "говорит"))
PARAMETER_FAMILIES = (
    (("вибрац", "виброскорост", "скз"), (
        ("vib_rms", ("скз", "общ")), ("vib_1x", ("1x", "1х", "оборотн")), ("vib_2x", ("2x", "2х")),
        ("vib_hf", ("вч", "высокочастотн", "шум")), ("vib_axial", ("осев",)))),
    (("температур", "нагрев"), (("temp_bearing", ("подшипник",)), ("temp_winding", ("обмот", "двигател", "электродвигател")))),
    (("давлен",), (
        ("press_in", ("вход", "всас")), ("press_out", ("выход", "нагнетан")), ("press_out_true", ("манометр", "стрелочн")))),
    (("ток", "небаланс"), (
        ("current_a", ("фаз",)), ("current_b", ("фаз",)), ("current_c", ("фаз",)),
        ("current_unbalance", ("небаланс", "перекос")))),
    (("расход", "подач"), (("flow", ()),)),
    (("мощност",), (("power", ()),)),
    (("кпд",), (("efficiency", ()),)),
    (("оборот",), (("rpm", ()),)),
)
EXACT_WORDS = frozenset(("ток", "скз", "кпд", "вч", "1x", "1х", "2x", "2х"))

MODE_TITLES = {"running": "в работе", "stopped": "остановлен"}
STATUS_TITLES = {"ok": "без замечаний", "check": "требует проверки", "defect": "признаки возможного дефекта"}
STATE_TITLES = {"open": "открыто", "in_work": "в работе", "resolved": "устранено"}
WORK_TITLES = {"checked": "проверка", "maintenance": "обслуживание", "replacement": "замена"}
SENSOR_TITLES = {"ok": "отклонений по датчикам нет", "check": "рекомендуется проверка",
                 "defect": "обнаружены признаки возможного дефекта", "unknown": "недостаточно данных датчиков по этому узлу"}
LEVEL_TITLES = {"ok": "норма", "warn": "уставки предупреждения", "alarm": "уставки тревоги"}
SOURCE_TITLES = {"customer": "база заказчика", "model": "модельный ряд"}
LABEL_TITLES = (("vibration", "по вибрации"), ("temperature", "по температуре"))
RECORD_TITLES = {"finding": "Замечание", "maintenance": "Запись о работах", "document": "Документ", "node": "Узел",
                 "rule": "Правило"}


def deeplink(*path) -> str:
    """Собирает ссылку для мобильного приложения; части пути кодируются, чтобы обозначение не сломало адрес."""
    return SCHEME + "/".join(quote(str(part), safe="") for part in path)


def _number(value) -> str:
    """Записывает число по-русски: не больше двух знаков после запятой, без лишних нулей."""
    text = f"{float(value):.2f}".rstrip("0").rstrip(".")
    return text.replace(".", ",")


def _day(moment) -> str:
    """Записывает дату в виде ДД.ММ.ГГГГ."""
    return moment.strftime("%d.%m.%Y")


def _moment(moment: datetime) -> str:
    """Записывает дату и время в виде ДД.ММ.ГГГГ ЧЧ:ММ."""
    return moment.strftime("%d.%m.%Y %H:%M")


def _plural(count: int, one: str, few: str, many: str) -> str:
    """Подбирает форму слова к числу: 1 осмотр, 2 осмотра, 5 осмотров."""
    tail = abs(int(count)) % 100
    if 11 <= tail <= 14:
        return many
    if tail % 10 == 1:
        return one
    if 2 <= tail % 10 <= 4:
        return few
    return many


def _sentence(text: str) -> str:
    """Убирает пробелы по краям и ставит точку в конце, если предложение не закончено знаком."""
    text = " ".join(str(text).split())
    return text if not text or text[-1] in ".!?" else text + "."


def _lower_first(text: str) -> str:
    """Делает первую букву строчной, чтобы вставить текст в середину предложения; сокращения вроде «ВЧ» не трогает."""
    if len(text) > 1 and text[1].isupper():
        return text
    return text[:1].lower() + text[1:]


def _resource_text(calculated: dict) -> str:
    """Готовит строку расчётного ресурса для вставки в предложение: со строчной буквы и с десятичной запятой."""
    return _sentence(DECIMAL_POINT.sub(r"\1,\2", _lower_first(calculated["text"])))


def _plain(text: str | None) -> str:
    """Убирает из текста правила места подстановки вида {items}: в описании правила подставлять нечего."""
    return PLACEHOLDER.sub("", text or "").strip()


@dataclass
class Reply:
    """Ответ помощника: намерение, строки-факты, ссылки и признак того, что данные найдены."""

    intent: str
    facts: list[str] = field(default_factory=list)
    links: list[dict] = field(default_factory=list)
    found: bool = True

    @property
    def answer(self) -> str:
        """Текст ответа: факты по одному на строку."""
        return "\n".join(self.facts)

    def say(self, line: str) -> None:
        """Добавляет строку ответа."""
        self.facts.append(line)

    def link(self, kind: str, title: str, *path) -> None:
        """Добавляет ссылку для приложения, собирая адрес из частей пути."""
        self.attach(kind, title, deeplink(*path))

    def attach(self, kind: str, title: str, target: str) -> None:
        """Добавляет готовую ссылку; повторы и ссылки сверх предела пропускаются."""
        if len(self.links) < MAX_LINKS and all(entry["deeplink"] != target for entry in self.links):
            self.links.append({"title": title, "deeplink": target, "kind": kind})


@dataclass
class Unit:
    """Агрегат вместе с карточкой и текущими показаниями: всё, что нужно для ответа о нём."""

    item: Equipment
    card: dict
    fallback_day: date

    @property
    def id(self) -> str:
        """Обозначение агрегата."""
        return self.item.id

    @property
    def label(self) -> str:
        """Название агрегата с обозначением."""
        return f"{self.item.name} ({self.item.id})"

    @property
    def node_names(self) -> dict[str, str]:
        """Названия узлов по их кодам."""
        return {node["id"]: node["name"] for node in self.card["nodes"]}

    @cached_property
    def live(self) -> dict | None:
        """Показания на момент курсора телеметрии с описанием параметров; None, если телеметрии нет."""
        try:
            player = get_player(self.item.id)
        except (KeyError, TelemetryDataError):
            return None
        moment = player.cursor
        readings = player.snapshot(moment)
        if not readings:
            return None
        return {"player": player, "moment": moment, "readings": readings,
                "parameters": {entry["code"]: entry for entry in player.parameters(moment)}}

    @cached_property
    def telemetry_note(self) -> str:
        """Объясняет, почему показаний нет: агрегат без датчиков или лента телеметрии недоступна."""
        try:
            get_player(self.item.id)
        except TelemetryDataError:
            return TELEMETRY_DOWN
        except KeyError:
            return NO_TELEMETRY
        return TELEMETRY_DOWN

    @property
    def today(self) -> date:
        """Текущий день для расчёта ресурса: момент ленты телеметрии, а без неё - сегодняшняя дата."""
        return self.live["moment"].date() if self.live else self.fallback_day

    @property
    def run_hours(self) -> float:
        """Наработка агрегата: по счётчику телеметрии, а без неё - из карточки."""
        if self.live:
            return self.live["readings"].get("run_hours", self.item.run_hours)
        return self.item.run_hours

    @cached_property
    def diagnosis(self) -> dict | None:
        """Диагноз по датчикам на момент курсора: без камеры и отметок инженера; None без телеметрии."""
        if not self.live:
            return None
        player, moment = self.live["player"], self.live["moment"]
        trends = {}
        for code in CODES:
            slope = player.trend(code, TREND_HOURS, moment)
            if slope is not None:
                trends[code] = slope
        return diagnose(self.card, self.live["readings"], trends, {})

    def resource(self, node: dict) -> dict:
        """Нормативный срок и расчётный остаток ресурса узла."""
        return resource_estimates(self.card, node, self.run_hours, self.today)


def _load_units(session: Session, today: date) -> list[Unit]:
    """Читает всё оборудование с узлами и готовит карточки."""
    items = session.scalars(select(Equipment).options(selectinload(Equipment.nodes)).order_by(Equipment.id))
    return [Unit(item=item, card=equipment_card(item), fallback_day=today) for item in items]


def _vocabulary(units: list[Unit], rules: list[dict]) -> frozenset[str]:
    """Собирает словарь для исправления опечаток: слова карточек, названий правил и слова самих вопросов."""
    result = set(search.base_vocabulary()) | set(TYPO_WORDS)
    for group in (RULE_WORDS, DOCUMENT_WORDS, ATTENTION_WORDS, STATE_WORDS, FINDING_WORDS, JOURNAL_WORDS,
                  INSPECTION_WORDS, WORK_WORDS, MAINTENANCE_WORDS, TELEMETRY_WORDS, RESOLVED_WORDS, CARD_WORDS,
                  LIST_WORDS, STOPPED_WORDS):
        result.update(group)
    for family, members in PARAMETER_FAMILIES:
        result.update(family)
        for _, qualifiers in members:
            result.update(qualifiers)
    for unit in units:
        result |= search.unit_vocabulary(unit.card)
    for rule in rules:
        result |= search.stems_of(rule.get("title") or "")
    return frozenset(result)


def _has_token(query: search.Query, tokens: frozenset[str]) -> bool:
    """Проверяет, что в вопросе есть одно из слов целиком: «ТО» не должно находиться внутри «торцевое»."""
    return any(token in tokens for token in query.tokens)


def _has_word(query: search.Query, *prefixes: str) -> bool:
    """Проверяет слово вопроса: короткие слова вроде «ток» и «кпд» сравниваются целиком, остальные - по началу."""
    exact = [prefix for prefix in prefixes if prefix in EXACT_WORDS]
    loose = [prefix for prefix in prefixes if prefix not in EXACT_WORDS]
    if any(token in exact or base in exact for token, base in zip(query.tokens, query.stems)):
        return True
    return bool(loose) and query.has(*loose)


def _choose_units(query: search.Query, units: list[Unit], equipment_id: str | None) -> tuple[list[Unit], bool]:
    """Определяет агрегаты, о которых вопрос, и сообщает, названы ли они в самом вопросе.

    Без названия берётся агрегат, открытый в приложении. Если слова вопроса одинаково подходят нескольким
    агрегатам, открытый агрегат выбирает среди них. Вопрос обо всём оборудовании сразу («какие агрегаты...»,
    «везде») открытым агрегатом не сужается.
    """
    scores = search.match_units(query, [unit.card for unit in units])
    everywhere = _has_token(query, EVERYWHERE_TOKENS) or any(phrase in query.text for phrase in EVERYWHERE_PHRASES)
    context = [] if everywhere else [unit for unit in units if unit.id == equipment_id]
    if not scores:
        return context, False
    top = max(scores.values())
    named = [unit for unit in units if scores.get(unit.id) == top]
    if len(named) > 1 and context and context[0] in named:
        return context, True
    return named, True


def _node_hits(query: search.Query, units: list[Unit]) -> list[tuple[Unit, dict]]:
    """Находит узлы, названные в вопросе, у каждого из агрегатов; слабые совпадения отбрасываются."""
    hits = []
    for unit in units:
        node, score = search.match_node(query, unit.card["nodes"])
        if node is not None and score >= 2.0:
            hits.append((unit, node))
    return hits


def _names_node(query: search.Query) -> bool:
    """Проверяет, что в вопросе есть разговорное название какого-либо узла оборудования."""
    known = {word for group in search.NODE_WORDS.values() for word in group}
    return any(search.has_stem(known, base) for token, base in zip(query.tokens, query.stems) if len(token) > 2)


def _parameter_codes(query: search.Query) -> list[str]:
    """Определяет параметры телеметрии, о которых спрашивают: семейство по слову, параметр по уточнению."""
    codes = []
    for family, members in PARAMETER_FAMILIES:
        if not _has_word(query, *family):
            continue
        exact = [code for code, qualifiers in members if qualifiers and _has_word(query, *qualifiers)]
        codes += exact or [code for code, _ in members]
    return codes


def _person(user) -> str:
    """Кто выполнил осмотр или работу: имя и должность."""
    if user is None:
        return "исполнитель не указан"
    return f"{user.name} ({role_title(user)})"


def _finding_line(finding: Finding, names: dict[str, str]) -> str:
    """Описывает замечание одной строкой: название, узел, правило, оценка и состояние устранения."""
    node = names.get(finding.node_code)
    where = f", узел «{node}»" if node else ""
    rule = f", правило {finding.rule_id}" if finding.rule_id else ""
    status = STATUS_TITLES.get(finding.status, finding.status)
    state = STATE_TITLES.get(finding.state, finding.state)
    return f"{finding.title}{where}{rule}: {status}, {state}, запись от {_day(finding.created_at)}"


def _remarks(findings) -> list[Finding]:
    """Оставляет записи осмотра с замечаниями: отметки «проверено» и записи о работах сюда не входят."""
    return [finding for finding in findings if finding.status != "ok"]


def _unresolved(session: Session, equipment_id: str, node_code: str | None = None) -> list[Finding]:
    """Читает незакрытые замечания агрегата или одного его узла, сначала новые."""
    query = select(Finding).where(Finding.equipment_id == equipment_id, Finding.state.notin_(("resolved", "rejected")),
                                  Finding.status != "ok")
    if node_code is not None:
        query = query.where(Finding.node_code == node_code)
    return list(session.scalars(query.order_by(Finding.created_at.desc(), Finding.id.desc()).limit(RECORD_LIMIT)))


def _inspections(session: Session, equipment_id: str, limit: int) -> list[Inspection]:
    """Читает последние осмотры агрегата вместе с исполнителем и записями."""
    query = select(Inspection).where(Inspection.equipment_id == equipment_id).options(
        joinedload(Inspection.user), selectinload(Inspection.findings))
    return list(session.scalars(query.order_by(Inspection.started_at.desc(), Inspection.id.desc()).limit(limit)))


def _works(session: Session, equipment_id: str, limit: int, node_code: str | None = None) -> list[MaintenanceRecord]:
    """Читает последние записи о работах на агрегате или на одном его узле."""
    query = select(MaintenanceRecord).where(MaintenanceRecord.equipment_id == equipment_id)
    if node_code is not None:
        query = query.where(MaintenanceRecord.node_code == node_code)
    query = query.options(joinedload(MaintenanceRecord.user))
    return list(session.scalars(query.order_by(MaintenanceRecord.at.desc(), MaintenanceRecord.id.desc()).limit(limit)))


def _inspection_line(inspection: Inspection) -> str:
    """Описывает осмотр одной строкой истории: когда, кто и с каким результатом."""
    head = f"{_moment(inspection.started_at)} - осмотр, {_person(inspection.user)}"
    if inspection.status != "finished":
        return f"{head}: осмотр не завершён."
    remarks = _remarks(inspection.findings)
    if not remarks:
        return f"{head}: замечаний нет."
    listed = "; ".join(f"{finding.title} ({STATUS_TITLES.get(finding.status, finding.status)}, "
                       f"{STATE_TITLES.get(finding.state, finding.state)})" for finding in remarks)
    return f"{head}: {len(remarks)} {_plural(len(remarks), 'замечание', 'замечания', 'замечаний')} - {listed}."


def _work_line(record: MaintenanceRecord, names: dict[str, str]) -> str:
    """Описывает запись о работе одной строкой истории: когда, что, на каком узле и при какой наработке."""
    node = names.get(record.node_code)
    where = f", узел «{node}»" if node else ""
    hours = f" Наработка {_number(record.hours_at)} ч." if record.hours_at is not None else ""
    comment = _sentence(record.comment or "без описания")
    return (f"{_moment(record.at)} - {WORK_TITLES.get(record.kind, record.kind)}{where}: {comment}{hours} "
            f"Выполнил: {_person(record.user)}.")


def _level(meta: dict, value: float) -> str | None:
    """Сравнивает значение с уставками параметра: "ok", "warn", "alarm" или None, если уставок нет."""
    warn, alarm, direction = meta.get("warn"), meta.get("alarm"), meta.get("direction")
    if direction not in ("high", "low") or warn is None:
        return None
    beyond = (lambda limit: value > limit) if direction == "high" else (lambda limit: value < limit)
    if alarm is not None and beyond(alarm):
        return "alarm"
    return "warn" if beyond(warn) else "ok"


def _reading(meta: dict, value: float) -> str:
    """Записывает показание с единицей измерения и оценкой по уставкам."""
    unit = f" {meta['unit']}" if meta.get("unit") else ""
    level = _level(meta, value)
    text = f"{meta['name']} {_number(value)}{unit}"
    if level is None:
        return f"{text} - уставки не заданы"
    if level == "ok":
        return f"{text} - норма"
    side = "выше" if meta["direction"] == "high" else "ниже"
    return f"{text} - {side} {LEVEL_TITLES[level]}"


def _limits(meta: dict) -> str:
    """Записывает уставки параметра; пустая строка, если их нет."""
    if _level(meta, 0.0) is None:
        return ""
    side = "выше" if meta["direction"] == "high" else "ниже"
    unit = f" {meta['unit']}" if meta.get("unit") else ""
    text = f"предупреждение {side} {_number(meta['warn'])}{unit}"
    if meta.get("alarm") is not None:
        text += f", тревога {side} {_number(meta['alarm'])}{unit}"
    return text


def _sensor_findings(unit: Unit) -> list[dict]:
    """Возвращает находки диагностики по датчикам; сроки обслуживания сюда не входят - они считаются отдельно."""
    if not unit.diagnosis:
        return []
    return [found for found in unit.diagnosis["findings"]
            if {line.get("source") for line in found.get("evidence") or []} != {"resource"}]


def _interval_line(entry: dict) -> str:
    """Описывает один вид обслуживания: интервал, наработка после последнего и остаток."""
    if entry["state"] == "insufficient_data":
        return f"{entry['name']}: недостаточно данных - нет: {'; '.join(entry['missing'])}."
    head = (f"{entry['name']}: интервал {_number(entry['interval_hours'])} ч, после последнего обслуживания "
            f"{_number(entry['since_hours'])} ч")
    if entry["state"] == "due":
        over = entry["since_hours"] - entry["interval_hours"]
        return f"{head} - срок наступил, превышение {_number(over)} ч."
    tail = f"осталось {_number(entry['remaining_hours'])} ч"
    return f"{head}, {tail} - срок приближается." if entry["state"] == "approaching" else f"{head}, {tail}."


def _reasons(session: Session, unit: Unit) -> list[tuple[int, str, tuple]]:
    """Собирает причины обратить внимание на агрегат: важность, строка ответа и ссылка.

    Порядок важности тот же, что в маршруте осмотра: незакрытое замечание, затем отклонение по датчикам,
    затем наступивший и приближающийся срок обслуживания или ресурса узла.
    """
    names = unit.node_names
    reasons = []
    for finding in _unresolved(session, unit.id):
        reasons.append((0 if finding.status == "defect" else 1,
                        f"Незакрытое замечание: {_finding_line(finding, names)}.",
                        ("finding", finding.title, "finding", finding.id)))
    for found in _sensor_findings(unit):
        status = SENSOR_TITLES.get(found["status"], found["status"])
        reasons.append((2 if found["status"] == "defect" else 3,
                        f"По датчикам на {_moment(unit.live['moment'])}: {found['title']} (правило "
                        f"{found['rule_id']}) - {status}.",
                        ("rule", f"Правило {found['rule_id']}: {found['title']}", "rule", found["rule_id"])))
    for entry in maintenance_intervals(unit.card, unit.run_hours):
        if entry["state"] in ("due", "approaching"):
            reasons.append((4 if entry["state"] == "due" else 5, f"Обслуживание - {_interval_line(entry)}",
                            ("equipment", unit.item.name, "equipment", unit.id)))
    for node in unit.card["nodes"]:
        calculated = unit.resource(node)["calculated"]
        if calculated["state"] in ("due", "approaching"):
            reasons.append((4 if calculated["state"] == "due" else 5,
                            f"Ресурс узла «{node['name']}»: {_resource_text(calculated)}",
                            ("node", f"{node['name']} - {unit.item.name}", "equipment", unit.id, "node", node["id"])))
    reasons.sort(key=lambda reason: reason[0])
    return reasons


def _urgency(reasons: list[tuple[int, str, tuple]]) -> tuple[int, ...]:
    """Срочность агрегата для сортировки: важность его главных причин, недостающие места - как «причин нет»."""
    ranks = [reason[0] for reason in reasons[:MAX_REASONS]]
    return tuple(ranks) + (9,) * (MAX_REASONS - len(ranks))


def _say_reasons(reply: Reply, reasons: list[tuple[int, str, tuple]], limit: int) -> None:
    """Выводит причины списком и добавляет их ссылки; сверх предела сообщает, сколько ещё осталось."""
    for _, line, link in reasons[:limit]:
        reply.say(f"- {line}")
        reply.link(*link)
    if len(reasons) > limit:
        rest = len(reasons) - limit
        reply.say(f"- И ещё {rest} {_plural(rest, 'причина', 'причины', 'причин')} - откройте карточку агрегата.")


def _card(session: Session, reply: Reply, unit: Unit) -> None:
    """Отвечает карточкой агрегата: что это, где стоит, в каком режиме и что требует внимания."""
    item = unit.item
    maker = unit.card.get("manufacturer")
    reply.say(f"{unit.label}: модель {item.model}, серийный номер {item.serial}"
              + (f", производитель {maker}." if maker else "."))
    reply.say(f"Место установки: {item.location}. Режим: {MODE_TITLES.get(item.mode, item.mode)}. "
              f"Наработка: {_number(unit.run_hours)} ч.")
    latest = session.scalar(select(func.max(Inspection.started_at)).where(Inspection.equipment_id == unit.id))
    reply.say(f"Последний осмотр: {_moment(latest)}." if latest else "Осмотров агрегата в базе нет.")
    reply.link("equipment", item.name, "equipment", unit.id)
    reasons = _reasons(session, unit)
    if reasons:
        reply.say("Требует внимания:")
        _say_reasons(reply, reasons, MAX_REASONS + 2)
    else:
        reply.say("Незакрытых замечаний, отклонений по датчикам и подходящих сроков обслуживания не найдено.")
    reply.link("history", f"История: {item.name}", "equipment", unit.id, "history")


def _attention(session: Session, units: list[Unit]) -> Reply:
    """Отвечает, какие агрегаты требуют внимания и почему; агрегаты идут от самых срочных.

    Ссылки даются на агрегаты, требующие внимания; если таких нет - на все.
    """
    reply = Reply("attention")
    if not units:
        reply.say("В базе нет оборудования.")
        reply.found = False
        return reply
    listed = [(unit, _reasons(session, unit)) for unit in units]
    listed.sort(key=lambda entry: (_urgency(entry[1]), entry[0].id))
    urgent = [entry for entry in listed if entry[1]]
    for unit, _ in urgent or listed:
        reply.link("equipment", unit.item.name, "equipment", unit.id)
    if len(units) > 1:
        reply.say(f"Внимания требуют {len(urgent)} из {len(units)} "
                  f"{_plural(len(units), 'агрегата', 'агрегатов', 'агрегатов')}.")
    for unit, reasons in listed:
        place = f"{unit.label}, {unit.item.location}, {MODE_TITLES.get(unit.item.mode, unit.item.mode)}"
        if not reasons:
            reply.say(f"{place}: незакрытых замечаний, отклонений по датчикам и подходящих сроков не найдено.")
        else:
            reply.say(f"{place} - {len(reasons)} {_plural(len(reasons), 'причина', 'причины', 'причин')}:")
            _say_reasons(reply, reasons, MAX_REASONS if len(units) > 1 else MAX_REASONS + 2)
    return reply


def _overview(session: Session, units: list[Unit]) -> Reply:
    """Отвечает карточками названных агрегатов."""
    reply = Reply("equipment")
    for unit in units[:MAX_UNITS]:
        _card(session, reply, unit)
    _note_cut(reply, units)
    return reply


def _note_cut(reply: Reply, units: list[Unit]) -> None:
    """Сообщает, что показаны не все подходящие агрегаты, если их больше предела."""
    if len(units) > MAX_UNITS:
        reply.say(f"Показаны первые {MAX_UNITS} из {len(units)} агрегатов - уточните агрегат в вопросе.")


def _history(session: Session, units: list[Unit]) -> Reply:
    """Отвечает историей агрегатов: осмотры и записи о работах, сначала новые."""
    reply = Reply("history")
    shown = units[:MAX_UNITS]
    per_unit = MAX_EVENTS if len(shown) == 1 else 3
    for unit in shown:
        inspections = _inspections(session, unit.id, RECORD_LIMIT)
        works = _works(session, unit.id, RECORD_LIMIT)
        reply.link("history", f"История: {unit.item.name}", "equipment", unit.id, "history")
        if not inspections and not works:
            reply.say(f"{unit.label}: история пуста - осмотров и записей о работах нет.")
            continue
        reply.say(f"{unit.label}: в истории {len(inspections)} "
                  f"{_plural(len(inspections), 'осмотр', 'осмотра', 'осмотров')} и {len(works)} "
                  f"{_plural(len(works), 'запись', 'записи', 'записей')} о работах.")
        events = [(entry.started_at, 1, entry.id, entry) for entry in inspections]
        events += [(entry.at, 0, entry.id, entry) for entry in works]
        events.sort(key=lambda event: event[:3], reverse=True)
        for _, is_inspection, _, entry in events[:per_unit]:
            if is_inspection:
                reply.say(f"- {_inspection_line(entry)}")
                reply.link("inspection", f"Осмотр {_day(entry.started_at)} - {unit.item.name}", "inspection", entry.id)
            else:
                reply.say(f"- {_work_line(entry, unit.node_names)}")
        if len(events) > per_unit:
            reply.say(f"Показаны последние {per_unit} из {len(events)} "
                      f"{_plural(len(events), 'события', 'событий', 'событий')} - полная история по ссылке.")
    _note_cut(reply, units)
    return reply


def _last_inspection(session: Session, units: list[Unit]) -> Reply:
    """Отвечает о последнем осмотре каждого из агрегатов: когда, кто, с каким результатом."""
    reply = Reply("last_inspection")
    for unit in units[:MAX_UNITS]:
        latest = _inspections(session, unit.id, 1)
        if not latest:
            reply.say(f"{unit.label}: осмотров в базе нет.")
            reply.link("equipment", unit.item.name, "equipment", unit.id)
            continue
        inspection = latest[0]
        span = _moment(inspection.started_at)
        if inspection.finished_at:
            span += f"-{inspection.finished_at.strftime('%H:%M')}"
        done = "осмотр завершён" if inspection.status == "finished" else "осмотр не завершён"
        reply.say(f"{unit.label}: последний осмотр {span}, выполнил {_person(inspection.user)}, {done}.")
        reply.link("inspection", f"Осмотр {_day(inspection.started_at)} - {unit.item.name}", "inspection", inspection.id)
        remarks = _remarks(inspection.findings)
        clean = len(inspection.findings) - len(remarks)
        reply.say(f"Записей осмотра: {len(inspection.findings)}, из них с замечаниями - {len(remarks)}, "
                  f"без замечаний - {clean}.")
        for finding in remarks:
            reply.say(f"- {_finding_line(finding, unit.node_names)}.")
            reply.link("finding", finding.title, "finding", finding.id)
        reply.link("history", f"История: {unit.item.name}", "equipment", unit.id, "history")
    _note_cut(reply, units)
    return reply


def _wants_resolved(query: search.Query) -> bool:
    """Проверяет, что спрашивают об устранённых замечаниях: «устранённые», «закрытые», но не «не устранены»."""
    for index, token in enumerate(query.tokens):
        if token.startswith(RESOLVED_WORDS) and (index == 0 or query.tokens[index - 1] != "не"):
            return True
    return False


def _resolved_findings(session: Session, units: list[Unit]) -> Reply:
    """Отвечает устранёнными замечаниями по агрегатам, сначала новые."""
    reply = Reply("resolved_findings")
    for unit in units:
        query = select(Finding).where(Finding.equipment_id == unit.id, Finding.state == "resolved", Finding.status != "ok")
        findings = list(session.scalars(query.order_by(Finding.created_at.desc(), Finding.id.desc()).limit(MAX_EVENTS)))
        if not findings:
            reply.say(f"{unit.label}: устранённых замечаний нет.")
        else:
            reply.say(f"{unit.label}: последние устранённые замечания - {len(findings)}.")
        for finding in findings:
            reply.say(f"- {_finding_line(finding, unit.node_names)}.")
            reply.link("finding", finding.title, "finding", finding.id)
    for unit in units:
        reply.link("history", f"История: {unit.item.name}", "equipment", unit.id, "history")
    return reply


def _unit_list(units: list[Unit], mode: str | None) -> Reply:
    """Перечисляет оборудование базы, при необходимости только работающее или только остановленное."""
    reply = Reply("equipment_list")
    chosen = [unit for unit in units if mode is None or unit.item.mode == mode]
    title = {None: "В базе", "running": "В работе", "stopped": "Остановлено"}[mode]
    reply.say(f"{title} {len(chosen)} из {len(units)} единиц оборудования." if mode else
              f"{title} {len(units)} {_plural(len(units), 'единица', 'единицы', 'единиц')} оборудования.")
    for unit in chosen:
        reply.say(f"- {unit.label}: {unit.item.location}, {MODE_TITLES.get(unit.item.mode, unit.item.mode)}, "
                  f"наработка {_number(unit.run_hours)} ч.")
        reply.link("equipment", unit.item.name, "equipment", unit.id)
    return reply


def _open_findings(session: Session, units: list[Unit]) -> Reply:
    """Отвечает незакрытыми замечаниями по агрегатам с рекомендациями."""
    reply = Reply("open_findings")
    found = [(unit, _unresolved(session, unit.id)) for unit in units]
    total = sum(len(findings) for _, findings in found)
    if len(units) > 1:
        busy = sum(1 for _, findings in found if findings)
        reply.say(f"Всего незакрытых замечаний: {total}, агрегатов с замечаниями: {busy} из {len(units)}.")
    for unit, findings in found:
        if not findings:
            reply.say(f"{unit.label}: незакрытых замечаний нет.")
        else:
            reply.say(f"{unit.label}: незакрытых замечаний - {len(findings)}.")
        for finding in findings:
            advice = f" Рекомендация: {_sentence(finding.recommendation)}" if finding.recommendation else ""
            reply.say(f"- {_finding_line(finding, unit.node_names)}.{advice}")
            reply.link("finding", finding.title, "finding", finding.id)
        resolved = session.scalar(select(func.count()).select_from(Finding).where(
            Finding.equipment_id == unit.id, Finding.state == "resolved", Finding.status != "ok"))
        if resolved:
            reply.say(f"Устранённых замечаний в истории агрегата: {resolved}.")
    for unit, _ in found:
        reply.link("equipment", unit.item.name, "equipment", unit.id)
    return reply


def _resolved_on_node(session: Session, equipment_id: str, node_code: str) -> list[Finding]:
    """Читает устранённые замечания по одному узлу агрегата, сначала новые."""
    query = select(Finding).where(Finding.equipment_id == equipment_id, Finding.node_code == node_code,
                                  Finding.state == "resolved", Finding.status != "ok")
    return list(session.scalars(query.order_by(Finding.created_at.desc(), Finding.id.desc()).limit(RECORD_LIMIT)))


def _node_findings(session: Session, hits: list[tuple[Unit, dict]], resolved_only: bool) -> Reply:
    """Отвечает замечаниями по узлу, названному в вопросе: незакрытые и устранённые отдельно, сначала новые.

    Узлы с замечаниями идут первыми; если по узлу замечаний нет, об этом сказано прямо.
    """
    reply = Reply("node_findings")
    found = []
    for unit, node in hits:
        opened = [] if resolved_only else _unresolved(session, unit.id, node["id"])
        found.append((unit, node, opened, _resolved_on_node(session, unit.id, node["id"])))
    found.sort(key=lambda entry: (not entry[2], not entry[3]))
    for unit, node, opened, solved in found[:MAX_UNITS]:
        where = f"{unit.label}, узел «{node['name']}»"
        if resolved_only:
            reply.say(f"{where}: устранённых замечаний - {len(solved)}." if solved else
                      f"{where}: устранённых замечаний нет.")
        elif opened or solved:
            reply.say(f"{where}: незакрытых замечаний - {len(opened)}, устранённых - {len(solved)}.")
        else:
            reply.say(f"{where}: замечаний в базе нет.")
        for finding in opened:
            advice = f" Рекомендация: {_sentence(finding.recommendation)}" if finding.recommendation else ""
            reply.say(f"- {_finding_line(finding, {})}.{advice}")
            reply.link("finding", finding.title, "finding", finding.id)
        for finding in solved[:MAX_EVENTS]:
            reply.say(f"- {_finding_line(finding, {})}.")
            reply.link("finding", finding.title, "finding", finding.id)
        if len(solved) > MAX_EVENTS:
            reply.say(f"Показаны последние {MAX_EVENTS} устранённых - полная история по ссылке.")
        reply.link("node", f"{node['name']} - {unit.item.name}", "equipment", unit.id, "node", node["id"])
    for unit, _, _, _ in found[:MAX_UNITS]:
        reply.link("history", f"История: {unit.item.name}", "equipment", unit.id, "history")
    if len(found) > MAX_UNITS:
        reply.say(f"Показаны первые {MAX_UNITS} из {len(found)} агрегатов с таким узлом - уточните агрегат в вопросе.")
    return reply


def _maintenance(session: Session, units: list[Unit]) -> Reply:
    """Отвечает о сроках обслуживания: виды ТО по регламенту, ресурс узлов на исходе и последняя работа."""
    reply = Reply("maintenance_due")
    for unit in units[:MAX_UNITS]:
        reply.say(f"{unit.label}: наработка {_number(unit.run_hours)} ч, расчёт на {_day(unit.today)}.")
        reply.link("equipment", unit.item.name, "equipment", unit.id)
        intervals = maintenance_intervals(unit.card, unit.run_hours)
        if not intervals:
            reply.say("Регламент технического обслуживания в карточке агрегата не задан.")
        for entry in intervals:
            reply.say(f"- {_interval_line(entry)}")
            if entry["state"] in ("due", "approaching") and entry.get("work") and len(units) == 1:
                reply.say(f"  Состав работ: {_sentence(entry['work'])}")
        for node in unit.card["nodes"]:
            calculated = unit.resource(node)["calculated"]
            if calculated["state"] in ("due", "approaching"):
                reply.say(f"- Ресурс узла «{node['name']}»: {_resource_text(calculated)}")
                reply.link("node", f"{node['name']} - {unit.item.name}", "equipment", unit.id, "node", node["id"])
        for record in _works(session, unit.id, 1):
            reply.say(f"Последняя запись о работах: {_work_line(record, unit.node_names)}")
        reply.link("history", f"История: {unit.item.name}", "equipment", unit.id, "history")
    _note_cut(reply, units)
    return reply


def _node(session: Session, hits: list[tuple[Unit, dict]]) -> Reply:
    """Отвечает о состоянии узла тремя раздельными оценками: фактическое состояние, норматив и расчётный ресурс."""
    reply = Reply("node_state")
    for unit, node in hits[:MAX_UNITS]:
        code = node["id"]
        reply.say(f"{node['name']} - {unit.label}.")
        reply.link("node", f"{node['name']} - {unit.item.name}", "equipment", unit.id, "node", code)
        if unit.live:
            state = (unit.diagnosis["nodes"].get(code) or {"status": "unknown", "reasons": []})
            flagged = state["status"] in ("check", "defect") and state.get("reasons")
            reasons = f": {'; '.join(state['reasons'])}" if flagged else ""
            reply.say(f"Фактическое состояние по датчикам на {_moment(unit.live['moment'])}: "
                      f"{SENSOR_TITLES.get(state['status'], state['status'])}{reasons}.")
            for found in _sensor_findings(unit):
                if found["node_id"] != code:
                    continue
                reply.say(f"- {_sentence(found['diagnosis'])} Рекомендация: {_sentence(found['recommendation'])}")
                if found.get("missing"):
                    reply.say(f"  Что ещё проверить: {'; '.join(found['missing'])}.")
                reply.link("rule", f"Правило {found['rule_id']}: {found['title']}", "rule", found["rule_id"])
            shown = [(key, unit.live["parameters"][key]) for key in node.get("parameters") or []
                     if key in unit.live["parameters"] and key in unit.live["readings"]]
            if shown:
                reply.say("Показания: " + "; ".join(_reading(meta, unit.live["readings"][key]) for key, meta in shown) + ".")
            for key, meta in shown:
                reply.link("chart", f"График: {meta['name']}", "equipment", unit.id, "chart", key)
        else:
            reply.say(f"Фактическое состояние по датчикам: {unit.telemetry_note}.")
        estimate = unit.resource(node)
        source = estimate["normative"].get("source")
        reply.say(_sentence(estimate["normative"]["text"]) + (f" Источник: {_sentence(source)}" if source else ""))
        reply.say(f"Расчётный ресурс: {_resource_text(estimate['calculated'])}")
        unresolved = _unresolved(session, unit.id, code)
        if not unresolved:
            reply.say("Незакрытых замечаний по узлу нет.")
        for finding in unresolved:
            advice = f" Рекомендация: {_sentence(finding.recommendation)}" if finding.recommendation else ""
            reply.say(f"Незакрытое замечание: {_finding_line(finding, {})}.{advice}")
            reply.link("finding", finding.title, "finding", finding.id)
        works = _works(session, unit.id, 1, code)
        if works:
            reply.say(f"Последняя работа на узле: {_work_line(works[0], {})}")
        else:
            reply.say("Записей о работах на узле нет.")
        reply.link("history", f"История: {unit.item.name}", "equipment", unit.id, "history")
    if len(hits) > MAX_UNITS:
        reply.say(f"Показаны первые {MAX_UNITS} из {len(hits)} агрегатов с таким узлом - уточните агрегат в вопросе.")
    if any(unit.live for unit, _ in hits[:MAX_UNITS]):
        reply.say(DECISION_LINE)
    return reply


def _no_such_node(units: list[Unit]) -> Reply:
    """Отвечает, что названного узла в карточках нет, и перечисляет узлы, которые есть."""
    reply = Reply("node_state", found=False)
    for unit in units[:MAX_UNITS]:
        names = ", ".join(node["name"] for node in unit.card["nodes"])
        reply.say(f"{unit.label}: узла, названного в вопросе, в карточке нет. Узлы агрегата: {names}.")
        reply.link("equipment", unit.item.name, "equipment", unit.id)
    return reply


def _parameters(units: list[Unit], named: bool, codes: list[str]) -> Reply:
    """Отвечает показаниями датчиков: названные параметры или сводка отклонений, с уставками и источником данных."""
    reply = Reply("parameter")
    chosen = units if named else ([unit for unit in units if unit.live] or units)
    for unit in chosen[:MAX_UNITS]:
        reply.link("equipment", unit.item.name, "equipment", unit.id)
        if not unit.live:
            reply.say(f"{unit.label}: {unit.telemetry_note}.")
            continue
        readings, catalogue = unit.live["readings"], unit.live["parameters"]
        reply.say(f"{unit.label}, показания датчиков на {_moment(unit.live['moment'])}:")
        wanted = [code for code in codes if code in catalogue and code in readings]
        if wanted:
            listed = wanted
        else:
            graded = [code for code, meta in catalogue.items() if code in readings and _level(meta, readings[code])]
            listed = [code for code in graded if _level(catalogue[code], readings[code]) != "ok"]
            if not listed:
                reply.say(f"- Все {len(graded)} параметров с уставками в норме.")
        for code in listed:
            meta = catalogue[code]
            limits = _limits(meta)
            origin = SOURCE_TITLES.get(meta.get("source"), meta.get("source"))
            reply.say(f"- {_reading(meta, readings[code])}" + (f" ({limits})" if limits else "") + f". Источник: {origin}.")
            reply.link("chart", f"График: {meta['name']}", "equipment", unit.id, "chart", code)
        labels = [(title, unit.live["player"].customer_label(kind, unit.live["moment"])) for kind, title in LABEL_TITLES]
        labels = [f"{title} - «{label}»" for title, label in labels if label]
        if labels:
            reply.say(f"Диагноз заказчика в его базе на этот час: {'; '.join(labels)}.")
    _note_cut(reply, chosen)
    return reply


def _unit_words(units: list[Unit]) -> frozenset[str]:
    """Собирает слова, которыми в вопросе называют сами агрегаты: название, место, обозначение, модель, номер."""
    result = set()
    for unit in units:
        result |= search.unit_vocabulary({**unit.card, "documents": [], "nodes": []})
        result |= search.stems_of(" ".join((unit.id, unit.item.model, unit.item.serial)))
    return frozenset(result)


def _documents(query: search.Query, units: list[Unit]) -> Reply:
    """Отвечает, где лежит документ: сначала подходящие по названию, а без уточнения - все документы агрегатов."""
    reply = Reply("document")
    skip = _unit_words(units)
    asked = [base for base in query.content() if base not in search.GENERIC_STEMS and base not in skip]
    scored = []
    for unit in units:
        for document in unit.card.get("documents") or []:
            stems = search.stems_of(document.get("title") or "")
            scored.append((sum(1 for base in asked if search.has_stem(stems, base)), unit, document))
    if not scored:
        reply.say("Документов в карточках оборудования нет.")
        reply.found = False
        return reply
    best = max(score for score, _, _ in scored)
    for score, unit, document in scored:
        if score == best:
            reply.say(f"{document['title']} - {unit.label}, файл «{document.get('file') or 'не указан'}».")
            reply.link("document", document["title"], "document", document["id"])
    for unit in units[:MAX_UNITS]:
        reply.link("equipment", unit.item.name, "equipment", unit.id)
    return reply


def _rule_text(reply: Reply, rule: dict, node_names: dict[str, str]) -> None:
    """Описывает правило диагностики: признаки, диагноз, рекомендация, узел и критичность."""
    reply.say(f"Правило {rule['id']} «{rule['title']}».")
    reply.say(f"Что видит камера: {_sentence(_lower_first(rule.get('camera_text') or 'не задано'))} "
              f"Данные датчиков: {_sentence(_lower_first(rule.get('sensor_text') or 'не заданы'))}")
    reply.say(f"Диагноз: {_sentence(_plain(rule.get('diagnosis')))}")
    reply.say(f"Рекомендация: {_sentence(_plain(rule.get('recommendation')))}")
    status = STATUS_TITLES.get(rule.get("status"), rule.get("status"))
    node = node_names.get(rule.get("node"))
    where = f"Узел: {node}. " if node else ""
    reply.say(f"{where}При срабатывании: {status}, критичность {rule.get('severity')} из 3.")
    reply.link("rule", f"Правило {rule['id']}: {rule['title']}", "rule", rule["id"])


def _all_node_names(units: list[Unit]) -> dict[str, str]:
    """Названия узлов по кодам по всем агрегатам: для подписи узла в описании правила."""
    names = {}
    for unit in reversed(units):
        names.update(unit.node_names)
    return names


def _rule_records(rules: list[dict]) -> list[search.Record]:
    """Готовит правила для поиска по словам: заголовок и текст признаков, диагноза и рекомендации."""
    return [search.Record(
        kind="rule", title=rule["title"], deeplink=deeplink("rule", rule["id"]), ref=rule["id"],
        summary=f"{rule['id']} «{rule['title']}»",
        text=" ".join(_plain(rule.get(key)) for key in ("diagnosis", "recommendation", "camera_text", "sensor_text")))
        for rule in rules]


def _rules(query: search.Query, rules: list[dict], units: list[Unit]) -> Reply | None:
    """Отвечает о правиле по номеру или по словам вопроса; None, если вопрос не о правилах."""
    by_id = {rule["id"]: rule for rule in rules}
    asked = [f"{RULE_LETTERS[letter]}{int(number):02d}" for letter, number in RULE_ID.findall(query.text)]
    asked += [f"R{int(number):02d}" for number in RULE_NUMBER.findall(query.text)]
    asked = list(dict.fromkeys(asked))
    if not asked and not any(base in RULE_WORDS for base in query.stems):
        return None
    reply = Reply("rule")
    names = _all_node_names(units)
    if asked:
        for rule_id in asked[:MAX_RULES]:
            if rule_id in by_id:
                _rule_text(reply, by_id[rule_id], names)
            else:
                reply.say(f"Правила {rule_id} в перечне нет.")
        if not reply.links:
            reply.found = False
            reply.say("Есть правила: " + ", ".join(by_id) + ".")
        return reply
    hits = search.rank(query, _rule_records(rules), limit=MAX_RULES, skip=frozenset(RULE_WORDS))
    if hits:
        for record in hits:
            _rule_text(reply, by_id[record.ref], names)
        return reply
    customer = [rule for rule in rules if rule.get("group") == "customer"] or rules
    reply.say(f"В перечне {len(rules)} {_plural(len(rules), 'правило', 'правила', 'правил')} диагностики. "
              f"Правила заказчика:")
    for rule in customer:
        reply.say(f"- {rule['id']}: {rule['title']}.")
        reply.link("rule", f"Правило {rule['id']}: {rule['title']}", "rule", rule["id"])
    return reply


def _explain(query: search.Query, rules: list[dict], units: list[Unit]) -> Reply | None:
    """Отвечает на общие вопросы «что делать», «почему», «что значит» правилом диагностики, подходящим по словам.

    Применяется, когда в вопросе не назван агрегат: о названном агрегате отвечают его собственные данные.
    """
    if not any(phrase in query.text for phrase in EXPLAIN_PHRASES):
        return None
    hits = search.rank(query, _rule_records(rules), limit=2, skip=EXPLAIN_SKIP)
    if not hits:
        return None
    reply = Reply("rule")
    by_id = {rule["id"]: rule for rule in rules}
    for record in hits:
        _rule_text(reply, by_id[record.ref], _all_node_names(units))
    return reply


def _records(session: Session, units: list[Unit], rules: list[dict]) -> list[search.Record]:
    """Готовит записи для свободного поиска: замечания, работы, документы и узлы агрегатов, правила."""
    records = _rule_records(rules)
    for unit in units:
        names = unit.node_names
        findings = select(Finding).where(Finding.equipment_id == unit.id, Finding.status != "ok", Finding.state != "rejected")
        for finding in session.scalars(findings.order_by(Finding.id.desc()).limit(RECORD_LIMIT)):
            text = " ".join(filter(None, (finding.diagnosis, finding.recommendation, finding.comment,
                                          names.get(finding.node_code))))
            records.append(search.Record(
                kind="finding", title=finding.title, text=text, deeplink=deeplink("finding", finding.id),
                equipment_id=unit.id, at=finding.created_at, summary=f"{_finding_line(finding, names)} - {unit.label}"))
        for record in _works(session, unit.id, RECORD_LIMIT):
            title = " ".join(filter(None, (WORK_TITLES.get(record.kind), names.get(record.node_code))))
            records.append(search.Record(
                kind="maintenance", title=title, text=record.comment or "", equipment_id=unit.id, at=record.at,
                deeplink=deeplink("equipment", unit.id, "history"),
                summary=f"{_work_line(record, names)} Агрегат: {unit.label}"))
        for document in unit.card.get("documents") or []:
            records.append(search.Record(
                kind="document", title=document["title"], text="", deeplink=deeplink("document", document["id"]),
                equipment_id=unit.id, summary=f"{document['title']} - {unit.label}"))
        for node in unit.card["nodes"]:
            records.append(search.Record(
                kind="node", title=node["name"], text=node.get("source") or "", equipment_id=unit.id,
                deeplink=deeplink("equipment", unit.id, "node", node["id"]),
                summary=f"{node['name']} - {unit.label}" + (f". {_sentence(node['source'])}" if node.get("source") else "")))
    return records


def _free_search(session: Session, query: search.Query, units: list[Unit], named: bool, rules: list[dict]) -> Reply | None:
    """Ищет слова вопроса по всем записям и отвечает найденным; None, если ничего не подошло."""
    hits = search.rank(query, _records(session, units, rules), skip=_unit_words(units) if named else frozenset())
    if not hits:
        return None
    reply = Reply("search")
    if hits[0].kind == "rule":
        by_id = {rule["id"]: rule for rule in rules}
        _rule_text(reply, by_id[hits[0].ref], _all_node_names(units))
        hits = hits[1:]
        if hits:
            reply.say("Также найдено:")
    else:
        reply.say(f"Найдено записей: {len(hits)}.")
    unit_names = {unit.id: unit.item.name for unit in units}
    for record in hits:
        reply.say(f"- {RECORD_TITLES[record.kind]}: {_sentence(record.summary)}")
        if record.kind == "maintenance":
            reply.attach("history", f"История: {unit_names[record.equipment_id]}", record.deeplink)
        elif record.kind == "rule":
            reply.attach("rule", f"Правило {record.ref}: {record.title}", record.deeplink)
        elif record.kind == "node":
            reply.attach("node", f"{record.title} - {unit_names[record.equipment_id]}", record.deeplink)
        else:
            reply.attach(record.kind, record.title, record.deeplink)
    return reply


def examples(units: list[Unit]) -> list[str]:
    """Возвращает примеры вопросов, на которые помощник умеет отвечать, с настоящим обозначением агрегата."""
    if not units:
        return ["Какое оборудование требует внимания?", "Что означает правило R06?", "Какие есть правила диагностики?"]
    first = next((unit for unit in units if unit.card.get("maintenance")), units[0])
    return [f"Покажи историю агрегата {first.id}", f"Какие открытые замечания по {first.id}?",
            "Какое оборудование требует внимания?"]


def _not_found(units: list[Unit]) -> Reply:
    """Честно отвечает, что данных по вопросу нет, и предлагает примеры вопросов."""
    reply = Reply("unknown", found=False)
    reply.say("Не нашёл ответа на этот вопрос в данных об оборудовании, осмотрах, работах, документах и правилах.")
    reply.say("Попробуйте спросить, например:")
    for example in examples(units):
        reply.say(f"- {example}")
    return reply


def _unknown_unit(designations: list[str], units: list[Unit]) -> Reply:
    """Отвечает, что оборудования с таким обозначением в базе нет, и перечисляет известное."""
    reply = Reply("unknown_equipment", found=False)
    quoted = ", ".join(f"«{entry}»" for entry in designations)
    reply.say(f"Не нашёл в базе оборудование или запись с обозначением {quoted}.")
    if units:
        reply.say("В базе есть: " + ", ".join(unit.label for unit in units[:MAX_LINKS]) + ".")
    for unit in units:
        reply.link("equipment", unit.item.name, "equipment", unit.id)
    return reply


def answer(session: Session, question: str, equipment_id: str | None = None, today: date | None = None) -> Reply:
    """Отвечает на вопрос об оборудовании по данным базы, правил и телеметрии.

    equipment_id - агрегат, открытый в приложении: он подразумевается, когда вопрос не называет другой.
    today - день для расчёта ресурса агрегатов без телеметрии (по умолчанию сегодняшний).
    """
    units = _load_units(session, today or date.today())
    rules = load_rules()
    query = search.parse(question, _vocabulary(units, rules))
    if not query.tokens:
        return _not_found(units)
    about_rule = _rules(query, rules, units)
    if about_rule is not None:
        return about_rule
    if not units:
        return Reply("unknown", ["В базе нет оборудования - отвечать не о чем."], found=False)
    known = [json.dumps(unit.card, ensure_ascii=False) for unit in units] + [rule["id"] for rule in rules]
    identities = [" ".join((unit.id, unit.item.serial, unit.item.model)) for unit in units]
    unknown = search.unknown_designations(query, known, identities)
    if unknown:
        return _unknown_unit(unknown, units)
    named, explicit = _choose_units(query, units, equipment_id)
    explained = None if explicit else _explain(query, rules, units)
    if explained is not None:
        return explained
    scope = named or units
    hits = _node_hits(query, scope)
    if query.has(*DOCUMENT_WORDS):
        return _documents(query, scope)
    wants_state = query.has(*STATE_WORDS) and not hits
    if query.has(*ATTENTION_WORDS) or "первую очередь" in query.text or (wants_state and not named):
        return _attention(session, scope)
    if wants_state:
        return _overview(session, named)
    if query.has(*FINDING_WORDS):
        if hits:
            return _node_findings(session, hits, _wants_resolved(query))
        return _resolved_findings(session, scope) if _wants_resolved(query) else _open_findings(session, scope)
    codes = _parameter_codes(query)
    if codes or query.has(*TELEMETRY_WORDS):
        return _parameters(scope, bool(named), codes)
    if query.has(*JOURNAL_WORDS):
        return _node(session, hits) if hits else _history(session, scope)
    if query.has(*INSPECTION_WORDS):
        return _last_inspection(session, scope)
    if query.has(*WORK_WORDS) or _has_token(query, WORK_TOKENS) or any(phrase in query.text for phrase in WORK_PHRASES):
        return _node(session, hits) if hits else _history(session, scope)
    if query.has(*MAINTENANCE_WORDS) or _has_token(query, MAINTENANCE_TOKENS):
        return _node(session, hits) if hits else _maintenance(session, scope)
    if hits:
        return _node(session, hits)
    if _names_node(query) and named:
        return _no_such_node(named)
    if named and query.has(*CARD_WORDS):
        return _overview(session, named)
    stopped = query.has(*STOPPED_WORDS)
    running = any(phrase in query.text for phrase in RUNNING_PHRASES)
    if not explicit and (stopped or running or query.has(*LIST_WORDS)):
        return _unit_list(units, "stopped" if stopped else "running" if running else None)
    found = _free_search(session, query, scope, bool(named), rules)
    if found is not None:
        return found
    if named:
        return _overview(session, named)
    return _not_found(units)
