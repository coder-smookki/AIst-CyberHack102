"""Распознавание на кадрах камеры: детектор узлов и дефектов, чтение шильдика и стрелочного манометра.

Детектор загружается при первом обращении: подключение библиотеки занимает секунды, а сервер должен
запускаться сразу и работать даже без файла модели. Если в папке models есть models.json, загружаются все
перечисленные в нём модели и их рамки объединяются; иначе берётся models/detector.onnx. Порог уверенности
задаётся для каждой модели полем conf_check и уточняется для отдельных классов полем thresholds
({класс: порог}); без них действует общий порог 0,25. Чтение шильдика и манометра выполняют функции из
папки cv.
"""
import io
import json
import logging
import os
import threading
import time
from importlib import import_module
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, UnidentifiedImageError

from server.rules import STRONG_CONFIDENCE, WEAK_CONFIDENCE, defect_signs

MODELS_DIR = Path(__file__).resolve().parents[1] / "models"
MANIFEST = "models.json"
DEFAULT_MODEL = "detector.onnx"
MAX_FRAME_BYTES = 8 * 1024 * 1024
MAX_FRAME_PIXELS = 40_000_000
MERGE_OVERLAP = 0.5
WARM_UP_SIDE = 640
GAUGE_UNSURE = "Стрелка манометра не определена уверенно - снимите прибор ближе, анфас и без бликов"

logger = logging.getLogger(__name__)
_ocr_lock = threading.Lock()


class FrameError(ValueError):
    """Кадр камеры не принят: пустой, слишком большой, не JPEG или повреждён; status - код ответа HTTP."""

    def __init__(self, message: str, status: int):
        """Запоминает текст причины и код ответа."""
        super().__init__(message)
        self.status = status


class DetectorUnavailable(RuntimeError):
    """Детектор не может обработать кадр: нет файла модели или модель не загрузилась."""


def decode_frame(data: bytes) -> np.ndarray:
    """Проверяет кадр камеры и превращает его в изображение; принимается только JPEG разумного размера."""
    if not data:
        raise FrameError("Кадр пустой", 422)
    if len(data) > MAX_FRAME_BYTES:
        raise FrameError(f"Кадр больше {MAX_FRAME_BYTES // (1024 * 1024)} МБ", 413)
    if not data.startswith(b"\xff\xd8"):
        raise FrameError("Кадр должен быть в формате JPEG", 415)
    try:
        with Image.open(io.BytesIO(data)) as picture:
            pixels = picture.width * picture.height
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise FrameError("Кадр повреждён: изображение не читается", 422) from None
    if pixels > MAX_FRAME_PIXELS:
        raise FrameError("Кадр слишком большого размера в пикселях", 413)
    frame = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if frame is None:
        raise FrameError("Кадр повреждён: изображение не читается", 422)
    return frame


def box_status(cls: str, conf: float, defects: set[str]) -> str:
    """Определяет статус рамки: уверенный дефект, повод для проверки, уверенно найденный узел или сомнение.

    Неуверенная находка дефекта не скрывается: пропустить дефект хуже, чем лишний раз проверить.
    """
    if cls in defects:
        return "defect" if conf >= STRONG_CONFIDENCE else "check"
    return "ok" if conf >= STRONG_CONFIDENCE else "unsure"


def _overlap(first: dict, second: dict) -> float:
    """Возвращает долю пересечения двух рамок от их объединения."""
    width = min(first["x2"], second["x2"]) - max(first["x1"], second["x1"])
    height = min(first["y2"], second["y2"]) - max(first["y1"], second["y1"])
    shared = max(0.0, width) * max(0.0, height)
    union = ((first["x2"] - first["x1"]) * (first["y2"] - first["y1"])
             + (second["x2"] - second["x1"]) * (second["y2"] - second["y1"]) - shared)
    return shared / union if union > 0 else 0.0


