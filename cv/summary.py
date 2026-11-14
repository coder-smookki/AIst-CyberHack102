"""Сводка всех опытов с детекторами в один файл runs/reports/cv_summary.json.

Запуск:
    python cv/summary.py [runs/reports/cv_summary.json]

Числа берутся только из готовых отчётов: cmp_*.json (cv/compare.py), latency_*.json (cv/latency.py),
timing.json рядом с весами (cv/train.py), отчётов по тестовой части макета (cv/evaluate.py) и замера
чтения шильдика и манометра (cv/bench_blender.py). Если отчёта нет, в сводке остаётся пустое значение,
числа не придумываются.
"""
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
REPORTS = os.path.join(ROOT, "runs", "reports")
EXPERIMENTS = (
    {"name": "stand_9t", "family": "LibreYOLO9t", "weights_licence": "MIT", "start": "LibreYOLO9t.pt",
     "data": "data/blender/ds: кадры макета, 11 классов, обучение 296, проверка 50", "run": "detector",
     "compare": "cmp_stand_only", "latency": "latency_stand_9t",
     "note": "модель узлов макета, реальные дефекты заказчика не видит и не должна"},
    {"name": "defects_9t", "family": "LibreYOLO9t", "weights_licence": "MIT", "start": "LibreYOLO9t.pt",
     "data": "data/open/defects_ds: 464 кадра обучения, 4 класса", "run": "defects_9t",
     "compare": "cmp_defects_9t", "latency": "latency_defects_9t", "note": "базовая модель дефектов"},
    {"name": "defects_9t_v2", "family": "LibreYOLO9t", "weights_licence": "MIT",
     "start": "runs/defects_9t/weights/best.pt", "data": "data/open/defects_ds_v2: 554 кадра обучения, 4 класса",
     "run": "defects_9t_v2", "compare": "cmp_defects_9t_v2", "latency": "latency_defects_9t",
     "note": "дообучение базовой модели на наборе с выравниванием редких классов, всего 12 + 18 эпох"},
    {"name": "defects_9s", "family": "LibreYOLO9s", "weights_licence": "MIT", "start": "LibreYOLO9s.pt",
     "data": "data/open/defects_ds_v2: 554 кадра обучения, 4 класса", "run": "defects_9s",
     "compare": "cmp_defects_9s", "latency": "latency_defects_9s", "note": "модель того же семейства крупнее"},
    {"name": "defects_rfdetr_n", "family": "RF-DETR nano", "weights_licence": "Apache-2.0", "start": "LibreRFDETRn.pt",
     "data": "data/open/defects_ds_v2: 554 кадра обучения, 4 класса, вход 384 px", "run": "defects_rfdetr_n",
     "compare": "cmp_defects_rfdetr_n", "latency": "latency_defects_rfdetr_n",
     "note": "детектор на трансформере, 5 эпох, без смены размера входа; ONNX float32 384 px даёт те же числа, что веса .pt"},
    {"name": "defects_rfdetr_n_640", "family": "RF-DETR nano", "weights_licence": "Apache-2.0", "start": "LibreRFDETRn.pt",
     "data": "те же веса, ONNX с входом 640 px", "run": None,
     "compare": "cmp_defects_rfdetr_n_onnx_640", "latency": "latency_defects_rfdetr_n_640",
     "note": "модель обучена на 384 px, на 640 px хуже по всем показателям, CoreML на 640 px падает с ошибкой"},
    {"name": "defects_rfdetr_n_int8", "family": "RF-DETR nano", "weights_licence": "Apache-2.0", "start": "LibreRFDETRn.pt",
     "data": "те же веса, ONNX 384 px, веса MatMul и Gemm в int8 (cv/quantize.py)", "run": None,
     "compare": "cmp_defects_rfdetr_n_int8", "latency": "latency_defects_rfdetr_n_int8",
     "note": "33.6 МБ вместо 107.6 МБ: файл float32 больше предела GitHub 100 МБ"},
    {"name": "stand_9t_plus_defects_9t", "family": "две модели LibreYOLO9t", "weights_licence": "MIT", "start": None,
     "data": "модель узлов макета и базовая модель дефектов, рамки объединяются", "run": None,
     "compare": "cmp_two_models_9t", "latency": None, "note": "проверка схемы из двух моделей"},
    {"name": "stand_9t_plus_defects_9t_v2", "family": "две модели LibreYOLO9t", "weights_licence": "MIT", "start": None,
     "data": "модель узлов макета и defects_9t_v2, рамки объединяются", "run": None,
     "compare": "cmp_two_models_9t_v2", "latency": None, "note": "предыдущий вариант поставки"},
    {"name": "delivered", "family": "модели из папки models", "weights_licence": "см. models/models.json", "start": None,
     "data": "файлы ONNX из models/models.json, рамки объединяются, как на сервере", "run": None,
     "compare": "cmp_delivered_two_models", "latency": None, "note": "то, что загружает сервер"},
)
DECISION = ("Две модели вместо одной общей: модель узлов макета (stand, LibreYOLO9t, обучена только на кадрах Blender) "
            "и модель реальных дефектов (defects, RF-DETR nano, вход 384 px, веса MatMul в int8). Общую модель не обучали: "
            "классы узлов размечены только на кадрах макета, и снимки заказчика без разметки узлов учили бы общую модель "
            "не замечать узлы. Для дефектов выбрана RF-DETR nano: при пороге 0.25 она находит дефект на большем числе "
            "снимков, чем LibreYOLO9t и LibreYOLO9s (отложенные снимки, их копии с имитацией монитора, набор из сети), "
            "и даёт меньше ложных тревог на исправных снимках из сети; точность рамок ниже. Полнота важнее точности. "
            "Цена - время: около 65 мс на кадр на процессоре против 42 мс у LibreYOLO9t; CoreML для RF-DETR медленнее "
            "процессора. LibreYOLO9s обучалась 12 эпох против 30 у defects_9t_v2, сравнение с ней неравное.")


