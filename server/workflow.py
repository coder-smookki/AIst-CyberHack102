"""Взаимодействие ролей: сообщения оператора о неисправности, задания инженерам на осмотр и лента уведомлений.

Оператор сообщает о признаках неисправности агрегата. Мастер разбирает сообщения и назначает инженеру
осмотр агрегата - с причиной, срочностью, сроком и, если есть, ссылкой на сообщение. Инженер видит свои
задания; задание закрывается само, когда этот инженер завершает осмотр агрегата, а связанное сообщение
получает состояние «осмотр выполнен». Уведомления не хранятся отдельно: лента каждый раз собирается из
заданий и сообщений, поэтому она всегда совпадает с данными.
"""

from datetime import date, datetime, timedelta
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session, joinedload

from server.auth import current_user, granted, require_permission, role_title
from server.db import get_session
from server.equipment import get_equipment
from server.models import FAULT_STATUSES, TASK_STATUSES, FaultReport, Inspection, InspectionTask, User, now

FAULT_SIGNS = {
    "noise": "Шум",
    "vibration": "Вибрация",
    "leak": "Течь",
    "burning_smell": "Запах гари",
    "heat": "Нагрев",
    "other": "Другое",
}
FAULT_TITLES = {"new": "Новое", "assigned": "Назначен осмотр", "inspected": "Осмотр выполнен", "rejected": "Отклонено"}
TASK_TITLES = {"open": "Назначено", "done": "Выполнено", "cancelled": "Отменено"}
PRIORITY_TITLES = {"low": "Низкая", "normal": "Обычная", "high": "Высокая", "urgent": "Срочно"}
PRIORITY_RANK = {"urgent": 0, "high": 1, "normal": 2, "low": 3}
RECENT_DAYS = 14

router = APIRouter(tags=["workflow"], dependencies=[Depends(current_user)])
ASSIGN = require_permission("tasks.assign")
REPORT = require_permission("fault.report")


class FaultBody(BaseModel):
    """Сообщение о неисправности: агрегат, признаки из перечня (код или название) и комментарий."""

    equipment_id: str = Field(min_length=1, max_length=32)
    signs: list[str] = Field(min_length=1, max_length=len(FAULT_SIGNS))
    comment: str | None = Field(default=None, max_length=1000)


class RejectBody(BaseModel):
    """Отклонение сообщения о неисправности с пояснением для оператора."""

    comment: str | None = Field(default=None, max_length=1000)


class TaskBody(BaseModel):
    """Задание на осмотр: агрегат, инженер, причина, срочность, срок и необязательное сообщение о неисправности."""

    equipment_id: str = Field(min_length=1, max_length=32)
    assignee_id: int = Field(ge=1)
    reason: str = Field(min_length=1, max_length=1000)
    fault_report_id: int | None = Field(default=None, ge=1)
    priority: Literal["low", "normal", "high", "urgent"] = "normal"
    due_date: date | None = None


class CancelBody(BaseModel):
    """Отмена задания с необязательной причиной."""

    comment: str | None = Field(default=None, max_length=1000)


def _stamp(moment: datetime | None) -> str | None:
    """Записывает время в виде ISO с точностью до секунды; отсутствующее время остаётся пустым."""
    return moment.isoformat(timespec="seconds") if moment else None


def _fold(text: str) -> str:
    """Приводит строку к виду для сравнения: без регистра и пробелов по краям, буква ё как е."""
    return text.strip().casefold().replace("ё", "е")


def normalize_signs(values: list[str]) -> list[str]:
    """Переводит признаки (коды или русские названия) в коды перечня без повторов; неизвестный признак - 422."""
    by_name = {_fold(code): code for code in FAULT_SIGNS} | {_fold(name): code for code, name in FAULT_SIGNS.items()}
    codes = []
    for value in values:
        code = by_name.get(_fold(value))
        if code is None:
            known = ", ".join(name.lower() for name in FAULT_SIGNS.values())
            raise HTTPException(status_code=422, detail=f"Неизвестный признак «{value}» - допустимы: {known}")
        if code not in codes:
            codes.append(code)
    return codes


def _person(user: User | None) -> dict | None:
    """Сотрудник в ответе: номер, имя и роль, без почты."""
    if user is None:
        return None
    return {"id": user.id, "name": user.name, "role": user.role, "role_title": role_title(user)}


