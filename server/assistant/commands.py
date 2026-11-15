"""Разбор русских команд ассистента веб-панели: какое действие просит сотрудник и с какими значениями.

Языковой модели нет: текст приводится к нижнему регистру, слова сравниваются по началам с перечнем
синонимов, опечатка в одну букву в длинном слове прощается, порядок слов не важен. Если команда не узнана,
действие не выбирается - ассистент переспрашивает. Имя нового сотрудника ставится в именительный падеж
только по известным именам и типичным окончаниям фамилий; в сомнительном случае разбор возвращает варианты.
"""
import re
from datetime import datetime, timedelta

from server.assistant.search import TRANSLIT, distance, fold

WORD = re.compile(r"[a-zа-я0-9]+(?:-[a-zа-я0-9]+)*")
EMAIL = re.compile(r"[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}", re.IGNORECASE)
NAME_WORD = re.compile(r"[А-ЯЁа-яё]+(?:-[А-ЯЁа-яё]+)?")
REASON = re.compile(r"(?:по\s+причине|причина|причиной|основание|так\s+как|потому\s+что)\s*[:\-–—]?\s*(.+)$"
                    r"|[:–—]\s*(.+)$", re.IGNORECASE)
NUMBER = re.compile(r"(?<![\d.:])(\d{1,4})(?![\d.:])")
RELATIVE = re.compile(r"(\d{1,3})\s*(минут|мин|час|ч\b|сут|дн|день|недел)")
DATE = re.compile(r"(?<!\d)(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?(?!\d)")
CLOCK = re.compile(r"(?<!\d)(\d{1,2}):(\d{2})(?!\d)")

CREATE = ("созда", "создай", "создать", "завед", "завест", "добав", "зарегистр", "нов")
USER_OBJECTS = ("юзер", "пользовател", "сотрудник", "учетк", "учетн", "аккаунт", "логин", "работник", "человек")
STRONG_CREATE = ("завед", "завест", "зарегистр", "заведи")
RESET = ("сброс", "сбрась", "скинь", "выда", "выдать", "нов", "сгенер", "обнов", "смен", "помен", "забыл",
         "восстанов", "перевыпус", "временн")
ROLE_CHANGE = ("смен", "измен", "помен", "назнач", "сдела", "постав", "выда", "переве", "дай", "присво")
SESSION = ("сеанс", "сесси", "разлогин", "вылогин", "выкин")
DELETE = ("удал", "сотри", "стери", "уничтож", "снеси", "очист")
HELP = ("умеешь", "можешь", "помощ", "помоги", "справк", "help", "команд", "возможност", "функци")
SHOW = ("покаж", "показ", "список", "кто", "какие", "каких", "выведи", "перечисл", "сколько", "есть", "у")
NAVIGATE = ("откр", "перейд", "перейт", "иди", "зайд", "покаж", "отобраз", "переключ", "страниц", "раздел", "вкладк")
MAKE = ("сдела", "созда", "сним", "запуст", "выполн", "сохран", "забэкап", "забекап", "бэкап", "бекап")
SWITCH = ("включ", "запуст", "переключ", "постав", "смодел", "сымитир", "имитир", "покаж", "верн", "сброс", "выбер")
TASK = ("осмотр", "осмотрет", "задан", "задач", "обход", "проверк", "провер")
ASSIGN = ("назнач", "поруч", "отправ", "направ", "постав", "дай", "выда", "созда")
POLICY_CHANGE = ("установ", "постав", "смени", "измени", "поменя", "сделай", "разреши", "запрети", "включи", "выключи",
                 "отключи", "увелич", "уменьш", "задай")

ROLE_WORDS = {
    "security_admin": (("иб",), ("безопасник",), ("админ", "безопасност"), ("администратор", "безопасност")),
    "admin": (("сисадмин",), ("админ",), ("администратор",), ("программист",)),
    "master": (("мастер",),),
    "engineer": (("инженер",),),
    "operator": (("оператор",),),
}

