"""Варианты вывода детектора дефектов: отражение кадра, разбиение на части и пороги по классам.

Обёртка Options ведёт себя как модель LibreYOLO для cv/protocol.py: вызывается как model(frame, conf=...)
и возвращает объект с полями boxes.xyxy, boxes.cls, boxes.conf и names.
    flip - кадр прогоняется ещё и отражённым по горизонтали, рамки возвращаются в исходные координаты;
    tiles - число частей по стороне (2 даёт сетку 2x2 с перекрытием overlap) плюс целый кадр;
    рамки всех прогонов объединяются подавлением повторов внутри класса (NMS по пересечению nms_iou).
Пороги по классам задаются отображением уверенности remap_scores: порог класса переходит в общий
порог, поэтому показатели cv/protocol.py на этом общем пороге соответствуют порогам по классам.
"""
from types import SimpleNamespace

import numpy as np


def nms(boxes: np.ndarray, scores: np.ndarray, threshold: float) -> list[int]:
    """Возвращает индексы рамок, оставшихся после жадного подавления повторов."""
    order = np.argsort(-scores)
    keep = []
    while order.size:
        first = order[0]
        keep.append(int(first))
        if order.size == 1:
            break
        rest = order[1:]
        x1 = np.maximum(boxes[first, 0], boxes[rest, 0])
        y1 = np.maximum(boxes[first, 1], boxes[rest, 1])
        x2 = np.minimum(boxes[first, 2], boxes[rest, 2])
        y2 = np.minimum(boxes[first, 3], boxes[rest, 3])
        inter = np.clip(x2 - x1, 0, None) * np.clip(y2 - y1, 0, None)
        def area(b):
            """Площадь рамок xyxy."""
            return (b[..., 2] - b[..., 0]) * (b[..., 3] - b[..., 1])

        union = area(boxes[first]) + area(boxes[rest]) - inter
        order = rest[inter / np.maximum(union, 1e-9) < threshold]
    return keep


def tile_windows(width: int, height: int, tiles: int, overlap: float) -> list[tuple]:
    """Возвращает окна (x1, y1, x2, y2) сетки tiles x tiles с перекрытием соседних частей."""
    windows = []
    tile_w, tile_h = width / (tiles - (tiles - 1) * overlap), height / (tiles - (tiles - 1) * overlap)
    for row in range(tiles):
        for col in range(tiles):
            x1, y1 = int(col * tile_w * (1 - overlap)), int(row * tile_h * (1 - overlap))
            x2 = width if col == tiles - 1 else min(width, int(x1 + tile_w))
            y2 = height if row == tiles - 1 else min(height, int(y1 + tile_h))
            windows.append((x1, y1, x2, y2))
    return windows


class Options:
    """Обёртка модели с отражением кадра и разбиением на части."""

    def __init__(self, model, flip: bool = False, tiles: int = 0, overlap: float = 0.2, nms_iou: float = 0.5):
        """Запоминает модель и параметры вывода."""
        self.model = model
        self.flip = flip
        self.tiles = tiles
        self.overlap = overlap
        self.nms_iou = nms_iou
        self.names = getattr(model, "names", {})

    def raw(self, frame: np.ndarray, conf: float) -> tuple:
        """Прогоняет модель на одном кадре и возвращает рамки, классы и уверенности как массивы numpy."""
        result = self.model(frame, conf=conf)
        result = result[0] if isinstance(result, (list, tuple)) else result
        def as_array(value):
            """Переводит тензор или массив в numpy."""
            return value.cpu().numpy() if hasattr(value, "cpu") else np.asarray(value)

        boxes = as_array(result.boxes.xyxy).reshape(-1, 4).astype(np.float32)
        return boxes, as_array(result.boxes.cls).astype(int), as_array(result.boxes.conf).astype(np.float32)

    def __call__(self, frame: np.ndarray, conf: float = 0.25) -> SimpleNamespace:
        """Возвращает объединённые рамки всех прогонов в формате результата LibreYOLO."""
        height, width = frame.shape[:2]
        parts = [self.raw(frame, conf)]
        if self.flip:
            boxes, classes, scores = self.raw(np.ascontiguousarray(frame[:, ::-1]), conf)
            boxes = boxes.copy()
            boxes[:, [0, 2]] = width - boxes[:, [2, 0]]
            parts.append((boxes, classes, scores))
        if self.tiles > 1:
            for x1, y1, x2, y2 in tile_windows(width, height, self.tiles, self.overlap):
                boxes, classes, scores = self.raw(np.ascontiguousarray(frame[y1:y2, x1:x2]), conf)
                parts.append((boxes + np.float32([x1, y1, x1, y1]), classes, scores))
        boxes = np.concatenate([part[0] for part in parts])
        classes = np.concatenate([part[1] for part in parts])
        scores = np.concatenate([part[2] for part in parts])
        keep = []
        if len(parts) > 1:
            for cls in np.unique(classes):
                index = np.where(classes == cls)[0]
                keep.extend(index[nms(boxes[index], scores[index], self.nms_iou)])
            keep = np.array(sorted(keep), dtype=int)
        else:
            keep = np.arange(len(scores))
        return SimpleNamespace(boxes=SimpleNamespace(xyxy=boxes[keep], cls=classes[keep], conf=scores[keep]),
                               names=self.names)


def remap_score(score: float, threshold: float, level: float = 0.25) -> float:
    """Монотонно отображает уверенность так, что порог класса threshold переходит в общий порог level."""
    if score <= threshold:
        return level * score / threshold
    return level + (1 - level) * (score - threshold) / (1 - threshold)


def remap_records(records: list[dict], thresholds: dict, level: float = 0.25) -> list[dict]:
    """Возвращает копии записей cv/protocol.py с уверенностями, отображёнными по порогам классов."""
    out = []
    for row in records:
        copy = dict(row)
        copy["predicted"] = [(name, box, remap_score(score, thresholds.get(name, level), level))
                             for name, box, score in row["predicted"]]
        out.append(copy)
    return out