def fault_view(report: FaultReport, task: InspectionTask | None = None) -> dict:
    """Описывает сообщение о неисправности для ответа сервера."""
    return {
        "id": report.id,
        "equipment_id": report.equipment_id,
        "equipment_name": report.equipment.name,
        "signs": [{"code": code, "title": FAULT_SIGNS.get(code, code)} for code in report.signs or []],
        "comment": report.comment,
        "status": report.status,
        "status_title": FAULT_TITLES[report.status],
        "status_comment": report.status_comment,
        "author": _person(report.user),
        "handled_by": _person(report.handled_by),
        "created_at": _stamp(report.created_at),
        "status_changed_at": _stamp(report.status_changed_at),
        "task_id": task.id if task else None,
    }


def task_view(task: InspectionTask, today: date | None = None) -> dict:
    """Описывает задание на осмотр для ответа сервера; overdue - срок прошёл, а задание не выполнено."""
    today = today or now().date()
    report = task.fault_report
    return {
        "id": task.id,
        "equipment_id": task.equipment_id,
        "equipment_name": task.equipment.name,
        "equipment_location": task.equipment.location,
        "assignee": _person(task.assignee),
        "assigned_by": _person(task.assigned_by),
        "reason": task.reason,
        "priority": task.priority,
        "priority_title": PRIORITY_TITLES[task.priority],
        "due_date": task.due_date.isoformat() if task.due_date else None,
        "overdue": bool(task.status == "open" and task.due_date and task.due_date < today),
        "status": task.status,
        "status_title": TASK_TITLES[task.status],
        "created_at": _stamp(task.created_at),
        "closed_at": _stamp(task.closed_at),
        "inspection_id": task.inspection_id,
        "fault_report": (
            None
            if report is None
            else {
                "id": report.id,
                "status": report.status,
                "status_title": FAULT_TITLES[report.status],
                "signs": [FAULT_SIGNS.get(code, code) for code in report.signs or []],
                "comment": report.comment,
            }
        ),
        "deeplink": f"kstvizor://task/{task.id}",
    }


def _tasks_query():
    """Запрос заданий вместе с агрегатом, сотрудниками и сообщением о неисправности."""
    return select(InspectionTask).options(
        joinedload(InspectionTask.equipment),
        joinedload(InspectionTask.assignee),
        joinedload(InspectionTask.assigned_by),
        joinedload(InspectionTask.fault_report),
    )


def _reports_query():
    """Запрос сообщений о неисправности вместе с агрегатом и сотрудниками."""
    return select(FaultReport).options(
        joinedload(FaultReport.equipment), joinedload(FaultReport.user), joinedload(FaultReport.handled_by)
    )


def _sorted_tasks(tasks) -> list[InspectionTask]:
    """Сначала открытые задания по срочности и сроку, затем закрытые, от новых к старым."""

    def key(task: InspectionTask):
        """Ключ сортировки задания."""
        if task.status == "open":
            return (0, PRIORITY_RANK[task.priority], task.due_date or date.max, -task.id)
        return (1, 0, date.max, -task.id)

    return sorted(tasks, key=key)


def _latest_tasks(session: Session, report_ids: list[int]) -> dict[int, InspectionTask]:
    """Последнее задание по каждому сообщению о неисправности."""
    if not report_ids:
        return {}
    latest = {}
    for task in session.scalars(
        select(InspectionTask).where(InspectionTask.fault_report_id.in_(report_ids)).order_by(InspectionTask.id)
    ):
        latest[task.fault_report_id] = task
    return latest


def _reports_view(session: Session, reports: list[FaultReport]) -> list[dict]:
    """Описывает список сообщений вместе с номерами их последних заданий."""
    tasks = _latest_tasks(session, [report.id for report in reports])
    return [fault_view(report, tasks.get(report.id)) for report in reports]


def close_tasks(session: Session, inspection: Inspection, moment: datetime) -> list[InspectionTask]:
    """Закрывает открытые задания автора осмотра на этот агрегат; связанные сообщения - «осмотр выполнен».

    Вызывается при завершении осмотра внутри той же транзакции; сохраняет вызывающий.
    """
    tasks = list(
        session.scalars(
            select(InspectionTask).where(
                InspectionTask.equipment_id == inspection.equipment_id,
                InspectionTask.assignee_id == inspection.user_id,
                InspectionTask.status == "open",
            )
        )
    )
    for task in tasks:
        task.status, task.closed_at, task.inspection_id = "done", moment, inspection.id
        report = session.get(FaultReport, task.fault_report_id) if task.fault_report_id else None
        if report is not None and report.status == "assigned":
            report.status, report.status_changed_at = "inspected", moment
            report.status_comment = f"Выполнен осмотр № {inspection.id}"
    return tasks