PAGES = {
    "overview": ("Обзор системы", (("обзор",), ("главн",), ("дашборд",))),
    "telemetry": ("Телеметрия и сценарии", (("телеметр",), ("сценари",))),
    "equipment": ("Оборудование", (("оборудован",), ("агрегат",))),
    "models": ("Распознавание", (("модел",), ("распознав",))),
    "log": ("Журнал и резерв", (("журнал", "сервер"), ("резерв",), ("бэкап",), ("бекап",), ("журнал", "событ"))),
    "users": ("Пользователи", (("пользовател",), ("юзер",), ("сотрудник",), ("учетн",))),
    "roles": ("Роли и права", (("рол",), ("права",), ("прав",))),
    "seclog": ("Журнал безопасности", (("журнал", "безопасн"), ("аудит",))),
    "policy": ("Политика", (("политик",),)),
    "summary": ("Сводка смены", (("сводк",), ("смен", "итог"))),
    "profile": ("Профиль", (("профил",), ("мой", "аккаунт"), ("личн", "кабинет"))),
}

POLICY_FIELDS = {
    "min_password_length": "Минимальная длина пароля",
    "require_letters_digits": "Пароль из букв и цифр",
    "lockout_attempts": "Неудачных попыток до блокировки входа",
    "lockout_minutes": "Блокировка входа, минут",
    "session_hours": "Срок сеанса, часов",
    "biometrics_allowed": "Вход по биометрии",
}

MALE_NAMES = (
    "Александр", "Алексей", "Анатолий", "Андрей", "Антон", "Аркадий", "Арсений", "Артём", "Артем", "Айдар", "Азат",
    "Борис", "Вадим", "Валентин", "Валерий", "Василий", "Виктор", "Виталий", "Владимир", "Владислав", "Вячеслав",
    "Геннадий", "Георгий", "Глеб", "Григорий", "Даниил", "Данил", "Денис", "Дмитрий", "Евгений", "Егор", "Иван",
    "Игорь", "Ильдар", "Илья", "Кирилл", "Константин", "Лев", "Леонид", "Максим", "Марат", "Марк", "Матвей",
    "Михаил", "Никита", "Николай", "Олег", "Павел", "Пётр", "Петр", "Ринат", "Роман", "Руслан", "Рустам",
    "Семён", "Семен", "Сергей", "Станислав", "Степан", "Тимофей", "Тимур", "Фёдор", "Федор", "Филипп",
    "Эдуард", "Юрий", "Ярослав",
)
FEMALE_NAMES = (
    "Александра", "Алина", "Алла", "Альбина", "Анастасия", "Ангелина", "Анна", "Валентина", "Валерия", "Вера",
    "Виктория", "Галина", "Гульнара", "Дарья", "Диана", "Евгения", "Екатерина", "Елена", "Елизавета", "Жанна",
    "Зоя", "Ирина", "Карина", "Кира", "Ксения", "Лариса", "Лидия", "Лилия", "Любовь", "Людмила", "Маргарита",
    "Марина", "Мария", "Надежда", "Наталья", "Наталия", "Нина", "Оксана", "Олеся", "Ольга", "Полина", "Регина",
    "Светлана", "София", "Софья", "Таисия", "Тамара", "Татьяна", "Ульяна", "Эльвира", "Юлия", "Яна",
)
FLEETING = {"Лев": "Льв", "Павел": "Павл", "Пётр": "Петр", "Петр": "Петр"}
HUSHING = "гкхжшчщ"
CASES = ("nom", "gen", "acc", "dat", "ins")


def words(text: str) -> list[str]:
    """Слова команды в нижнем регистре, ё как е; адреса почты в слова не попадают."""
    return WORD.findall(fold(EMAIL.sub(" ", text)))


def emails(text: str) -> list[str]:
    """Адреса почты из команды в нижнем регистре."""
    return [found.lower() for found in EMAIL.findall(text)]


def starts(word: str, prefix: str) -> bool:
    """Слово начинается с основы; в основе от шести букв прощается одна опечатка."""
    if word.startswith(prefix):
        return True
    return len(prefix) >= 6 and len(word) >= len(prefix) and distance(word[:len(prefix)], prefix) <= 1