def merge_boxes(boxes: list[dict]) -> list[dict]:
    """Объединяет рамки нескольких моделей: из сильно пересекающихся рамок одного класса остаётся самая уверенная."""
    kept = []
    for box in sorted(boxes, key=lambda item: -item["conf"]):
        if all(box["cls"] != other["cls"] or _overlap(box, other) < MERGE_OVERLAP for other in kept):
            kept.append(box)
    return kept


def ort_threads() -> int:
    """Возвращает число потоков вычисления ONNX: KST_ORT_THREADS или доступные процессу ядра, не больше 16.

    Без ограничения среда выполнения создаёт поток на каждое ядро машины, и в контейнере с лимитом процессора
    потоки мешают друг другу.
    """
    value = os.environ.get("KST_ORT_THREADS", "").strip()
    if value.isdigit() and int(value) > 0:
        return int(value)
    try:
        cores = len(os.sched_getaffinity(0))
    except AttributeError:
        cores = os.cpu_count() or 4
    return max(1, min(cores, 16))


def _tune_session(model) -> None:
    """Пересоздаёт сеанс ONNX модели с заданным числом потоков; при ошибке оставляет исходный сеанс."""
    session = getattr(model, "session", None)
    path = getattr(session, "_model_path", None)
    if session is None or not path:
        return
    try:
        import onnxruntime as ort
        options = ort.SessionOptions()
        options.intra_op_num_threads = ort_threads()
        options.inter_op_num_threads = 1
        model.session = ort.InferenceSession(path, sess_options=options, providers=session.get_providers())
    except Exception:
        logger.warning("Не удалось задать число потоков ONNX для %s", path, exc_info=True)


def _load_model(path: Path):
    """Загружает модель ONNX; библиотека детектора подключается только здесь, при первом кадре."""
    from libreyolo import LibreYOLO
    model = LibreYOLO(str(path))
    _tune_session(model)
    return model


def _threshold(value, default: float) -> float:
    """Проверяет порог уверенности из описания моделей: число строго от 0 до 1, иначе берётся default."""
    if isinstance(value, (int, float)) and not isinstance(value, bool) and 0.0 < float(value) < 1.0:
        return float(value)
    return default


def model_thresholds(entry) -> tuple[float, dict[str, float]]:
    """Возвращает порог модели и пороги отдельных классов из записи models.json.

    Порог модели - поле conf_check, пороги классов - поле thresholds; негодные значения заменяются общим
    порогом 0,25 или порогом модели.
    """
    if not isinstance(entry, dict):
        return WEAK_CONFIDENCE, {}
    default = _threshold(entry.get("conf_check"), WEAK_CONFIDENCE)
    listed = entry.get("thresholds")
    classes = {str(cls): _threshold(value, default) for cls, value in listed.items()} if isinstance(listed, dict) else {}
    return default, classes


def _model_boxes(model, frame: np.ndarray, default: float = WEAK_CONFIDENCE,
                 classes: dict[str, float] | None = None) -> list[dict]:
    """Запускает одну модель на кадре и возвращает её рамки в пикселях кадра.

    Модель запускается с наименьшим из её порогов, затем каждая рамка сверяется с порогом своего класса.
    """
    classes = classes or {}
    result = model(frame, conf=min([default, *classes.values()]))
    result = result[0] if isinstance(result, (list, tuple)) else result
    names = getattr(result, "names", None) or getattr(model, "names", {})
    boxes = []
    for corners, index, score in zip(result.boxes.xyxy, result.boxes.cls, result.boxes.conf):
        name, conf = str(names[int(index)]), float(score)
        if conf < classes.get(name, default):
            continue
        x1, y1, x2, y2 = (round(float(value), 1) for value in corners)
        boxes.append({"cls": name, "conf": round(conf, 3), "x1": x1, "y1": y1, "x2": x2, "y2": y2})
    return boxes


