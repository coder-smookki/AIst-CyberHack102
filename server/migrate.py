"""Перевод базы прежней схемы на роли из таблицы roles без потери данных.

В прежней схеме роль сотрудника была одной из трёх строк с проверкой CHECK, а столбцов блокировки и
временного пароля не было. SQLite не умеет снимать CHECK и добавлять внешний ключ к существующей таблице,
поэтому таблица users пересобирается по документированной процедуре SQLite: новая таблица, перенос строк,
удаление старой, переименование, проверка внешних ключей. Номера сотрудников сохраняются, значит ссылки
из осмотров, работ и сеансов остаются верными. Роли engineer, master и admin становятся системными ролями
с теми же кодами. Всё выполняется одной транзакцией: при ошибке база остаётся в прежнем виде.

Таблица findings прежнего вида (состояние без «отклонено», без столбцов отклонения и комментариев)
пересобирается так же: номера находок сохраняются, недостающие столбцы получают пустые значения.
Недостающие необязательные столбцы других таблиц (способ опознания агрегата в осмотре) добавляются ALTER TABLE.
"""

import json
import sqlite3
from datetime import datetime

from sqlalchemy.dialects import sqlite
from sqlalchemy.schema import CreateIndex, CreateTable

from server.models import Finding, User
from server.permissions import SYSTEM_ROLES, ordered

NEW_COLUMNS = ("is_active", "must_change_password", "created_at", "last_login_at", "password_changed_at")
FINDING_COLUMNS = ("rejected_at", "rejected_by_id", "notes")
REJECTED_STATE = "'rejected'"
ADDED_COLUMNS = (("inspections", "identified_by", "VARCHAR(16)"),)


def _columns(connection: sqlite3.Connection, table: str) -> set[str]:
    """Имена столбцов таблицы; пустое множество - таблицы нет."""
    return {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}


def needs_upgrade(connection: sqlite3.Connection) -> bool:
    """Сообщает, что в базе таблица users прежнего вида, без ссылки на роль и признаков блокировки."""
    columns = _columns(connection, "users")
    return bool(columns) and not set(NEW_COLUMNS) <= columns


def findings_need_upgrade(connection: sqlite3.Connection) -> bool:
    """Сообщает, что таблица findings прежнего вида: нет состояния «отклонено» или столбцов отклонения."""
    columns = _columns(connection, "findings")
    if not columns:
        return False
    row = connection.execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'findings'").fetchone()
    return not set(FINDING_COLUMNS) <= columns or REJECTED_STATE not in (row[0] if row else "")


def _table_ddl(table, name: str) -> str:
    """Текст создания таблицы по нынешней модели под другим именем."""
    ddl = str(CreateTable(table).compile(dialect=sqlite.dialect())).strip()
    head = f"CREATE TABLE {table.name} "
    if not ddl.startswith(head):
        raise RuntimeError(f"Неожиданное описание таблицы {table.name} - перевод базы невозможен")
    return f"CREATE TABLE {name} " + ddl[len(head) :]


def _users_ddl(name: str) -> str:
    """Текст создания таблицы users по нынешней модели под другим именем."""
    return _table_ddl(User.__table__, name)


def _upgrade_findings(connection: sqlite3.Connection) -> None:
    """Пересобирает таблицу findings по нынешней модели, перенося все строки и общие столбцы."""
    kept = [column.name for column in Finding.__table__.columns if column.name in _columns(connection, "findings")]
    listed = ", ".join(kept)
    connection.execute("DROP TABLE IF EXISTS findings_upgrade")
    connection.execute(_table_ddl(Finding.__table__, "findings_upgrade"))
    connection.execute(f"INSERT INTO findings_upgrade ({listed}) SELECT {listed} FROM findings")
    connection.execute("DROP TABLE findings")
    connection.execute("ALTER TABLE findings_upgrade RENAME TO findings")
    for index in Finding.metadata.tables[Finding.__tablename__].indexes:
        connection.execute(str(CreateIndex(index, if_not_exists=True).compile(dialect=sqlite.dialect())))


