"""Поиск помощника: приведение слов вопроса к основам, опечатки, поиск агрегатов, узлов и записей.

Языковая модель здесь не нужна: слова вопроса сравниваются с названиями, обозначениями и текстами
из базы. Окончания отбрасываются грубо, обозначения сравниваются без разделителей и без различия
кириллицы и латиницы («Н-101», «N-101», «н101» - одно и то же), опечатка в одну букву исправляется
по словарю из слов самой базы.
"""

import re
from dataclasses import dataclass
from datetime import datetime
from functools import lru_cache

WORD = re.compile(r"[a-zа-я0-9№]+")
PARTICLE = re.compile(r"(?<=[а-я])-(?:то|нибудь|либо)(?![а-я0-9])")
NUMBERED = re.compile(r"(?:№|#|номер[а-я]*)\s*(\d{1,2})(?!\d)")
DESIGNATION = re.compile(
    r"(?<![a-zа-я0-9№-])(?:[a-zа-я]{1,4}-\d{1,4}(?:-\d{1,3})?|[a-zа-я]{1,4}\d{2,4}|\d{6,}(?:-\d{1,3})?)(?![a-zа-я0-9])"
)
ENDINGS = tuple(
    sorted(
        (
            "иями",
            "ями",
            "ами",
            "иях",
            "иям",
            "ием",
            "ией",
            "его",
            "ого",
            "ему",
            "ому",
            "ыми",
            "ими",
            "ах",
            "ях",
            "ам",
            "ям",
            "ов",
            "ев",
            "ей",
            "ой",
            "ий",
            "ый",
            "ая",
            "яя",
            "ое",
            "ее",
            "ые",
            "ие",
            "ую",
            "юю",
            "ых",
            "их",
            "ым",
            "им",
            "ом",
            "ем",
            "ия",
            "ии",
            "ию",
            "ью",
            "а",
            "я",
            "о",
            "е",
            "у",
            "ю",
            "ы",
            "и",
            "ь",
            "й",
        ),
        key=len,
        reverse=True,
    )
)
MIN_STEM = 3
TRANSLIT = {
    "а": "a",
    "б": "b",
    "в": "v",
    "г": "g",
    "д": "d",
    "е": "e",
    "ж": "zh",
    "з": "z",
    "и": "i",
    "й": "y",
    "к": "k",
    "л": "l",
    "м": "m",
    "н": "n",
    "о": "o",
    "п": "p",
    "р": "r",
    "с": "s",
    "т": "t",
    "у": "u",
    "ф": "f",
    "х": "h",
    "ц": "c",
    "ч": "ch",
    "ш": "sh",
    "щ": "sch",
    "ъ": "",
    "ы": "y",
    "ь": "",
    "э": "e",
    "ю": "yu",
    "я": "ya",
}
LOOKALIKE = str.maketrans("abcehkmoptxy", "авсенкмортху")
STOP_WORDS = frozenset(
    (
        "и",
        "а",
        "но",
        "или",
        "в",
        "во",
        "на",
        "по",
        "с",
        "со",
        "у",
        "о",
        "об",
        "от",
        "до",
        "за",
        "из",
        "к",
        "ко",
        "для",
        "при",
        "про",
        "над",
        "под",
        "не",
        "ни",
        "ли",
        "же",
        "бы",
        "что",
        "чем",
        "кто",
        "где",
        "когда",
        "как",
        "какой",
        "какая",
        "какое",
        "какие",
        "каких",
        "каком",
        "какую",
        "сколько",
        "почему",
        "зачем",
        "это",
        "этот",
        "эта",
        "эти",
        "этого",
        "этой",
        "там",
        "тут",
        "есть",
        "был",
        "была",
        "было",
        "были",
        "будет",
        "мне",
        "нам",
        "нужно",
        "надо",
        "можно",
        "покажи",
        "показать",
        "найди",
        "найти",
        "расскажи",
        "скажи",
        "дай",
        "сейчас",
        "него",
        "нему",
        "нем",
        "ним",
        "ней",
        "них",
        "его",
        "ее",
        "их",
        "все",
        "всех",
        "всё",
        "ещё",
        "еще",
        "уже",
        "только",
        "очень",
        "пожалуйста",
        "такое",
        "такой",
        "такая",
        "номер",
        "номера",
        "номеру",
        "номером",
        "означает",
        "означают",
        "значит",
        "значат",
        "делать",
        "если",
        "нет",
        "чтобы",
        "тогда",
        "находится",
        "находятся",
    )
)
GENERIC_STEMS = frozenset(
    (
        "насос",
        "насосн",
        "агрегат",
        "оборудован",
        "установк",
        "единиц",
        "узел",
        "узл",
        "устройств",
        "объект",
    )
)
ORDINALS = {"перв": "№1", "втор": "№2", "трет": "№3", "четверт": "№4", "пят": "№5"}
TYPE_WORDS = {
    "inline_centrifugal_pump": ("центробежн", "инлайн", "циркуляционн"),
    "progressive_cavity_pump": ("винтов", "шнеков", "героторн"),
}
NODE_WORDS = {
    "motor": ("двигател", "электродвигател", "мотор", "электромотор", "эд"),
    "motor_bearings": ("подшипник",),
    "terminal_box": ("клеммн", "клеммник", "коробк", "борно"),
    "coupling": ("муфт", "кожух", "полумуфт"),
    "seal": ("уплотнен", "сальник", "торцев"),
    "casing": ("корпус", "колес", "улитк", "проточн"),
    "flanges": ("фланец", "фланц"),
    "gauge": ("манометр",),
    "gearbox": ("редуктор", "масл"),
    "frame": ("рам", "анкер", "анкерн", "болт", "фундамент"),
    "temp_sensor": ("термопреобразовател", "термодатчик", "термопар"),
}
NODE_SKIP_STEMS = frozenset(("цел", "рабоч", "защит")) | GENERIC_STEMS
STRONG_WEIGHT = 5.0
NAME_WEIGHT = 3.0
PLACE_WEIGHT = 2.0
FUZZY_MIN_LENGTH = 6
FUZZY_LONG_LENGTH = 10
FUZZY_TAIL = 2


