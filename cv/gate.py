"""Жёсткий порог качества: новая модель допускается в models/ только если ни один показатель не стал хуже.

Запуск:
    python cv/gate.py <название> <папка_кандидата> [--baseline models] [--clean data/open/clean-indoor/images]
                      [--defect-sets holdout,holdout_screen,web,val] [--part-sets parts,blender]

Папка кандидата устроена как models/: models.json и файлы ONNX (можно ссылками). Оба набора моделей
проверяются ровно по правилам сервера (cv/delivered.py: пороги из models.json и объединение рамок) на всех
отложенных наборах: снимки заказчика и их копии "с монитора", набор из сети, val, чистые снимки помещений,
тест parts_real и тест рендеров макета; время вывода каждого изменившегося файла ONNX меряется cv/latency.py.

Проверки (кандидат против поставленного набора, допуск на шум - одно изображение набора или NOISE_ABS):
    доля найденных дефектных снимков, точность рамок дефектов, mAP50 - не ниже;
    доля ложных тревог на чистых снимках (набор из сети и чистые снимки помещений) - не выше;
    точность и полнота рамок узлов на parts и blender - не ниже;
    время вывода - не больше чем на LATENCY_SLACK (20%).
Итог PASS только если прошли все проверки; отчёт runs/reports/gate_<название>.json с таблицей.
"""

import argparse
import glob
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
NOISE_ABS = 0.02
LATENCY_SLACK = 0.20
LEVEL = "conf_served"


def tolerance(count: int | None) -> float:
    """Допуск на шум для доли по набору из count изображений: одно изображение, но не меньше NOISE_ABS."""
    return max(NOISE_ABS, 1.0 / count) if count else NOISE_ABS


def check(name: str, base: float | None, cand: float | None, higher_better: bool, tol: float) -> dict:
    """Сравнивает один показатель; отсутствующее значение у обоих наборов не считается ухудшением."""
    if base is None and cand is None:
        return {"check": name, "baseline": None, "candidate": None, "tolerance": tol, "result": "PASS"}
    if cand is None or base is None:
        return {"check": name, "baseline": base, "candidate": cand, "tolerance": tol, "result": "FAIL"}
    worse = (base - cand) if higher_better else (cand - base)
    return {
        "check": name,
        "baseline": round(base, 4),
        "candidate": round(cand, 4),
        "tolerance": round(tol, 4),
        "result": "FAIL" if worse > tol + 1e-9 else "PASS",
    }


def latency_check(name: str, base_ms: float, cand_ms: float, slack: float = LATENCY_SLACK) -> dict:
    """Проверяет, что медианное время вывода кандидата не больше базового более чем на slack."""
    limit = base_ms * (1 + slack)
    return {
        "check": name,
        "baseline": round(base_ms, 1),
        "candidate": round(cand_ms, 1),
        "tolerance": f"+{int(slack * 100)}%",
        "result": "PASS" if cand_ms <= limit else "FAIL",
    }


def defect_checks(set_name: str, base: dict, cand: dict) -> list[dict]:
    """Проверки набора дефектов: найденные дефектные снимки, точность рамок, mAP50 и ложные тревоги."""
    b, c = base[LEVEL], cand[LEVEL]
    rows = [
        check(
            f"{set_name}: найден дефект",
            b.get("image_defect_found"),
            c.get("image_defect_found"),
            True,
            tolerance(b.get("defective_images")),
        ),
        check(
            f"{set_name}: ложные тревоги",
            b.get("false_alarm_rate"),
            c.get("false_alarm_rate"),
            False,
            tolerance(b.get("clean_images")),
        ),
    ]
    if b.get("box_precision") is not None or c.get("box_precision") is not None:
        rows.append(check(f"{set_name}: точность рамок", b.get("box_precision"), c.get("box_precision"), True, NOISE_ABS))
    if base.get("map50") is not None:
        rows.append(check(f"{set_name}: mAP50", base.get("map50"), cand.get("map50"), True, NOISE_ABS))
    return rows


def part_checks(set_name: str, base: dict, cand: dict) -> list[dict]:
    """Проверки набора узлов: точность и полнота рамок и mAP50."""
    b, c = base[LEVEL], cand[LEVEL]
    return [
        check(f"{set_name}: точность узлов", b.get("box_precision"), c.get("box_precision"), True, NOISE_ABS),
        check(f"{set_name}: полнота узлов", b.get("box_recall"), c.get("box_recall"), True, NOISE_ABS),
        check(f"{set_name}: mAP50 узлов", base.get("map50"), cand.get("map50"), True, NOISE_ABS),
    ]


def clean_rate(alarms: int, total: int) -> float | None:
    """Доля чистых снимков с хотя бы одной рамкой дефекта."""
    return alarms / total if total else None


def verdict(rows: list[dict]) -> str:
    """Итог: PASS, если все проверки прошли."""
    return "PASS" if rows and all(row["result"] == "PASS" for row in rows) else "FAIL"