@router.get("/fault-reports/signs")
def fault_signs() -> list[dict]:
    """Перечень признаков неисправности для формы оператора."""
    return [{"code": code, "title": title} for code, title in FAULT_SIGNS.items()]


@router.post("/fault-reports", status_code=201)
def create_fault_report(
    body: FaultBody, user: Annotated[User, Depends(REPORT)], session: Annotated[Session, Depends(get_session)]
) -> dict:
    """Принимает сообщение оператора о неисправности; признак «другое» требует комментария."""
    item = get_equipment(session, body.equipment_id)
    signs = normalize_signs(body.signs)
    comment = (body.comment or "").strip() or None
    if "other" in signs and comment is None:
        raise HTTPException(status_code=422, detail="Опишите признак «Другое» в комментарии")
    report = FaultReport(equipment_id=item.id, user_id=user.id, signs=signs, comment=comment, status="new", created_at=now())
    session.add(report)
    session.commit()
    return fault_view(session.scalars(_reports_query().where(FaultReport.id == report.id)).one())


@router.get("/fault-reports", dependencies=[Depends(ASSIGN)])
def list_fault_reports(
    session: Annotated[Session, Depends(get_session)],
    status: Annotated[Literal[FAULT_STATUSES] | None, Query()] = None,
    equipment_id: Annotated[str | None, Query(max_length=32)] = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
) -> list[dict]:
    """Все сообщения о неисправностях для мастера, сначала новые; отбор по состоянию и агрегату."""
    query = _reports_query()
    if status:
        query = query.where(FaultReport.status == status)
    if equipment_id:
        query = query.where(FaultReport.equipment_id == equipment_id)
    reports = list(session.scalars(query.order_by(FaultReport.created_at.desc(), FaultReport.id.desc()).limit(limit)))
    return _reports_view(session, reports)


@router.get("/fault-reports/my")
def my_fault_reports(
    user: Annotated[User, Depends(REPORT)],
    session: Annotated[Session, Depends(get_session)],
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
) -> list[dict]:
    """Сообщения о неисправностях, отправленные самим сотрудником, с их текущим состоянием."""
    query = _reports_query().where(FaultReport.user_id == user.id)
    reports = list(session.scalars(query.order_by(FaultReport.created_at.desc(), FaultReport.id.desc()).limit(limit)))
    return _reports_view(session, reports)


def _get_report(session: Session, report_id: int) -> FaultReport:
    """Сообщение о неисправности по номеру или ответ 404."""
    report = session.scalars(_reports_query().where(FaultReport.id == report_id)).one_or_none()
    if report is None:
        raise HTTPException(status_code=404, detail="Сообщение о неисправности не найдено")
    return report


@router.get("/fault-reports/{report_id}")
def fault_report(
    report_id: int, user: Annotated[User, Depends(current_user)], session: Annotated[Session, Depends(get_session)]
) -> dict:
    """Одно сообщение: его автору или сотруднику с правом назначать осмотры."""
    report = _get_report(session, report_id)
    if report.user_id != user.id and "tasks.assign" not in granted(session, user):
        raise HTTPException(status_code=403, detail="Сообщение доступно его автору и мастеру")
    return _reports_view(session, [report])[0]


@router.post("/fault-reports/{report_id}/reject")
def reject_fault_report(
    report_id: int, body: RejectBody, user: Annotated[User, Depends(ASSIGN)], session: Annotated[Session, Depends(get_session)]
) -> dict:
    """Отклоняет новое сообщение - например, повтор уже известной неисправности; оператор увидит пояснение."""
    report = _get_report(session, report_id)
    if report.status != "new":
        raise HTTPException(
            status_code=409, detail=f"Отклонить можно только новое сообщение, а это - " f"«{FAULT_TITLES[report.status]}»"
        )
    report.status, report.status_changed_at, report.handled_by_id = "rejected", now(), user.id
    report.status_comment = (body.comment or "").strip() or None
    session.commit()
    return _reports_view(session, [_get_report(session, report_id)])[0]


def _get_task(session: Session, task_id: int) -> InspectionTask:
    """Задание по номеру или ответ 404."""
    task = session.scalars(_tasks_query().where(InspectionTask.id == task_id)).one_or_none()
    if task is None:
        raise HTTPException(status_code=404, detail="Задание не найдено")
    return task


