"""Рисует найденные моделями рамки на снимках и сохраняет небольшие файлы для описания проекта.

Запуск:
    python cv/draw_detections.py <папка_результата> <веса[,ещё_веса]> <снимок> [<снимок> ...]

Рамки нескольких моделей наносятся на один снимок, как это делает сервер. Дефекты выделены красным
и оранжевым, исправные узлы синим. Каждый файл ужимается до размера не больше 200 КБ.
"""
import os
import sys

import cv2
import numpy as np

DEFECT_COLORS = {"corrosion": (12, 154, 227), "leak": (48, 59, 217), "terminal_box_burnt": (48, 59, 217),
                 "damage": (187, 79, 107), "coupling_no_guard": (48, 59, 217)}
NODE_COLOR = (166, 90, 19)
LIMIT = 200_000


def detections(models: list, frame: np.ndarray, conf: float = 0.25) -> list[tuple]:
    """Возвращает рамки всех моделей как (класс, рамка в пикселях, уверенность)."""
    rows = []
    for model in models:
        result = model(frame, conf=conf)
        result = result[0] if isinstance(result, (list, tuple)) else result
        names = getattr(result, "names", None) or getattr(model, "names", {})
        rows += [(names[int(cls)], [int(v) for v in box], float(score))
                 for box, cls, score in zip(result.boxes.xyxy, result.boxes.cls, result.boxes.conf)]
    return sorted(merge_same_class(rows), key=lambda row: row[2])


def overlap(a: list, b: list) -> float:
    """Возвращает долю пересечения двух рамок от их объединения."""
    width, height = min(a[2], b[2]) - max(a[0], b[0]), min(a[3], b[3]) - max(a[1], b[1])
    inter = max(0, width) * max(0, height)
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def merge_same_class(rows: list[tuple], limit: float = 0.5) -> list[tuple]:
    """Убирает повторы одного класса от разных моделей: из сильно пересекающихся рамок остаётся самая уверенная."""
    kept = []
    for row in sorted(rows, key=lambda row: -row[2]):
        if all(row[0] != other[0] or overlap(row[1], other[1]) < limit for other in kept):
            kept.append(row)
    return kept


def annotate(frame: np.ndarray, rows: list[tuple], side: int = 900) -> np.ndarray:
    """Уменьшает снимок до заданной длинной стороны и наносит рамки с подписями."""
    scale = min(1.0, side / max(frame.shape[:2]))
    image = cv2.resize(frame, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1.0 else frame.copy()
    for name, (x1, y1, x2, y2), score in rows:
        color = DEFECT_COLORS.get(name, NODE_COLOR)
        x1, y1, x2, y2 = (int(v * scale) for v in (x1, y1, x2, y2))
        cv2.rectangle(image, (x1, y1), (x2, y2), color, 2)
        text = f"{name} {score:.2f}"
        (width, height), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
        top = max(height + 6, y1)
        cv2.rectangle(image, (x1, top - height - 6), (x1 + width + 6, top), color, -1)
        cv2.putText(image, text, (x1 + 3, top - 4), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1, cv2.LINE_AA)
    return image


def save_small(image: np.ndarray, path: str) -> int:
    """Сохраняет JPEG, снижая качество, пока файл не уложится в ограничение размера."""
    for quality in (88, 80, 72, 64, 56, 48, 40):
        data = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, quality])[1]
        if len(data) <= LIMIT:
            break
    data.tofile(path)
    return len(data)


def main() -> None:
    """Обрабатывает перечисленные снимки и печатает, что найдено на каждом."""
    out, weights, files = sys.argv[1], sys.argv[2].split(","), sys.argv[3:]
    from libreyolo import LibreYOLO
    models = [LibreYOLO(path) for path in weights]
    os.makedirs(out, exist_ok=True)
    for index, path in enumerate(files):
        target, _, source = path.rpartition("=")
        frame = cv2.imdecode(np.fromfile(source, np.uint8), cv2.IMREAD_COLOR)
        rows = detections(models, frame)
        name = target or f"detect_{index:02d}"
        size = save_small(annotate(frame, rows), os.path.join(out, name + ".jpg"))
        print(name, size, [(row[0], round(row[2], 2)) for row in reversed(rows)])


if __name__ == "__main__":
    main()