class Detector:
    """Детектор узлов и дефектов с отложенной загрузкой моделей.

    Метод detect возвращает рамки {cls, conf, x1, y1, x2, y2} в пикселях кадра. Любой объект с таким методом
    можно передать серверу вместо этого класса - так проверки обходятся без файла модели.
    """

    def __init__(self, models_dir: Path | str = MODELS_DIR, loader=None):
        """Принимает папку моделей и необязательную функцию загрузки модели по пути к файлу."""
        self._dir = Path(models_dir)
        self._loader = loader or _load_model
        self._load_lock = threading.Lock()
        self._run_lock = threading.Lock()
        self._models = None
        self._failure = None

    def _plan(self) -> dict:
        """Определяет, какие файлы моделей нужны: по models.json, а без него - detector.onnx.

        Возвращает найденные файлы, отсутствующие файлы, дефектные классы и пороги моделей из описания
        и замечание о нечитаемом описании.
        """
        names, defects, note, thresholds = [DEFAULT_MODEL], set(), None, {}
        manifest = self._dir / MANIFEST
        if manifest.is_file():
            try:
                with open(manifest, encoding="utf-8") as file:
                    document = json.load(file)
                entries = document.get("models", []) if isinstance(document, dict) else document
                listed = []
                for entry in entries if isinstance(entries, list) else []:
                    name = entry.get("file") if isinstance(entry, dict) else entry
                    if isinstance(name, str) and name.endswith(".onnx") and Path(name).name == name:
                        listed.append(name)
                        thresholds.setdefault(name, model_thresholds(entry))
                        if isinstance(entry, dict):
                            defects.update(str(cls) for cls in entry.get("defect_classes") or [])
                if not listed:
                    raise ValueError("в описании нет ни одной модели")
                names = list(dict.fromkeys(listed))
            except (OSError, ValueError, AttributeError, TypeError):
                defects, note, thresholds = set(), f"{MANIFEST} не читается - используется {DEFAULT_MODEL}", {}
                names = [DEFAULT_MODEL]
        found = [name for name in names if (self._dir / name).is_file()]
        return {"files": found, "missing": [name for name in names if name not in found], "defects": defects, "note": note,
                "thresholds": {name: thresholds.get(name, (WEAK_CONFIDENCE, {})) for name in found}}

    @property
    def available(self) -> bool:
        """Сообщает, есть ли на диске хотя бы один файл модели."""
        return bool(self._plan()["files"])

    @property
    def loaded(self) -> bool:
        """Сообщает, загружены ли модели в память."""
        return self._models is not None

    @property
    def defect_classes(self) -> set[str]:
        """Дефектные классы, объявленные в описании моделей, в дополнение к перечню правил диагностики."""
        return self._plan()["defects"]

    @property
    def min_confidence(self) -> float:
        """Наименьший порог уверенности среди моделей на диске; ниже него рамки не возвращаются."""
        values = [value for default, classes in self._plan()["thresholds"].values() for value in (default, *classes.values())]
        return min(values) if values else WEAK_CONFIDENCE

    def info(self) -> dict:
        """Описывает состояние детектора для проверки готовности сервера."""
        plan = self._plan()
        return {"ready": bool(plan["files"]) and self._failure is None, "loaded": self.loaded, "models": plan["files"],
                "missing": plan["missing"], "note": self._failure or plan["note"]}

    def load(self) -> list:
        """Загружает модели при первом вызове и возвращает их; повторные вызовы ничего не загружают.

        Неудачная загрузка запоминается, чтобы не повторять долгую попытку на каждом кадре.
        """
        with self._load_lock:
            if self._models is not None:
                return self._models
            if self._failure is not None:
                raise DetectorUnavailable(self._failure)
            plan = self._plan()
            if not plan["files"]:
                raise DetectorUnavailable("Модель детектора не найдена: в папке models нет файла " + ", ".join(plan["missing"]))
            models, failed = [], []
            for name in plan["files"]:
                try:
                    models.append((self._loader(self._dir / name), *plan["thresholds"][name]))
                except Exception as error:
                    logger.warning("Модель %s не загрузилась: %s", name, type(error).__name__)
                    failed.append(name)
            if not models:
                self._failure = "Модель детектора не загрузилась: " + ", ".join(failed)
                raise DetectorUnavailable(self._failure)
            self._models = models
            return models

    def detect(self, frame: np.ndarray) -> list[dict]:
        """Находит узлы и дефекты на кадре всеми загруженными моделями с их порогами и объединяет рамки."""
        models = self.load()
        boxes = []
        with self._run_lock:
            for model, default, classes in models:
                boxes.extend(_model_boxes(model, frame, default, classes))
        return merge_boxes(boxes)

    def _warm(self) -> None:
        """Загружает модели и прогоняет пустой кадр, чтобы первый кадр инженера не ждал загрузки."""
        try:
            self.detect(np.zeros((WARM_UP_SIDE, WARM_UP_SIDE, 3), np.uint8))
        except DetectorUnavailable as error:
            logger.warning("Детектор не готов: %s", error)

    def warm_up(self) -> None:
        """Запускает загрузку моделей в фоне, если файлы есть на диске и модели ещё не загружены."""
        if self.available and not self.loaded:
            threading.Thread(target=self._warm, name="detector-warm-up", daemon=True).start()


