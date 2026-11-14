"""Маршруты осмотров: начало, фиксация результатов, завершение, замечания и отчёты PDF и Excel.

Все запросы требуют входа и права по роли: просмотр - «Просмотр замечаний», осмотр - «Проведение осмотров»,
записи в осмотр - ещё и «Фиксация замечаний», смена состояния и отклонение замечания - «Подтверждение замечаний»,
комментарий к замечанию - «Просмотр замечаний» или автор осмотра,
отчёт - «Отчёты по своим осмотрам» для своего осмотра или «Отчёты по всем осмотрам» для любого.
Маршруты замечаний объявлены раньше маршрутов с номером осмотра, иначе слово findings в адресе
принималось бы за номер.
"""
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Response, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from server.auth import current_user, granted, require_permission
from server.db import get_session
from server.inspections import acoustics, service
from server.models import User
from server.reports import build_pdf, build_xlsx

XLSX_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
VIEW = require_permission("findings.view")
INSPECT = require_permission("inspect.run")
REPORTS = require_permission("reports.own", "reports.all", any_of=True)

router = APIRouter(prefix="/inspections", tags=["inspections"], dependencies=[Depends(current_user)])


class StartBody(BaseModel):
    """Запрос начала осмотра: обозначение оборудования и способ его опознания (по шильдику, вручную, по QR)."""

    equipment_id: str = Field(min_length=1, max_length=32)
    identified_by: Literal["nameplate", "manual", "qr"] | None = None


class StateBody(BaseModel):
    """Запрос смены состояния замечания; для отклонения (rejected) комментарий-причина обязателен."""

    state: Literal["open", "in_work", "resolved", "rejected"]
    comment: str | None = Field(default=None, max_length=1000)


class CommentBody(BaseModel):
    """Комментарий сотрудника к замечанию."""

    text: str = Field(min_length=1, max_length=1000)


@router.post("", status_code=201)
def start(body: StartBody, response: Response, user: Annotated[User, Depends(INSPECT)],
          session: Annotated[Session, Depends(get_session)]) -> dict:
    """Начинает осмотр; если у сотрудника уже идёт осмотр этого агрегата, возвращает его с кодом 200."""
    inspection, created = service.start_inspection(session, user, body.equipment_id, body.identified_by)
    if not created:
        response.status_code = 200
    return {**service.inspection_view(session, inspection), "resumed": not created}