@router.post("/tasks", status_code=201)
def create_task(
    body: TaskBody, user: Annotated[User, Depends(ASSIGN)], session: Annotated[Session, Depends(get_session)]
) -> dict:
    """Назначает инженеру осмотр агрегата; связанное сообщение о неисправности получает «назначен осмотр».

    Исполнитель должен быть действующим сотрудником с правом «Проведение осмотров».
    """
    item = get_equipment(session, body.equipment_id)
    assignee = session.get(User, body.assignee_id)
    if assignee is None:
        raise HTTPException(status_code=404, detail="Исполнитель не найден")
    if not assignee.is_active or "inspect.run" not in granted(session, assignee):
        raise HTTPException(
            status_code=422, detail="Исполнитель должен быть действующим сотрудником с правом " "«Проведение осмотров»"
        )
    reason = body.reason.strip()
    if not reason:
        raise HTTPException(status_code=422, detail="Укажите причину осмотра")
    report = None
    if body.fault_report_id is not None:
        report = session.get(FaultReport, body.fault_report_id)
        if report is None:
            raise HTTPException(status_code=404, detail="Сообщение о неисправности не найдено")
        if report.equipment_id != item.id:
            raise HTTPException(status_code=422, detail="Сообщение о неисправности относится к другому агрегату")
        if report.status in ("rejected", "inspected"):
            raise HTTPException(status_code=409, detail=f"Сообщение уже закрыто: «{FAULT_TITLES[report.status]}»")
    moment = now()
    task = InspectionTask(
        equipment_id=item.id,
        assignee_id=assignee.id,
        assigned_by_id=user.id,
        reason=reason,
        fault_report_id=report.id if report else None,
        priority=body.priority,
        due_date=body.due_date,
        status="open",
        created_at=moment,
    )
    session.add(task)
    if report is not None and report.status != "assigned":
        report.status, report.status_changed_at, report.handled_by_id = "assigned", moment, user.id
        report.status_comment = f"Назначен осмотр: {assignee.name}"
    session.commit()
    return task_view(_get_task(session, task.id))


@router.get("/tasks", dependencies=[Depends(ASSIGN)])
def list_tasks(
    session: Annotated[Session, Depends(get_session)],
    status: Annotated[Literal[TASK_STATUSES] | None, Query()] = None,
    assignee_id: Annotated[int | None, Query(ge=1)] = None,
    equipment_id: Annotated[str | None, Query(max_length=32)] = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 200,
) -> list[dict]:
    """Все задания для мастера: открытые по срочности и сроку, затем закрытые."""
    query = _tasks_query()
    if status:
        query = query.where(InspectionTask.status == status)
    if assignee_id:
        query = query.where(InspectionTask.assignee_id == assignee_id)
    if equipment_id:
        query = query.where(InspectionTask.equipment_id == equipment_id)
    tasks = session.scalars(query.order_by(InspectionTask.id.desc()).limit(limit))
    return [task_view(task) for task in _sorted_tasks(tasks)]


@router.get("/tasks/my")
def my_tasks(
    user: Annotated[User, Depends(require_permission("inspect.run"))],
    session: Annotated[Session, Depends(get_session)],
    status: Annotated[Literal[TASK_STATUSES] | None, Query()] = "open",
) -> list[dict]:
    """Задания, назначенные самому инженеру; по умолчанию - открытые, срочные и с близким сроком первыми."""
    query = _tasks_query().where(InspectionTask.assignee_id == user.id)
    if status:
        query = query.where(InspectionTask.status == status)
    return [task_view(task) for task in _sorted_tasks(session.scalars(query))]


@router.get("/tasks/{task_id}")
def one_task(
    task_id: int, user: Annotated[User, Depends(current_user)], session: Annotated[Session, Depends(get_session)]
) -> dict:
    """Одно задание: исполнителю или сотруднику с правом назначать осмотры."""
    found = _get_task(session, task_id)
    if found.assignee_id != user.id and "tasks.assign" not in granted(session, user):
        raise HTTPException(status_code=403, detail="Задание доступно исполнителю и мастеру")
    return task_view(found)


@router.post("/tasks/{task_id}/cancel")
def cancel_task(
    task_id: int, body: CancelBody, user: Annotated[User, Depends(ASSIGN)], session: Annotated[Session, Depends(get_session)]
) -> dict:
    """Отменяет открытое задание; связанное сообщение снова становится новым, если других заданий по нему нет."""
    found = _get_task(session, task_id)
    if found.status != "open":
        raise HTTPException(status_code=409, detail=f"Задание уже закрыто: «{TASK_TITLES[found.status]}»")
    moment = now()
    found.status, found.closed_at = "cancelled", moment
    note = (body.comment or "").strip()
    if note:
        found.reason = f"{found.reason}\nОтменено - {user.name}, {moment:%d.%m.%Y %H:%M}: {note}"
    report = found.fault_report
    if report is not None and report.status == "assigned":
        others = session.scalar(
            select(InspectionTask.id).where(
                InspectionTask.fault_report_id == report.id, InspectionTask.status == "open", InspectionTask.id != found.id
            )
        )
        if others is None:
            report.status, report.status_changed_at = "new", moment
            report.status_comment = "Задание на осмотр отменено"
    session.commit()
    return task_view(_get_task(session, task_id))


