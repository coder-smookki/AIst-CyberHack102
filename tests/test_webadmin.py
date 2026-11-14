"""Проверки веб-панели администратора: раздача страниц по адресу /web/, оформление файлов без внешних адресов
и строчных комментариев, маршруты /webadmin (метрики, модели, замер, журнал, резервные копии, блокировка с
причиной) и права доступа к ним.

Сервер собирается целиком на копии базы, детектор подменён, стоимость хэша пароля снижена.
"""
import re
import shutil
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from server import auth, db
from server import seed as seeding
from server.app import create_app
from server.inspections import service

WEB = Path(__file__).resolve().parents[1] / "server" / "webadmin"
OWN_JS = ("app.js", "boot.js", "pages_common.js", "pages_sec.js", "pages_admin.js", "start.js")
EXTERNAL = re.compile(r"(?:https?:)?//[a-z0-9.-]+\.[a-z]{2,}/", re.IGNORECASE)
SECRET = "w" * 48
PASSWORD = "demo12345"


class FakeDetector:
    """Подменный детектор: рамок нет, две модели считаются загруженными."""

    defect_classes = ("leak",)

    def detect(self, frame):
        """Возвращает пустой список рамок."""
        return []

    def info(self):
        """Состояние моделей как у настоящего детектора."""
        return {"ready": True, "loaded": True, "models": ["detector.onnx", "defects.onnx"], "missing": [], "note": None}


def forget_caches():
    """Сбрасывает запомненные хэши демонстрационных паролей и счётчик неудачных входов."""
    seeding._demo_hash.cache_clear()
    auth._decoy_hash.cache_clear()
    auth._failures.clear()


@pytest.fixture(scope="module")
def seeded_database(tmp_path_factory):
    """Один раз создаёт базу с начальными данными; каждая проверка работает со своей копией."""
    path = tmp_path_factory.mktemp("webadmin") / "kst.db"
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("KST_DB", str(path))
        patch.setattr(auth, "SCRYPT_N", 2**10)
        forget_caches()
        db.init_db()
        with db.SessionLocal() as session:
            seeding.seed(session)
        db.engine.dispose()
        forget_caches()
    return path


@pytest.fixture
def client(seeded_database, tmp_path, monkeypatch):
    """Полный сервер на отдельной копии базы."""
    shutil.copyfile(seeded_database, tmp_path / "kst.db")
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    monkeypatch.setenv("KST_SECRET", SECRET)
    monkeypatch.delenv("KST_LLM_URL", raising=False)
    monkeypatch.setattr(auth, "SCRYPT_N", 2**10)
    forget_caches()
    with TestClient(create_app(FakeDetector())) as test_client:
        yield test_client
    service._live.clear()
    db.engine.dispose()
    forget_caches()


def headers(client, email):
    """Заголовок авторизации сотрудника после входа по паролю."""
    response = client.post("/auth/login", json={"email": email, "password": PASSWORD})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


def test_static_files_and_style():
    """Страница, стили, сценарии, шрифты и картинки на месте; нет внешних адресов и строчных комментариев."""
    for name in ("index.html", "css/app.css", "css/web.css", "css/panel.css", "js/core.js", "js/web.js", *[f"js/{n}" for n in OWN_JS]):
        path = WEB / name
        assert path.is_file() and path.stat().st_size > 100, name
        text = path.read_text(encoding="utf-8").replace("http://www.w3.org/2000/svg", "")
        assert not EXTERNAL.search(text), name
        if name.endswith(".js"):
            plain = re.sub(r"/\*\*.*?\*/", "", text, flags=re.DOTALL)
            plain = re.sub(r"\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'", "\"\"", plain)
            assert not re.search(r"(?<![:\\])//", plain), name
    assert {path.name for path in (WEB / "assets" / "fonts").iterdir()} >= {"Geologica-Regular.ttf", "Geologica-SemiBold.ttf"}
    assert (WEB / "assets" / "hero.jpg").is_file()


def test_panel_is_served(client):
    """Панель открывается по /web/, старый пульт /panel/ продолжает работать."""
    page = client.get("/web/")
    assert page.status_code == 200 and "КСТ Визор" in page.text and "js/app.js" in page.text
    assert client.get("/web", follow_redirects=False).status_code in (307, 302)
    assert client.get("/web/css/web.css").status_code == 200
    assert client.get("/panel/").status_code == 200


def test_admin_metrics_models_events(client):
    """Администратор системы видит метрики, описание моделей, замер кадра и журнал событий сервера."""
    admin = headers(client, "admin@kst.demo")
    metrics = client.get("/webadmin/metrics", headers=admin).json()
    assert metrics["cpu"]["cores"] >= 1 and metrics["database"]["size_bytes"] > 0 and metrics["uptime_s"] >= 0
    models = client.get("/webadmin/models", headers=admin).json()
    assert models["detector"]["loaded"] is True
    files = {item["file"]: item for item in models["models"]}
    assert "detector.onnx" in files and files["detector.onnx"]["loaded"] is True
    assert "weights_licence" in files["detector.onnx"] and "classes" in files["detector.onnx"]
    bench = client.post("/webadmin/models/benchmark", headers=admin)
    assert bench.status_code == 200 and bench.json()["boxes"] == 0 and bench.json()["w"] == 640
    events = client.get("/webadmin/events", headers=admin, params={"limit": 50}).json()
    assert events[0]["kind"] in {"server", "inspection", "finding", "sound"}
    assert any(item["kind"] == "server" for item in events)
    assert [item["at"] for item in events] == sorted((item["at"] for item in events), reverse=True)


