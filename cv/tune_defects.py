"""Проверка вариантов вывода модели дефектов и выбор порогов по классам только на проверочной части.

Запуск:
    python cv/tune_defects.py <название> <веса> [--flip] [--tiles 2] [--sets val,holdout,holdout_screen,web]
                              [--rule constrained|fbeta] [--min-found 0.793] [--min-recall 0.138] [--beta 2]
                              [--thresholds-from <отчёт.json>]

Модель оборачивается в cv/infer_options.Options (отражение кадра, разбиение 2x2 плюс целый кадр) и
прогоняется по наборам cv/protocol.py один раз с низким порогом; записи сохраняются в
runs/reports/cache/<название>_<набор>.pkl. Пороги по классам выбираются только на части val:
    constrained (по умолчанию) - пороги поднимаются, пока доля найденных дефектных снимков val не ниже
    min_found и полнота рамок val не ниже min_recall; по умолчанию это показатели поставленной модели
    defects.onnx на val при пороге 0.25, то есть полнота не хуже прежней, а лишних рамок меньше;
    fbeta - для каждого класса порог с наибольшим F-beta рамок (beta=2: полнота вдвое важнее точности).
Отложенные снимки заказчика, их копии и набор из сети в выборе порогов не участвуют, на них только
считаются показатели. С --thresholds-from пороги берутся из прежнего отчёта (тоже выбранные на val).
Отчёт runs/reports/<название>.json: показатели при общих порогах (как в cv/protocol.py) и в разделе
per_class при выбранных порогах по классам.
"""
import argparse
import json
import os
import pickle
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from infer_options import Options, remap_records
from protocol import (DEFECT_CLASSES, DEFECT_NAMES, FLOOR, LEVELS, ROOT, SET_NOTES, SET_PATHS, labelled_records,
                      match, summarize, web_records)

GRID = tuple(round(0.05 + 0.025 * step, 3) for step in range(27))


def records_for(model, name: str, cache: str) -> list[dict]:
    """Возвращает записи набора из кэша или прогоняет модель и сохраняет их."""
    if os.path.exists(cache):
        return pickle.load(open(cache, "rb"))
    if name == "web":
        records = web_records([model], DEFECT_NAMES)
    else:
        folder, split = SET_PATHS[name]
        records = labelled_records([model], os.path.join(ROOT, folder), split, DEFECT_NAMES)
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    pickle.dump(records, open(cache, "wb"))
    return records


def choose_thresholds(records: list[dict], beta: float) -> dict:
    """Выбирает для каждого класса порог с наибольшим F-beta рамок на переданных записях (только val)."""
    matched = [match(row["predicted"], row["truth"]) for row in records]
    chosen = {}
    for cls in DEFECT_CLASSES:
        positives = sum(1 for row in records for name, _ in row["truth"] if name == cls)
        if positives == 0:
            continue
        best = (-1.0, 0.25, 0.0, 0.0)
        for level in GRID:
            tp = sum(1 for rows in matched for name, score, ok in rows if name == cls and score >= level and ok)
            fp = sum(1 for rows in matched for name, score, ok in rows if name == cls and score >= level and not ok)
            precision, recall = tp / max(tp + fp, 1), tp / positives
            score = (1 + beta ** 2) * precision * recall / max(beta ** 2 * precision + recall, 1e-9)
            if score > best[0] + 1e-9:
                best = (score, level, precision, recall)
        chosen[cls] = {"threshold": best[1], "f_beta": round(best[0], 3), "precision": round(best[2], 3),
                       "recall": round(best[3], 3)}
    return chosen


def val_counts(prepared: list[tuple], thresholds: dict) -> tuple:
    """Считает на подготовленных записях val верные и лишние рамки, найденные дефектные снимки и тревоги."""
    tp = fp = found = alarms = 0
    for rows, wanted, clean in prepared:
        kept = [(name, ok) for name, score, ok in rows if score >= thresholds[name]]
        tp += sum(ok for _, ok in kept)
        fp += sum(not ok for _, ok in kept)
        if wanted:
            found += bool(kept)
        elif clean:
            alarms += bool(kept)
    return tp, fp, found, alarms


