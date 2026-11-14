"""База данных сервера: движок SQLite, фабрика сеансов и создание таблиц.

Путь к файлу базы читается в момент открытия соединения, поэтому один и тот же движок и одна фабрика
сеансов работают и с рабочей базой, и с временной базой тестов: достаточно задать KST_DB и вызвать init_db().
Изменения сохраняет тот, кто их делает: сеанс сам ничего не фиксирует, нужен явный session.commit().
"""
import json
import os
import sqlite3
from collections.abc import Iterator
from importlib import import_module

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker
from sqlalchemy.pool import QueuePool

from server import config


class Base(DeclarativeBase):
    """Общий предок всех таблиц."""


def _connect() -> sqlite3.Connection:
    """Открывает соединение с файлом базы по пути, действующему сейчас, и включает проверку внешних ключей.

    Новый файл базы создаётся с правами 600: в нём лежат хэши паролей и токенов.
    """
    path = os.path.abspath(config.db_path())
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.exists(path):
        os.close(os.open(path, os.O_WRONLY | os.O_CREAT, 0o600))
    connection = sqlite3.connect(path, timeout=15, check_same_thread=False)
    connection.execute("PRAGMA foreign_keys=ON")
    return connection


def _dump_json(value: object) -> str:
    """Записывает JSON без экранирования кириллицы, чтобы по сохранённому тексту можно было искать."""
    return json.dumps(value, ensure_ascii=False)


engine = create_engine("sqlite://", creator=_connect, poolclass=QueuePool, json_serializer=_dump_json)
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)


def get_session() -> Iterator[Session]:
    """Зависимость FastAPI: выдаёт сеанс базы на время запроса и закрывает его."""
    with SessionLocal() as session:
        yield session


def init_db() -> None:
    """Переключает движок на текущий путь базы и создаёт в ней недостающие таблицы.

    Все таблицы создаются одной записью на диск: так схема появляется целиком или не появляется вовсе,
    а новая база создаётся в несколько раз быстрее, чем при отдельной записи на каждую таблицу.
    База прежней схемы (роли без таблицы roles) после этого переводится на нынешнюю на месте, с сохранением
    сотрудников, осмотров и истории.
    """
    import_module("server.models")
    engine.dispose()
    with engine.begin() as connection:
        driver = connection.connection.driver_connection
        if not driver.in_transaction:
            driver.execute("BEGIN")
        Base.metadata.create_all(connection)
    engine.dispose()
    if import_module("server.migrate").upgrade(os.path.abspath(config.db_path())):
        engine.dispose()
