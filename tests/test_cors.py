"""Проверки CORS: браузерная страница с этой же машины (презентация, открытая из файла или с localhost) может
войти и прочитать ответ сервера, а страницы с других адресов - нет; список источников задаётся KST_CORS_ORIGINS.

Проверяются предварительный запрос OPTIONS и заголовки обычного ответа; база и модели для этого не нужны.
"""
import pytest
from fastapi.testclient import TestClient

from server import config
from server.app import create_app

ALLOW = "access-control-allow-origin"


class NoDetector:
    """Подменный детектор: для проверок CORS кадры не нужны."""

    def detect(self, frame):
        """Рамок нет."""
        return []


def preflight(client: TestClient, origin: str):
    """Предварительный запрос браузера перед входом с заголовком Content-Type: application/json."""
    return client.options("/auth/login", headers={"Origin": origin, "Access-Control-Request-Method": "POST",
                                                  "Access-Control-Request-Headers": "content-type"})


def make_client(monkeypatch, value: str | None) -> TestClient:
    """Приложение с заданным значением KST_CORS_ORIGINS; None - переменная не задана."""
    if value is None:
        monkeypatch.delenv("KST_CORS_ORIGINS", raising=False)
    else:
        monkeypatch.setenv("KST_CORS_ORIGINS", value)
    return TestClient(create_app(NoDetector()))


@pytest.mark.parametrize("origin", ["http://localhost:5173", "http://127.0.0.1:8080", "http://localhost", "null"])
def test_default_allows_local_pages(monkeypatch, origin):
    """По умолчанию разрешены localhost и 127.0.0.1 с любым портом и страница, открытая из файла."""
    client = make_client(monkeypatch, None)
    answer = preflight(client, origin)
    assert answer.status_code == 200
    assert answer.headers[ALLOW] == origin
    assert "access-control-allow-credentials" not in answer.headers
    simple = client.get("/no-such-page", headers={"Origin": origin})
    assert simple.headers[ALLOW] == origin


@pytest.mark.parametrize("origin", ["https://evil.example", "http://localhost.evil.example", "http://192.168.1.10:8765",
                                    "https://localhost:5173", "http://127.0.0.1.evil.example:80", "nullx"])
def test_default_rejects_other_pages(monkeypatch, origin):
    """Чужие сайты, адреса локальной сети и похожие на localhost имена не получают разрешения."""
    client = make_client(monkeypatch, None)
    assert preflight(client, origin).status_code == 400
    assert ALLOW not in client.get("/no-such-page", headers={"Origin": origin}).headers


def test_env_replaces_default_list(monkeypatch):
    """KST_CORS_ORIGINS заменяет список по умолчанию; звёздочка означает любой порт."""
    client = make_client(monkeypatch, "http://10.0.0.5:*, https://panel.example/")
    assert preflight(client, "http://10.0.0.5:3000").headers[ALLOW] == "http://10.0.0.5:3000"
    assert preflight(client, "https://panel.example").headers[ALLOW] == "https://panel.example"
    for origin in ("http://localhost:3000", "null", "http://10.0.0.5:3000/evil", "http://10.0.0.50:3000"):
        assert preflight(client, origin).status_code == 400


@pytest.mark.parametrize("value", ["", "off", " , "])
def test_env_can_disable_cors(monkeypatch, value):
    """Пустое значение или off выключают CORS: заголовков разрешения нет ни для кого."""
    client = make_client(monkeypatch, value)
    assert config.cors_origin_regex() is None
    assert ALLOW not in client.get("/no-such-page", headers={"Origin": "http://localhost:5173"}).headers