def has(tokens: list[str], *prefixes: str) -> bool:
    """Есть ли в команде слово, начинающееся с одной из основ."""
    return any(starts(word, prefix) for word in tokens for prefix in prefixes)


def has_all(tokens: list[str], group: tuple[str, ...]) -> bool:
    """Есть ли в команде слова на все основы группы; короткие основы вроде «иб» сравниваются целиком."""
    return all(any(word == prefix if len(prefix) <= 2 else starts(word, prefix) for word in tokens) for prefix in group)


def role_of(tokens: list[str], roles: list[tuple[str, str]]) -> str | None:
    """Код роли, названной в команде; сначала роли базы по названию, затем синонимы системных ролей."""
    for code, title in roles:
        title_words = [word for word in words(title) if len(word) > 2]
        named = title_words and all(has(tokens, word[:max(4, len(word) - 2)]) for word in title_words)
        if code not in ROLE_WORDS and named:
            return code
    for code, groups in ROLE_WORDS.items():
        if any(has_all(tokens, group) for group in groups):
            return code
    return None


def page_of(tokens: list[str]) -> str | None:
    """Раздел панели, названный в команде; более точные сочетания слов важнее одиночных."""
    best, best_size = None, 0
    for key, (_, groups) in PAGES.items():
        for group in groups:
            if len(group) > best_size and has_all(tokens, group):
                best, best_size = key, len(group)
    return best


def reason_of(text: str) -> str | None:
    """Причина из команды: после слов «причина», «по причине» или после двоеточия, тире."""
    found = REASON.search(text)
    if not found:
        return None
    value = (found.group(1) or found.group(2) or "").strip(" .,;:-–—")
    return value[:120] or None


def detect(text: str) -> str | None:
    """Действие, которое просит команда, или None, если команда не узнана."""
    tokens = words(text)
    if not tokens:
        return "help"
    deleting = any(word.startswith(DELETE) for word in tokens)
    if deleting and has(tokens, *USER_OBJECTS, "баз", "данн", "журнал", "рол", "запис"):
        return "unsupported_delete"
    page = page_of(tokens)
    if has(tokens, *HELP) and not has(tokens, "парол"):
        if page and has(tokens, "страниц", "раздел", "экран", "вкладк", "по"):
            return "page_help"
        return "help"
    if page and has(tokens, "как") and has(tokens, "пользоват", "работат") and not has(tokens, "парол"):
        return "page_help"
    return _account(tokens, text) or _master(tokens) or _admin(tokens) or (
        "navigate" if page and (has(tokens, *NAVIGATE) or len(tokens) <= 3) else None)


def _policy(tokens: list[str]) -> bool:
    """Касается ли команда настройки политики безопасности."""
    if has(tokens, "событ", "журнал") or (has(tokens, "неудач") and not has(tokens, "блокир", "политик")):
        return False
    return has(tokens, "политик") or policy_field(tokens) is not None


def policy_field(tokens: list[str]) -> str | None:
    """Поле политики, о котором говорит команда."""
    if has(tokens, "биометр"):
        return "biometrics_allowed"
    if has(tokens, "букв") and has(tokens, "цифр"):
        return "require_letters_digits"
    if has(tokens, "длин", "символ", "знак") and has(tokens, "парол"):
        return "min_password_length"
    if has(tokens, "попыт") and (has(tokens, "блокир", "блокировк", "политик", "лимит", "допуст", "максим")):
        return "lockout_attempts"
    if has(tokens, "минут") and has(tokens, "блокировк", "блокиру", "блокир"):
        return "lockout_minutes"
    if has(tokens, "сеанс", "сесси") and has(tokens, "срок", "длительн", "час", "живет", "действ", "время"):
        return "session_hours"
    return None


