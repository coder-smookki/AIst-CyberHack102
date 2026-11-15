"""Оценка детектора на размеченной выборке: точность и полнота по классам.

Запуск:
    python cv/evaluate.py <веса> <папка_изображений> <папка_разметки> <data.yaml> [порог=0.25] [отчёт.json]

Предсказание считается верным, если совпал класс и пересечение рамок не меньше половины их объединения.
Порог уверенности по умолчанию низкий: пропуск дефекта для заказчика хуже лишнего предупреждения.
"""
import glob
import json
import os
import sys
import time

import cv2
from libreyolo import LibreYOLO


def load_names(data_yaml: str) -> list[str]:
    """Читает список классов из файла набора данных."""
    names = []
    for line in open(data_yaml, encoding="utf-8"):
        head, _, tail = line.strip().partition(":")
        if head.strip().isdigit():
            names.append(tail.strip())
    return names


def iou(a: tuple, b: tuple) -> float:
    """Возвращает долю пересечения двух рамок от их объединения."""
    x1, y1, x2, y2 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    inter = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union > 0 else 0.0


def read_truth(path: str, width: int, height: int) -> list[tuple]:
    """Читает рамки разметки в пикселях изображения."""
    rows = []
    if os.path.exists(path):
        for line in open(path):
            c, x, y, w, h = line.split()[:5]
            x, y, w, h = float(x) * width, float(y) * height, float(w) * width, float(h) * height
            rows.append((int(c), (x - w / 2, y - h / 2, x + w / 2, y + h / 2)))
    return rows


def evaluate(weights: str, images: str, labels: str, names: list[str], conf: float) -> dict:
    """Прогоняет модель по выборке и собирает показатели по каждому классу."""
    model = LibreYOLO(weights)
    stats = {n: {"tp": 0, "fp": 0, "fn": 0} for n in names}
    files = sorted(glob.glob(os.path.join(images, "*.jpg")))
    started = time.time()
    for path in files:
        frame = cv2.imread(path)
        height, width = frame.shape[:2]
        truth = read_truth(os.path.join(labels, os.path.basename(path)[:-4] + ".txt"), width, height)
        result = model(frame, conf=conf)
        result = result[0] if isinstance(result, (list, tuple)) else result
        predicted = sorted(((int(c), tuple(float(v) for v in b), float(p))
                            for b, c, p in zip(result.boxes.xyxy, result.boxes.cls, result.boxes.conf)),
                           key=lambda row: -row[2])
        used = set()
        for cls, box, _ in predicted:
            best, best_iou = None, 0.5
            for index, (t_cls, t_box) in enumerate(truth):
                if index in used or t_cls != cls:
                    continue
                value = iou(box, t_box)
                if value >= best_iou:
                    best, best_iou = index, value
            if best is None:
                stats[names[cls]]["fp"] += 1
            else:
                used.add(best)
                stats[names[cls]]["tp"] += 1
        for index, (t_cls, _) in enumerate(truth):
            if index not in used:
                stats[names[t_cls]]["fn"] += 1
    total = {"tp": 0, "fp": 0, "fn": 0}
    for row in stats.values():
        for key in total:
            total[key] += row[key]
        row["precision"] = round(row["tp"] / (row["tp"] + row["fp"]), 3) if row["tp"] + row["fp"] else None
        row["recall"] = round(row["tp"] / (row["tp"] + row["fn"]), 3) if row["tp"] + row["fn"] else None
    return {
        "images": len(files), "conf": conf, "ms_per_image": round((time.time() - started) / max(1, len(files)) * 1000, 1),
        "precision": round(total["tp"] / max(1, total["tp"] + total["fp"]), 3),
        "recall": round(total["tp"] / max(1, total["tp"] + total["fn"]), 3),
        "classes": stats,
    }


if __name__ == "__main__":
    threshold = float(sys.argv[5]) if len(sys.argv) > 5 else 0.25
    report = evaluate(sys.argv[1], sys.argv[2], sys.argv[3], load_names(sys.argv[4]), threshold)
    if len(sys.argv) > 6:
        json.dump(report, open(sys.argv[6], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"кадров {report['images']}, порог {report['conf']}, точность {report['precision']}, полнота {report['recall']}, "
          f"{report['ms_per_image']} мс на кадр")
    for name, row in report["classes"].items():
        print(f"  {name:20s} верно {row['tp']:4d}  лишних {row['fp']:4d}  пропущено {row['fn']:4d}  "
              f"точность {row['precision']}  полнота {row['recall']}")
