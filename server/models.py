"""Таблицы сервера: роли, сотрудники и их сеансы, журнал и политика безопасности, оборудование и узлы,
осмотры, находки, записи о работах, сообщения о неисправностях и задания на осмотр.

Время в базе - местное время сервера без часового пояса, как в базах датчиков заказчика.
Поля JSON сохраняются при присваивании нового значения целиком: правка вложенного словаря на месте не отслеживается.
Перечни INSPECTION_STATUSES, FINDING_STATUSES и FINDING_SOURCES - принятые значения полей; база их не проверяет.
"""
from datetime import date, datetime

from sqlalchemy import JSON, CheckConstraint, ForeignKey, Index, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from server.db import Base

MODES = ("running", "stopped")
FINDING_STATES = ("open", "in_work", "resolved")
FINDING_STATUSES = ("ok", "check", "defect")
FINDING_SOURCES = ("camera", "sensor", "resource", "manual")
INSPECTION_STATUSES = ("active", "finished")
MAINTENANCE_KINDS = ("checked", "maintenance", "replacement")
FAULT_STATUSES = ("new", "assigned", "inspected", "rejected")
TASK_STATUSES = ("open", "done", "cancelled")
TASK_PRIORITIES = ("low", "normal", "high", "urgent")


def now() -> datetime:
    """Возвращает текущее местное время сервера - так помечаются все записи."""
    return datetime.now()


def _one_of(column: str, values: tuple[str, ...]) -> str:
    """Составляет условие проверки: значение столбца входит в перечень допустимых."""
    return f"{column} IN ({', '.join(repr(value) for value in values)})"


class Role(Base):
    """Роль сотрудника: название, описание и набор прав из перечня server/permissions.py.

    Системные роли нельзя удалить, но их название и права администратор ИБ менять может.
    """

    __tablename__ = "roles"

    code: Mapped[str] = mapped_column(String(32), primary_key=True)
    title: Mapped[str] = mapped_column(String(80))
    description: Mapped[str] = mapped_column(Text, default="")
    is_system: Mapped[bool] = mapped_column(default=False)
    permissions: Mapped[list] = mapped_column(JSON, default=list)
    created_at: Mapped[datetime] = mapped_column(default=now)
    updated_at: Mapped[datetime] = mapped_column(default=now)


class User(Base):
    """Учётная запись сотрудника: вход по почте и паролю, права определяет роль.

    Заблокированная запись не может войти. Признак must_change_password ставится при выдаче временного пароля:
    пока пароль не сменён, сервер пропускает только смену пароля, выход и сведения о себе.
    """

    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    email: Mapped[str] = mapped_column(String(254), unique=True)
    name: Mapped[str] = mapped_column(String(120))
    role: Mapped[str] = mapped_column(ForeignKey("roles.code"), index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    is_active: Mapped[bool] = mapped_column(default=True)
    must_change_password: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime | None] = mapped_column(default=now)
    last_login_at: Mapped[datetime | None]
    password_changed_at: Mapped[datetime | None]

    role_info: Mapped[Role] = relationship(lazy="joined")


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


class SecurityEvent(Base):
    """Запись журнала безопасности: что произошло, кто это сделал, над кем и с какими подробностями.

    actor_id - кто действовал (при неудачном входе неизвестен), target_user_id и target_role - над чем,
    email - почта, которой пытались войти, ip - адрес устройства.
    """

    __tablename__ = "security_events"

    id: Mapped[int] = mapped_column(primary_key=True)
    at: Mapped[datetime] = mapped_column(default=now, index=True)
    event: Mapped[str] = mapped_column(String(32), index=True)
    actor_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    target_user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    target_role: Mapped[str | None] = mapped_column(String(32))
    email: Mapped[str | None] = mapped_column(String(254))
    ip: Mapped[str | None] = mapped_column(String(64))
    details: Mapped[dict | None] = mapped_column(JSON(none_as_null=True))

    actor: Mapped[User | None] = relationship(foreign_keys=[actor_id])
    target_user: Mapped[User | None] = relationship(foreign_keys=[target_user_id])