def _account(tokens: list[str], text: str) -> str | None:
    """Действия администратора ИБ: учётные записи, сеансы, журнал, политика."""
    if _policy(tokens):
        changing = bool(NUMBER.search(text)) or any(word.startswith(POLICY_CHANGE) for word in tokens)
        return "policy_set" if changing else "policy_show"
    if has(tokens, "заблокирован", "блокирован") and not has(tokens, "разблок"):
        return "list_blocked"
    if has(tokens, "разблок") or (has(tokens, "сним", "убер") and has(tokens, "блок")) or (
            has(tokens, "восстанов", "верн") and has(tokens, "доступ")):
        return "unblock_user"
    if has(tokens, "заблок", "блокир", "забан") and not has(tokens, "временн"):
        return "block_user"
    if has(tokens, "временн") and has(tokens, "парол") and not has(tokens, "сброс", "сбрось", "выдай", "выдать",
                                                                       "сгенер", "скинь", "перевыпус"):
        return "list_temp"
    if has(tokens, "не") and has(tokens, "сменил", "поменял") and has(tokens, "парол"):
        return "list_temp"
    role_named = any(has_all(tokens, group) for groups in ROLE_WORDS.values() for group in groups)
    creating = has(tokens, *STRONG_CREATE) or (has(tokens, *CREATE) and (has(tokens, *USER_OBJECTS) or role_named))
    other_object = has(tokens, *TASK, "резерв", "копи", "бэкап", "бекап") or (
        has(tokens, "рол") and not has(tokens, *USER_OBJECTS))
    if creating and not other_object:
        return "create_user"
    if has(tokens, "парол") and has(tokens, *RESET):
        return "reset_password"
    if has(tokens, *SESSION) and not has(tokens, "политик"):
        return "close_sessions"
    if has(tokens, "событ", "аудит") or (has(tokens, "вход", "входил", "логин") and has(
            tokens, "неудач", "ошиб", "неуспеш", "провал", "сегодня", "последн", "кто", "попыт")) or (
            has(tokens, "журнал") and has(tokens, "безопасн") and has(tokens, "покаж", "что", "последн", "сегодня")):
        return "security_events"
    if has(tokens, "рол") and has(tokens, *ROLE_CHANGE) and not has(tokens, *TASK, "созда"):
        return "change_role"
    if has(tokens, "сдела", "переве", "назнач") and not has(tokens, *TASK) and any(
            has_all(tokens, group) for groups in ROLE_WORDS.values() for group in groups):
        return "change_role"
    return None


def _admin(tokens: list[str]) -> str | None:
    """Действия администратора системы: сценарий, время стенда, резервная копия, состояние, модели, оборудование."""
    if has(tokens, "резервн", "бэкап", "бекап", "backup") or (has(tokens, "копи") and has(tokens, "баз")):
        if has(tokens, *MAKE):
            return "backup"
        return None
    if has(tokens, "сценари") or (has(tokens, "нормальн", "норм") and has(tokens, "режим", "верн")) or (
            has(tokens, *SWITCH) and has(tokens, "перегрев", "дисбаланс", "расцентровк", "кавитац", "износ", "дрейф",
                                         "подшипник")):
        return "scenario_switch"
    if has(tokens, "перемот", "сдвин", "передвин", "промота", "отмота", "переставь", "курсор") or (
            has(tokens, "время") and has(tokens, "стенд", "лент", "телеметр")):
        return "move_time"
    if has(tokens, "здоров", "health", "канал") or (has(tokens, "сервер", "систем") and has(
            tokens, "состоян", "статус", "как", "работа", "жив", "здоров", "провер")):
        return "server_state"
    if has(tokens, "модел", "отпечат", "fingerprint", "нейросет"):
        return "models"
    if has(tokens, "оборудован", "агрегат", "насос", "установк", "трансформатор", "шкаф") or any(
            DESIGNATED.search(word) for word in tokens):
        if any(DESIGNATED.search(word) for word in tokens):
            return "open_unit"
        return "equipment_list"
    return None


DESIGNATED = re.compile(r"^[a-zа-я]{1,4}-?\d{1,4}$")


