"""Проверка детектора типа оборудования и выбор порогов по классам только на val с упором на точность.

Запуск:
    python cv/eval_equipment.py <название> <веса.onnx|.pt> [--data data/equipment_ds_v1] [--target 0.9]
                                [--min-area 0.01] [--clean data/open/clean-indoor/images]

Порог класса - наименьший порог из сетки (от 0,5), при котором точность рамок класса на val не ниже target;
рамки меньше min_area кадра отбрасываются всегда. Если в наборе есть часть negtest (кадры без оборудования,
не участвовавшие в обучении), её чётные кадры добавляются к val при выборе порога (ложная рамка на них
снижает точность класса), а на нечётных считается доля кадров с ложной рамкой. Если ни один порог не даёт
нужной точности, класс считается ненадёжным (порог None) и в поставку не идёт. На части test (реальные снимки,
не участвовавшие в обучении и выборе порогов) считаются точность, полнота и AP50 по классам при общем пороге 0.25
и при выбранных порогах; на чистых снимках помещений (клавиатуры, мониторы, стены) - доля снимков с ложной рамкой.
Отчёт runs/reports/<название>.json.
"""

import argparse
import glob
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_equipment import EQUIPMENT_CLASSES
from protocol import ROOT, average_precision, match, read_frame, read_truth

GRID = tuple(round(0.5 + 0.05 * step, 2) for step in range(9))


def records_for(model, folder: str, split: str) -> list[dict]:
    """Прогоняет модель по части набора и возвращает записи: разметка, рамки модели и размер кадра."""
    records = []
    for path in sorted(glob.glob(os.path.join(folder, "images", split, "*"))):
        frame = read_frame(path)
        if frame is None:
            continue
        height, width = frame.shape[:2]
        stem = os.path.splitext(os.path.basename(path))[0]
        truth = [
            (EQUIPMENT_CLASSES[cls], box)
            for cls, box in read_truth(os.path.join(folder, "labels", split, stem + ".txt"), width, height)
        ]
        result = model(frame, conf=0.05)
        result = result[0] if isinstance(result, (list, tuple)) else result
        names = result.names if isinstance(getattr(result, "names", None), dict) else dict(enumerate(EQUIPMENT_CLASSES))
        predicted = [
            (names[int(c)], tuple(float(v) for v in box), float(s))
            for box, c, s in zip(result.boxes.xyxy, result.boxes.cls, result.boxes.conf)
        ]
        records.append({"file": os.path.basename(path), "truth": truth, "predicted": predicted, "size": (width, height)})
    return records


def filtered(record: dict, thresholds: dict, min_area: float) -> list[tuple]:
    """Оставляет рамки не ниже порога своего класса и не меньше min_area кадра; класс с порогом None убирается."""
    width, height = record["size"]
    out = []
    for name, box, score in record["predicted"]:
        limit = thresholds.get(name)
        area = (box[2] - box[0]) * (box[3] - box[1]) / float(width * height)
        if limit is not None and score >= limit and area >= min_area:
            out.append((name, box, score))
    return out


def class_stats(records: list[dict], thresholds: dict, min_area: float) -> dict:
    """Считает по классам верные, лишние и пропущенные рамки, точность, полноту и AP50."""
    stats = {name: {"tp": 0, "fp": 0, "fn": 0, "scored": []} for name in EQUIPMENT_CLASSES}
    for record in records:
        kept = filtered(record, thresholds, min_area)
        rows = match(kept, record["truth"])
        for name, score, ok in rows:
            stats[name]["tp" if ok else "fp"] += 1
            stats[name]["scored"].append((score, ok))
        for name, _ in record["truth"]:
            stats[name]["fn"] += 1
        for name, _, ok in rows:
            stats[name]["fn"] -= ok
    out = {}
    for name, row in stats.items():
        positives = row["tp"] + row["fn"]
        found = row["tp"] + row["fp"]
        out[name] = {
            "tp": row["tp"],
            "fp": row["fp"],
            "fn": row["fn"],
            "precision": round(row["tp"] / found, 3) if found else None,
            "recall": round(row["tp"] / positives, 3) if positives else None,
            "ap50": average_precision(row["scored"], positives) if positives else None,
        }
    return out


def pick_thresholds(records: list[dict], target: float, min_area: float) -> dict:
    """Выбирает для каждого класса наименьший порог сетки с точностью на val не ниже target, иначе None."""
    chosen = {}
    for name in EQUIPMENT_CLASSES:
        chosen[name] = None
        for level in GRID:
            row = class_stats(records, {name: level}, min_area)[name]
            if row["tp"] and row["precision"] is not None and row["precision"] >= target:
                chosen[name] = level
                break
    return chosen