def _note(key: str, kind: str, at: datetime | None, title: str, text: str, **extra) -> dict:
    """Одно уведомление ленты."""
    return {"id": key, "kind": kind, "at": _stamp(at), "title": title, "text": text, **extra}


@router.get("/notifications")
def notifications(
    user: Annotated[User, Depends(current_user)],
    session: Annotated[Session, Depends(get_session)],
    since: Annotated[datetime | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> list[dict]:
    """Лента уведомлений сотрудника, сначала новые; since - только события позже указанного момента.

    Виды: task_assigned и task_cancelled - задания самому сотруднику; task_done - выполнено задание, которое
    он назначил; fault_report_new - новые сообщения о неисправностях (тем, кто назначает осмотры);
    fault_report_status - изменилось состояние его собственного сообщения. Закрытые события старше
    двух недель в ленту не попадают.
    """
    have = granted(session, user)
    horizon = now() - timedelta(days=RECENT_DAYS)
    items = []
    for task in session.scalars(_tasks_query().where(InspectionTask.assignee_id == user.id)):
        where = f"{task.equipment.name} ({task.equipment_id})"
        link = {"task_id": task.id, "equipment_id": task.equipment_id, "deeplink": f"kstvizor://task/{task.id}"}
        if task.status == "open" or task.created_at >= horizon:
            due = f", срок {task.due_date:%d.%m.%Y}" if task.due_date else ""
            items.append(
                _note(
                    f"task-{task.id}",
                    "task_assigned",
                    task.created_at,
                    "Назначен осмотр",
                    f"{where}: {task.reason}. Срочность: {PRIORITY_TITLES[task.priority].lower()}{due}",
                    priority=task.priority,
                    **link,
                )
            )
        if task.status == "cancelled" and task.closed_at and task.closed_at >= horizon:
            items.append(
                _note(
                    f"task-{task.id}-cancelled",
                    "task_cancelled",
                    task.closed_at,
                    "Задание отменено",
                    f"{where}: осмотр больше не требуется",
                    **link,
                )
            )
    for task in session.scalars(
        _tasks_query().where(
            InspectionTask.assigned_by_id == user.id, InspectionTask.status == "done", InspectionTask.closed_at >= horizon
        )
    ):
        items.append(
            _note(
                f"task-{task.id}-done",
                "task_done",
                task.closed_at,
                "Осмотр по заданию выполнен",
                f"{task.assignee.name} осмотрел {task.equipment.name} ({task.equipment_id})",
                task_id=task.id,
                equipment_id=task.equipment_id,
                inspection_id=task.inspection_id,
                deeplink=f"kstvizor://inspection/{task.inspection_id}",
            )
        )
    if "tasks.assign" in have:
        for report in session.scalars(_reports_query().where(FaultReport.status == "new")):
            signs = ", ".join(FAULT_SIGNS.get(code, code).lower() for code in report.signs or [])
            items.append(
                _note(
                    f"fault-{report.id}",
                    "fault_report_new",
                    report.created_at,
                    "Сообщение о неисправности",
                    f"{report.equipment.name} ({report.equipment_id}): {signs}. Сообщил {report.user.name}",
                    fault_report_id=report.id,
                    equipment_id=report.equipment_id,
                    deeplink=f"kstvizor://fault-report/{report.id}",
                )
            )
    for report in session.scalars(
        _reports_query().where(
            FaultReport.user_id == user.id, FaultReport.status != "new", FaultReport.status_changed_at >= horizon
        )
    ):
        text = f"{report.equipment.name} ({report.equipment_id}): {FAULT_TITLES[report.status].lower()}"
        if report.status_comment:
            text += f" - {report.status_comment}"
        items.append(
            _note(
                f"fault-{report.id}-{report.status}",
                "fault_report_status",
                report.status_changed_at,
                "Состояние вашего сообщения",
                text,
                fault_report_id=report.id,
                status=report.status,
                equipment_id=report.equipment_id,
                deeplink=f"kstvizor://fault-report/{report.id}",
            )
        )
    if since is not None:
        items = [item for item in items if item["at"] and item["at"] > _stamp(since)]
    items.sort(key=lambda item: (item["at"] or "", item["id"]), reverse=True)
    return items[:limit]