def _in_transaction(connection: sqlite3.Connection, work) -> None:
    """Выполняет перестройку таблиц одной транзакцией с отключёнными внешними ключами и проверкой после."""
    connection.execute("PRAGMA foreign_keys=OFF")
    connection.execute("BEGIN IMMEDIATE")
    try:
        work()
        broken = connection.execute("PRAGMA foreign_key_check").fetchall()
        if broken:
            raise RuntimeError(f"После перевода базы нарушены внешние ключи: {broken[:5]}")
        connection.execute("COMMIT")
    except Exception:
        connection.execute("ROLLBACK")
        raise
    finally:
        connection.execute("PRAGMA foreign_keys=ON")


def upgrade(path: str) -> bool:
    """Переводит базу по пути path на нынешнюю схему, если нужно; возвращает, был ли выполнен перевод.

    Сначала таблица users, затем таблица findings; каждая перестройка - своей транзакцией.
    """
    users = _upgrade_users(path)
    connection = sqlite3.connect(path, timeout=15, isolation_level=None)
    try:
        added = _add_columns(connection)
        if not findings_need_upgrade(connection):
            return users or added
        _in_transaction(connection, lambda: _upgrade_findings(connection))
        return True
    finally:
        connection.close()


def _add_columns(connection: sqlite3.Connection) -> bool:
    """Добавляет недостающие необязательные столбцы; возвращает, был ли добавлен хотя бы один."""
    added = False
    for table, column, kind in ADDED_COLUMNS:
        columns = _columns(connection, table)
        if columns and column not in columns:
            connection.execute(f"ALTER TABLE {table} ADD COLUMN {column} {kind}")
            added = True
    return added


def _upgrade_users(path: str) -> bool:
    """Переводит таблицу users на роли из таблицы roles, если нужно; возвращает, был ли выполнен перевод.

    Таблица roles к этому моменту уже создана общим созданием таблиц; сюда добавляются недостающие
    системные роли, без которых строки сотрудников не прошли бы проверку внешнего ключа.
    """
    connection = sqlite3.connect(path, timeout=15, isolation_level=None)
    try:
        if not needs_upgrade(connection):
            return False
        connection.execute("PRAGMA foreign_keys=OFF")
        connection.execute("BEGIN IMMEDIATE")
        try:
            moment = datetime.now().isoformat(sep=" ")
            for code, (title, description, permissions) in SYSTEM_ROLES.items():
                connection.execute(
                    "INSERT OR IGNORE INTO roles (code, title, description, is_system, permissions, created_at, updated_at)"
                    " VALUES (?, ?, ?, 1, ?, ?, ?)",
                    (code, title, description, json.dumps(ordered(permissions), ensure_ascii=False), moment, moment),
                )
            connection.execute("DROP TABLE IF EXISTS users_upgrade")
            connection.execute(_users_ddl("users_upgrade"))
            connection.execute(
                "INSERT INTO users_upgrade (id, email, name, role, password_hash, is_active, must_change_password, created_at)"
                " SELECT id, email, name, role, password_hash, 1, 0, ? FROM users",
                (moment,),
            )
            connection.execute("DROP TABLE users")
            connection.execute("ALTER TABLE users_upgrade RENAME TO users")
            connection.execute("CREATE INDEX IF NOT EXISTS ix_users_role ON users (role)")
            broken = connection.execute("PRAGMA foreign_key_check").fetchall()
            if broken:
                raise RuntimeError(f"После перевода базы нарушены внешние ключи: {broken[:5]}")
            connection.execute("COMMIT")
        except Exception:
            connection.execute("ROLLBACK")
            raise
        finally:
            connection.execute("PRAGMA foreign_keys=ON")
        return True
    finally:
        connection.close()