def fold(text: str) -> str:
    """Приводит текст к виду для сравнения: без различия регистра, буква ё как е."""
    return text.casefold().replace("ё", "е")


def words(text: str) -> list[str]:
    """Разбивает текст на слова из букв и цифр; знак № остаётся частью слова."""
    return WORD.findall(fold(text))


@lru_cache(maxsize=20000)
def stem(word: str) -> str:
    """Грубо отбрасывает одно русское окончание, оставляя не меньше трёх букв; числа и обозначения не трогает."""
    if any(symbol.isdigit() for symbol in word) or not re.fullmatch(r"[а-я]+", word):
        return word
    for ending in ENDINGS:
        if word.endswith(ending) and len(word) - len(ending) >= MIN_STEM:
            return word[: -len(ending)]
    return word


def similar(left: str, right: str) -> bool:
    """Считает основы одним словом, если они равны или одна продолжает другую не более чем на две буквы."""
    if left == right:
        return True
    short, long = sorted((left, right), key=len)
    return len(short) >= 4 and len(long) - len(short) <= 2 and long.startswith(short) and short.isalpha()


def distance(left: str, right: str) -> int:
    """Считает число правок между словами: вставка, удаление, замена буквы и перестановка соседних букв."""
    previous_row, row = None, list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        before, previous_row, row = previous_row, row, [i]
        for j, b in enumerate(right, 1):
            cost = min(previous_row[j] + 1, row[j - 1] + 1, previous_row[j - 1] + (a != b))
            if before is not None and i > 1 and j > 1 and a == right[j - 2] and left[i - 2] == b:
                cost = min(cost, before[j - 2] + 1)
            row.append(cost)
    return row[-1]


def compact(text: str) -> str:
    """Оставляет только буквы и цифры и записывает кириллицу латиницей: «Н-101» и «n101» становятся равны."""
    return "".join(TRANSLIT.get(symbol, symbol) for symbol in fold(text) if symbol.isalnum())


