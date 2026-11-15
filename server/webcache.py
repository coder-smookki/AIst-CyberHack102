"""Быстрая отдача веб-панели и условные ответы API.

Стили и сценарии панели подключаются со страницы с меткой версии в адресе (?v=...): метка считается по
размеру и времени изменения файлов, поэтому такие файлы браузер хранит год и не перепроверяет, а после
обновления сервера получает новые адреса. Сама страница всегда перепроверяется, шрифты и картинки хранятся
месяц. Запросы GET с заголовком If-None-Match получают метку содержимого ответа JSON и короткий ответ 304,
если данные не изменились: панель опрашивает сервер раз в полторы секунды и не скачивает одно и то же.
Клиенты без этого заголовка (приложение на телефоне) получают ответы как раньше.

Собранная на Next.js панель (web/out) отдаётся по /web/, /panel/ и /_next/: файлы с хешем в имени хранятся год,
страницы перепроверяются; прежняя панель без сборки остаётся по /web-classic/ и /panel-classic/.
"""

import hashlib
import os
import re
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from starlette.types import ASGIApp, Message, Receive, Scope, Send

YEAR = "public, max-age=31536000, immutable"
MONTH = "public, max-age=2592000"
REVALIDATE = "no-cache"
VERSIONED = re.compile(r'(href|src)="((?:css|js)/[^"?#]+)"')
INDEX_PATHS = ("", ".", "index.html")
MAX_BODY = 4 * 1024 * 1024
STATIC_PREFIXES = ("/web/", "/panel/", "/docs-assets/", "/_next/", "/web-classic/", "/panel-classic/")
EXPORT_DIR = Path(__file__).resolve().parent.parent / "web" / "out"
UI_DEFAULT = "next"


def version_of(folder: Path) -> str:
    """Метка версии папки со стилями и сценариями: меняется при изменении любого файла."""
    digest = hashlib.sha1()
    for path in sorted(folder.rglob("*")):
        if path.is_file() and path.suffix in (".css", ".js", ".html"):
            stat = path.stat()
            digest.update(f"{path.relative_to(folder).as_posix()}:{stat.st_size}:{stat.st_mtime_ns};".encode())
    return digest.hexdigest()[:12]


def index_html(folder: Path) -> str:
    """Страница панели, в которой адреса стилей и сценариев дополнены меткой версии."""
    version = version_of(folder)
    text = (folder / "index.html").read_text(encoding="utf-8")
    return VERSIONED.sub(lambda match: f'{match.group(1)}="{match.group(2)}?v={version}"', text)


class PanelFiles(StaticFiles):
    """Файлы веб-панели с правилами хранения в браузере: версия в адресе - год, шрифты и картинки - месяц."""

    def __init__(self, *, directory: Path) -> None:
        """Запоминает папку панели; страница index.html отдаётся и по адресу папки."""
        super().__init__(directory=directory, html=True)
        self.folder = Path(directory)

    async def get_response(self, path: str, scope: Scope):
        """Отдаёт файл с заголовком Cache-Control; страницу панели собирает заново с меткой версии."""
        if path in INDEX_PATHS:
            return HTMLResponse(index_html(self.folder), headers={"Cache-Control": REVALIDATE})
        response = await super().get_response(path, scope)
        if response.status_code in (200, 304):
            if b"v=" in scope.get("query_string", b""):
                response.headers["Cache-Control"] = YEAR
            elif path.startswith("assets"):
                response.headers["Cache-Control"] = MONTH
            else:
                response.headers["Cache-Control"] = REVALIDATE
        return response


def mount_panel(app: FastAPI, prefix: str, folder: Path, name: str = "webadmin") -> None:
    """Подключает веб-панель по адресу prefix."""
    app.mount(prefix, PanelFiles(directory=folder), name=name)


