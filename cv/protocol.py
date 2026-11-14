"""Единый протокол проверки детекторов дефектов и узлов на зафиксированных тестовых наборах.

Запуск:
    python cv/protocol.py <название> <веса> [<ещё_веса> ...] [--sets holdout,holdout_screen,web,val]
                          [--mode defects|parts] [--out runs/reports/<название>.json]

Веса - файлы .onnx или .pt, которые читает LibreYOLO. Если весов несколько, их рамки объединяются,
как это делает сервер с двумя моделями. Модель запускается один раз с низким порогом FLOOR, затем
показатели считаются для каждого порога из LEVELS.

Наборы (только проверка, на них ничего не обучается и не подбирается):
    holdout - 8 отложенных снимков заказчика из первой сборки data/open/defects_ds;
    holdout_screen - их 40 копий с имитацией съёмки с монитора (не настоящая съёмка экрана);
    web - 90 снимков data/web_testset, только показатели по снимкам, разбивка по группам manifest.csv;
    val - проверочная часть data/open/defects_ds_v3, по ней разрешено выбирать эпоху и порог;
    parts - тестовая часть data/open/parts_real для модели узлов (режим parts);
    blender - тестовая часть data/blender/ds (70 кадров макета, разметка полная) для модели узлов.

Показатели: по каждому классу верные, лишние и пропущенные рамки, точность, полнота и AP50 (рамка верна,
если совпал класс и пересечение не меньше половины объединения); доля дефектных снимков, где найден хотя
бы один дефект и где найден дефект нужного класса; доля ложных тревог на чистых снимках. В наборе parts
разметка неполная, поэтому рамки класса, не размеченного на данном снимке, не считаются лишними.
"""
import argparse
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
DEFECT_CLASSES = ("corrosion", "leak", "terminal_box_burnt", "damage")
DEFECT_NAMES = DEFECT_CLASSES + ("coupling_no_guard",)
PART_CLASSES = ("motor", "pump_casing", "flange", "coupling_guard", "coupling_no_guard", "terminal_box",
                "terminal_box_burnt", "nameplate", "gauge", "leak", "corrosion")
LEVELS = (0.15, 0.25, 0.35, 0.5)
FLOOR = 0.05
WEB_EXPECTED = {"corrosion": "corrosion", "leak": "leak", "burnt_electrical": "terminal_box_burnt",
                "insulation_damage": "damage", "crack": "damage"}
WEB_CLEAN = ("equipment_ok", "gauge", "nameplate")
SET_PATHS = {
    "holdout": ("data/open/defects_ds", "holdout"),
    "holdout_screen": ("data/open/defects_ds", "holdout_screen"),
    "val": ("data/open/defects_ds_v3", "val"),
    "parts": ("data/open/parts_real", "test"),
    "blender": ("data/blender/ds", "test"),
}
SET_NOTES = {
    "holdout": "8 отложенных снимков заказчика, в обучении не участвовали",
    "holdout_screen": "40 копий отложенных снимков с имитацией съёмки с монитора; настоящая съёмка экрана не замерялась",
    "web": "90 снимков из сети, разметка только по снимку (группа в manifest.csv)",
    "val": "проверочная часть defects_ds_v3, по ней можно выбирать эпоху и порог",
    "parts": "тестовая часть parts_real, разметка неполная по классам",
    "blender": "тестовая часть кадров макета из Blender, в обучении не участвовала",
}


def match(predicted: list[tuple], truth: list[tuple], labelled: set | None = None) -> list[tuple]:
    """Сопоставляет рамки одного снимка с разметкой жадно по убыванию уверенности.

    predicted - (класс, рамка, уверенность), truth - (класс, рамка). Возвращает (класс, уверенность,
    верна ли рамка) для каждой учтённой рамки. При заданном labelled рамки других классов пропускаются.
    """
    used, rows = set(), []
    for name, box, score in sorted(predicted, key=lambda row: -row[2]):
        if labelled is not None and name not in labelled:
            continue
        best, best_iou = None, 0.5
        for index, (t_name, t_box) in enumerate(truth):
            value = iou(box, t_box) if index not in used and t_name == name else 0.0
            if value >= best_iou:
                best, best_iou = index, value
        if best is not None:
            used.add(best)
        rows.append((name, score, best is not None))
    return rows


