"""Помощник: вопрос об оборудовании и истории осмотров - ответ из данных базы и ссылки для приложения."""
from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, StringConstraints
from sqlalchemy.orm import Session

from server.assistant import intents, llm
from server.auth import current_user
from server.db import get_session
from server.equipment import get_equipment

router = APIRouter(prefix="/assistant", tags=["assistant"], dependencies=[Depends(current_user)])


class AskBody(BaseModel):
    """Вопрос помощнику; equipment_id - агрегат, открытый в приложении, если он есть."""

    question: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]
    equipment_id: Annotated[str | None, Field(max_length=32)] = None


@router.post("/ask")
def ask(body: AskBody, session: Annotated[Session, Depends(get_session)]) -> dict:
    """Отвечает на вопрос: текст, ссылки для приложения и способ получения ответа.

    mode "search" - ответ собран поиском по данным; "llm" - те же факты связаны в текст локальной моделью.
    Ссылки в обоих случаях одни и те же. Неизвестный equipment_id - ошибка 404.
    """
    equipment_id = body.equipment_id or None
    if equipment_id is not None:
        get_equipment(session, equipment_id)
    reply = intents.answer(session, body.question, equipment_id)
    text = llm.rephrase(body.question, reply.facts) if reply.found else None
    return {"answer": text or reply.answer, "links": reply.links, "mode": "llm" if text else "search"}
