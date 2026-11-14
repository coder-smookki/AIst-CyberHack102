"""Перевод базы прежней схемы на роли из таблицы roles без потери данных.

В прежней схеме роль сотрудника была одной из трёх строк с проверкой CHECK, а столбцов блокировки и
временного пароля не было. SQLite не умеет снимать CHECK и добавлять внешний ключ к существующей таблице,
поэтому таблица users пересобирается по документированной процедуре SQLite: новая таблица, перенос строк,
удаление старой, переименование, проверка внешних ключей. Номера сотрудников сохраняются, значит ссылки
из осмотров, работ и сеансов остаются верными. Роли engineer, master и admin становятся системными ролями
с теми же кодами. Всё выполняется одной транзакцией: при ошибке база остаётся в прежнем виде.
"""
import json
import sqlite3
from datetime import datetime

from sqlalchemy.dialects import sqlite
from sqlalchemy.schema import CreateTable

from server.models import User
from server.permissions import SYSTEM_ROLES, ordered

NEW_COLUMNS = ("is_active", "must_change_password", "created_at", "last_login_at", "password_changed_at")


def _columns(connection: sqlite3.Connection, table: str) -> set[str]:
    """Имена столбцов таблицы; пустое множество - таблицы нет."""
    return {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}


def needs_upgrade(connection: sqlite3.Connection) -> bool:
    """Сообщает, что в базе таблица users прежнего вида, без ссылки на роль и признаков блокировки."""
    columns = _columns(connection, "users")
    return bool(columns) and not set(NEW_COLUMNS) <= columns


def _users_ddl(name: str) -> str:
    """Текст создания таблицы users по нынешней модели под другим именем."""
    ddl = str(CreateTable(User.__table__).compile(dialect=sqlite.dialect())).strip()
    head = "CREATE TABLE users "
    if not ddl.startswith(head):
        raise RuntimeError("Неожиданное описание таблицы users - перевод базы невозможен")
    return f"CREATE TABLE {name} " + ddl[len(head):]


def upgrade(path: str) -> bool:
    """Переводит базу по пути path на нынешнюю схему, если нужно; возвращает, был ли выполнен перевод.

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
                    (code, title, description, json.dumps(ordered(permissions), ensure_ascii=False), moment, moment))
            connection.execute("DROP TABLE IF EXISTS users_upgrade")
            connection.execute(_users_ddl("users_upgrade"))
            connection.execute(
                "INSERT INTO users_upgrade (id, email, name, role, password_hash, is_active, must_change_password, created_at)"
                " SELECT id, email, name, role, password_hash, 1, 0, ? FROM users", (moment,))
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