def average_precision(scored: list[tuple], positives: int) -> float | None:
    """Считает AP по всем точкам огибающей точности для списка (уверенность, верна ли рамка)."""
    if positives == 0:
        return None
    ordered = sorted(scored, key=lambda row: -row[0])
    hits = np.array([1.0 if ok else 0.0 for _, ok in ordered])
    if hits.size == 0:
        return 0.0
    tp = np.cumsum(hits)
    recall = np.concatenate(([0.0], tp / positives, [tp[-1] / positives]))
    precision = np.concatenate(([1.0], tp / np.arange(1, hits.size + 1), [0.0]))
    for index in range(precision.size - 2, -1, -1):
        precision[index] = max(precision[index], precision[index + 1])
    return round(float(np.sum((recall[1:] - recall[:-1]) * precision[1:])), 3)


def ratio(top: int, bottom: int) -> float | None:
    """Возвращает долю с тремя знаками или None при пустом знаменателе."""
    return round(top / bottom, 3) if bottom else None


def summarize(records: list[dict], classes: tuple, levels: tuple = LEVELS) -> dict:
    """Сводит показатели набора для каждого порога.

    Запись снимка: truth, predicted, labelled (или None) и group (для набора web). Снимок дефектный,
    если на нём есть рамка дефекта или его группа из WEB_EXPECTED; чистый, если группа из WEB_CLEAN
    или снимок размечен рамками полностью и рамок нет.
    """
    matched = [match(row["predicted"], row["truth"], row.get("labelled")) for row in records]
    positives = {}
    for row in records:
        for name, _ in row["truth"]:
            positives[name] = positives.get(name, 0) + 1
    names = sorted(set(positives) | {name for rows in matched for name, _, _ in rows},
                   key=lambda name: (classes.index(name) if name in classes else len(classes), name))
    report = {"images": len(records), "boxes": positives,
              "ap50": {name: average_precision([(s, ok) for rows in matched for n, s, ok in rows if n == name],
                                               positives.get(name, 0)) for name in names}}
    values = [value for name, value in report["ap50"].items() if value is not None]
    report["map50"] = round(sum(values) / len(values), 3) if values else None
    for level in levels:
        stats = {name: {"tp": 0, "fp": 0, "fn": 0} for name in names}
        defective = found = right = clean = alarms = 0
        groups = {}
        for row, rows in zip(records, matched):
            kept = [(name, ok) for name, score, ok in rows if score >= level]
            for name, ok in kept:
                stats[name]["tp" if ok else "fp"] += 1
            for t_name, _ in row["truth"]:
                stats[t_name]["fn"] += 1
            for name, ok in kept:
                stats[name]["fn"] -= ok
            alarm_names = {name for name, _, score in row["predicted"] if score >= level and name in DEFECT_NAMES}
            wanted = {name for name, _ in row["truth"] if name in DEFECT_NAMES}
            if row.get("group") in WEB_EXPECTED:
                wanted = {WEB_EXPECTED[row["group"]]}
            if wanted:
                defective += 1
                found += bool(alarm_names)
                right += bool(wanted & alarm_names)
            elif row.get("group") in WEB_CLEAN or (row.get("group") is None and row.get("labelled") is None):
                clean += 1
                alarms += bool(alarm_names)
            if row.get("group") is not None:
                group = groups.setdefault(row["group"], {"images": 0, "any_defect": 0, "right_class": 0})
                group["images"] += 1
                group["any_defect"] += bool(alarm_names)
                group["right_class"] += bool(wanted & alarm_names)
        for row in stats.values():
            row["precision"] = ratio(row["tp"], row["tp"] + row["fp"])
            row["recall"] = ratio(row["tp"], row["tp"] + row["fn"])
        tp, fp, fn = (sum(row[key] for row in stats.values()) for key in ("tp", "fp", "fn"))
        entry = {"box_precision": ratio(tp, tp + fp), "box_recall": ratio(tp, tp + fn),
                 "defective_images": defective, "image_defect_found": ratio(found, defective),
                 "image_right_class_found": ratio(right, defective), "clean_images": clean,
                 "false_alarm_rate": ratio(alarms, clean), "classes": stats}
        if groups:
            entry["groups"] = groups
        report[f"conf_{level}"] = entry
    return report


def predict(models: list, frame: np.ndarray, keep: tuple, floor: float = FLOOR) -> list[tuple]:
    """Возвращает рамки всех моделей как (класс, рамка в пикселях, уверенность) для классов из keep."""
    rows = []
    for model in models:
        result = model(frame, conf=floor)
        result = result[0] if isinstance(result, (list, tuple)) else result
        names = getattr(result, "names", None) or getattr(model, "names", {})
        for box, cls, score in zip(result.boxes.xyxy, result.boxes.cls, result.boxes.conf):
            index = int(cls)
            name = names.get(index) if isinstance(names, dict) else (names[index] if index < len(names) else None)
            if name in keep:
                rows.append((name, tuple(float(v) for v in box), float(score)))
    return rows


