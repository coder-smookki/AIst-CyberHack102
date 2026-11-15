"""Необязательная переформулировка ответа локальной языковой моделью.

Модель получает вопрос и найденные факты и только связывает их в текст; ссылок она не видит и изменить
их не может. Включается переменными KST_LLM_URL (адрес локального сервера, совместимого с Ollama) и
KST_LLM_MODEL. При любой ошибке, превышении времени, пустом ответе или ответе с числами, которых нет в
фактах, возвращается None - и помощник отдаёт ответ, собранный поиском. Запросы уходят только на
локальный адрес, системные настройки прокси не используются.
"""

import ipaddress
import logging
import os
import re
from urllib.parse import urlsplit

import httpx

log = logging.getLogger(__name__)

CHAT_PATH = "/api/chat"
TIMEOUT = httpx.Timeout(4.0, connect=0.5, write=0.5, pool=0.5)
MIN_ANSWER_ROOM = 600
THINKING = re.compile(r"<think>.*?</think>", re.DOTALL)
LIST_MARK = re.compile(r"^\s*\d+[.)]\s+", re.MULTILINE)
NUMBER = re.compile(r"\d+")
LONG_DASH = re.compile(r"[\u2012-\u2015]")
INSTRUCTION = (
    "Ты помогаешь инженеру по обходу оборудования. Тебе дан вопрос и факты, найденные в базе данных. "
    "Ответь на вопрос связным текстом на русском языке, используя только эти факты. Ничего не добавляй, "
    "не предполагай и не давай советов от себя. Числа, даты, названия, обозначения и номера правил переноси "
    "без изменений. Не упоминай ссылки и не используй разметку. Если фактов для ответа недостаточно, "
    "перечисли факты как есть."
)


def is_local(url: str) -> bool:
    """Проверяет, что адрес ведёт на этот компьютер или в локальную сеть: внешние узлы запрещены."""
    parts = urlsplit(url)
    host = parts.hostname
    if parts.scheme not in ("http", "https") or not host:
        return False
    if host == "localhost" or host.endswith(".localhost"):
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return address.is_loopback or address.is_private


def configured() -> tuple[str, str] | None:
    """Возвращает адрес запроса и имя модели, если модель включена и адрес локальный; иначе None."""
    url = (os.environ.get("KST_LLM_URL") or "").strip()
    model = (os.environ.get("KST_LLM_MODEL") or "").strip()
    if not url or not model:
        return None
    if not is_local(url):
        log.warning("KST_LLM_URL указывает не на локальный адрес - языковая модель не используется")
        return None
    base = url.rstrip("/")
    return (base if base.endswith(CHAT_PATH) else base + CHAT_PATH), model


def make_client() -> httpx.Client:
    """Создаёт клиент для запроса к модели: короткие ожидания, без прокси из окружения и без перенаправлений."""
    return httpx.Client(timeout=TIMEOUT, trust_env=False, follow_redirects=False)


def _numbers(text: str) -> set[str]:
    """Выбирает из текста все числа как наборы цифр без ведущих нулей."""
    return {found.lstrip("0") or "0" for found in NUMBER.findall(text)}


def clean(text: object) -> str:
    """Убирает из ответа модели рассуждения и длинные тире; для нестрокового ответа возвращает пустую строку."""
    if not isinstance(text, str):
        return ""
    return LONG_DASH.sub("-", THINKING.sub("", text)).strip()


def grounded(text: str, question: str, facts: list[str]) -> bool:
    """Проверяет ответ модели: он не пуст, не раздут и не содержит чисел, которых нет в фактах и вопросе."""
    source = "\n".join(facts)
    if not text or len(text) > max(MIN_ANSWER_ROOM, 2 * len(source)):
        return False
    return _numbers(LIST_MARK.sub("", text)) <= _numbers(source) | _numbers(question)


def rephrase(question: str, facts: list[str]) -> str | None:
    """Просит локальную модель связать факты в ответ; None означает, что нужно отдать ответ поиска."""
    target = configured()
    if target is None or not facts:
        return None
    endpoint, model = target
    payload = {
        "model": model,
        "stream": False,
        "think": False,
        "options": {"temperature": 0},
        "messages": [
            {"role": "system", "content": INSTRUCTION},
            {"role": "user", "content": f"Вопрос: {question}\n\nФакты:\n" + "\n".join(facts)},
        ],
    }
    try:
        with make_client() as client:
            response = client.post(endpoint, json=payload)
            response.raise_for_status()
            text = clean(response.json()["message"]["content"])
    except Exception as error:
        log.warning("Языковая модель не ответила, отдан ответ поиска: %s", type(error).__name__)
        return None
    if not grounded(text, question, facts):
        log.warning("Ответ языковой модели отклонён проверкой, отдан ответ поиска")
        return None
    return text