class ExportFiles(StaticFiles):
    """Файлы сборки Next.js: /_next/static/ с хешем в имени хранятся год, картинки - месяц, страницы перепроверяются."""

    def __init__(self, *, directory: Path, html: bool = False) -> None:
        """Запоминает папку сборки; для страниц index.html отдаётся по адресу папки."""
        super().__init__(directory=directory, html=html)

    async def get_response(self, path: str, scope: Scope):
        """Отдаёт файл сборки с заголовком Cache-Control по его виду."""
        response = await super().get_response(path, scope)
        if response.status_code in (200, 304):
            if path.startswith("static/"):
                response.headers["Cache-Control"] = YEAR
            elif path.startswith("assets"):
                response.headers["Cache-Control"] = MONTH
            else:
                response.headers["Cache-Control"] = REVALIDATE
        return response


def export_dir() -> Path | None:
    """Папка сборки Next.js, если веб-панель и пульт нужно отдавать из неё.

    KST_WEB_UI=next или classic выбирает интерфейс (по умолчанию UI_DEFAULT), KST_WEB_EXPORT задаёт другую папку
    сборки. Без собранных файлов (тесты без Node) остаётся прежний интерфейс.
    """
    if os.environ.get("KST_WEB_UI", UI_DEFAULT).strip().lower() != "next":
        return None
    folder = Path(os.environ.get("KST_WEB_EXPORT") or EXPORT_DIR)
    needed = (folder / "web" / "index.html", folder / "panel" / "index.html", folder / "_next" / "static")
    return folder if all(path.exists() for path in needed) else None


def mount_export(app: FastAPI, folder: Path) -> None:
    """Подключает сборку Next.js: /_next/ (стили, сценарии, шрифты), /web/ и /panel/."""
    app.mount("/_next", ExportFiles(directory=folder / "_next"), name="next")
    app.mount("/web", ExportFiles(directory=folder / "web", html=True), name="webadmin")
    app.mount("/panel", ExportFiles(directory=folder / "panel", html=True), name="panel")


class ConditionalGet:
    """Условные ответы на GET: метка содержимого ETag для ответов JSON и 304, если данные не изменились.

    Работает только для запросов с заголовком If-None-Match и только для ответов 200 с JSON не крупнее
    4 МБ; файлы, снимки, отчёты и статические страницы проходят без изменений.
    """

    def __init__(self, app: ASGIApp) -> None:
        """Запоминает следующее звено обработки запроса."""
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        """Пропускает запрос дальше; ответ JSON сравнивает с меткой клиента и при совпадении отвечает 304."""
        wanted = None
        if scope["type"] == "http" and scope["method"] == "GET" and not scope["path"].startswith(STATIC_PREFIXES):
            wanted = next((value for name, value in scope["headers"] if name == b"if-none-match"), None)
        if wanted is None:
            await self.app(scope, receive, send)
            return
        start: Message | None = None
        chunks: list[bytes] = []
        size = 0
        passing = False

        async def relay(message: Message) -> None:
            """Копит ответ JSON до конца, остальные ответы передаёт сразу."""
            nonlocal start, size, passing
            if passing:
                await send(message)
                return
            if message["type"] == "http.response.start":
                headers = dict(message.get("headers") or [])
                kind = headers.get(b"content-type", b"")
                if message["status"] != 200 or not kind.startswith(b"application/json") or b"etag" in headers:
                    passing = True
                    await send(message)
                    return
                start = message
                return
            if message["type"] != "http.response.body" or start is None:
                await send(message)
                return
            chunk = message.get("body", b"")
            chunks.append(chunk)
            size += len(chunk)
            if size > MAX_BODY:
                passing = True
                await send(start)
                await send({"type": "http.response.body", "body": b"".join(chunks), "more_body": message.get("more_body", False)})
                return
            if message.get("more_body"):
                return
            body = b"".join(chunks)
            tag = b'"' + hashlib.sha1(body).hexdigest()[:20].encode() + b'"'
            kept = [(name, value) for name, value in start.get("headers") or [] if name != b"content-length"]
            if tag == wanted:
                gone = [(name, value) for name, value in kept if name != b"content-type"]
                await send({"type": "http.response.start", "status": 304, "headers": [*gone, (b"etag", tag)]})
                await send({"type": "http.response.body", "body": b""})
                return
            sent = [*kept, (b"content-length", str(len(body)).encode()), (b"etag", tag)]
            await send({"type": "http.response.start", "status": 200, "headers": sent})
            await send({"type": "http.response.body", "body": body})

        await self.app(scope, receive, relay)
