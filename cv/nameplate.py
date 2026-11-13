"""Чтение заводского шильдика и поиск оборудования по серийному номеру.

Запуск:
    python cv/nameplate.py <изображение> [data/equipment.json]
"""
import difflib
import json
import re
import sys

import cv2
import numpy as np

SERIAL_RE = re.compile(r"\d{6,8}\s*[-–]\s*\d{3,5}")
MODEL_RE = re.compile(r"[A-Z]{2,3}\s*\d{2,3}\s*/\s*\d{2,3}\s*-\s*\d+[,.]?\d*\s*/\s*\d")

_engine = None


def engine():
    """Возвращает общий экземпляр распознавателя текста, создавая его при первом вызове."""
    global _engine
    if _engine is None:
        from rapidocr import RapidOCR
        _engine = RapidOCR()
    return _engine


def enhance(image: np.ndarray, min_side: int = 480) -> np.ndarray:
    """Увеличивает мелкий кадр и выравнивает контраст, чтобы текст читался увереннее."""
    h, w = image.shape[:2]
    scale = max(1.0, min_side / min(h, w))
    if scale > 1.0:
        image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
    lab = cv2.cvtColor(image, cv2.COLOR_BGR2LAB)
    lab[..., 0] = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8)).apply(lab[..., 0])
    return cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)


def read_lines(image: np.ndarray) -> list[dict]:
    """Распознаёт строки текста на изображении и возвращает их с уверенностью."""
    result = engine()(enhance(image))
    if result is None or result.txts is None:
        return []
    return [{"text": str(t), "score": round(float(s), 3)} for t, s in zip(result.txts, result.scores)]


def parse_fields(lines: list[dict]) -> dict:
    """Выделяет из распознанных строк модель и серийный номер."""
    joined = "  ".join(line["text"] for line in lines)
    normalized = joined.upper().replace("О", "0").replace("З", "3")
    serial = SERIAL_RE.search(normalized)
    model = MODEL_RE.search(normalized)
    return {
        "serial": re.sub(r"\s*[-–]\s*", "-", serial.group(0)) if serial else None,
        "model": re.sub(r"\s+", " ", model.group(0)).strip() if model else None,
        "text": joined,
    }


def match_equipment(fields: dict, cards: list[dict], cutoff: float = 0.72) -> dict | None:
    """Находит карточку оборудования по серийному номеру с допуском на ошибки распознавания."""
    serial = fields.get("serial")
    if serial:
        by_serial = {card["serial"]: card for card in cards}
        if serial in by_serial:
            return {"card": by_serial[serial], "by": "serial", "ratio": 1.0}
        close = difflib.get_close_matches(serial, list(by_serial), n=1, cutoff=cutoff)
        if close:
            ratio = difflib.SequenceMatcher(None, serial, close[0]).ratio()
            return {"card": by_serial[close[0]], "by": "serial_fuzzy", "ratio": round(ratio, 3)}
    model = fields.get("model")
    if model:
        compact = re.sub(r"\s+", "", model)
        same = [card for card in cards if re.sub(r"\s+", "", card["model"]).upper().endswith(compact)]
        if len(same) == 1:
            return {"card": same[0], "by": "model", "ratio": 1.0}
    return None


def identify(image: np.ndarray, cards: list[dict]) -> dict:
    """Полный путь: кадр шильдика, распознанные поля и найденная карточка оборудования."""
    lines = read_lines(image)
    fields = parse_fields(lines)
    return {"fields": fields, "match": match_equipment(fields, cards), "lines": lines}


if __name__ == "__main__":
    cards_path = sys.argv[2] if len(sys.argv) > 2 else "data/equipment.json"
    cards = json.load(open(cards_path, encoding="utf-8"))["equipment"]
    frame = cv2.imdecode(np.fromfile(sys.argv[1], np.uint8), cv2.IMREAD_COLOR)
    print(json.dumps(identify(frame, cards), ensure_ascii=False, indent=1))
