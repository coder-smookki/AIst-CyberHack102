"""Таблицы сервера: сотрудники и их сеансы, оборудование и узлы, осмотры, находки, записи о работах.

Время в базе - местное время сервера без часового пояса, как в базах датчиков заказчика.
Поля JSON сохраняются при присваивании нового значения целиком: правка вложенного словаря на месте не отслеживается.
Перечни INSPECTION_STATUSES, FINDING_STATUSES и FINDING_SOURCES - принятые значения полей; база их не проверяет.
"""
from datetime import date, datetime

from sqlalchemy import JSON, CheckConstraint, ForeignKey, Index, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from server.db import Base

ROLES = ("engineer", "master", "admin")
MODES = ("running", "stopped")
FINDING_STATES = ("open", "in_work", "resolved")
FINDING_STATUSES = ("ok", "check", "defect")
FINDING_SOURCES = ("camera", "sensor", "resource", "manual")
INSPECTION_STATUSES = ("active", "finished")
MAINTENANCE_KINDS = ("checked", "maintenance", "replacement")


def now() -> datetime:
    """Возвращает текущее местное время сервера - так помечаются все записи."""
    return datetime.now()


def _one_of(column: str, values: tuple[str, ...]) -> str:
    """Составляет условие проверки: значение столбца входит в перечень допустимых."""
    return f"{column} IN ({', '.join(repr(value) for value in values)})"


class User(Base):
    """Учётная запись сотрудника: вход по почте и паролю, роль определяет права."""

    __tablename__ = "users"
    __table_args__ = (CheckConstraint(_one_of("role", ROLES), name="ck_users_role"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(254), unique=True)
    name: Mapped[str] = mapped_column(String(120))
    role: Mapped[str] = mapped_column(String(16))
    password_hash: Mapped[str] = mapped_column(String(255))


class RefreshToken(Base):
    """Токен обновления на устройстве сотрудника: хранится только хэш, при каждом обновлении заменяется новым.

    Поле family общее у всей цепочки токенов одного входа - это и есть сеанс, который можно отозвать целиком.
    """

    __tablename__ = "refresh_tokens"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    family: Mapped[str] = mapped_column(String(32), index=True)
    device: Mapped[str | None] = mapped_column(String(120))
    created_at: Mapped[datetime] = mapped_column(default=now)
    revoked: Mapped[bool] = mapped_column(default=False)


class Equipment(Base):
    """Единица оборудования: изменяемое состояние лежит в столбцах, неизменное описание из карточки - в data."""

    __tablename__ = "equipment"
    __table_args__ = (CheckConstraint(_one_of("mode", MODES), name="ck_equipment_mode"),)

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    name: Mapped[str] = mapped_column(String(200))
    type: Mapped[str] = mapped_column(String(64))
    model: Mapped[str] = mapped_column(String(120))
    serial: Mapped[str] = mapped_column(String(64), unique=True)
    location: Mapped[str] = mapped_column(String(200))
    mode: Mapped[str] = mapped_column(String(16))
    run_hours: Mapped[float]
    data: Mapped[dict] = mapped_column(JSON, default=dict)

    nodes: Mapped[list["Node"]] = relationship(back_populates="equipment", order_by="Node.id")


class Node(Base):
    """Узел оборудования: наработка и даты установки и замены меняются, нормативы и классы детектора - в data."""

    __tablename__ = "nodes"
    __table_args__ = (UniqueConstraint("equipment_id", "code", name="uq_nodes_equipment_code"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    equipment_id: Mapped[str] = mapped_column(ForeignKey("equipment.id"))
    code: Mapped[str] = mapped_column(String(64))
    name: Mapped[str] = mapped_column(String(200))
    hours: Mapped[float | None]
    installed: Mapped[date | None]
    replaced: Mapped[date | None]
    data: Mapped[dict] = mapped_column(JSON, default=dict)

    equipment: Mapped[Equipment] = relationship(back_populates="nodes")


class Inspection(Base):
    """Осмотр оборудования сотрудником: время начала и конца, состояние и итоговая сводка."""

    __tablename__ = "inspections"
    __table_args__ = (Index("ix_inspections_equipment_started", "equipment_id", "started_at"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    equipment_id: Mapped[str] = mapped_column(ForeignKey("equipment.id"))
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    started_at: Mapped[datetime] = mapped_column(default=now)
    finished_at: Mapped[datetime | None]
    status: Mapped[str] = mapped_column(String(16), default="active")
    summary: Mapped[dict | None] = mapped_column(JSON(none_as_null=True))

    equipment: Mapped[Equipment] = relationship()
    user: Mapped[User] = relationship()
    findings: Mapped[list["Finding"]] = relationship(back_populates="inspection", order_by="Finding.id")


class Finding(Base):
    """Находка осмотра: что и на каком узле замечено, чем подтверждено и в каком состоянии устранение."""

    __tablename__ = "findings"
    __table_args__ = (
        CheckConstraint(_one_of("state", FINDING_STATES), name="ck_findings_state"),
        CheckConstraint("severity IS NULL OR severity BETWEEN 0 AND 3", name="ck_findings_severity"),
        Index("ix_findings_equipment_state", "equipment_id", "state"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    inspection_id: Mapped[int] = mapped_column(ForeignKey("inspections.id"), index=True)
    equipment_id: Mapped[str] = mapped_column(ForeignKey("equipment.id"))
    node_code: Mapped[str | None] = mapped_column(String(64))
    source: Mapped[str] = mapped_column(String(16))
    rule_id: Mapped[str | None] = mapped_column(String(16))
    status: Mapped[str] = mapped_column(String(16))
    severity: Mapped[int | None]
    title: Mapped[str] = mapped_column(String(200))
    diagnosis: Mapped[str | None] = mapped_column(Text)
    recommendation: Mapped[str | None] = mapped_column(Text)
    confidence: Mapped[float | None]
    evidence: Mapped[list | None] = mapped_column(JSON(none_as_null=True))
    comment: Mapped[str | None] = mapped_column(Text)
    photo_path: Mapped[str | None] = mapped_column(String(300))
    state: Mapped[str] = mapped_column(String(16), default="open")
    created_at: Mapped[datetime] = mapped_column(default=now)

    inspection: Mapped[Inspection] = relationship(back_populates="findings")


class MaintenanceRecord(Base):
    """Запись о работе на оборудовании или узле: проверка, обслуживание или замена."""

    __tablename__ = "maintenance_records"
    __table_args__ = (
        CheckConstraint(_one_of("kind", MAINTENANCE_KINDS), name="ck_maintenance_kind"),
        Index("ix_maintenance_equipment_at", "equipment_id", "at"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    equipment_id: Mapped[str] = mapped_column(ForeignKey("equipment.id"))
    node_code: Mapped[str | None] = mapped_column(String(64))
    kind: Mapped[str] = mapped_column(String(16))
    comment: Mapped[str | None] = mapped_column(Text)
    user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    at: Mapped[datetime] = mapped_column(default=now)
    hours_at: Mapped[float | None]

    user: Mapped[User | None] = relationship()
