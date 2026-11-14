"""QR-код как запасной путь опознания агрегата: разбор адресов, точное совпадение, порядок после шильдика."""
import cv2
import numpy as np
import pytest

from server import qr, recognition
from test_api_extra import client, headers, readings, seeded_database

CARDS = [{"id": "N-101", "serial": "2786107-0142", "model": "IL 65/160-5,5/2"},
         {"id": "AMS-1", "serial": "21031004-1", "model": "PCP60S12/3"},
         {"id": "AMS-2", "serial": "21031004-2", "model": "PCP60S12/3"}]


def qr_image(text: str, scale: int = 8, border: int = 48, with_text: bool = False) -> np.ndarray:
    """Кадр с QR-кодом, созданным самим OpenCV, на светлом фоне; по желанию - с надписью рядом."""
    code = cv2.QRCodeEncoder.create().encode(text)
    code = cv2.resize(code, None, fx=scale, fy=scale, interpolation=cv2.INTER_NEAREST)
    code = cv2.copyMakeBorder(code, border, border, border, border, cv2.BORDER_CONSTANT, value=255)
    frame = cv2.cvtColor(code, cv2.COLOR_GRAY2BGR)
    if with_text:
        frame = cv2.copyMakeBorder(frame, 0, 0, 0, 320, cv2.BORDER_CONSTANT, value=(255, 255, 255))
        cv2.putText(frame, "KST", (frame.shape[1] - 280, 120), cv2.FONT_HERSHEY_SIMPLEX, 2, (0, 0, 0), 4)
    return frame


def jpeg_of(frame: np.ndarray) -> bytes:
    """Кадр в формате JPEG высокого качества."""
    ok, data = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
    assert ok
    return data.tobytes()


@pytest.mark.parametrize("text, expected", [
    ("https://kct-vizor.lumnex.ru:4433/equipment/N-101", ["N-101", "equipment"]),
    ("http://plant.local/u?id=AMS-1&src=label", ["AMS-1", "label", "u"]),
    ("id:N-101", ["id:N-101", "N-101"]),
    ("KST N-101", ["KST N-101", "KST", "N-101"]),
])
def test_code_tokens_strip_urls(text, expected):
    """От адреса остаются значения параметров и части пути; имя сервера в коды не попадает."""
    tokens = qr.code_tokens(text)
    assert tokens[:len(expected)] == expected
    assert not any("lumnex" in token or "plant.local" in token for token in tokens)


def test_match_by_id_serial_and_url():
    """Совпадение по обозначению и по заводскому номеру, в том числе из адреса; by всегда qr."""
    by_id = qr.match_code(["https://example.invalid/equipment/n-101?from=qr"], CARDS)
    assert by_id["card"]["id"] == "N-101" and by_id["by"] == "qr" and by_id["code"] == "n-101" and by_id["field"] == "id"
    by_serial = qr.match_code(["serial=21031004-2"], CARDS)
    assert by_serial["card"]["id"] == "AMS-2" and by_serial["field"] == "serial"


def test_no_guessing():
    """Чужой код, одна только модель или коды двух разных агрегатов не дают совпадения."""
    assert qr.match_code(["https://example.invalid/catalog/pump"], CARDS) is None
    assert qr.match_code(["PCP60S12/3"], CARDS) is None
    assert qr.match_code(["N-101", "AMS-1"], CARDS) is None
    assert qr.match_code([], CARDS) is None


def test_reads_generated_qr_image():
    """Детектор OpenCV читает созданный QR-код и находит агрегат; на кадре без кода - ничего."""
    match, texts = qr.read_and_match(qr_image("https://kct.local/equipment/AMS-1"), CARDS)
    assert texts == ["https://kct.local/equipment/AMS-1"] and match["card"]["id"] == "AMS-1"
    assert qr.read_and_match(np.full((200, 200, 3), 200, np.uint8), CARDS) == (None, [])


def test_endpoint_falls_back_to_qr_and_flows_into_inspection(client, monkeypatch):
    """Шильдик не прочитан - сервер находит агрегат по QR-коду, а осмотр запоминает способ опознания «qr»."""
    engineer = headers(client, "engineer")
    monkeypatch.setattr(recognition, "read_text", lambda frame: [{"text": "XYZ", "score": 0.8}])
    frame = jpeg_of(qr_image("https://kct-vizor.lumnex.ru:4433/equipment/N-101", with_text=True))
    body = client.post("/recognize/nameplate", headers=engineer, files={"frame": ("p.jpg", frame, "image/jpeg")}).json()
    assert body["found"] is True and body["match"]["by"] == "qr" and body["match"]["equipment_id"] == "N-101"
    assert body["identified_by"] == "qr" and body["qr"] == "N-101" and "QR" in body["message"]
    assert body["lines"] == [{"text": "XYZ", "score": 0.8}]
    response = client.post("/inspections", json={"equipment_id": body["match"]["equipment_id"],
                                                 "identified_by": body["identified_by"]}, headers=engineer)
    assert response.status_code in (200, 201) and response.json()["identified_by"] == "qr"


def test_nameplate_text_stays_first(client, monkeypatch):
    """Если текст шильдика дал агрегат, QR на том же кадре не читается и не меняет ответ."""
    engineer = headers(client, "engineer")
    monkeypatch.setattr(recognition, "read_text", lambda frame: [{"text": "Зав. № 2786107-0142", "score": 0.9}])
    monkeypatch.setattr(qr, "read_and_match", lambda *args: pytest.fail("QR не должен читаться"))
    frame = jpeg_of(qr_image("AMS-1"))
    body = client.post("/recognize/nameplate", headers=engineer, files={"frame": ("p.jpg", frame, "image/jpeg")}).json()
    assert body["match"]["equipment_id"] == "N-101" and body["match"]["by"] == "serial"
    assert body["identified_by"] == "nameplate" and body["qr"] is None


def test_qr_works_when_text_recognition_is_unavailable(client, monkeypatch):
    """Без моделей распознавания текста QR-код всё равно опознаёт агрегат; без кода - прежний ответ 503."""
    engineer = headers(client, "engineer")

    def broken(frame):
        """Распознаватель текста не установлен."""
        raise ImportError("rapidocr")

    monkeypatch.setattr(recognition, "read_text", broken)
    frame = jpeg_of(qr_image("21031004-1"))
    body = client.post("/recognize/nameplate", headers=engineer, files={"frame": ("p.jpg", frame, "image/jpeg")}).json()
    assert body["match"]["equipment_id"] == "AMS-1" and body["identified_by"] == "qr" and body["lines"] == []
    plain = jpeg_of(np.full((240, 320, 3), 180, np.uint8))
    assert client.post("/recognize/nameplate", headers=engineer,
                       files={"frame": ("p.jpg", plain, "image/jpeg")}).status_code == 503