def defect_classes(detector) -> set[str]:
    """Возвращает классы, которые сервер считает дефектами: перечень правил плюс объявленные детектором."""
    return set(defect_signs()) | set(getattr(detector, "defect_classes", None) or ())


def detect_frame(detector, data: bytes) -> dict:
    """Читает кадр камеры и находит на нём узлы и дефекты: размер кадра, время работы детектора и рамки.

    Рамки с уверенностью ниже наименьшего порога моделей (min_confidence детектора, по умолчанию 0,25)
    отбрасываются. Негодный кадр даёт FrameError, отсутствие модели - DetectorUnavailable.
    """
    frame = decode_frame(data)
    floor = getattr(detector, "min_confidence", WEAK_CONFIDENCE)
    floor = floor if isinstance(floor, (int, float)) else WEAK_CONFIDENCE
    started = time.perf_counter()
    boxes = [dict(box) for box in detector.detect(frame) if box["conf"] >= floor]
    boxes.sort(key=lambda box: -box["conf"])
    return {"w": int(frame.shape[1]), "h": int(frame.shape[0]), "ms": round((time.perf_counter() - started) * 1000, 1),
            "boxes": boxes}


def read_text(frame: np.ndarray) -> list[dict]:
    """Распознаёт строки текста на кадре шильдика; распознаватель общий, поэтому вызовы идут по одному."""
    with _ocr_lock:
        return import_module("cv.nameplate").read_lines(frame)


def read_nameplate(frame: np.ndarray, cards: list[dict]) -> dict:
    """Читает шильдик и ищет оборудование среди карточек с полями serial и model.

    Возвращает распознанные строки, поля, найденное совпадение и карточки той же модели, если совпадение
    не однозначно: в этом случае агрегат выбирает инженер, сервер не угадывает.
    """
    module = import_module("cv.nameplate")
    lines = read_text(frame)
    fields = module.parse_fields(lines)
    match = module.match_equipment(fields, cards)
    candidates = [] if match else [card for _, card in module.same_model(module.haystack_of(fields), cards)]
    return {"lines": lines, "fields": fields, "match": match, "candidates": candidates}


def read_gauge(frame: np.ndarray, scale: dict) -> dict:
    """Читает стрелочный манометр по шкале из карточки оборудования: {min, max, sweep_deg}.

    Возвращает {ok, value, reason, angle_deg, contrast}. Ненадёжное чтение даёт ok = False и value = None:
    сомнительное число в диагностику не передаётся.
    """
    found = import_module("cv.gauge").read_gauge(frame, float(scale["min"]), float(scale["max"]), float(scale["sweep_deg"]))
    if found.get("ok") and found.get("value") is not None:
        return {"ok": True, "value": float(found["value"]), "reason": None, "angle_deg": found.get("angle_deg"),
                "contrast": found.get("contrast")}
    reason = found.get("reason")
    reason = f"Манометр не прочитан: {reason}" if reason else GAUGE_UNSURE
    return {"ok": False, "value": None, "reason": reason, "angle_deg": found.get("angle_deg"), "contrast": found.get("contrast")}
