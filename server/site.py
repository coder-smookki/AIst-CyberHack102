"""Сведения об объекте для шапки приложения: название станции, текущая смена, имя сервера и часовой пояс.

Название берётся из переменной KST_SITE_NAME, часовой пояс - из KST_TIMEZONE, затем TZ, по умолчанию
Europe/Moscow; имя сервера - из KST_SERVER_NAME, а без неё - имя машины. Смена считается по местному
времени объекта: дневная 08:00-20:00, ночная 20:00-08:00.
"""
import os
import socket
from datetime import datetime, time, timedelta, timezone, tzinfo
from typing import Annotated
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends

from server.auth import current_user
from server.models import User

DEFAULT_SITE_NAME = "Насосная станция № 2"
DEFAULT_TIMEZONE = "Europe/Moscow"
FIXED_OFFSETS = {"Europe/Moscow": 3, "Asia/Yekaterinburg": 5, "UTC": 0}
DAY_START = time(8, 0)
NIGHT_START = time(20, 0)

router = APIRouter(tags=["site"])


def timezone_name() -> str:
    """Название часового пояса объекта из настроек."""
    return (os.environ.get("KST_TIMEZONE") or os.environ.get("TZ") or DEFAULT_TIMEZONE).lstrip(":")


def _zone(name: str) -> tzinfo | None:
    """Часовой пояс по названию; без базы часовых поясов - постоянное смещение для известных поясов."""
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        hours = FIXED_OFFSETS.get(name)
        return timezone(timedelta(hours=hours), name) if hours is not None else None


def server_name() -> str:
    """Имя сервера: из переменной KST_SERVER_NAME, а без неё - имя машины."""
    return (os.environ.get("KST_SERVER_NAME") or "").strip() or socket.gethostname()


def shift_of(moment: datetime) -> dict:
    """Смена по местному времени: дневная 08:00-20:00 или ночная 20:00-08:00, с началом и концом."""
    clock = moment.time()
    day = moment.date()
    if DAY_START <= clock < NIGHT_START:
        start, end = datetime.combine(day, DAY_START), datetime.combine(day, NIGHT_START)
        return {"code": "day", "shift": "08:00-20:00", "title": "Дневная смена", "start": start, "end": end}
    if clock < DAY_START:
        day -= timedelta(days=1)
    start = datetime.combine(day, NIGHT_START)
    return {"code": "night", "shift": "20:00-08:00", "title": "Ночная смена", "start": start,
            "end": start + timedelta(hours=12)}


def site_info(moment: datetime | None = None) -> dict:
    """Сведения об объекте на момент moment (по умолчанию - сейчас по местному времени объекта)."""
    name = timezone_name()
    zone = _zone(name)
    if moment is None:
        moment = datetime.now(zone) if zone else datetime.now()
    local = moment.replace(tzinfo=None)
    shift = shift_of(local)
    return {
        "name": (os.environ.get("KST_SITE_NAME") or "").strip() or DEFAULT_SITE_NAME,
        "shift": shift["shift"], "shift_code": shift["code"], "shift_title": shift["title"],
        "shift_start": shift["start"].isoformat(timespec="minutes"),
        "shift_end": shift["end"].isoformat(timespec="minutes"),
        "server_name": server_name(), "timezone": name,
        "local_time": local.isoformat(timespec="seconds"),
    }


@router.get("/site")
def site(user: Annotated[User, Depends(current_user)]) -> dict:
    """Название объекта, текущая смена, имя сервера и часовой пояс; нужен только вход."""
    return site_info()
