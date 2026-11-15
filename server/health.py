"""Состояние каналов сервера для проверки готовности: база, каждая модель, распознавание текста, телеметрия, звук.

Ответ не раскрывает пути на диске: только имена файлов моделей, короткие хэши и состояния. Проверка дешёвая и
ничего не загружает: модели распознавания не поднимаются в память, базы заказчика не читаются целиком.
"""

from importlib import import_module

from server import fingerprint
from server.telemetry import loader

OK, MISSING, ERROR = "ok", "missing", "error"
STATE_TITLES = {OK: "работает", MISSING: "нет данных или файлов", ERROR: "ошибка"}


def _channel(state: str, detail: str | None = None, **extra) -> dict:
    """Описание одного канала: состояние, его русское название и пояснение."""
    return {"state": state, "title": STATE_TITLES[state], "detail": detail, **extra}


def _models(detector) -> list[dict]:
    """Каждая модель из models/models.json: есть ли файл, загружена ли она, короткий хэш файла."""
    info = getattr(detector, "info", None)
    state = info() if callable(info) else None
    loaded = set((state or {}).get("models") or []) if (state or {}).get("loaded") else set()
    failure = state.get("note") if state and not state.get("ready") else None
    rows = []
    for model in fingerprint.current()["models"]:
        if not model["present"]:
            rows.append(_channel(MISSING, "файла модели нет в поставке", file=model["file"], loaded=False, sha256=None))
            continue
        rows.append(
            _channel(
                ERROR if failure else OK, failure, file=model["file"], loaded=model["file"] in loaded, sha256=model["sha256"]
            )
        )
    return rows


def _ocr() -> dict:
    """Распознавание текста шильдика: установлен ли распознаватель и лежат ли его модели локально."""
    try:
        nameplate = import_module("cv.nameplate")
        nameplate.ocr_model_paths()
    except ImportError:
        return _channel(MISSING, "распознаватель текста не установлен")
    except OSError:
        return _channel(MISSING, "нет файлов моделей распознавания текста, их нужно положить в models/ocr")
    return _channel(OK, None, loaded=getattr(nameplate, "_engine", None) is not None)


def _telemetry() -> dict:
    """Данные телеметрии: лежат ли базы заказчика по вибрации и температуре; без них часть рядов только модельная."""
    try:
        for parts in (loader.VIBRATION_FILE, loader.TEMPERATURE_FILE):
            loader._locate(loader.CUSTOMER_DIR, parts)
    except (loader.TelemetryDataError, OSError):
        return _channel(MISSING, "баз заказчика нет: показания датчиков только модельные")
    return _channel(OK, "базы заказчика по вибрации и температуре на месте")


def _sound() -> dict:
    """Анализ звука агрегата: нужны только numpy и стандартный модуль wave."""
    try:
        import_module("server.sound")
    except ImportError:
        return _channel(ERROR, "модуль анализа звука не загружается")
    return _channel(OK)


def channels(detector, database: str) -> dict:
    """Собирает состояние всех каналов сервера."""
    return {
        "database": _channel(OK if database == "ok" else ERROR),
        "models": _models(detector),
        "ocr": _ocr(),
        "telemetry": _telemetry(),
        "sound": _sound(),
    }
