"""QR-код на агрегате - запасной способ опознания, когда текст шильдика не прочитан.

Код читается детектором QR из OpenCV, без новых зависимостей и без обращения к сети. В коде может быть
обозначение агрегата, его заводской номер или адрес со ссылкой на агрегат: от адреса остаётся только сам
код (часть пути или значение параметра), сам адрес никогда не открывается. Совпадение принимается только
точное и только с одним агрегатом: если код подходит к нескольким, сервер не угадывает.
"""

import re
from urllib.parse import parse_qsl, unquote, urlsplit

import cv2
import numpy as np

URL = re.compile(r"^[a-z][a-z0-9+.-]*://", re.IGNORECASE)
SEPARATORS = re.compile(r"[\s;,|]+")
PREFIX = re.compile(r"^[a-z][a-z0-9_-]*[:=]", re.IGNORECASE)
MAX_TEXT = 512


def read_codes(frame: np.ndarray) -> list[str]:
    """Возвращает тексты всех QR-кодов на кадре; без кодов - пустой список."""
    if frame is None or frame.size == 0:
        return []
    detector = cv2.QRCodeDetector()
    texts = []
    try:
        found, decoded, _, _ = detector.detectAndDecodeMulti(frame)
        if found:
            texts.extend(text for text in decoded if text)
    except cv2.error:
        pass
    if not texts:
        try:
            text, _, _ = detector.detectAndDecode(frame)
        except cv2.error:
            text = ""
        if text:
            texts.append(text)
    return [text[:MAX_TEXT] for text in dict.fromkeys(texts)]


def _key(value) -> str:
    """Ключ сравнения: без пробелов и регистра."""
    return re.sub(r"\s+", "", str(value or "")).casefold()


def code_tokens(text: str) -> list[str]:
    """Разбирает текст QR-кода на возможные коды агрегата, от самых вероятных к остальным.

    От адреса остаются значения параметров и части пути (последняя часть первой); имя сервера не
    используется. Приставки вида «id:» или «serial=» отбрасываются.
    """
    text = (text or "").strip()
    tokens = []
    if URL.match(text):
        parts = urlsplit(text)
        tokens.extend(unquote(value) for _, value in parse_qsl(parts.query) if value)
        tokens.extend(unquote(segment) for segment in reversed(parts.path.split("/")) if segment)
        if parts.fragment:
            tokens.append(unquote(parts.fragment))
    else:
        tokens.append(text)
        tokens.extend(SEPARATORS.split(text))
    cleaned = []
    for token in tokens:
        token = token.strip()
        bare = PREFIX.sub("", token, count=1).strip()
        cleaned.extend(item for item in (token, bare) if item)
    return list(dict.fromkeys(cleaned))


def match_code(texts: list[str], cards: list[dict]) -> dict | None:
    """Находит агрегат по текстам QR-кодов: точное совпадение обозначения или заводского номера.

    Возвращает {card, by: "qr", ratio: 1.0, code, field} или None, если совпадений нет или их несколько.
    """
    by_id = {_key(card.get("id")): card for card in cards if card.get("id")}
    serials = {}
    for card in cards:
        if card.get("serial"):
            serials.setdefault(_key(card["serial"]), []).append(card)
    found = {}
    for text in texts:
        for token in code_tokens(text):
            key = _key(token)
            if key in by_id:
                found.setdefault(by_id[key]["id"], (by_id[key], token, "id"))
            elif len(serials.get(key, ())) == 1:
                card = serials[key][0]
                found.setdefault(card["id"], (card, token, "serial"))
    if len(found) != 1:
        return None
    card, token, field = next(iter(found.values()))
    return {"card": card, "by": "qr", "ratio": 1.0, "code": token, "field": field}


def read_and_match(frame: np.ndarray, cards: list[dict]) -> tuple[dict | None, list[str]]:
    """Читает QR-коды кадра и сопоставляет их с карточками; возвращает совпадение и прочитанные тексты."""
    texts = read_codes(frame)
    return (match_code(texts, cards) if texts else None), texts