def id_keys(text: str) -> frozenset[str]:
    """Возвращает варианты обозначения для сравнения: по звучанию и по начертанию букв («H-101» как «Н-101»)."""
    return frozenset((compact(text), compact(fold(text).translate(LOOKALIKE))))


@lru_cache(maxsize=20000)
def stems_of(text: str) -> frozenset[str]:
    """Возвращает основы всех значимых слов текста; результат запоминается, тексты записей повторяются."""
    return frozenset(stem(word) for word in words(text) if len(word) > 1 or word.isdigit())


def has_stem(stems, wanted: str) -> bool:
    """Проверяет, что среди основ есть слово, совпадающее с искомым; числа сравниваются только точно."""
    if not wanted.isalpha():
        return wanted in stems
    return any(similar(wanted, candidate) for candidate in stems)


@dataclass
class Query:
    """Разобранный вопрос: приведённый текст, слова и их основы после исправления опечаток."""

    text: str
    tokens: list[str]
    stems: list[str]

    def has(self, *prefixes: str) -> bool:
        """Проверяет, что в вопросе есть слово, начинающееся с одного из заданных начал."""
        return self.position(*prefixes) is not None

    def position(self, *prefixes: str) -> int | None:
        """Возвращает место первого слова, начинающегося с одного из заданных начал, или None."""
        for index, (token, base) in enumerate(zip(self.tokens, self.stems)):
            if token.startswith(prefixes) or base.startswith(prefixes):
                return index
        return None

    def content(self) -> list[str]:
        """Возвращает основы содержательных слов: без служебных слов и одиночных букв."""
        result = []
        for token, base in zip(self.tokens, self.stems):
            if token in STOP_WORDS or (len(token) < 3 and not token.isdigit()) or base in result:
                continue
            result.append(base)
        return result


def _known(token: str, base: str, vocabulary: frozenset[str]) -> bool:
    """Проверяет, что слово вопроса уже есть в словаре: как начало слова или как совпадающая основа."""
    for entry in vocabulary:
        if len(entry) >= 4 and (token.startswith(entry) or similar(base, entry)):
            return True
    return base in vocabulary


def _corrected(token: str, base: str, vocabulary: frozenset[str]) -> str:
    """Исправляет опечатку: возвращает ближайшее слово словаря на ту же букву или исходную основу.

    Короткие слова не исправляются - у них слишком много случайных соседей; для слов от 6 букв
    допускается одна правка, от 10 букв - две. Начало слова сравнивается со словарным, только если
    остаток не длиннее окончания: иначе «находится» превратилось бы в «находка».
    """
    best = None
    for entry in sorted(vocabulary):
        if len(entry) < FUZZY_MIN_LENGTH or entry[0] != token[0] or not entry.isalpha():
            continue
        limit = 2 if len(entry) >= FUZZY_LONG_LENGTH else 1
        gap = distance(base, entry)
        if len(token) - len(entry) <= FUZZY_TAIL:
            gap = min(gap, distance(token[: len(entry)], entry))
        if gap <= limit and (best is None or gap < best[0]):
            best = (gap, entry)
    return best[1] if best else base


def parse(question: str, vocabulary: frozenset[str]) -> Query:
    """Разбирает вопрос на слова и основы и исправляет опечатки по словарю известных слов."""
    text = PARTICLE.sub("", fold(question))
    text = NUMBERED.sub(r" №\1 ", text)
    tokens = WORD.findall(text)
    stems = []
    for token in tokens:
        base = stem(token)
        fixable = len(token) >= 5 and token.isalpha() and token not in STOP_WORDS
        if fixable and not _known(token, base, vocabulary):
            base = _corrected(token, base, vocabulary)
        stems.append(base)
    return Query(text=text, tokens=tokens, stems=stems)


def unit_vocabulary(card: dict) -> frozenset[str]:
    """Собирает слова карточки агрегата для словаря опечаток: название, место, узлы, документы."""
    texts = [card.get("name") or "", card.get("location") or "", card.get("manufacturer") or ""]
    texts += [node.get("name") or "" for node in card.get("nodes") or []]
    texts += [document.get("title") or "" for document in card.get("documents") or []]
    result = set()
    for text in texts:
        result |= stems_of(text)
    for extra in TYPE_WORDS.get(card.get("type"), ()):
        result.add(extra)
    return frozenset(result)


