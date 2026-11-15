"""Проверка набора моделей так, как его запускает сервер: пороги из models.json и объединение рамок.

Запуск:
    python cv/delivered.py <название> <описание_models.json> [--models <папка с файлами ONNX>]
                           [--sets holdout,holdout_screen,web,val,parts,blender] [--mode defects|parts]

Каждая модель из описания прогоняется по наборам cv/protocol.py один раз с низким порогом FLOOR, сырые
рамки сохраняются в runs/reports/cache/raw_<начало SHA-1 файла>_<набор>.pkl. Затем к ним применяются пороги
модели и классов (server.recognition.model_thresholds) и объединение рамок разных моделей
(server.recognition.merge_boxes), то есть те же правила, что на сервере. Показатели считает
protocol.summarize; уровень conf_served - ровно то, что вернул бы сервер, остальные уровни - общий порог
поверх порогов из описания. Отложенные снимки заказчика, их копии и набор из сети только проверяются:
выбирать пороги по ним нельзя, для выбора служит часть val.
"""

import argparse
import hashlib
import json
import os
import pickle
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from protocol import (
    DEFECT_CLASSES,
    DEFECT_NAMES,
    FLOOR,
    LEVELS,
    PART_CLASSES,
    ROOT,
    SET_NOTES,
    SET_PATHS,
    labelled_records,
    parts_labelled,
    summarize,
    web_records,
)
from server.recognition import merge_boxes, model_options, model_thresholds

CACHE = os.path.join(ROOT, "runs", "reports", "cache")


def cache_path(file: str, set_name: str, cache: str = CACHE) -> str:
    """Возвращает путь кэша сырых рамок модели по содержимому её файла: замена файла не смешивает кэши."""
    with open(file, "rb") as handle:
        digest = hashlib.sha1(handle.read()).hexdigest()[:16]
    return os.path.join(cache, f"raw_{digest}_{set_name}.pkl")


def raw_records(model, file: str, set_name: str, keep: tuple, cache: str = CACHE) -> list[dict] | None:
    """Возвращает записи снимков набора с сырыми рамками одной модели, читая их из кэша, если он есть."""
    path = cache_path(file, set_name, cache)
    if os.path.exists(path):
        with open(path, "rb") as handle:
            return pickle.load(handle)
    if set_name == "web":
        records = web_records([model], keep)
    else:
        folder, split = SET_PATHS[set_name]
        folder = os.path.join(ROOT, folder)
        if not os.path.isdir(os.path.join(folder, "images", split)):
            return None
        records = labelled_records([model], folder, split, keep, parts_labelled() if set_name == "parts" else None)
    os.makedirs(cache, exist_ok=True)
    with open(path, "wb") as handle:
        pickle.dump(records, handle)
    return records


def served(predicted_by_model: list[list[tuple]], entries: list[dict]) -> list[tuple]:
    """Применяет к сырым рамкам моделей пороги из их записей models.json и объединяет рамки, как сервер."""
    boxes = []
    for predicted, entry in zip(predicted_by_model, entries):
        default, classes = model_thresholds(entry)
        for name, (x1, y1, x2, y2), score in predicted:
            if score >= classes.get(name, default):
                boxes.append({"cls": name, "conf": score, "x1": x1, "y1": y1, "x2": x2, "y2": y2})
    return [(box["cls"], (box["x1"], box["y1"], box["x2"], box["y2"]), box["conf"]) for box in merge_boxes(boxes)]


def combine(per_model: list[list[dict]], entries: list[dict]) -> list[dict]:
    """Собирает записи снимков с рамками, которые вернул бы сервер для набора моделей."""
    combined = []
    for rows in zip(*per_model):
        record = dict(rows[0])
        record["predicted"] = served([row["predicted"] for row in rows], entries)
        combined.append(record)
    return combined


def evaluate(entries: list[dict], models_dir: str, sets: list[str], mode: str, loader=None) -> dict:
    """Считает показатели набора моделей на перечисленных наборах с порогами и объединением сервера.

    Модели-подсказки (hint в models.json, детектор типа оборудования) пропускаются: их классы переименованы и
    с рамками узлов и дефектов не объединяются, поэтому на показатели этих наборов они не влияют.
    """
    entries = [entry for entry in entries if not model_options(entry).get("hint")]
    keep = DEFECT_NAMES if mode == "defects" else PART_CLASSES
    classes = DEFECT_CLASSES if mode == "defects" else PART_CLASSES
    if loader is None:
        from libreyolo import LibreYOLO

        loader = LibreYOLO
    files = [os.path.join(models_dir, entry["file"]) for entry in entries]
    models = {}
    out = {}
    for set_name in sets:
        started = time.time()
        per_model = []
        for file in files:
            records = raw_records(None, file, set_name, keep) if os.path.exists(cache_path(file, set_name)) else None
            if records is None:
                models.setdefault(file, loader(file))
                records = raw_records(models[file], file, set_name, keep)
            per_model.append(records)
        if any(records is None for records in per_model):
            out[set_name] = {"missing": SET_PATHS.get(set_name)}
            continue
        floor = min(min([default, *thresholds.values()]) for default, thresholds in map(model_thresholds, entries))
        levels = tuple(sorted({round(floor, 3), *(level for level in LEVELS if level > floor)}))
        report = summarize(combine(per_model, entries), classes, levels)
        report["conf_served"] = report[f"conf_{levels[0]}"]
        report["note"] = SET_NOTES[set_name]
        report["seconds"] = round(time.time() - started, 1)
        out[set_name] = report
    return out


def main() -> None:
    """Читает описание моделей, считает показатели и сохраняет отчёт runs/reports/<название>.json."""
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("manifest")
    parser.add_argument("--models", default=None)
    parser.add_argument("--sets", default="holdout,holdout_screen,web,val")
    parser.add_argument("--mode", choices=("defects", "parts"), default="defects")
    args = parser.parse_args()
    entries = json.load(open(args.manifest, encoding="utf-8"))
    entries = entries.get("models", []) if isinstance(entries, dict) else entries
    models_dir = args.models or os.path.dirname(os.path.abspath(args.manifest))
    report = {
        "name": args.name,
        "manifest": args.manifest,
        "models": [entry["file"] for entry in entries],
        "thresholds": {entry["file"]: model_thresholds(entry) for entry in entries},
        "mode": args.mode,
        "iou": 0.5,
        "floor": FLOOR,
        "date": time.strftime("%Y-%m-%d"),
        "sets": evaluate(entries, models_dir, args.sets.split(","), args.mode),
    }
    out = os.path.join(ROOT, "runs", "reports", f"{args.name}.json")
    json.dump(report, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for set_name, part in report["sets"].items():
        row = part.get("conf_served")
        if row:
            print(
                f"{args.name} {set_name}: рамки P {row['box_precision']} R {row['box_recall']}, дефект найден "
                f"{row['image_defect_found']}, нужный класс {row['image_right_class_found']}, "
                f"ложные тревоги {row['false_alarm_rate']}, mAP50 {part['map50']}"
            )
    print("отчёт:", out)


if __name__ == "__main__":
    main()
