"""Проверки описания API: схема OpenAPI, страница /docs без внешних адресов, файл схемы в репозитории."""
import json
import re

import pytest
from fastapi.testclient import TestClient

from server import apidocs, auth, db
from server import seed as seeding
from server.app import create_app
from server.inspections import service

PASSWORD = "demo12345"
EXTERNAL = re.compile(r"https?://", re.IGNORECASE)


class FakeDetector:
    """Подменный детектор: рамок на кадре нет."""

    def detect(self, frame):
        """Возвращает пустой список рамок."""
        return []


@pytest.fixture(scope="module")
def client(tmp_path_factory):
    """Сервер на временной базе с подменным детектором."""
    path = tmp_path_factory.mktemp("apidocs") / "kst.db"
    with pytest.MonkeyPatch.context() as patch:
        patch.setenv("KST_DB", str(path))
        patch.setenv("KST_SECRET", "d" * 48)
        patch.setattr(auth, "SCRYPT_N", 2**10)
        seeding._demo_hash.cache_clear()
        with TestClient(create_app(FakeDetector())) as test_client:
            yield test_client
        service._live.clear()
        seeding._demo_hash.cache_clear()
        db.engine.dispose()


def bearer(client, who="engineer"):
    """Заголовок авторизации демонстрационного сотрудника."""
    response = client.post("/auth/login", json={"email": f"{who}@kst.demo", "password": PASSWORD})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['access_token']}"}