def base_vocabulary() -> frozenset[str]:
    """Возвращает слова, известные без базы: названия узлов в разговорной речи и общие слова об оборудовании."""
    result = set(GENERIC_STEMS)
    for group in NODE_WORDS.values():
        result.update(group)
    for group in TYPE_WORDS.values():
        result.update(group)
    return frozenset(result)


def _ordinal_alias(query: Query, index: int, name_stems: frozenset[str]) -> str | None:
    """Понимает «первый агрегат» как «№1», если рядом стоит слово об оборудовании, а не «в первую очередь»."""
    alias = ORDINALS.get(query.stems[index])
    if alias is None:
        return None
    around = [query.stems[place] for place in (index - 1, index + 1) if 0 <= place < len(query.stems)]
    if any(base in GENERIC_STEMS or has_stem(name_stems, base) for base in around if base not in ORDINALS):
        return alias
    return None


def _strong_tokens(query: Query, card: dict) -> tuple[set[int], float]:
    """Находит слова вопроса, образующие обозначение, серийный номер или модель агрегата, и вес совпадения.

    Полное обозначение или полный серийный номер весят больше обрывка: по обрывку «21031004» подходят
    оба винтовых агрегата, по полному номеру «21031004-1» - только первый. Обрывок серийного номера
    принимается одним куском или кусками не короче трёх знаков, иначе с номером совпала бы любая дата.
    """
    keys = id_keys(card.get("id") or "")
    serial = compact(card.get("serial") or "")
    model = compact(card.get("model") or "")
    found, weight = set(), 0.0
    for start in range(len(query.tokens)):
        for size in (3, 2, 1):
            pieces = [token.replace("№", "") for token in query.tokens[start : start + size]]
            if len(pieces) < size or not all(pieces):
                continue
            window = compact("".join(pieces))
            digits = any(symbol.isdigit() for symbol in window)
            exact = bool(id_keys("".join(pieces)) & keys) or (digits and window == serial)
            by_serial = digits and len(window) >= 4 and window in serial and all(len(piece) >= 3 for piece in pieces)
            by_model = digits and len(window) >= 5 and window in model
            if exact or by_serial or by_model:
                found.update(range(start, start + size))
                weight = max(weight, STRONG_WEIGHT + 1.0 if exact else STRONG_WEIGHT)
    return found, weight


def match_units(query: Query, cards: list[dict]) -> dict[str, float]:
    """Оценивает, какие агрегаты названы в вопросе: по обозначению, серийному номеру, модели, названию и месту.

    Возвращает вес каждого названного агрегата. Слова, подходящие ко всем агрегатам сразу, никого не
    выделяют и не учитываются; одиночная цифра учитывается только вместе с другим совпавшим словом.
    """
    strong = {card["id"]: _strong_tokens(query, card) for card in cards}
    taken = set()
    for tokens, _ in strong.values():
        taken |= tokens
    fields = {}
    for card in cards:
        other = stems_of(card.get("manufacturer") or "") | frozenset(TYPE_WORDS.get(card.get("type"), ()))
        fields[card["id"]] = (stems_of(card.get("name") or ""), stems_of(card.get("location") or "") | other)
    worded, numbered = {}, {}
    for index, (token, base) in enumerate(zip(query.tokens, query.stems)):
        if index in taken or token in STOP_WORDS or base in GENERIC_STEMS or (len(token) < 2 and not token.isdigit()):
            continue
        weights = {}
        for card in cards:
            name_stems, place_stems = fields[card["id"]]
            alias = _ordinal_alias(query, index, name_stems)
            if has_stem(name_stems, alias or base):
                weights[card["id"]] = NAME_WEIGHT
            elif alias is None and has_stem(place_stems, base):
                weights[card["id"]] = PLACE_WEIGHT
        if not weights or (len(weights) == len(cards) > 1):
            continue
        target = numbered if token.isdigit() else worded
        for key, weight in weights.items():
            target[key] = target.get(key, 0.0) + weight
    scores = {}
    for card in cards:
        key = card["id"]
        score = strong[key][1] + worded.get(key, 0.0)
        if score > 0:
            scores[key] = score + numbered.get(key, 0.0)
    return scores