def load(path: str):
    """Читает файл JSON или возвращает None, если файла нет."""
    return json.load(open(path, encoding="utf-8")) if os.path.exists(path) else None


def labelled_row(part: dict | None, level: str) -> dict | None:
    """Оставляет от показателей размеченной выборки главное для одного порога уверенности."""
    if not part or level not in part:
        return None
    row = part[level]
    return {"images": part["images"], "box_precision": row["box_precision"], "box_recall": row["box_recall"],
            "image_defect_found": row["image_defect_found"], "image_right_class_found": row["image_right_class_found"],
            "classes": row["classes"]}


def web_row(part: dict | None, level: str) -> dict | None:
    """Оставляет от показателей тестового набора из сети главное для одного порога уверенности."""
    if not part or level not in part:
        return None
    row = part[level]
    return {"defective_images": row["defective_images"], "image_recall_any_defect": row["image_recall_any_defect"],
            "image_recall_right_class": row["image_recall_right_class"], "clean_images": row["clean_images"],
            "false_alarm_rate": row["false_alarm_rate"],
            "groups": {kind: [group["any_defect"], group["right_class"], group["images"]]
                       for kind, group in row["groups"].items()}}


def latency_row(report: dict | None) -> dict | None:
    """Сводит замер времени вывода к медианам по поставщикам вычислений."""
    if not report:
        return None
    row = {"model": report["model"], "size_mb": report["size_mb"]}
    for run in report["runs"]:
        key = "coreml_ms" if run["provider"].startswith("CoreML") else "cpu_ms"
        row[key] = run.get("median_ms")
        if "input" in run:
            row["input"] = next(iter(run["input"].values()))
        if "error" in run:
            row[key + "_error"] = run["error"]
    return row


def experiment_row(spec: dict, reports: str = REPORTS, runs: str | None = None) -> dict:
    """Собирает строку сводки по одному опыту из его отчётов."""
    runs = runs or os.path.join(ROOT, "runs")
    timing = load(os.path.join(runs, spec["run"], "timing.json")) if spec["run"] else None
    compare = load(os.path.join(reports, spec["compare"] + ".json")) or {}
    row = {key: spec[key] for key in ("name", "family", "weights_licence", "start", "data", "note")}
    row["epochs"] = timing["epochs"] if timing else None
    row["train_minutes"] = timing["train_minutes"] if timing else None
    row["measured"] = bool(compare)
    for level in ("conf_0.25", "conf_0.5"):
        row[level] = {"holdout": labelled_row(compare.get("holdout"), level),
                      "holdout_screen": labelled_row(compare.get("holdout_screen"), level),
                      "web_testset": web_row(compare.get("web_testset"), level)}
    row["latency_640"] = latency_row(load(os.path.join(reports, spec["latency"] + ".json"))) if spec["latency"] else None
    return row


