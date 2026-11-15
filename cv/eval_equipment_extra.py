"""Рамки детектора типа оборудования на наборах без разметки типа: data/web_testset (90) и тест рендеров (70).

Запуск:
    python cv/eval_equipment_extra.py <название> <веса.onnx|.pt> <отчёт eval_equipment.json> [--min-area 0.01]

Пороги классов берутся из отчёта cv/eval_equipment.py (выбраны там только на val и чётных кадрах negtest).
Для каждого снимка записываются рамки после порогов (класс, уверенность), для web_testset - группа снимка из
manifest.csv. Число снимков с рамкой считается по каждому классу; верность типа на снимках из сети нужно
смотреть глазами (разметки типа у них нет). На рендерах макета верный тип - pump_unit или motor.
С --newtest <папка сборки> считаются ещё точность и полнота на части newtest (части valid/test новых источников
второй сборки, cv/build_equipment_v2.py) при тех же порогах.
Отчёт runs/reports/<название>.json.
"""

import argparse
import csv
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from eval_equipment import class_stats, filtered, records_for, records_for_frame
from protocol import ROOT


def run(model, files: list, thresholds: dict, min_area: float, groups: dict) -> dict:
    """Прогоняет модель по снимкам и собирает рамки после порогов."""
    frames, by_class = {}, {}
    for path in files:
        record = records_for_frame(model, path)
        kept = [(name, round(score, 3)) for name, _, score in filtered(record, thresholds, min_area)]
        if kept:
            frames[os.path.basename(path)] = {"group": groups.get(os.path.basename(path), ""), "boxes": kept}
            for name in {name for name, _ in kept}:
                by_class[name] = by_class.get(name, 0) + 1
    return {"images": len(files), "frames_with_box": len(frames), "by_class": by_class, "frames": frames}


def main() -> None:
    """Считает рамки на web_testset и тесте рендеров с порогами из отчёта и пишет отчёт."""
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("weights")
    parser.add_argument("report")
    parser.add_argument("--min-area", type=float, default=0.01)
    parser.add_argument("--newtest", default=None, help="папка сборки с частью newtest (data/equipment_ds_v2)")
    args = parser.parse_args()
    from libreyolo import LibreYOLO

    model = LibreYOLO(args.weights)
    thresholds = json.load(open(args.report, encoding="utf-8"))["thresholds"]
    web = os.path.join(ROOT, "data", "web_testset")
    groups, files = {}, []
    for row in csv.DictReader(open(os.path.join(web, "manifest.csv"), encoding="utf-8")):
        path = os.path.join(web, row["file"])
        if os.path.exists(path):
            files.append(path)
            groups[os.path.basename(path)] = row.get("class", "")
    blender = sorted(glob.glob(os.path.join(ROOT, "data", "blender", "ds", "images", "test", "*")))
    report = {
        "name": args.name,
        "weights": args.weights,
        "thresholds_from": args.report,
        "thresholds": thresholds,
        "web_testset": run(model, files, thresholds, args.min_area, groups),
        "blender_test": run(model, blender, thresholds, args.min_area, {}),
    }
    if args.newtest:
        report["newtest_tuned"] = class_stats(records_for(model, args.newtest, "newtest"), thresholds, args.min_area)
        print("newtest_tuned", {name: (row["tp"], row["fp"], row["fn"]) for name, row in report["newtest_tuned"].items()})
    out = os.path.join(ROOT, "runs", "reports", f"{args.name}.json")
    json.dump(report, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for key in ("web_testset", "blender_test"):
        print(key, report[key]["frames_with_box"], "из", report[key]["images"], report[key]["by_class"])
    print("отчёт:", out)


if __name__ == "__main__":
    main()