def read_frame(path: str) -> np.ndarray:
    """Читает кадр по пути с кириллицей."""
    return cv2.imdecode(np.fromfile(path, np.uint8), cv2.IMREAD_COLOR)


def labelled_records(models: list, folder: str, split: str, keep: tuple, partial: dict | None = None) -> list[dict]:
    """Прогоняет модели по размеченной части набора YOLO и возвращает записи снимков."""
    names = load_names(os.path.join(folder, "data.yaml"))
    records = []
    for path in sorted(glob.glob(os.path.join(folder, "images", split, "*"))):
        frame = read_frame(path)
        if frame is None:
            continue
        height, width = frame.shape[:2]
        stem = os.path.splitext(os.path.basename(path))[0]
        truth = [(names[cls], box) for cls, box in read_truth(os.path.join(folder, "labels", split, stem + ".txt"), width, height)]
        record = {"file": os.path.basename(path), "truth": [row for row in truth if row[0] in keep],
                  "predicted": predict(models, frame, keep), "labelled": None, "group": None}
        if partial is not None:
            record["labelled"] = partial.get(f"images/{split}/{os.path.basename(path)}", set())
        records.append(record)
    return records


def web_records(models: list, keep: tuple) -> list[dict]:
    """Прогоняет модели по data/web_testset; рамок нет, есть только группа снимка."""
    folder = os.path.join(ROOT, "data", "web_testset")
    records = []
    for row in csv.DictReader(open(os.path.join(folder, "manifest.csv"), encoding="utf-8")):
        path = os.path.join(folder, row["file"])
        frame = read_frame(path) if os.path.exists(path) else None
        if frame is not None:
            records.append({"file": row["file"], "truth": [], "predicted": predict(models, frame, keep),
                            "labelled": set(), "group": row["class"]})
    return records


def parts_labelled() -> dict:
    """Читает из описи parts_real, какие классы размечены на каждом снимке."""
    path = os.path.join(ROOT, "data", "open", "parts_real", "manifest.csv")
    return {row["file"]: set(filter(None, row["classes"].split(";")))
            for row in csv.DictReader(open(path, encoding="utf-8"))}


def run(models: list, sets: list[str], mode: str) -> dict:
    """Считает показатели на перечисленных наборах и возвращает отчёт по каждому."""
    keep = DEFECT_NAMES if mode == "defects" else PART_CLASSES
    classes = DEFECT_CLASSES if mode == "defects" else PART_CLASSES
    out = {}
    for name in sets:
        started = time.time()
        if name == "web":
            records = web_records(models, keep)
        else:
            folder, split = SET_PATHS[name]
            folder = os.path.join(ROOT, folder)
            if not os.path.isdir(os.path.join(folder, "images", split)):
                out[name] = {"missing": f"{folder}/images/{split}"}
                continue
            records = labelled_records(models, folder, split, keep, parts_labelled() if name == "parts" else None)
        report = summarize(records, classes)
        report["note"] = SET_NOTES[name]
        report["seconds"] = round(time.time() - started, 1)
        out[name] = report
    return out


def main() -> None:
    """Загружает модели, считает показатели и сохраняет отчёт в runs/reports."""
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("weights", nargs="+")
    parser.add_argument("--sets", default=None)
    parser.add_argument("--mode", choices=("defects", "parts"), default="defects")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()
    sets = args.sets.split(",") if args.sets else (["parts"] if args.mode == "parts" else ["holdout", "holdout_screen", "web", "val"])
    from libreyolo import LibreYOLO
    models = [LibreYOLO(path) for path in args.weights]
    report = {"name": args.name, "weights": args.weights, "mode": args.mode, "iou": 0.5, "floor": FLOOR,
              "levels": list(LEVELS), "date": time.strftime("%Y-%m-%d"), "sets": run(models, sets, args.mode)}
    out = args.out or os.path.join(ROOT, "runs", "reports", f"{args.name}.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(report, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for name, part in report["sets"].items():
        for level in LEVELS:
            row = part.get(f"conf_{level}")
            if row:
                print(f"{args.name} {name} порог {level}: рамки P {row['box_precision']} R {row['box_recall']}, "
                      f"дефект найден {row['image_defect_found']}, ложные тревоги {row['false_alarm_rate']}, mAP50 {part['map50']}")
    print("отчёт:", out)


if __name__ == "__main__":
    main()
