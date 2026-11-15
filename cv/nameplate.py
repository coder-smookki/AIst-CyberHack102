"""Чтение заводского шильдика и поиск оборудования по серийному номеру.

Запуск:
    python cv/nameplate.py <изображение> [data/equipment.json]
"""

import difflib
import json
import re
import sys
from pathlib import Path

import cv2
import numpy as np

SERIAL_RE = re.compile(r"\d{6,8}\s*[-–]\s*\d{1,5}")
MODEL_RE = re.compile(r"[A-Z]{2,3}\s*\d{2,3}\s*/\s*\d{2,3}\s*-\s*\d+[,.]?\d*\s*/\s*\d")
LOOKALIKES = str.maketrans("АВЕКМНОРСТХУЗ", "ABEKMHOPCTXY3")
CONFUSED = str.maketrans("OILSBZ", "011582")
MARGIN = 0.05

OCR_MODELS = {
    "Det.model_path": "PP-OCRv6_det_small.onnx",
    "Cls.model_path": "ch_ppocr_mobile_v2.0_cls_mobile.onnx",
    "Rec.model_path": "PP-OCRv6_rec_small.onnx",
}

_engine = None


def ocr_model_paths() -> dict[str, str]:
    """Находит файлы моделей распознавания текста на диске: сначала models/ocr проекта, затем папку пакета.

    Пути передаются распознавателю явно, поэтому он не скачивает модели из сети. Если файла нет, выдаётся
    понятная ошибка вместо обращения к внешнему адресу.
    """
    import rapidocr

    folders = [Path(__file__).resolve().parent.parent / "models" / "ocr", Path(rapidocr.__file__).resolve().parent / "models"]
    found, missing = {}, []
    for key, name in OCR_MODELS.items():
        path = next((folder / name for folder in folders if (folder / name).is_file()), None)
        if path is None:
            missing.append(name)
        else:
            found[key] = str(path)
    if missing:
        raise FileNotFoundError("Нет файлов моделей распознавания текста: " + ", ".join(missing) + ". Положите их в models/ocr")
    return found


def engine():
    """Возвращает общий экземпляр распознавателя текста с локальными моделями, создавая его при первом вызове."""
    global _engine
    if _engine is None:
        from rapidocr import RapidOCR

        _engine = RapidOCR(params=ocr_model_paths())
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


def compact(text: str) -> str:
    """Приводит текст к виду для сравнения.

    Похожие кириллические буквы заменяются латинскими, буквы, которые распознаватель путает с цифрами,
    заменяются цифрами, пробелы и знаки убираются. Так запись на шильдике и запись в реестре совпадают,
    даже если они набраны с разными разделителями.
    """
    return re.sub(r"[^A-Z0-9]", "", text.upper().translate(LOOKALIKES).translate(CONFUSED))


def model_key(model: str) -> str:
    """Берёт начало обозначения модели, достаточное для узнавания.

    Исполнение и материалы в конце обозначения на шильдике часто записаны иначе, чем в реестре.
    """
    key = ""
    for token in model.split():
        key += compact(token)
        if len(key) >= 8:
            break
    return key


def similarity(key: str, haystack: str) -> float:
    """Возвращает долю совпадения ключа с самым похожим на него участком текста."""
    if not key or not haystack:
        return 0.0
    if key in haystack:
        return 1.0
    matcher = difflib.SequenceMatcher(None, autojunk=False)
    matcher.set_seq2(key)
    best = 0.0
    for start in range(max(1, len(haystack) - len(key) + 1)):
        matcher.set_seq1(haystack[start : start + len(key)])
        if matcher.quick_ratio() > best:
            best = max(best, matcher.ratio())
    return best


def rank(cards: list[dict], key_of, haystack: str) -> list[tuple[float, int, dict]]:
    """Оценивает сходство ключа каждой карточки с текстом шильдика, самые похожие и длинные в начале."""
    scored = [(similarity(key, haystack), len(key), card) for card in cards if len(key := key_of(card)) >= 5]
    return sorted(scored, key=lambda item: item[:2], reverse=True)


def same_model(haystack: str, cards: list[dict], cutoff: float = 0.85) -> list[tuple[float, dict]]:
    """Возвращает карточки, модель которых читается в тексте шильдика."""
    ranked = rank(cards, lambda card: model_key(card["model"]), haystack)
    if not ranked or ranked[0][0] < cutoff:
        return []
    return [(ratio, card) for ratio, _, card in ranked if ranked[0][0] - ratio < MARGIN]


def haystack_of(fields: dict) -> str:
    """Готовит текст шильдика к поиску: строки сравниваются по отдельности и не склеиваются между собой."""
    return "|".join(compact(part) for part in re.split(r"\s{2,}", fields["text"]))


def match_equipment(fields: dict, cards: list[dict], cutoff: float = 0.8) -> dict | None:
    """Находит карточку оборудования по тексту шильдика.

    Серийные номера и модели берутся из реестра и ищутся в распознанном тексте, поэтому формат номера
    у разных производителей значения не имеет. Сначала проверяется серийный номер, с допуском на ошибки
    распознавания. Если несколько карточек подходят одинаково, выбор не делается. Когда номер не прочитан,
    карточка находится по модели, если такая модель в реестре одна.
    """
    haystack = haystack_of(fields)
    by_serial = rank(cards, lambda card: compact(card["serial"]), haystack)
    if by_serial and by_serial[0][0] >= cutoff:
        ratio, _, card = by_serial[0]
        if ratio == 1.0 or len(by_serial) == 1 or ratio - by_serial[1][0] >= MARGIN:
            return {"card": card, "by": "serial" if ratio == 1.0 else "serial_fuzzy", "ratio": round(ratio, 3)}
    by_model = same_model(haystack, cards)
    if len(by_model) == 1:
        return {"card": by_model[0][1], "by": "model", "ratio": round(by_model[0][0], 3)}
    return None


def identify(image: np.ndarray, cards: list[dict]) -> dict:
    """Полный путь: кадр шильдика, распознанные поля и найденная карточка оборудования.

    Если карточка не определена однозначно, в `candidates` попадают карточки с той же моделью,
    чтобы инженер выбрал агрегат сам.
    """
    lines = read_lines(image)
    fields = parse_fields(lines)
    match = match_equipment(fields, cards)
    candidates = [] if match else [card for _, card in same_model(haystack_of(fields), cards)]
    return {"fields": fields, "match": match, "candidates": candidates, "lines": lines}


if __name__ == "__main__":
    cards_path = sys.argv[2] if len(sys.argv) > 2 else "data/equipment.json"
    cards = json.load(open(cards_path, encoding="utf-8"))["equipment"]
    frame = cv2.imdecode(np.fromfile(sys.argv[1], np.uint8), cv2.IMREAD_COLOR)
    print(json.dumps(identify(frame, cards), ensure_ascii=False, indent=1))