def test_backups(client, tmp_path):
    """Резервная копия создаётся рядом с базой в папке backups и появляется в списке."""
    admin = headers(client, "admin@kst.demo")
    assert client.get("/webadmin/backups", headers=admin).json()["backups"] == []
    made = client.post("/webadmin/backups", headers=admin)
    assert made.status_code == 201
    file = tmp_path / "backups" / made.json()["file"]
    assert file.is_file() and file.stat().st_size > 0
    listed = client.get("/webadmin/backups", headers=admin).json()["backups"]
    assert [item["file"] for item in listed] == [made.json()["file"]]


def test_permissions(client):
    """Без нужного права маршруты /webadmin отвечают 403, без входа - 401."""
    assert client.get("/webadmin/metrics").status_code == 401
    security = headers(client, "security@kst.demo")
    engineer = headers(client, "engineer@kst.demo")
    for path in ("/webadmin/metrics", "/webadmin/models", "/webadmin/events", "/webadmin/backups"):
        assert client.get(path, headers=security).status_code == 403, path
        assert client.get(path, headers=engineer).status_code == 403, path
    assert client.post("/webadmin/backups", headers=engineer).status_code == 403
    admin = headers(client, "admin@kst.demo")
    assert client.post("/webadmin/users/1/block", headers=admin, json={"reason": "Увольнение"}).status_code == 403


def test_block_with_reason(client):
    """Блокировка с причиной закрывает сеансы, причина видна в журнале и в сведениях о блокировке."""
    security = headers(client, "security@kst.demo")
    users = {item["email"]: item for item in client.get("/admin/users", headers=security).json()}
    operator = users["operator@kst.demo"]
    headers(client, "operator@kst.demo")
    blocked = client.post(f"/webadmin/users/{operator['id']}/block", headers=security,
                          json={"reason": "Утеря устройства", "comment": "Планшет KV-T07"})
    assert blocked.status_code == 200 and blocked.json()["is_active"] is False and blocked.json()["active_sessions"] == 0
    info = client.get(f"/webadmin/users/{operator['id']}/block", headers=security).json()
    assert info["reason"] == "Утеря устройства" and info["comment"] == "Планшет KV-T07" and info["actor"]
    log = client.get("/admin/security-log", headers=security, params={"event": "user_blocked"}).json()
    assert log[0]["details"]["reason"] == "Утеря устройства"
    login = client.post("/auth/login", json={"email": "operator@kst.demo", "password": PASSWORD})
    assert login.status_code == 403
    me = users["security@kst.demo"]
    assert client.post(f"/webadmin/users/{me['id']}/block", headers=security, json={"reason": "x"}).status_code == 409
    assert client.post(f"/webadmin/users/{operator['id']}/block", headers=security, json={"reason": ""}).status_code == 422
    assert client.get("/webadmin/users/9999/block", headers=security).json()["reason"] is None


def local_links(text):
    """Адреса файлов, на которые ссылается страница: атрибуты href и src."""
    return re.findall(r'(?:href|src)="([^"]+)"', text)


def test_served_pages_work_offline(client):
    """Отдаваемые страницы /web/, /panel/ и /docs и все их файлы не ссылаются на внешние адреса."""
    for page_url in ("/web/", "/panel/", "/docs"):
        page = client.get(page_url)
        assert page.status_code == 200, page_url
        assert not EXTERNAL.search(page.text) and "https://" not in page.text and "http://" not in page.text, page_url
        links = local_links(page.text)
        assert links, page_url
        for link in links:
            assert not link.startswith(("http:", "https:", "//")), (page_url, link)
            if link.startswith("data:"):
                continue
            target = link if link.startswith("/") else page_url.rsplit("/", 1)[0] + "/" + link
            response = client.get(target)
            assert response.status_code == 200, (page_url, target)
            if target.split("?")[0].endswith((".css", ".js", ".html")) and not target.startswith("/docs-assets/"):
                text = response.text.replace("http://www.w3.org/2000/svg", "")
                assert not EXTERNAL.search(text), target
                for url in re.findall(r"url\(\"?([^\")]+)\"?\)", text):
                    assert url.startswith(("data:", "../", "#")) or not re.match(r"[a-z]+:", url), (target, url)


def test_panel_cache_rules(client):
    """Стили и сценарии с меткой версии хранятся год, страница перепроверяется, шрифты WOFF2 хранятся месяц."""
    page = client.get("/web/")
    assert page.headers["cache-control"] == "no-cache"
    versioned = re.findall(r'(?:href|src)="((?:css|js)/[^"]+\?v=[0-9a-f]+)"', page.text)
    assert len(versioned) >= 10 and all("defer" in tag for tag in re.findall(r"<script[^>]*>", page.text))
    for link in versioned:
        response = client.get("/web/" + link)
        assert response.status_code == 200 and "immutable" in response.headers["cache-control"], link
    font = client.get("/web/assets/fonts/Geologica-Regular.woff2")
    assert font.status_code == 200 and font.headers["cache-control"] == "public, max-age=2592000"
    assert "Geologica-Regular.woff2" in client.get("/web/" + next(v for v in versioned if "app.css" in v)).text


def test_polling_gets_not_modified(client):
    """Повторный опрос панели с меткой содержимого получает 304 без тела."""
    admin = headers(client, "admin@kst.demo")
    first = client.get("/webadmin/events?limit=5", headers={**admin, "If-None-Match": '"0"'})
    assert first.status_code == 200 and first.headers["etag"]
    again = client.get("/webadmin/events?limit=5", headers={**admin, "If-None-Match": first.headers["etag"]})
    assert again.status_code == 304 and again.content == b""
