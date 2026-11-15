"""Сравнение детекторов дефектов на отложенных снимках заказчика и на тестовом наборе из сети.

Запуск:
    python cv/compare.py <название> <папка_набора> <отчёт.json> <веса> [<ещё_веса> ...]

Если указано несколько файлов весов, их рамки объединяются, как это делает сервер с двумя моделями.
Считаются: точность и полнота рамок на отложенных снимках, доля дефектных снимков, на которых найден
хотя бы один дефект, те же показатели после имитации съёмки с монитора, доля найденных дефектных
снимков и доля ложных тревог на тестовом наборе data/web_testset. Обучение на этих снимках не ведётся.
"""

import csv
import glob
import json
import os
import sys
import time

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from evaluate import iou, load_names, read_truth

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DEFECTS = ("corrosion", "leak", "terminal_box_burnt", "damage", "coupling_no_guard")
WEB_EXPECTED = {
    "corrosion": "corrosion",
    "leak": "leak",
    "burnt_electrical": "terminal_box_burnt",
    "insulation_damage": "damage",
    "crack": "damage",
}
WEB_CLEAN = ("equipment_ok", "gauge", "nameplate")
LEVELS = (0.25, 0.5)


def predict(models: list, frame: np.ndarray, conf: float = 0.25) -> list[tuple]:
    """Возвращает рамки дефектов всех моделей как (класс, рамка в пикселях, уверенность)."""
    rows = []
    for model in models:
        result = model(frame, conf=conf)
        result = result[0] if isinstance(result, (list, tuple)) else result
        names = getattr(result, "names", None) or getattr(model, "names", {})
        for box, cls, score in zip(result.boxes.xyxy, result.boxes.cls, result.boxes.conf):
            name = names[int(cls)]
            if name in DEFECTS:
                rows.append((name, tuple(float(v) for v in box), float(score)))
    return sorted(rows, key=lambda row: -row[2])


def match_boxes(predicted: list[tuple], truth: list[tuple], stats: dict) -> None:
    """Сопоставляет рамки с разметкой по классу и пересечению не меньше половины и пополняет счётчики."""
    used = set()
    for name, box, _ in predicted:
        best, best_iou = None, 0.5
        for index, (t_name, t_box) in enumerate(truth):
            value = iou(box, t_box) if index not in used and t_name == name else 0.0
            if value >= best_iou:
                best, best_iou = index, value
        row = stats.setdefault(name, {"tp": 0, "fp": 0, "fn": 0})
        if best is None:
            row["fp"] += 1
        else:
            used.add(best)
            row["tp"] += 1
    for index, (t_name, _) in enumerate(truth):
        if index not in used:
            stats.setdefault(t_name, {"tp": 0, "fp": 0, "fn": 0})["fn"] += 1


def labelled_split(models: list, root: str, split: str, names: list[str]) -> dict:
    """Считает показатели на размеченной выборке для каждого порога уверенности."""
    files = sorted(glob.glob(os.path.join(root, "images", split, "*.jpg")))
    report = {"images": len(files)}
    cache = []
    for path in files:
        frame = cv2.imread(path)
        height, width = frame.shape[:2]
        label = os.path.join(root, "labels", split, os.path.basename(path)[:-4] + ".txt")
        truth = [(names[cls], box) for cls, box in read_truth(label, width, height)]
        cache.append((os.path.basename(path), truth, predict(models, frame, min(LEVELS))))
    for level in LEVELS:
        stats, found, right, missed = {}, 0, 0, []
        for file, truth, predicted in cache:
            kept = [row for row in predicted if row[2] >= level]
            match_boxes(kept, truth, stats)
            wanted = {name for name, _ in truth}
            found += bool(kept)
            right += bool(wanted & {name for name, _, _ in kept})
            if not kept:
                missed.append(file)
        tp, fp, fn = (sum(row[key] for row in stats.values()) for key in ("tp", "fp", "fn"))
        report[f"conf_{level}"] = {
            "box_precision": round(tp / (tp + fp), 3) if tp + fp else None,
            "box_recall": round(tp / (tp + fn), 3) if tp + fn else None,
            "image_defect_found": round(found / max(1, len(cache)), 3),
            "image_right_class_found": round(right / max(1, len(cache)), 3),
            "images_without_any_detection": missed,
            "classes": stats,
        }
    return report


def web_split(models: list) -> dict | None:
    """Считает на тестовом наборе из сети долю найденных дефектных снимков и долю ложных тревог."""
    folder = os.path.join(ROOT, "data", "web_testset")
    manifest = os.path.join(folder, "manifest.csv")
    if not os.path.exists(manifest):
        return None
    cache = []
    for row in csv.DictReader(open(manifest, encoding="utf-8")):
        path = os.path.join(folder, row["file"])
        if os.path.exists(path):
            frame = cv2.imdecode(np.fromfile(path, np.uint8), cv2.IMREAD_COLOR)
            cache.append((row["class"], predict(models, frame, min(LEVELS))))
    report = {"images": len(cache)}
    for level in LEVELS:
        groups = {}
        for kind, predicted in cache:
            kept = {name for name, _, score in predicted if score >= level}
            row = groups.setdefault(kind, {"images": 0, "any_defect": 0, "right_class": 0})
            row["images"] += 1
            row["any_defect"] += bool(kept)
            row["right_class"] += WEB_EXPECTED.get(kind) in kept
        defective = [row for kind, row in groups.items() if kind in WEB_EXPECTED]
        clean = [row for kind, row in groups.items() if kind in WEB_CLEAN]
        total, alarms = sum(row["images"] for row in defective), sum(row["images"] for row in clean)
        report[f"conf_{level}"] = {
            "defective_images": total,
            "image_recall_any_defect": round(sum(row["any_defect"] for row in defective) / max(1, total), 3),
            "image_recall_right_class": round(sum(row["right_class"] for row in defective) / max(1, total), 3),
            "clean_images": alarms,
            "false_alarm_rate": round(sum(row["any_defect"] for row in clean) / max(1, alarms), 3),
            "groups": groups,
        }
    return report


def main() -> None:
    """Загружает модели, считает все показатели и сохраняет отчёт."""
    title, root, out, weights = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    from libreyolo import LibreYOLO

    models = [LibreYOLO(path) for path in weights]
    names = load_names(os.path.join(root, "data.yaml"))
    started = time.time()
    report = {
        "name": title,
        "weights": weights,
        "holdout": labelled_split(models, root, "holdout", names),
        "holdout_screen": labelled_split(models, root, "holdout_screen", names),
        "web_testset": web_split(models),
    }
    report["seconds"] = round(time.time() - started, 1)
    json.dump(report, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for part in ("holdout", "holdout_screen"):
        row = report[part]["conf_0.25"]
        print(
            f"{title} {part}: кадров {report[part]['images']}, точность рамок {row['box_precision']}, "
            f"полнота рамок {row['box_recall']}, дефект найден на {row['image_defect_found']} снимков"
        )
    if report["web_testset"]:
        row = report["web_testset"]["conf_0.25"]
        print(
            f"{title} web: дефектных {row['defective_images']}, найдено {row['image_recall_any_defect']}, "
            f"верный класс {row['image_recall_right_class']}, ложных тревог {row['false_alarm_rate']} из {row['clean_images']}"
        )


if __name__ == "__main__":
    main()