def _master(tokens: list[str]) -> str | None:
    """Действия мастера: сводка смены, находки на подтверждение, задание на осмотр."""
    if has(tokens, *ASSIGN) and has(tokens, *TASK):
        return "assign_task"
    if has(tokens, "находк", "замечан", "дефект") and has(tokens, "подтвержд", "ожида", "жд", "неразобран", "открыт",
                                                       "нов", "провер", "рассмотр"):
        return "findings_pending"
    if has(tokens, "сводк", "обстановк") or (has(tokens, "смен") and has(tokens, "как", "итог", "что", "состоян")):
        return "shift_summary"
    return None


def _name_forms(name: str) -> dict[str, str]:
    """Падежные формы известного имени: родительный, винительный, дательный и творительный."""
    if name == "Любовь":
        return {"nom": name, "gen": "Любови", "acc": name, "dat": "Любови", "ins": "Любовью"}
    if name.endswith("а"):
        base = name[:-1]
        return {"nom": name, "gen": base + ("и" if base[-1] in HUSHING else "ы"), "acc": base + "у", "dat": base + "е",
                "ins": base + "ой"}
    if name.endswith("ия"):
        base = name[:-1]
        return {"nom": name, "gen": base + "и", "acc": base + "ю", "dat": base + "и", "ins": base + "ей"}
    if name.endswith("я"):
        base = name[:-1]
        return {"nom": name, "gen": base + "и", "acc": base + "ю", "dat": base + "е", "ins": base + "ей"}
    if name.endswith("й"):
        base = name[:-1]
        return {"nom": name, "gen": base + "я", "acc": base + "я", "dat": base + "ю", "ins": base + "ем"}
    base = FLEETING.get(name, name)
    return {"nom": name, "gen": base + "а", "acc": base + "а", "dat": base + "у", "ins": base + "ом"}


def _known_names() -> dict[str, list[tuple[str, str, str]]]:
    """Словарь: форма имени в нижнем регистре - варианты (именительный падеж, пол, падеж)."""
    table: dict[str, list[tuple[str, str, str]]] = {}
    for gender, names in (("m", MALE_NAMES), ("f", FEMALE_NAMES)):
        for name in names:
            if any(fold(name) == fold(other) for other in names[:names.index(name)]):
                continue
            for case, form in _name_forms(name).items():
                entry = (name, gender, case)
                bucket = table.setdefault(fold(form), [])
                if entry not in bucket:
                    bucket.append(entry)
    return table


KNOWN_NAMES = _known_names()

SURNAME_RULES: dict[str, dict[str, tuple[tuple[str, str], ...]]] = {
    "m": {
        "nom": (("ов", "ов"), ("ев", "ев"), ("ин", "ин"), ("ын", "ын"), ("ский", "ский"), ("цкий", "цкий"),
                ("ой", "ой"), ("ый", "ый"), ("ий", "ий"), ("вич", "вич"), ("ич", "ич")),
        "gen": (("ова", "ов"), ("ева", "ев"), ("ина", "ин"), ("ына", "ын"), ("ского", "ский"), ("цкого", "цкий"),
                ("вича", "вич"), ("ича", "ич")),
        "dat": (("ову", "ов"), ("еву", "ев"), ("ину", "ин"), ("ыну", "ын"), ("скому", "ский"), ("цкому", "цкий"),
                ("вичу", "вич"), ("ичу", "ич")),
        "ins": (("овым", "ов"), ("евым", "ев"), ("иным", "ин"), ("ыным", "ын"), ("ским", "ский"), ("цким", "цкий"),
                ("вичем", "вич"), ("ичем", "ич")),
    },
    "f": {
        "nom": (("ова", "ова"), ("ева", "ева"), ("ина", "ина"), ("ына", "ына"), ("ская", "ская"), ("цкая", "цкая"),
                ("вна", "вна"), ("чна", "чна")),
        "acc": (("ову", "ова"), ("еву", "ева"), ("ину", "ина"), ("ыну", "ына"), ("скую", "ская"), ("цкую", "цкая"),
                ("вну", "вна"), ("чну", "чна")),
        "gen": (("овой", "ова"), ("евой", "ева"), ("иной", "ина"), ("ыной", "ына"), ("ской", "ская"), ("цкой", "цкая"),
                ("вны", "вна"), ("чны", "чна")),
        "dat": (("овой", "ова"), ("евой", "ева"), ("иной", "ина"), ("ыной", "ына"), ("ской", "ская"), ("цкой", "цкая"),
                ("вне", "вна"), ("чне", "чна")),
        "ins": (("овой", "ова"), ("евой", "ева"), ("иной", "ина"), ("ыной", "ына"), ("ской", "ская"), ("цкой", "цкая"),
                ("вной", "вна"), ("чной", "чна")),
    },
}
SURNAME_RULES["m"]["acc"] = SURNAME_RULES["m"]["gen"]
VOWELS = "аеёиоуыэюя"


