"""Проверки веб-панели и пульта на Next.js (папка web/): исходники без внешних адресов и строчных комментариев,
копии модулей панели совпадают с прежней панелью, сервер отдаёт статическую сборку по /web/, /panel/ и /_next/ с
правилами хранения в браузере, прежние файлы остаются по /web-classic/ и /panel-classic/.

Проверки собранных файлов пропускаются, если сборки web/out нет (тесты без Node).
"""
import json
import re
import shutil
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from server import auth, db, webcache
from server.app import create_app
from server.inspections import service
from tests.test_webadmin import SECRET, FakeDetector, forget_caches, seeded_database  # noqa: F401

ROOT = Path(__file__).resolve().parents[1]
WEB = ROOT / "web"
OUT = WEB / "out"
SOURCES = ("app", "components", "types", "src")
EXTERNAL = re.compile(r"(?:https?:)?//[a-z0-9.-]+\.[a-z]{2,}/[^\s\"'`)]*", re.IGNORECASE)
KNOWN_TEXT_URLS = ("http://www.w3.org/", "https://react.dev/errors/", "https://nextjs.org/docs/", "https://github.com/zloirock/core-js")
built = pytest.mark.skipif(not (OUT / "web" / "index.html").is_file(), reason="нет сборки web/out (npm run build)")


def source_files():
    """Исходники приложения Next.js без шрифтов и картинок."""
    for folder in SOURCES:
        for path in (WEB / folder).rglob("*"):
            if path.is_file() and path.suffix in (".ts", ".tsx", ".js", ".css"):
                yield path
    yield WEB / "next.config.ts"


def test_package_pinned_and_static_export():
    """Версии зависимостей закреплены точно, сборка статическая с косой чертой в конце адресов."""
    package = json.loads((WEB / "package.json").read_text(encoding="utf-8"))
    for group in ("dependencies", "devDependencies"):
        for name, version in package[group].items():
            assert re.fullmatch(r"\d+\.\d+\.\d+", version), (name, version)
    assert {"next", "react", "react-dom"} <= set(package["dependencies"])
    assert (WEB / "package-lock.json").is_file()
    config = (WEB / "next.config.ts").read_text(encoding="utf-8")
    assert 'output: "export"' in config and "trailingSlash: true" in config


def test_sources_offline_and_commented_in_russian():
    """В исходниках нет внешних адресов, строчных комментариев и файлов Markdown."""
    for path in source_files():
        text = path.read_text(encoding="utf-8").replace("http://www.w3.org/2000/svg", "")
        assert not EXTERNAL.search(text), (path, EXTERNAL.search(text))
        if path.suffix in (".ts", ".tsx"):
            plain = re.sub(r"/\*\*.*?\*/", "", text, flags=re.DOTALL)
            plain = re.sub(r"`(?:\\.|[^`\\])*`|\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'", "\"\"", plain)
            assert not re.search(r"(?<![:\\])//|/\*(?!\*)", plain), path
    skip = ("node_modules", ".next", "out")
    assert not [p for p in WEB.rglob("*.md") if not set(p.relative_to(WEB).parts) & set(skip)]


def test_panel_modules_match_classic():
    """Модули и стили панели в web/src совпадают с прежней панелью; у пульта отличается только запуск."""
    for name in (ROOT / "server" / "webadmin" / "js").iterdir():
        assert (WEB / "src" / "admin" / "js" / name.name).read_bytes() == name.read_bytes(), name.name
    for name in (ROOT / "server" / "webadmin" / "css").iterdir():
        assert (WEB / "src" / "admin" / "css" / name.name).read_bytes() == name.read_bytes(), name.name
    assert (WEB / "src" / "panel" / "panel.css").read_bytes() == (ROOT / "server" / "panel" / "panel.css").read_bytes()
    classic = (ROOT / "server" / "panel" / "panel.js").read_text(encoding="utf-8").rstrip()
    copy = (WEB / "src" / "panel" / "panel.js").read_text(encoding="utf-8").rstrip()
    start = 'document.addEventListener("DOMContentLoaded", main);'
    assert classic.endswith(start) and copy.startswith(classic[: -len(start)])
    assert copy.endswith('if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", main);\nelse main();')


