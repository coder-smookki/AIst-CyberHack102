"""Работа без интернета: полный сценарий осмотра при запрете любых исходящих соединений, кроме localhost.

Сервер поднимается с настоящими моделями из папки models (если они на месте), настоящей телеметрией и
распознаванием текста (если его модели установлены). Любая попытка соединиться с внешним адресом, разрешить
внешнее имя или отправить датаграмму наружу запоминается и проваливает проверку, даже если вызывающий
код проглотил ошибку.
"""

import socket
from importlib import import_module

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

from server import auth, recognition
from server.app import create_app
from server.inspections import service

PASSWORD = "demo12345"
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "ip6-localhost"}


def _local(address) -> bool:
    """Сообщает, что адрес локальный: сокет Unix, localhost или петлевой адрес."""
    if isinstance(address, (str, bytes)):
        return True
    host = address[0] if isinstance(address, tuple) and address else address
    host = host.decode() if isinstance(host, bytes) else str(host)
    return host in LOCAL_HOSTS or host.startswith("127.")


@pytest.fixture
def no_internet(monkeypatch):
    """Запрещает исходящие соединения и разрешение имён, кроме localhost; возвращает список попыток."""
    attempts = []
    connect, connect_ex, sendto = socket.socket.connect, socket.socket.connect_ex, socket.socket.sendto
    getaddrinfo, create_connection = socket.getaddrinfo, socket.create_connection

    def guard(address, what):
        """Запоминает и запрещает обращение к нелокальному адресу."""
        if not _local(address):
            attempts.append((what, repr(address)))
            raise OSError(f"Проверка без интернета: обращение к {address!r} запрещено")

    def blocked_connect(self, address):
        """Соединение только с localhost."""
        guard(address, "connect")
        return connect(self, address)

    def blocked_connect_ex(self, address):
        """Соединение только с localhost."""
        guard(address, "connect_ex")
        return connect_ex(self, address)

    def blocked_sendto(self, data, *args):
        """Датаграммы только на localhost."""
        guard(args[-1], "sendto")
        return sendto(self, data, *args)

    def blocked_getaddrinfo(host, *args, **kwargs):
        """Разрешение имён только для localhost."""
        if host is not None:
            guard((host,), "getaddrinfo")
        return getaddrinfo(host, *args, **kwargs)

    def blocked_create_connection(address, *args, **kwargs):
        """Соединение только с localhost."""
        guard(address, "create_connection")
        return create_connection(address, *args, **kwargs)

    monkeypatch.setattr(socket.socket, "connect", blocked_connect)
    monkeypatch.setattr(socket.socket, "connect_ex", blocked_connect_ex)
    monkeypatch.setattr(socket.socket, "sendto", blocked_sendto)
    monkeypatch.setattr(socket, "getaddrinfo", blocked_getaddrinfo)
    monkeypatch.setattr(socket, "create_connection", blocked_create_connection)
    return attempts


def test_guard_really_blocks(no_internet):
    """Сама защита работает: внешний адрес запрещён и запомнен, localhost разрешён."""
    with pytest.raises(OSError):
        socket.create_connection(("example.com", 443), timeout=1)
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        with pytest.raises(OSError):
            probe.connect(("93.184.215.14", 80))
    finally:
        probe.close()
    assert [what for what, _ in no_internet] == ["create_connection", "connect"]
    no_internet.clear()
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        client.connect(server.getsockname())
    finally:
        client.close()
        server.close()
    assert no_internet == []


def _plate() -> np.ndarray:
    """Кадр шильдика насоса Н-101, нарисованный программно: модель и заводской номер."""
    image = np.full((360, 900, 3), 235, np.uint8)
    cv2.rectangle(image, (10, 10), (890, 350), (60, 60, 60), 3)
    for index, line in enumerate(["WILO", "IL 65/160-5,5/2", "No 2786107-0142", "5,5 kW 2900 1/min"]):
        cv2.putText(image, line, (40, 80 + index * 75), cv2.FONT_HERSHEY_DUPLEX, 1.6, (20, 20, 20), 3, cv2.LINE_AA)
    return image