@router.get("", dependencies=[Depends(VIEW)])
def list_inspections(
    session: Annotated[Session, Depends(get_session)],
    equipment_id: Annotated[str | None, Query(max_length=32)] = None,
    status: Annotated[Literal["active", "finished"] | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> list[dict]:
    """Список осмотров, сначала новые; отбор по оборудованию и состоянию."""
    return service.list_inspections(session, equipment_id, status, limit)


@router.get("/findings", dependencies=[Depends(VIEW)])
def list_findings(
    session: Annotated[Session, Depends(get_session)],
    state: Annotated[Literal["open", "in_work", "resolved", "rejected"] | None, Query()] = None,
    equipment_id: Annotated[str | None, Query(max_length=32)] = None,
    include_ok: Annotated[bool, Query()] = False,
    include_rejected: Annotated[bool, Query()] = False,
    limit: Annotated[int, Query(ge=1, le=500)] = 200,
) -> list[dict]:
    """Замечания по всем осмотрам для доски «открыто - в работе - устранено»; отклонённые - только по запросу."""
    return service.list_findings(session, equipment_id=equipment_id, state=state, include_ok=include_ok,
                                 include_rejected=include_rejected, limit=limit)


@router.get("/findings/{finding_id}", dependencies=[Depends(VIEW)])
def finding(finding_id: int, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Одно замечание с основаниями."""
    return service.one_finding_view(session, service.get_finding(session, finding_id))


@router.get("/findings/{finding_id}/photo", dependencies=[Depends(VIEW)])
def finding_photo(finding_id: int, session: Annotated[Session, Depends(get_session)]) -> FileResponse:
    """Стоп-кадр камеры, приложенный к замечанию."""
    path = service.photo_file(service.get_finding(session, finding_id))
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=3600"})


@router.post("/findings/{finding_id}/state")
def set_state(finding_id: int, body: StateBody, user: Annotated[User, Depends(require_permission("findings.confirm"))],
              session: Annotated[Session, Depends(get_session)]) -> dict:
    """Переводит замечание в следующее состояние или отклоняет его; нужно право «Подтверждение замечаний»."""
    changed = service.set_finding_state(session, service.get_finding(session, finding_id), body.state, user, body.comment)
    return service.one_finding_view(session, changed)


@router.post("/findings/{finding_id}/comment")
def comment(finding_id: int, body: CommentBody, user: Annotated[User, Depends(current_user)],
            session: Annotated[Session, Depends(get_session)]) -> dict:
    """Дописывает к замечанию комментарий с временем и автором: право «Просмотр замечаний» или автор осмотра."""
    found = service.get_finding(session, finding_id)
    if not service.can_comment(session, found, user, granted(session, user)):
        raise HTTPException(status_code=403, detail="Комментировать замечание может автор осмотра или сотрудник "
                                                    "с правом «Просмотр замечаний»")
    return service.one_finding_view(session, service.add_comment(session, found, user, body.text))


@router.get("/sound/{record_id}/audio", dependencies=[Depends(VIEW)])
def sound_audio(record_id: int, session: Annotated[Session, Depends(get_session)]) -> FileResponse:
    """Файл записи звука в формате WAV."""
    path = acoustics.audio_file(acoustics.get_sound(session, record_id))
    return FileResponse(path, media_type="audio/wav", headers={"Cache-Control": "private, max-age=3600"})


@router.get("/{inspection_id}", dependencies=[Depends(VIEW)])
def inspection(inspection_id: int, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Осмотр с находками и полнотой обхода."""
    return service.inspection_view(session, service.get_inspection(session, inspection_id))


@router.get("/{inspection_id}/findings", dependencies=[Depends(VIEW)])
def inspection_findings(inspection_id: int, session: Annotated[Session, Depends(get_session)]) -> list[dict]:
    """Все записи осмотра в порядке их появления."""
    return service.inspection_view(session, service.get_inspection(session, inspection_id))["findings"]


@router.post("/{inspection_id}/findings", status_code=201)
def add_finding(
    inspection_id: int,
    user: Annotated[User, Depends(require_permission("inspect.run", "findings.create"))],
    session: Annotated[Session, Depends(get_session)],
    kind: Annotated[Literal["checked", "defect", "maintenance", "replacement"], Form()],
    node: Annotated[str | None, Form(max_length=64)] = None,
    severity: Annotated[int | None, Form(ge=1, le=3)] = None,
    comment: Annotated[str | None, Form(max_length=2000)] = None,
    sign: Annotated[str | None, Form(max_length=64)] = None,
    rule_id: Annotated[str | None, Form(max_length=16)] = None,
    maintenance_code: Annotated[str | None, Form(max_length=32)] = None,
    frame: Annotated[UploadFile | None, File()] = None,
) -> dict:
    """Фиксирует результат по узлу: проверено, дефект, обслуживание или замена.

    Запрос - форма multipart; в поле frame можно приложить стоп-кадр камеры в формате JPEG.
    """
    found = service.get_inspection(session, inspection_id)
    picture = None
    if frame is not None:
        picture = frame.file.read(service.MAX_FRAME_BYTES + 1)
        if not picture:
            raise HTTPException(status_code=422, detail="Кадр пустой")
    created = service.add_finding(session, found, user, kind=kind, node=node, severity=severity, comment=comment,
                                  sign=sign, rule_id=rule_id, maintenance_code=maintenance_code, frame=picture)
    return service.one_finding_view(session, created)


@router.post("/{inspection_id}/sound", status_code=201)
def add_sound(
    inspection_id: int,
    user: Annotated[User, Depends(INSPECT)],
    session: Annotated[Session, Depends(get_session)],
    audio: Annotated[UploadFile, File()],
    normal: Annotated[bool, Form()] = False,
) -> dict:
    """Принимает запись звука агрегата (WAV PCM 16 бит, моно, 16-48 кГц, 2-30 с) и возвращает её анализ.

    Запрос - форма multipart с полем audio; normal = true отмечает запись как звучание исправного агрегата
    (такие записи служат нормой уровня). Признаки-кандидаты в ответе замечаниями не являются: подтверждение -
    запись дефекта с полем sign из кандидата.
    """
    found = service.get_inspection(session, inspection_id)
    data = audio.file.read(acoustics.sound.MAX_BYTES + 1)
    if not data:
        raise HTTPException(status_code=422, detail="Запись пустая")
    return acoustics.record_view(acoustics.add_sound(session, found, user, data, normal))


@router.get("/{inspection_id}/sound", dependencies=[Depends(VIEW)])
def sounds(inspection_id: int, session: Annotated[Session, Depends(get_session)]) -> list[dict]:
    """Записи звука осмотра с итогами анализа в порядке записи."""
    service.get_inspection(session, inspection_id)
    return [acoustics.record_view(record) for record in acoustics.list_sounds(session, inspection_id)]


@router.post("/{inspection_id}/finish")
def finish(inspection_id: int, user: Annotated[User, Depends(INSPECT)],
           session: Annotated[Session, Depends(get_session)]) -> dict:
    """Завершает осмотр и возвращает его со сводкой: число записей по статусам, длительность, оценки по узлам."""
    finished = service.finish_inspection(session, service.get_inspection(session, inspection_id), user)
    return service.inspection_view(session, finished)


def _report(session: Session, user: User, inspection_id: int, build, media_type: str, extension: str) -> Response:
    """Формирует файл отчёта и отдаёт его как вложение; без шрифта с кириллицей отвечает 503.

    Отчёт по чужому осмотру доступен только с правом «Отчёты по всем осмотрам».
    """
    found = service.get_inspection(session, inspection_id)
    if found.user_id != user.id and "reports.all" not in granted(session, user):
        raise HTTPException(status_code=403, detail="Отчёт по чужому осмотру доступен с правом «Отчёты по всем осмотрам»")
    data = service.report_data(session, found)
    try:
        content = build(data)
    except RuntimeError as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    name = f"kst-vizor-osmotr-{inspection_id}.{extension}"
    return Response(content, media_type=media_type, headers={"Content-Disposition": f'attachment; filename="{name}"'})


@router.get("/{inspection_id}/report.pdf")
def report_pdf(inspection_id: int, user: Annotated[User, Depends(REPORTS)],
               session: Annotated[Session, Depends(get_session)]) -> Response:
    """Отчёт об осмотре в формате PDF."""
    return _report(session, user, inspection_id, build_pdf, "application/pdf", "pdf")


@router.get("/{inspection_id}/report.xlsx")
def report_xlsx(inspection_id: int, user: Annotated[User, Depends(REPORTS)],
                session: Annotated[Session, Depends(get_session)]) -> Response:
    """Отчёт об осмотре в формате Excel."""
    return _report(session, user, inspection_id, build_xlsx, XLSX_TYPE, "xlsx")