def test_schema_is_published_in_russian(client):
    """Схема открыта по /openapi.json: русские разделы и названия операций, вход по токену Bearer."""
    response = client.get("/openapi.json")
    assert response.status_code == 200
    schema = response.json()
    assert schema["info"]["title"] == apidocs.API_TITLE and "Authorize" in schema["info"]["description"]
    tags = {tag["name"]: tag["description"] for tag in schema["tags"]}
    assert "Осмотры, находки и звук" in tags and "/ws/inspect/{inspection_id}" in tags["Распознавание в реальном времени (WebSocket)"]
    assert schema["components"]["securitySchemes"]["bearerAuth"] == {
        "type": "http", "scheme": "bearer", "bearerFormat": "JWT", "description": "Токен доступа из ответа POST /auth/login"}
    assert schema["components"]["securitySchemes"]["appKey"]["name"] == "X-KST-App"
    operations = [(path, method, operation) for path, item in schema["paths"].items() for method, operation in item.items()]
    assert len(operations) > 70
    for path, method, operation in operations:
        assert operation["tags"][0] in tags, path
        assert re.search("[А-Яа-яЁё]", operation["summary"]), (path, operation["summary"])
        assert len(operation["summary"]) <= apidocs.SUMMARY_LIMIT + 1, path
        assert ("security" in operation) == (path not in apidocs.OPEN_PATHS), path
    assert schema["paths"]["/auth/login"]["post"]["summary"].startswith("Вход")
    login = schema["paths"]["/auth/login"]["post"]["responses"]["200"]["content"]["application/json"]["schema"]
    assert login == {"$ref": "#/components/schemas/Tokens"}
    listing = schema["paths"]["/inspections/findings"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    assert listing == {"type": "array", "items": {"$ref": "#/components/schemas/FindingView"}}
    assert "application/pdf" in schema["paths"]["/inspections/{inspection_id}/report.pdf"]["get"]["responses"]["200"]["content"]
    assert "/web" not in schema["paths"] and "/docs" not in schema["paths"]


def test_every_documented_response_matches_a_route(client):
    """Каждая схема ответа привязана к существующему маршруту."""
    paths = client.get("/openapi.json").json()["paths"]
    for method, path in [*apidocs.RESPONSES, *apidocs.FILES]:
        assert method in paths.get(path, {}), (method, path)


def test_docs_page_works_offline(client):
    """Страница /docs ссылается только на локальные файлы; они отдаются, лицензия Apache-2.0 лежит рядом."""
    page = client.get("/docs")
    assert page.status_code == 200 and "swagger-ui" in page.text
    assert not EXTERNAL.search(page.text), EXTERNAL.findall(page.text)
    links = re.findall(r'(?:href|src)="([^"]+)"', page.text)
    assert links and all(link.startswith("/") for link in links), links
    for link in links:
        assert client.get(link).status_code == 200, link
    assert "url: '/openapi.json'" in page.text and '"validatorUrl": null' in page.text
    script = client.get("/docs-assets/swagger-ui-bundle.js")
    assert script.status_code == 200 and len(script.content) > 500_000
    licence = client.get("/docs-assets/LICENSE")
    assert licence.status_code == 200 and "Apache License" in licence.text and "Version 2.0" in licence.text
    assert (apidocs.STATIC_DIR / "NOTICE").is_file()
    assert client.get("/redoc").status_code == 404


def test_tracked_schema_file_matches_the_app(client):
    """Файл server/openapi.json совпадает со схемой приложения: после изменения маршрутов его надо обновить
    командой python -m server.apidocs."""
    assert apidocs.SCHEMA_FILE.is_file()
    tracked = apidocs.SCHEMA_FILE.read_text(encoding="utf-8")
    assert json.loads(tracked) == client.get("/openapi.json").json()
    assert tracked == apidocs.schema_text(client.app.openapi())


def test_documented_models_validate_real_responses(client):
    """Схемы ответов описывают настоящие ответы сервера: вход, площадка, оборудование, правила, осмотр, замечание."""
    login = client.post("/auth/login", json={"email": "engineer@kst.demo", "password": PASSWORD}).json()
    apidocs.Tokens.model_validate(login)
    engineer, master = bearer(client), bearer(client, "master")
    apidocs.UserView.model_validate(client.get("/auth/me", headers=engineer).json())
    apidocs.Health.model_validate(client.get("/health").json())
    apidocs.Site.model_validate(client.get("/site", headers=engineer).json())
    units = client.get("/equipment", headers=engineer).json()
    assert units and [apidocs.EquipmentBrief.model_validate(unit) for unit in units]
    apidocs.EquipmentCard.model_validate(client.get("/equipment/N-101", headers=engineer).json())
    apidocs.Telemetry.model_validate(client.get("/equipment/AMS-1/telemetry", headers=engineer).json())
    apidocs.Diagnosis.model_validate(client.get("/equipment/AMS-1/diagnosis", headers=engineer).json())
    apidocs.Resource.model_validate(client.get("/equipment/AMS-1/resource", headers=engineer).json())
    rules = client.get("/rules", headers=engineer).json()
    assert rules and [apidocs.RuleItem.model_validate(rule) for rule in rules]
    apidocs.RuleEvaluation.model_validate(client.get("/equipment/AMS-1/rules/R01", headers=engineer).json())
    started = client.post("/inspections", json={"equipment_id": "AMS-1", "identified_by": "manual"}, headers=engineer)
    inspection = apidocs.InspectionView.model_validate(started.json())
    created = client.post(f"/inspections/{inspection.id}/findings", headers=engineer,
                          data={"kind": "defect", "sign": "leak", "node": "seal"})
    finding = apidocs.FindingView.model_validate(created.json())
    rejected = client.post(f"/inspections/findings/{finding.id}/state", headers=master,
                           json={"state": "rejected", "comment": "проверка схемы"})
    assert apidocs.FindingView.model_validate(rejected.json()).rejected is True
    apidocs.InspectionView.model_validate(client.post(f"/inspections/{inspection.id}/finish", headers=engineer).json())
    listed = client.get("/inspections", headers=engineer).json()
    assert listed and [apidocs.InspectionBrief.model_validate(item) for item in listed]
    board = client.get("/inspections/findings?include_rejected=true", headers=master).json()
    assert board and [apidocs.FindingView.model_validate(item) for item in board]
    log = client.get("/admin/security-log?limit=5", headers=bearer(client, "security")).json()
    assert log and [apidocs.SecurityEventView.model_validate(row) for row in log]
    admin = bearer(client, "admin")
    apidocs.Metrics.model_validate(client.get("/webadmin/metrics", headers=admin).json())
    events = client.get("/webadmin/events?limit=5", headers=admin).json()
    assert events and [apidocs.ServerEvent.model_validate(row) for row in events]


def test_conditional_get_saves_repeated_downloads(client):
    """Повторный GET с меткой содержимого получает 304 без тела; без заголовка If-None-Match ответ прежний."""
    engineer = bearer(client)
    plain = client.get("/equipment", headers=engineer)
    assert plain.status_code == 200 and "etag" not in plain.headers
    first = client.get("/equipment", headers={**engineer, "If-None-Match": '"-"'})
    assert first.status_code == 200 and first.json() == plain.json()
    again = client.get("/equipment", headers={**engineer, "If-None-Match": first.headers["etag"]})
    assert again.status_code == 304 and again.content == b"" and again.headers["etag"] == first.headers["etag"]
    assert client.get("/equipment/NOPE", headers={**engineer, "If-None-Match": '"-"'}).status_code == 404