def clean_alarms(entries: list[dict], models_dir: str, folder: str) -> tuple[int, int]:
    """Считает чистые снимки, на которых набор моделей по правилам сервера выдал рамку дефекта."""
    from libreyolo import LibreYOLO

    from delivered import served
    from protocol import DEFECT_CLASSES, predict, read_frame

    models = [LibreYOLO(os.path.join(models_dir, entry["file"])) for entry in entries]
    files = sorted(glob.glob(os.path.join(folder, "*.jpg")) + glob.glob(os.path.join(folder, "*.png")))
    alarms = 0
    for path in files:
        frame = read_frame(path)
        if frame is None:
            continue
        per_model = [
            predict([model], frame, tuple(model.names.values()) if isinstance(model.names, dict) else tuple(model.names))
            for model in models
        ]
        boxes = served(per_model, entries)
        alarms += any(name in DEFECT_CLASSES for name, _, _ in boxes)
    return alarms, len(files)


def median_latency(path: str) -> float:
    """Медианное время вывода файла ONNX на процессоре по cv/latency.py."""
    from latency import measure

    return measure(path, "CPUExecutionProvider", 40)["median_ms"]


def main() -> None:
    """Проверяет кандидата против поставленного набора моделей и пишет отчёт с итогом PASS или FAIL."""
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("candidate")
    parser.add_argument("--baseline", default=os.path.join(ROOT, "models"))
    parser.add_argument("--clean", default=os.path.join(ROOT, "data", "open", "clean-indoor", "images"))
    parser.add_argument("--defect-sets", default="holdout,holdout_screen,web,val")
    parser.add_argument("--part-sets", default="parts,blender")
    args = parser.parse_args()
    from delivered import evaluate

    base_entries = json.load(open(os.path.join(args.baseline, "models.json"), encoding="utf-8"))
    cand_entries = json.load(open(os.path.join(args.candidate, "models.json"), encoding="utf-8"))
    rows = []
    defect_sets = [name for name in args.defect_sets.split(",") if name]
    part_sets = [name for name in args.part_sets.split(",") if name]
    if defect_sets:
        base = evaluate(base_entries, args.baseline, defect_sets, "defects")
        cand = evaluate(cand_entries, args.candidate, defect_sets, "defects")
        for name in defect_sets:
            if "missing" in base.get(name, {}) or "missing" in cand.get(name, {}):
                rows.append(
                    {
                        "check": f"{name}: набор недоступен",
                        "baseline": None,
                        "candidate": None,
                        "tolerance": None,
                        "result": "FAIL",
                    }
                )
            else:
                rows += defect_checks(name, base[name], cand[name])
    if part_sets:
        base = evaluate(base_entries, args.baseline, part_sets, "parts")
        cand = evaluate(cand_entries, args.candidate, part_sets, "parts")
        for name in part_sets:
            if "missing" in base.get(name, {}) or "missing" in cand.get(name, {}):
                rows.append(
                    {
                        "check": f"{name}: набор недоступен",
                        "baseline": None,
                        "candidate": None,
                        "tolerance": None,
                        "result": "FAIL",
                    }
                )
            else:
                rows += part_checks(name, base[name], cand[name])
    if os.path.isdir(args.clean):
        base_alarms, total = clean_alarms(base_entries, args.baseline, args.clean)
        cand_alarms, _ = clean_alarms(cand_entries, args.candidate, args.clean)
        rows.append(
            check(
                "чистые снимки помещений: ложные тревоги",
                clean_rate(base_alarms, total),
                clean_rate(cand_alarms, total),
                False,
                tolerance(total) * 0.999,
            )
        )
    else:
        rows.append(
            {
                "check": "чистые снимки помещений: набор недоступен",
                "baseline": None,
                "candidate": None,
                "tolerance": None,
                "result": "FAIL",
            }
        )
    base_files = {entry["file"]: entry for entry in base_entries}
    for entry in cand_entries:
        cand_path = os.path.realpath(os.path.join(args.candidate, entry["file"]))
        base_path = os.path.realpath(os.path.join(args.baseline, entry["file"])) if entry["file"] in base_files else None
        if base_path and os.path.exists(base_path) and base_path != cand_path:
            rows.append(latency_check(f"время вывода {entry['file']}, мс", median_latency(base_path), median_latency(cand_path)))
    report = {
        "name": args.name,
        "baseline": args.baseline,
        "candidate": args.candidate,
        "date": time.strftime("%Y-%m-%d %H:%M"),
        "verdict": verdict(rows),
        "checks": rows,
    }
    out = os.path.join(ROOT, "runs", "reports", f"gate_{args.name}.json")
    json.dump(report, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for row in rows:
        print(f"{row['result']:4s}  {row['check']}: {row['baseline']} -> {row['candidate']} (допуск {row['tolerance']})")
    print("ИТОГ:", report["verdict"], "отчёт:", out)


if __name__ == "__main__":
    main()