class SecurityPolicy(Base):
    """Политика безопасности - единственная строка с номером 1: требования к паролю, блокировка входа, сеансы."""

    __tablename__ = "security_policy"
    __table_args__ = (
        CheckConstraint("min_password_length BETWEEN 6 AND 128", name="ck_policy_password_length"),
        CheckConstraint("lockout_attempts BETWEEN 3 AND 100", name="ck_policy_attempts"),
        CheckConstraint("lockout_minutes BETWEEN 1 AND 1440", name="ck_policy_minutes"),
        CheckConstraint("session_hours BETWEEN 1 AND 8760", name="ck_policy_session"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    min_password_length: Mapped[int] = mapped_column(default=10)
    require_letters_digits: Mapped[bool] = mapped_column(default=True)
    lockout_attempts: Mapped[int] = mapped_column(default=10)
    lockout_minutes: Mapped[int] = mapped_column(default=5)
    session_hours: Mapped[int] = mapped_column(default=720)
    biometrics_allowed: Mapped[bool] = mapped_column(default=True)
    updated_at: Mapped[datetime | None]
    updated_by_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))


class FaultReport(Base):
    """Сообщение оператора о признаках неисправности агрегата: признаки из перечня и комментарий.

    Состояние: new - новое, assigned - назначен осмотр, inspected - осмотр выполнен, rejected - отклонено.
    """

    __tablename__ = "fault_reports"
    __table_args__ = (
        CheckConstraint(_one_of("status", FAULT_STATUSES), name="ck_fault_reports_status"),
        Index("ix_fault_reports_status_created", "status", "created_at"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    equipment_id: Mapped[str] = mapped_column(ForeignKey("equipment.id"))
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    signs: Mapped[list] = mapped_column(JSON, default=list)
    comment: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(16), default="new")
    status_comment: Mapped[str | None] = mapped_column(Text)
    handled_by_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(default=now)
    status_changed_at: Mapped[datetime | None]

    equipment: Mapped[Equipment] = relationship()
    user: Mapped[User] = relationship(foreign_keys=[user_id])
    handled_by: Mapped[User | None] = relationship(foreign_keys=[handled_by_id])


class InspectionTask(Base):
    """Задание инженеру осмотреть агрегат: причина, срочность, срок и, если есть, сообщение о неисправности.

    Задание закрывается само, когда назначенный инженер завершает осмотр этого агрегата.
    """

    __tablename__ = "inspection_tasks"
    __table_args__ = (
        CheckConstraint(_one_of("status", TASK_STATUSES), name="ck_tasks_status"),
        CheckConstraint(_one_of("priority", TASK_PRIORITIES), name="ck_tasks_priority"),
        Index("ix_tasks_assignee_status", "assignee_id", "status"),
        Index("ix_tasks_equipment_status", "equipment_id", "status"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    equipment_id: Mapped[str] = mapped_column(ForeignKey("equipment.id"))
    assignee_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    assigned_by_id: Mapped[int] = mapped_column(ForeignKey("users.id"))
    fault_report_id: Mapped[int | None] = mapped_column(ForeignKey("fault_reports.id"))
    reason: Mapped[str] = mapped_column(Text)
    priority: Mapped[str] = mapped_column(String(16), default="normal")
    due_date: Mapped[date | None]
    status: Mapped[str] = mapped_column(String(16), default="open")
    created_at: Mapped[datetime] = mapped_column(default=now)
    closed_at: Mapped[datetime | None]
    inspection_id: Mapped[int | None] = mapped_column(ForeignKey("inspections.id"))

    equipment: Mapped[Equipment] = relationship()
    assignee: Mapped[User] = relationship(foreign_keys=[assignee_id])
    assigned_by: Mapped[User] = relationship(foreign_keys=[assigned_by_id])
    fault_report: Mapped[FaultReport | None] = relationship()