def unknown_designations(query: Query, known_texts: list[str], identities: list[str]) -> list[str]:
    """Находит в вопросе обозначения и длинные номера, которых нет в известных текстах.

    Обозначением считается слово вида «Н-999», «н999» или номер от шести цифр. Известным оно признаётся,
    если целиком встречается в known_texts (карточки оборудования, номера правил: «ТО-1», «VG220», «R08»)
    или служит обрывком не короче четырёх знаков одного из identities - обозначений, серийных номеров и моделей.
    """
    candidates = DESIGNATION.findall(query.text)
    if not candidates:
        return []
    known = set()
    for text in known_texts:
        folded = fold(text)
        for piece in set(DESIGNATION.findall(folded) + WORD.findall(folded)):
            known |= id_keys(piece)
    dense = [compact(text) for text in identities]
    result = []
    for found in candidates:
        keys = id_keys(found)
        partial = any(len(key) >= 4 and key in text for key in keys for text in dense)
        if not keys & known and not partial and found.upper() not in result:
            result.append(found.upper())
    return result


def match_node(query: Query, nodes: list[dict]) -> tuple[dict | None, float]:
    """Находит узел агрегата, названный в вопросе, и возвращает его вместе с весом совпадения.

    Главное слово названия узла или его разговорное название весит больше остальных слов названия:
    «двигатель» - это электродвигатель, а не «подшипники двигателя».
    """
    asked = [base for token, base in zip(query.tokens, query.stems) if token not in STOP_WORDS and len(token) > 1]
    best, best_score = None, 0.0
    for node in nodes:
        named = [stem(word) for word in words(node.get("name") or "") if len(word) > 1]
        named = [base for base in named if base not in NODE_SKIP_STEMS and base not in STOP_WORDS]
        keys = set(NODE_WORDS.get(node.get("id"), ())) | set(named[:1])
        key_hit = any(has_stem(keys, base) for base in asked)
        hits = sum(1 for base in set(named) if has_stem(asked, base))
        score = 2.0 * key_hit + hits
        if score > best_score:
            best, best_score = node, score
    return best, best_score


@dataclass(frozen=True)
class Record:
    """Запись для свободного поиска: вид, заголовок, текст, ссылка для приложения, агрегат и время.

    summary - готовая строка для ответа, ref - обозначение записи в её источнике (например номер правила).
    """

    kind: str
    title: str
    text: str
    deeplink: str
    equipment_id: str | None = None
    at: datetime | None = None
    summary: str = ""
    ref: str = ""


def rank(query: Query, records: list[Record], limit: int = 5, skip: frozenset[str] = frozenset()) -> list[Record]:
    """Отбирает записи, в которых встречается не меньше половины содержательных слов вопроса.

    Совпадение в заголовке весит вдвое больше совпадения в тексте; при равном весе выше более новая запись.
    Основы из skip в сравнении не участвуют: это слова, которыми в вопросе назван сам агрегат.
    Одна-две цифры сами по себе ничего не ищут: они встречаются в любой дате и в любом номере.
    """
    asked = [
        base
        for base in query.content()
        if base not in GENERIC_STEMS and base not in skip and not (base.isdigit() and len(base) < 3)
    ]
    if not asked:
        return []
    scored = []
    for record in records:
        title_stems, text_stems = stems_of(record.title), stems_of(record.text)
        in_title = [base for base in asked if has_stem(title_stems, base)]
        in_text = [base for base in asked if base not in in_title and has_stem(text_stems, base)]
        matched = len(in_title) + len(in_text)
        if matched * 2 < len(asked) or matched == 0:
            continue
        stamp = record.at.timestamp() if record.at else 0.0
        scored.append((-(2 * len(in_title) + len(in_text)), -stamp, record.title, record.deeplink, record))
    scored.sort(key=lambda entry: entry[:4])
    return [entry[4] for entry in scored[:limit]]