def _surname_nominative(word: str, gender: str, case: str) -> str | None:
    """Фамилия или отчество в именительном падеже по известному падежу и полу; None - вывести надёжно нельзя.

    Двойная фамилия через дефис ставится в именительный падеж по частям.
    """
    if "-" in word:
        parts = [_surname_nominative(part, gender, case) for part in word.split("-")]
        return None if None in parts else "-".join(parts)
    low = fold(word)
    for ending, replacement in SURNAME_RULES[gender][case]:
        if low.endswith(ending) and len(low) > len(ending) + 1:
            return word[:len(word) - len(ending)] + replacement
    if gender == "f" and low[-1] not in VOWELS:
        return word
    if case == "nom" and low[-1] not in VOWELS:
        return word
    if gender == "m" and case in ("gen", "acc") and low.endswith("а") and low[-2] not in VOWELS and len(low) > 3:
        return word[:-1]
    if gender == "m" and case == "dat" and low.endswith("у") and low[-2] not in VOWELS and len(low) > 3:
        return word[:-1]
    if gender == "m" and case == "ins" and low.endswith("ом") and len(low) > 4:
        return word[:-2]
    return None


def _capital(word: str) -> str:
    """Слово с заглавной буквы, части через дефис - тоже."""
    return "-".join(part[:1].upper() + part[1:].lower() for part in word.split("-"))


def nominative_variants(name_words: list[str]) -> list[str]:
    """Варианты полного имени в именительном падеже; один вариант - имя выведено надёжно.

    Пустой список - имя не узнано или фамилию нельзя надёжно поставить в именительный падеж.
    """
    if not 1 <= len(name_words) <= 3:
        return []
    variants: list[str] = []
    for index, word in enumerate(name_words):
        for nominative, gender, case in KNOWN_NAMES.get(fold(word), []):
            parts = []
            for other_index, other in enumerate(name_words):
                if other_index == index:
                    parts.append(word if case == "nom" else nominative)
                    continue
                fixed = _surname_nominative(other, gender, case)
                if fixed is None:
                    parts = None
                    break
                parts.append(fixed)
            if parts:
                full = " ".join(_capital(part) for part in parts)
                if full not in variants:
                    variants.append(full)
    return variants


SERVICE_PREFIXES = (
    "созда", "завед", "завест", "добав", "зарегистр", "юзер", "пользовател", "сотрудник", "учетк", "учетн", "аккаунт",
    "логин", "работник", "челове", "парол", "безопасн", "надежн", "сложн", "придума", "сгенер", "случайн", "почт",
    "емейл", "мейл", "сброс", "сбрось", "скинь", "выда", "обнов", "смен", "помен", "забыл", "восстанов", "перевыпус",
    "временн", "измен", "назнач", "сдела", "постав", "переве", "присво", "сеанс", "сесси", "разлогин", "вылогин",
    "выкин", "заблок", "разблок", "блокир", "забан", "сним", "убер", "доступ", "закро", "закры", "заверш", "инженер",
    "мастер", "оператор", "админ", "сисадмин", "программист", "безопасник", "систем", "роль", "роли", "ролью",
    "осмотр", "задан", "задач", "обход", "провер", "поруч", "отправ", "направ", "срочн", "сегодня", "завтра",
    "агрегат", "насос", "пожалуйст", "плиз", "пусть", "можешь", "могу", "нужно", "надо",
    "событ", "вход", "покаж", "неудач", "последн", "журнал", "запис", "приоритет",
)
SERVICE_WORDS = frozenset((
    "нов", "новый", "нового", "новую", "новая", "новенького", "и", "с", "со", "для", "ему", "ей", "на", "в", "во",
    "как", "по", "у", "к", "от", "из", "за", "мне", "ему", "его", "ее", "её", "их", "иб", "это", "этого", "пароль",
    "дай", "ты", "вы", "а", "же", "бы", "ну", "под", "имя", "именем", "фио", "кто", "что", "этой", "чтобы", "все",
    "всех", "вчера", "сегодня", "высокий", "высоким", "высокой", "высокая",
))


