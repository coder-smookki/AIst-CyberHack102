"""Статические проверки пульта демонстрации server/panel: файлы, отсутствие внешних адресов, русский текст,
оформление кода и соответствие адресов API маршрутам сервера."""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

PANEL = Path(__file__).resolve().parents[1] / "server" / "panel"
TEXT_FILES = ("index.html", "panel.css", "panel.js")
ALLOWED_FONTS = {"Geologica-Regular.ttf", "Geologica-Medium.ttf", "Geologica-SemiBold.ttf"}
EXTERNAL = re.compile(r"(?:https?:)?//[a-z0-9.-]+\.[a-z]{2,}", re.IGNORECASE)
CYRILLIC = re.compile(r"[А-Яа-яЁё]")


def read(name: str) -> str:
    """Читает файл пульта как текст UTF-8."""
    return (PANEL / name).read_text(encoding="utf-8")


def js_without_strings() -> str:
    """Текст panel.js без строковых литералов и блоков JSDoc - для поиска строчных комментариев."""
    text = re.sub(r"/\*\*.*?\*/", "", read("panel.js"), flags=re.DOTALL)
    return re.sub(r"`(?:\\.|[^`\\])*`|\"(?:\\.|[^\"\\\n])*\"|'(?:\\.|[^'\\\n])*'", "\"\"", text)


def test_files_exist():
    """Страница, стили, сценарий и шрифты лежат в папке пульта и не пусты."""
    for name in TEXT_FILES:
        assert (PANEL / name).is_file(), name
        assert (PANEL / name).stat().st_size > 500, name
    fonts = {path.name for path in (PANEL / "fonts").iterdir()}
    assert fonts == ALLOWED_FONTS


def test_no_external_urls():
    """Ни в разметке, ни в стилях, ни в сценарии нет внешних адресов и подключений с CDN."""
    for name in TEXT_FILES:
        text = read(name)
        assert not EXTERNAL.search(text), f"{name}: {EXTERNAL.search(text).group(0)}"
        assert "@import" not in text
    html = read("index.html")
    for target in re.findall(r"(?:src|href)=\"([^\"]+)\"", html):
        assert target.startswith("data:") or not re.match(r"[a-z]+:|/", target), target


def test_relative_assets_resolve():
    """Подключённые файлы и шрифты из @font-face существуют рядом со страницей."""
    html = read("index.html")
    assert 'href="panel.css"' in html and 'src="panel.js"' in html
    for target in re.findall(r"url\(\"([^\"]+)\"\)", read("panel.css")):
        assert (PANEL / target).is_file(), target


def test_russian_interface():
    """Интерфейс на русском: язык страницы, заголовки разделов и сообщения об ошибках."""
    html = read("index.html")
    assert '<html lang="ru">' in html
    for phrase in ("Пульт демонстрации", "Сценарии и время", "Показания датчиков", "Текущий диагноз",
                   "История осмотров и работ", "Замечания", "Открыто", "В работе", "Устранено",
                   "Решение принимает инженер"):
        assert phrase in html, phrase
    script = read("panel.js")
    for phrase in ("Нет связи с сервером", "Действие не выполнено", "Недостаточно данных для оценки",
                   "Это не является подтверждением исправности"):
        assert phrase in script, phrase
    assert len(CYRILLIC.findall(script)) > 2000


def test_no_long_dashes():
    """В текстах пульта используется обычный дефис, длинных тире нет."""
    for name in TEXT_FILES:
        assert "—" not in read(name) and "–" not in read(name), name


def test_brand_style():
    """Фирменные цвета и скругление карточек 20 px заданы в стилях, шрифт Geologica подключён."""
    css = read("panel.css")
    for token in ("#135AA6", "#313132", "#F4F5F8", "20px", "Geologica"):
        assert token in css, token


