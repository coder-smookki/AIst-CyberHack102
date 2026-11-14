"""Записи звука агрегата в осмотре: приём WAV с телефона, анализ, хранение файла и итога, выдача списка.

Файл записи кладётся рядом со снимками находок, итог анализа - в таблицу sound_records. Признаки-кандидаты
замечаниями не становятся: инженер подтверждает нужный признак обычной записью дефекта с полем sign, и тогда
диагностика учитывает его как отметку инженера. Частота вращения берётся из телеметрии, а без неё - из карточки.
"""
from pathlib import Path

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from server import sound
from server.inspections.service import (
    _ensure_active,
    _ensure_editor,
    _person,
    _photos_dir,
    _stamp,
    _telemetry,
)
from server.models import Inspection, SoundRecord, User, now


def _blades(specs: dict) -> int | None:
    """Число лопаток рабочего колеса из карточки, если оно известно."""
    value = specs.get("impeller_blades") or specs.get("blades")
    return int(value) if isinstance(value, (int, float)) and value > 0 else None


def _normal_levels(session: Session, equipment_id: str) -> list[float]:
    """Уровни записей этого агрегата, отмеченных как норма, в порядке записи."""
    rows = session.scalars(select(SoundRecord).where(SoundRecord.equipment_id == equipment_id,
                                                     SoundRecord.normal.is_(True)).order_by(SoundRecord.id))
    return [row.summary["level_dbfs"] for row in rows if isinstance((row.summary or {}).get("level_dbfs"), (int, float))]


def record_view(record: SoundRecord) -> dict:
    """Описывает запись звука для ответа сервера; путь к файлу на диске не раскрывается."""
    return {"id": record.id, "inspection_id": record.inspection_id, "equipment_id": record.equipment_id,
            "user": _person(record.user), "created_at": _stamp(record.created_at), "normal": record.normal,
            "audio_url": f"/inspections/sound/{record.id}/audio" if record.audio_path else None,
            **(record.summary or {})}


def add_sound(session: Session, inspection: Inspection, user: User, data: bytes, normal: bool = False) -> SoundRecord:
    """Принимает запись звука осмотра, анализирует её, сохраняет файл и итог; неподходящая запись - 415 или 422.

    Норма уровня считается до добавления этой записи: запись-норма сравнивается с прежними нормами.
    """
    _ensure_editor(inspection, user)
    _ensure_active(inspection)
    try:
        samples, rate = sound.read_wav(data)
        item = inspection.equipment
        specs = item.data.get("specs") or {}
        readings, _, _ = _telemetry(item.id)
        rpm = readings.get("rpm") if readings.get("rpm") else specs.get("speed_rpm")
        measures = sound.analyse(samples, rate, rpm=float(rpm) if rpm else None, blades=_blades(specs))
    except sound.SoundError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    measures["rpm_source"] = "telemetry" if readings.get("rpm") else ("card" if rpm else None)
    baseline = sound.baseline_level(item.type, _normal_levels(session, item.id), specs)
    record = SoundRecord(inspection_id=inspection.id, equipment_id=item.id, user_id=user.id, created_at=now(),
                         normal=bool(normal), summary=sound.summary(measures, baseline))
    saved = None
    try:
        session.add(record)
        session.flush()
        relative = Path(f"inspection_{inspection.id}") / f"sound_{record.id}.wav"
        saved = _photos_dir() / relative
        saved.parent.mkdir(parents=True, exist_ok=True)
        saved.write_bytes(data)
        record.audio_path = relative.as_posix()
        session.commit()
    except Exception:
        session.rollback()
        if saved is not None:
            saved.unlink(missing_ok=True)
        raise
    session.refresh(record)
    return record


def list_sounds(session: Session, inspection_id: int) -> list[SoundRecord]:
    """Записи звука осмотра в порядке записи."""
    return list(session.scalars(select(SoundRecord).where(SoundRecord.inspection_id == inspection_id)
                                .order_by(SoundRecord.id)))


def recent_sounds(session: Session, limit: int = 20) -> list[SoundRecord]:
    """Последние записи звука по всем осмотрам, сначала новые."""
    return list(session.scalars(select(SoundRecord).order_by(SoundRecord.id.desc()).limit(limit)))


def get_sound(session: Session, record_id: int) -> SoundRecord:
    """Запись звука по номеру или 404."""
    record = session.get(SoundRecord, record_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Запись звука не найдена")
    return record


def audio_file(record: SoundRecord) -> Path:
    """Путь к файлу записи или 404, если файла нет."""
    root = _photos_dir()
    path = (root / (record.audio_path or "")).resolve()
    if not record.audio_path or not path.is_relative_to(root) or not path.is_file():
        raise HTTPException(status_code=404, detail="Файл записи не найден")
    return path