def is_service(word: str) -> bool:
    """Служебное слово команды, которое не может быть частью имени сотрудника."""
    low = fold(word)
    return low in SERVICE_WORDS or any(low.startswith(prefix) for prefix in SERVICE_PREFIXES)


def name_words(text: str) -> list[str]:
    """Слова, похожие на имя сотрудника: кириллица из исходного текста без служебных слов и без причины."""
    cut = re.split(r"(?:по\s+причине|причина|причиной|[:–—])", EMAIL.sub(" ", text), maxsplit=1)[0]
    return [word for word in NAME_WORD.findall(cut) if not is_service(word)]


def email_from_name(full_name: str, domain: str) -> str:
    """Почта из имени латиницей: имя.фамилия@домен, если имя узнано, иначе слова через точку."""
    parts = full_name.split()
    first = next((part for part in parts if part in MALE_NAMES or part in FEMALE_NAMES), None)
    ordered = [first, *[part for part in parts if part != first][:1]] if first and len(parts) > 1 else parts[:2]
    local = ".".join("".join(TRANSLIT.get(symbol, symbol) for symbol in fold(part) if symbol.isalpha() or symbol == "-")
                     for part in ordered)
    return f"{local}@{domain}"


def number_in(text: str) -> int | None:
    """Первое целое число команды, не являющееся частью даты или времени."""
    found = NUMBER.search(DATE.sub(" ", CLOCK.sub(" ", text)))
    return int(found.group(1)) if found else None


def switch_value(tokens: list[str]) -> bool | None:
    """Включить или выключить флажок политики: True, False или None, если команда не говорит."""
    if has(tokens, "запрет", "выключ", "отключ", "убер") or "не" in tokens or "нет" in tokens:
        return False
    if has(tokens, "разреш", "включ", "требов", "обязат") or "да" in tokens:
        return True
    return None


def target_time(text: str, cursor: datetime, first: datetime, last: datetime) -> datetime | None:
    """Новый момент ленты: «на 3 часа вперёд», «назад на сутки», «12.11 14:00», «в начало», «в конец»."""
    tokens = words(text)
    if has(tokens, "начал"):
        return first
    if has(tokens, "конец", "конц"):
        return last
    relative = RELATIVE.search(fold(text))
    if relative:
        amount, unit = int(relative.group(1)), relative.group(2)
        step = {"мин": timedelta(minutes=amount), "сут": timedelta(days=amount), "дн": timedelta(days=amount),
                "ден": timedelta(days=amount), "нед": timedelta(weeks=amount)}.get(unit[:3], timedelta(hours=amount))
        backwards = has(tokens, "назад", "раньше", "отмота")
        return cursor - step if backwards else cursor + step
    day = DATE.search(text)
    clock = CLOCK.search(text)
    if not day and not clock:
        return None
    try:
        moment = cursor
        if day:
            year = int(day.group(3)) if day.group(3) else cursor.year
            year = year + 2000 if year < 100 else year
            moment = moment.replace(year=year, month=int(day.group(2)), day=int(day.group(1)))
        if clock:
            moment = moment.replace(hour=int(clock.group(1)), minute=int(clock.group(2)))
        return moment.replace(second=0, microsecond=0)
    except ValueError:
        return None