def test_js_comments_are_russian_docblocks():
    """В сценарии нет строчных комментариев, а у каждой функции и класса есть блок JSDoc на русском."""
    script = read("panel.js")
    assert not re.search(r"(^|[^:\\])//", js_without_strings(), re.MULTILINE)
    lines = script.splitlines()
    for index, line in enumerate(lines):
        if re.match(r"^(async\s+)?function\s+\w+|^class\s+\w+|^\s+constructor\(", line):
            above = lines[index - 1].strip()
            assert above.endswith("*/"), f"нет описания у строки {index + 1}: {line.strip()}"
    for block in re.findall(r"/\*\*(.*?)\*/", script, flags=re.DOTALL):
        assert CYRILLIC.search(block), block


def test_css_comments_are_russian():
    """Комментарии в стилях только на русском."""
    for block in re.findall(r"/\*(.*?)\*/", read("panel.css"), flags=re.DOTALL):
        assert CYRILLIC.search(block), block


def test_element_ids_exist():
    """Каждый элемент, который ищет сценарий, есть в разметке."""
    html_ids = set(re.findall(r"\bid=\"([^\"]+)\"", read("index.html")))
    script = read("panel.js")
    wanted = set(re.findall(r"\w+:\s*\"([a-z][a-z0-9-]*)\"", script.split("const ids = {", 1)[1].split("};", 1)[0]))
    wanted |= {f"err-{name}" for name in re.findall(r"load\(\"([a-z]+)\"", script)}
    wanted |= {f"count-{column}" for column in ("open", "in_work", "resolved")}
    wanted |= {f"board-{column}" for column in ("open", "in_work", "resolved")}
    assert wanted - html_ids == set()


def api_paths() -> set[str]:
    """Шаблоны адресов API, к которым обращается пульт, с параметрами вида {x}."""
    script = read("panel.js")
    found = set()
    for tail in re.findall(r"unitPath\(\w+(?:,\s*(`[^`]*`|\"[^\"]*\"))?\)", script):
        found.add("/equipment/{x}" + re.sub(r"\$\{[^}]+\}", "{x}", tail.strip("`\"").split("?")[0]))
    for path in re.findall(r"(?:request|send)\(\"[A-Z]+\",\s*[`\"](/[^`\"?]+)", script):
        found.add(re.sub(r"(?<=[a-z])\{x\}$", "", re.sub(r"\$\{[^}]+\}", "{x}", path)))
    return found


def server_routes() -> set[tuple[str, str]]:
    """Маршруты серверных модулей, доступных пульту, в виде шаблонов с параметрами {x}."""
    from server import auth, equipment, telemetry_api
    from server.assistant.router import router as assistant_router
    from server.inspections import router as inspections_router

    routes = set()
    for router in (auth.router, equipment.router, telemetry_api.router, inspections_router, assistant_router):
        for route in router.routes:
            for method in route.methods:
                routes.add((method, re.sub(r"\{[^}]+\}", "{x}", route.path)))
    return routes


def test_api_paths_match_server_routes():
    """Каждый адрес, к которому обращается пульт, есть среди маршрутов сервера."""
    paths = api_paths()
    known = {path for _, path in server_routes()}
    assert {"/equipment/{x}/telemetry", "/equipment/{x}/cursor", "/equipment/{x}/scenarios/{x}",
            "/inspections/findings/{x}/state", "/auth/login"} <= paths
    for path in paths:
        candidates = {path, path.replace("report.{x}", "report.pdf")}
        assert candidates & known, path


def test_control_methods():
    """Пульт переключает сценарий и время методом POST, как определено на сервере."""
    routes = server_routes()
    script = read("panel.js")
    assert ("POST", "/equipment/{x}/scenarios/{x}") in routes and "request(\"POST\", unitPath(unitId, `/scenarios/" in script
    assert ("POST", "/equipment/{x}/cursor") in routes and "request(\"POST\", unitPath(unitId, \"/cursor\"), {json: {at:" in script
    assert "LIVE_PERIOD_MS = 2000" in script


def test_js_syntax():
    """Сценарий разбирается интерпретатором Node без ошибок, если Node установлен."""
    node = shutil.which("node")
    if node is None:
        pytest.skip("Node не установлен")
    result = subprocess.run([node, "--check", str(PANEL / "panel.js")], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