def false_alarms(records: list[dict], thresholds: dict, min_area: float) -> dict:
    """Считает кадры без оборудования, на которых после порогов осталась рамка, и число таких кадров по классам."""
    by_class, hit = {}, 0
    for record in records:
        names = {name for name, _, _ in filtered(record, thresholds, min_area)}
        hit += bool(names)
        for name in names:
            by_class[name] = by_class.get(name, 0) + 1
    return {
        "images": len(records),
        "with_alarm": hit,
        "rate": round(hit / len(records), 3) if records else None,
        "by_class": by_class,
    }


def clean_alarms(model, folder: str, thresholds: dict, min_area: float) -> dict:
    """Считает чистые снимки, на которых после порогов осталась хотя бы одна рамка оборудования."""
    files = sorted(glob.glob(os.path.join(folder, "*.jpg")) + glob.glob(os.path.join(folder, "*.png")))
    hits = {}
    for path in files:
        record = records_for_frame(model, path)
        names = sorted({name for name, _, _ in filtered(record, thresholds, min_area)})
        if names:
            hits[os.path.basename(path)] = names
    return {"images": len(files), "with_alarm": len(hits), "alarms": hits}


def records_for_frame(model, path: str) -> dict:
    """Возвращает запись одного снимка без разметки."""
    frame = read_frame(path)
    height, width = frame.shape[:2]
    result = model(frame, conf=0.05)
    result = result[0] if isinstance(result, (list, tuple)) else result
    names = result.names if isinstance(getattr(result, "names", None), dict) else dict(enumerate(EQUIPMENT_CLASSES))
    predicted = [
        (names[int(c)], tuple(float(v) for v in box), float(s))
        for box, c, s in zip(result.boxes.xyxy, result.boxes.cls, result.boxes.conf)
    ]
    return {"truth": [], "predicted": predicted, "size": (width, height)}


def main() -> None:
    """Выбирает пороги на val, считает показатели на test и чистых снимках и пишет отчёт."""
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("weights")
    parser.add_argument("--data", default=os.path.join(ROOT, "data", "equipment_ds_v1"))
    parser.add_argument("--target", type=float, default=0.9)
    parser.add_argument("--min-area", type=float, default=0.01)
    parser.add_argument("--clean", default=os.path.join(ROOT, "data", "open", "clean-indoor", "images"))
    args = parser.parse_args()
    from libreyolo import LibreYOLO

    model = LibreYOLO(args.weights)
    val = records_for(model, args.data, "val")
    test = records_for(model, args.data, "test")
    negatives = records_for(model, args.data, "negtest")
    neg_val, neg_test = negatives[0::2], negatives[1::2]
    thresholds = pick_thresholds(val + neg_val, args.target, args.min_area)
    flat = {name: 0.25 for name in EQUIPMENT_CLASSES}
    report = {
        "name": args.name,
        "weights": args.weights,
        "date": time.strftime("%Y-%m-%d %H:%M"),
        "target_precision": args.target,
        "min_area": args.min_area,
        "thresholds": thresholds,
        "val_tuned": class_stats(val, thresholds, args.min_area),
        "test_conf_0.25": class_stats(test, flat, 0.0),
        "test_tuned": class_stats(test, thresholds, args.min_area),
    }
    if negatives:
        report["negatives_conf_0.25"] = false_alarms(neg_test, flat, 0.0)
        report["negatives_tuned"] = false_alarms(neg_test, thresholds, args.min_area)
    if os.path.isdir(args.clean):
        report["clean_conf_0.25"] = clean_alarms(model, args.clean, flat, 0.0)
        report["clean_tuned"] = clean_alarms(model, args.clean, thresholds, args.min_area)
    out = os.path.join(ROOT, "runs", "reports", f"{args.name}.json")
    json.dump(report, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("пороги (val):", thresholds)
    for key in ("test_conf_0.25", "test_tuned"):
        print(key, {name: (row["precision"], row["recall"], row["ap50"]) for name, row in report[key].items()})
    for key in ("clean_conf_0.25", "clean_tuned"):
        if key in report:
            print(key, report[key]["with_alarm"], "из", report[key]["images"], report[key]["alarms"])
    for key in ("negatives_conf_0.25", "negatives_tuned"):
        if key in report:
            print(key, report[key])
    print("отчёт:", out)


if __name__ == "__main__":
    main()