def _qr(text: str) -> np.ndarray:
    """Кадр с QR-кодом, созданным OpenCV."""
    code = cv2.QRCodeEncoder.create().encode(text)
    code = cv2.resize(code, None, fx=8, fy=8, interpolation=cv2.INTER_NEAREST)
    return cv2.cvtColor(cv2.copyMakeBorder(code, 48, 48, 48, 48, cv2.BORDER_CONSTANT, value=255), cv2.COLOR_GRAY2BGR)


def _jpeg(image: np.ndarray) -> bytes:
    """Кадр в JPEG."""
    ok, data = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 92])
    assert ok
    return data.tobytes()


def _ocr_available() -> bool:
    """Установлены ли распознаватель текста и его локальные модели."""
    try:
        import_module("cv.nameplate").ocr_model_paths()
    except (ImportError, OSError):
        return False
    return True


def test_full_scenario_without_internet(no_internet, tmp_path, monkeypatch):
    """Вход, оборудование, шильдик и QR, осмотр с кадром камеры, находка, завершение и оба отчёта - без сети."""
    monkeypatch.setenv("KST_DB", str(tmp_path / "kst.db"))
    monkeypatch.setenv("KST_SECRET", "o" * 48)
    monkeypatch.setattr(auth, "SCRYPT_N", 2**10)
    detector = recognition.Detector()
    try:
        with TestClient(create_app(detector)) as client:
            health = client.get("/health").json()
            assert health["ok"] is True and health["channels"]["database"]["state"] == "ok"
            login = client.post("/auth/login", json={"email": "engineer@kst.demo", "password": PASSWORD})
            assert login.status_code == 200, login.text
            token = login.json()["access_token"]
            engineer = {"Authorization": f"Bearer {token}"}
            units = client.get("/equipment", headers=engineer).json()
            assert "N-101" in {unit["id"] for unit in units}
            assert client.get("/equipment/N-101", headers=engineer).json()["serial"] == "2786107-0142"

            plate = client.post(
                "/recognize/nameplate", headers=engineer, files={"frame": ("plate.jpg", _jpeg(_plate()), "image/jpeg")}
            )
            if _ocr_available():
                assert plate.status_code == 200, plate.text
                body = plate.json()
                assert body["match"]["equipment_id"] == "N-101" and body["identified_by"] == "nameplate"
            else:
                assert plate.status_code == 503
            by_qr = client.post(
                "/recognize/nameplate", headers=engineer, files={"frame": ("qr.jpg", _jpeg(_qr("N-101")), "image/jpeg")}
            ).json()
            assert by_qr["match"]["equipment_id"] == "N-101" and by_qr["match"]["by"] == "qr"

            started = client.post("/inspections", json={"equipment_id": "N-101", "identified_by": "nameplate"}, headers=engineer)
            assert started.status_code == 201, started.text
            inspection_id = started.json()["id"]
            if detector.available:
                with client.websocket_connect(f"/ws/inspect/{inspection_id}?token={token}") as live:
                    assert live.receive_json()["type"] == "state"
                    live.send_bytes(_jpeg(_plate()))
                    reply = live.receive_json()
                    assert reply["type"] == "frame", reply
            finding = client.post(
                f"/inspections/{inspection_id}/findings",
                headers=engineer,
                data={"kind": "defect", "sign": "corrosion", "node": "casing"},
                files={"frame": ("f.jpg", _jpeg(_plate()), "image/jpeg")},
            )
            assert finding.status_code == 201, finding.text
            assert finding.json()["has_photo"] is True and finding.json()["models_fingerprint"]
            finished = client.post(f"/inspections/{inspection_id}/finish", headers=engineer).json()
            assert finished["status"] == "finished" and finished["summary"]["status"] == "defect"
            pdf = client.get(f"/inspections/{inspection_id}/report.pdf", headers=engineer)
            assert pdf.status_code == 200 and pdf.content.startswith(b"%PDF")
            xlsx = client.get(f"/inspections/{inspection_id}/report.xlsx", headers=engineer)
            assert xlsx.status_code == 200 and xlsx.content.startswith(b"PK")
    finally:
        service._live.clear()
    assert no_internet == [], no_internet