def plates_summary(rows: list[dict]) -> dict:
    """Считает долю прочитанных шильдиков по ширине шильдика в кадре."""
    groups = {}
    for low, high in ((0, 60), (60, 100), (100, 10000)):
        part = [row for row in rows if low <= row["px"] < high]
        groups[f"{low}-{high}px" if high < 10000 else f"{low}px+"] = {
            "frames": len(part), "located": sum(row["located"] for row in part),
            "serial_exact": sum(row["serial_ok"] for row in part), "card_found": sum(row["card_ok"] for row in part)}
    return {"frames": len(rows), "located": sum(row["located"] for row in rows),
            "serial_exact": sum(row["serial_ok"] for row in rows), "card_found": sum(row["card_ok"] for row in rows),
            "by_width": groups}


def gauges_summary(rows: list[dict], span: float = 10.0) -> dict:
    """Считает долю прочитанных манометров и ошибку показания по ширине циферблата в кадре."""
    def part_summary(part: list[dict]) -> dict:
        """Сводит одну группу кадров: сколько прочитано и с какой ошибкой."""
        errors = sorted(abs(row["value"] - row["truth"]) for row in part if row["ok"] and row["value"] is not None)
        return {"frames": len(part), "located": sum(row["located"] for row in part), "read": len(errors),
                "median_error_bar": round(errors[len(errors) // 2], 2) if errors else None,
                "within_5pct_of_scale": sum(error <= 0.05 * span for error in errors),
                "error_over_10pct_of_scale": sum(error > 0.1 * span for error in errors)}
    summary = part_summary(rows)
    summary["by_width"] = {(f"{low}-{high}px" if high < 10000 else f"{low}px+"):
                           part_summary([row for row in rows if low <= row["px"] < high])
                           for low, high in ((0, 40), (40, 70), (70, 10000))}
    return summary


def build(reports: str = REPORTS) -> dict:
    """Собирает полную сводку: модель узлов макета, чтение шильдика и манометра, опыты с дефектами."""
    bench = load(os.path.join(reports, "blender_bench_detector_boxes_v2.json"))
    stand = {}
    for level, file in (("conf_0.25", "blender_test_conf025.json"), ("conf_0.5", "blender_test_conf050.json")):
        report = load(os.path.join(reports, file))
        stand[level] = report and {"images": report["images"], "precision": report["precision"], "recall": report["recall"],
                                   "classes": {name: [row["precision"], row["recall"]]
                                               for name, row in report["classes"].items()}}
    return {
        "machine": "MacBook Air M4, 16 ГБ, обучение на mps, замер времени в ONNX Runtime",
        "rules": ["отложенные снимки заказчика и тестовый набор из сети в обучении и подборе не участвовали",
                  "устойчивость проверена только на имитации съёмки с монитора, настоящая съёмка экрана не замерялась",
                  "рамка верна, если совпал класс и пересечение с разметкой не меньше половины объединения"],
        "stand_blender_test": stand,
        "nameplate_blender_test": bench and plates_summary(bench["plates"]),
        "gauge_blender_test": bench and gauges_summary(bench["gauges"]),
        "experiments": [experiment_row(spec, reports) for spec in EXPERIMENTS],
        "decision": DECISION,
        "delivered": load(os.path.join(ROOT, "models", "models.json")),
    }


def main() -> None:
    """Сохраняет сводку и печатает короткую таблицу по опытам."""
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPORTS, "cv_summary.json")
    summary = build()
    json.dump(summary, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for row in summary["experiments"]:
        part = row["conf_0.25"]
        hold, screen, web = part["holdout"] or {}, part["holdout_screen"] or {}, part["web_testset"] or {}
        print(f"{row['name']:26s} мин {row['train_minutes']}  отложенные P {hold.get('box_precision')} "
              f"R {hold.get('box_recall')} снимков с дефектом {hold.get('image_defect_found')}  "
              f"экран R {screen.get('box_recall')} снимков {screen.get('image_defect_found')}  "
              f"сеть найдено {web.get('image_recall_any_defect')} ложных {web.get('false_alarm_rate')}  "
              f"время {row['latency_640']}")


if __name__ == "__main__":
    main()
