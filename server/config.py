"""Настройки сервера: пути к данным, файл базы, секрет подписи токенов, сроки их действия и разрешённые
источники запросов из браузера (CORS)."""

import os
import re
import secrets
from datetime import timedelta
from functools import lru_cache
from pathlib import Path
from threading import Lock

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
RUNTIME_DIR = DATA_DIR / "runtime"
EQUIPMENT_FILE = DATA_DIR / "equipment.json"
ACCESS_TTL = timedelta(minutes=30)
REFRESH_TTL = timedelta(days=30)
SECRET_MIN_LENGTH = 32
CORS_DEFAULT_REGEX = r"http://(localhost|127\.0\.0\.1)(:\d{1,5})?|null"
_secret_lock = Lock()


def cors_origin_regex() -> str | None:
    """Возвращает шаблон источников, которым браузер разрешит читать ответы сервера, или None - CORS выключен.

    Без переменной KST_CORS_ORIGINS разрешены только страницы с этой же машины: http://localhost и
    http://127.0.0.1 с любым портом и страницы, открытые из файла (браузер присылает источник null) - так
    презентация с живой демонстрацией обращается к локальному серверу. В KST_CORS_ORIGINS через запятую
    перечисляются точные источники, например http://localhost:3000,null; звёздочка заменяет любой порт или
    часть имени без косой черты. Пустое значение или off выключают CORS.
    """
    value = os.environ.get("KST_CORS_ORIGINS")
    if value is None:
        return CORS_DEFAULT_REGEX
    items = [item.strip().rstrip("/") for item in value.split(",") if item.strip()]
    if not items or items == ["off"]:
        return None
    return "|".join(re.escape(item).replace(r"\*", "[^/]*") for item in items)


def db_path() -> str:
    """Возвращает путь к файлу базы: из переменной KST_DB, а без неё - data/runtime/kst.db."""
    return os.environ.get("KST_DB") or str(RUNTIME_DIR / "kst.db")


def secret_key() -> str:
    """Возвращает секрет подписи токенов: из переменной KST_SECRET, а без неё - из файла secret.key рядом с базой.

    Короткий секрет подбирается перебором, поэтому значение короче 32 символов отвергается сразу.
    Файл создаётся под замком: два одновременных первых запроса не должны увидеть его наполовину записанным.
    """
    value = os.environ.get("KST_SECRET")
    if not value:
        with _secret_lock:
            return _file_secret(str(Path(db_path()).resolve().with_name("secret.key")))
    if len(value) < SECRET_MIN_LENGTH:
        raise RuntimeError(f"KST_SECRET короче {SECRET_MIN_LENGTH} символов - задайте более длинный секрет")
    return value


@lru_cache
def _file_secret(path: str) -> str:
    """Читает секрет из файла, а при первом запуске создаёт файл со случайным значением и правами 600."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        with open(path, encoding="ascii") as file:
            value = file.read().strip()
        if len(value) < SECRET_MIN_LENGTH:
            raise RuntimeError(f"Файл секрета {path} пуст или повреждён - удалите его, сервер создаст новый") from None
        return value
    value = secrets.token_hex(32)
    with os.fdopen(descriptor, "w", encoding="ascii") as file:
        file.write(value)
    return value