def test_export_dir_needs_build(tmp_path, monkeypatch):
    """Без собранных файлов или с KST_WEB_UI=classic сервер остаётся на прежней панели."""
    monkeypatch.setenv("KST_WEB_UI", "next")
    monkeypatch.setenv("KST_WEB_EXPORT", str(tmp_path))
    assert webcache.export_dir() is None
    for part in ("web/index.html", "panel/index.html"):
        (tmp_path / part).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / part).write_text("<html></html>", encoding="utf-8")
    (tmp_path / "_next" / "static").mkdir(parents=True)
    assert webcache.export_dir() == tmp_path
    monkeypatch.setenv("KST_WEB_UI", "classic")
    assert webcache.export_dir() is None


def make_client(seeded, tmp_path, monkeypatch, ui):
    """Полный сервер на копии базы с выбранным интерфейсом."""
    shutil.copyfile(seeded, tmp_path / "kst.db")
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    monkeypatch.setenv("KST_SECRET", SECRET)
    monkeypatch.setenv("KST_WEB_UI", ui)
    monkeypatch.setenv("KST_WEB_EXPORT", str(OUT))
    monkeypatch.delenv("KST_LLM_URL", raising=False)
    monkeypatch.setattr(auth, "SCRYPT_N", 2**10)
    forget_caches()
    return TestClient(create_app(FakeDetector()))


@pytest.fixture
def next_client(seeded_database, tmp_path, monkeypatch):  # noqa: F811
    """Сервер, отдающий сборку Next.js."""
    with make_client(seeded_database, tmp_path, monkeypatch, "next") as client:
        yield client
    service._live.clear()
    db.engine.dispose()
    forget_caches()


@pytest.fixture
def classic_client(seeded_database, tmp_path, monkeypatch):  # noqa: F811
    """Сервер с прежней панелью по /web/."""
    with make_client(seeded_database, tmp_path, monkeypatch, "classic") as client:
        yield client
    service._live.clear()
    db.engine.dispose()
    forget_caches()


def links(text):
    """Адреса файлов, на которые ссылается страница."""
    return re.findall(r'(?:href|src)="([^"]+)"', text)


@built
def test_export_served_with_cache_rules(next_client):
    """Страницы перепроверяются, файлы /_next/static/ хранятся год, картинки - месяц, всё без внешних адресов."""
    for page_url, marker in (("/web/", 'id="app"'), ("/panel/", 'id="strip"')):
        page = next_client.get(page_url)
        assert page.status_code == 200 and page.headers["cache-control"] == "no-cache", page_url
        assert marker in page.text and "/_next/static/" in page.text, page_url
        assert "http://" not in page.text and "https://" not in page.text, page_url
        own = [link for link in links(page.text) if link.startswith("/_next/")]
        assert own, page_url
        for link in own:
            response = next_client.get(link)
            assert response.status_code == 200 and response.headers["cache-control"] == webcache.YEAR, link
            for url in EXTERNAL.findall(response.text):
                assert url.startswith(KNOWN_TEXT_URLS), (link, url)
    assert next_client.get("/web/assets/hero.jpg").headers["cache-control"] == webcache.MONTH
    assert next_client.get("/web", follow_redirects=False).status_code in (302, 307)
    assert next_client.get("/panel", follow_redirects=False).headers["location"] == "/panel/"


@built
def test_export_fonts_are_local(next_client):
    """Шрифты Geologica приходят из сборки, а не из интернета."""
    page = next_client.get("/web/").text
    css = [link for link in links(page) if link.endswith(".css")]
    text = "".join(next_client.get(link).text for link in css)
    fonts = re.findall(r"url\(\"?([^\")]+\.woff2)\"?\)", text)
    assert fonts and all(not re.match(r"[a-z]+:", url) for url in fonts)
    target = "/_next/static/" + fonts[0].split("../", 1)[-1] if fonts[0].startswith("../") else fonts[0]
    font = next_client.get(target)
    assert font.status_code == 200 and font.headers["cache-control"] == webcache.YEAR


@built
def test_classic_kept_next_to_export(next_client):
    """Прежние панель и пульт остаются по /web-classic/ и /panel-classic/."""
    page = next_client.get("/web-classic/")
    assert page.status_code == 200 and "js/app.js?v=" in page.text
    assert next_client.get("/panel-classic/").status_code == 200
    assert next_client.get("/panel-classic/panel.js").status_code == 200
    assert next_client.get("/webadmin/metrics").status_code == 401


def test_classic_switch(classic_client):
    """KST_WEB_UI=classic возвращает прежнюю панель на /web/ и /panel/."""
    assert "js/app.js?v=" in classic_client.get("/web/").text
    assert classic_client.get("/panel/panel.js").status_code == 200
    assert classic_client.get("/_next/static/x.js").status_code == 404