def constrained_thresholds(records: list[dict], min_found: float, min_recall: float) -> dict:
    """Поднимает пороги классов жадно, пока на val доля найденных дефектных снимков и полнота рамок не ниже заданных.

    На каждом шаге выбирается повышение порога одного класса, которое сильнее всего уменьшает число лишних
    рамок и ложных тревог на чистых снимках; шаги прекращаются, когда любое повышение нарушает ограничения.
    """
    prepared = []
    positives = 0
    for row in records:
        rows = [(name, score, ok) for name, score, ok in match(row["predicted"], row["truth"]) if name in DEFECT_CLASSES]
        wanted = any(name in DEFECT_CLASSES for name, _ in row["truth"])
        positives += sum(1 for name, _ in row["truth"] if name in DEFECT_CLASSES)
        prepared.append((rows, wanted, row.get("labelled") is None and not wanted))
    defective = sum(1 for _, wanted, _ in prepared if wanted)
    current = {cls: GRID[0] for cls in DEFECT_CLASSES}
    while True:
        tp, fp, found, alarms = val_counts(prepared, current)
        best = None
        for cls in DEFECT_CLASSES:
            higher = [level for level in GRID if level > current[cls]]
            if not higher:
                continue
            trial = dict(current, **{cls: higher[0]})
            t_tp, t_fp, t_found, t_alarms = val_counts(prepared, trial)
            if t_found / defective < min_found or t_tp / positives < min_recall:
                continue
            gain = (fp - t_fp) + 10 * (alarms - t_alarms) - 5 * (tp - t_tp)
            if best is None or gain > best[0]:
                best = (gain, trial)
        if best is None:
            break
        current = best[1]
    tp, fp, found, alarms = val_counts(prepared, current)
    return {cls: {"threshold": current[cls], "val_box_recall_all": round(tp / positives, 3),
                  "val_image_found": round(found / defective, 3), "val_false_boxes": fp} for cls in DEFECT_CLASSES}


def main() -> None:
    """Прогоняет наборы, выбирает пороги на val и сохраняет отчёт."""
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("weights")
    parser.add_argument("--flip", action="store_true")
    parser.add_argument("--tiles", type=int, default=0)
    parser.add_argument("--sets", default="val,holdout,holdout_screen,web")
    parser.add_argument("--beta", type=float, default=2.0)
    parser.add_argument("--thresholds-from", default=None)
    parser.add_argument("--rule", choices=("fbeta", "constrained"), default="constrained")
    parser.add_argument("--min-found", type=float, default=0.793)
    parser.add_argument("--min-recall", type=float, default=0.138)
    args = parser.parse_args()
    from libreyolo import LibreYOLO
    model = Options(LibreYOLO(args.weights), flip=args.flip, tiles=args.tiles)
    sets = args.sets.split(",")
    cache = os.path.join(ROOT, "runs", "reports", "cache")
    records = {}
    for name in sets:
        started = time.time()
        records[name] = records_for(model, name, os.path.join(cache, f"{args.name}_{name}.pkl"))
        print(name, len(records[name]), "снимков", round(time.time() - started, 1), "с", flush=True)
    if args.thresholds_from:
        chosen = json.load(open(args.thresholds_from, encoding="utf-8"))["thresholds"]
        source = args.thresholds_from
    elif args.rule == "fbeta":
        chosen = choose_thresholds(records["val"], args.beta)
        source = f"val, наибольший F-beta рамок, beta={args.beta}"
    else:
        chosen = constrained_thresholds(records["val"], args.min_found, args.min_recall)
        source = (f"val, наименьшее число лишних рамок и тревог при доле найденных дефектных снимков не ниже "
                  f"{args.min_found} и полноте рамок не ниже {args.min_recall}")
    thresholds = {cls: row["threshold"] for cls, row in chosen.items()}
    report = {"name": args.name, "weights": args.weights, "flip": args.flip, "tiles": args.tiles, "iou": 0.5,
              "floor": FLOOR, "levels": list(LEVELS), "beta": args.beta, "date": time.strftime("%Y-%m-%d"),
              "thresholds": chosen, "thresholds_source": source, "sets": {}}
    for name in sets:
        part = summarize(records[name], DEFECT_CLASSES)
        part["note"] = SET_NOTES[name]
        part["per_class"] = summarize(remap_records(records[name], thresholds), DEFECT_CLASSES, levels=(0.25,))["conf_0.25"]
        report["sets"][name] = part
    out = os.path.join(ROOT, "runs", "reports", f"{args.name}.json")
    json.dump(report, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("пороги по классам (выбраны на val):", thresholds)
    for name in sets:
        part = report["sets"][name]
        for key in [f"conf_{level}" for level in LEVELS] + ["per_class"]:
            row = part[key]
            print(f"{name} {key}: P {row['box_precision']} R {row['box_recall']} найден {row['image_defect_found']} "
                  f"класс {row['image_right_class_found']} ложные {row['false_alarm_rate']} mAP50 {part['map50']}")
    print("отчёт:", out)


if __name__ == "__main__":
    main()
