"""Сводка всех опытов с детекторами в один файл runs/reports/cv_summary.json.

Запуск:
    python cv/summary.py [runs/reports/cv_summary.json]

Числа берутся только из готовых отчётов: cmp_*.json (cv/compare.py), latency_*.json (cv/latency.py),
timing.json рядом с весами (cv/train.py), отчётов по тестовой части макета (cv/evaluate.py), замера
чтения шильдика и манометра (cv/bench_blender.py), отчётов единого протокола (cv/protocol.py,
cv/tune_defects.py), проверки поставки как на сервере (cv/delivered.py), опыта со вторым этапом
(cv/verifier.py) и замера круга кадр-ответ по WebSocket (runs/reports/roundtrip_ws_detect.json). Если отчёта
нет, в сводке остаётся пустое значение, числа не придумываются.
"""

import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
REPORTS = os.path.join(ROOT, "runs", "reports")
EXPERIMENTS = (
    {
        "name": "stand_9t",
        "family": "LibreYOLO9t",
        "weights_licence": "MIT",
        "start": "LibreYOLO9t.pt",
        "data": "data/blender/ds: кадры макета, 11 классов, обучение 296, проверка 50",
        "run": "detector",
        "compare": "cmp_stand_only",
        "latency": "latency_stand_9t",
        "note": "модель узлов макета, реальные дефекты заказчика не видит и не должна",
    },
    {
        "name": "defects_9t",
        "family": "LibreYOLO9t",
        "weights_licence": "MIT",
        "start": "LibreYOLO9t.pt",
        "data": "data/open/defects_ds: 464 кадра обучения, 4 класса",
        "run": "defects_9t",
        "compare": "cmp_defects_9t",
        "latency": "latency_defects_9t",
        "note": "базовая модель дефектов",
    },
    {
        "name": "defects_9t_v2",
        "family": "LibreYOLO9t",
        "weights_licence": "MIT",
        "start": "runs/defects_9t/weights/best.pt",
        "data": "data/open/defects_ds_v2: 554 кадра обучения, 4 класса",
        "run": "defects_9t_v2",
        "compare": "cmp_defects_9t_v2",
        "latency": "latency_defects_9t",
        "note": "дообучение базовой модели на наборе с выравниванием редких классов, всего 12 + 18 эпох",
    },
    {
        "name": "defects_9s",
        "family": "LibreYOLO9s",
        "weights_licence": "MIT",
        "start": "LibreYOLO9s.pt",
        "data": "data/open/defects_ds_v2: 554 кадра обучения, 4 класса",
        "run": "defects_9s",
        "compare": "cmp_defects_9s",
        "latency": "latency_defects_9s",
        "note": "модель того же семейства крупнее",
    },
    {
        "name": "defects_rfdetr_n",
        "family": "RF-DETR nano",
        "weights_licence": "Apache-2.0",
        "start": "LibreRFDETRn.pt",
        "data": "data/open/defects_ds_v2: 554 кадра обучения, 4 класса, вход 384 px",
        "run": "defects_rfdetr_n",
        "compare": "cmp_defects_rfdetr_n",
        "latency": "latency_defects_rfdetr_n",
        "note": "детектор на трансформере, 5 эпох, без смены размера входа; ONNX float32 384 px даёт те же числа, что веса .pt",
    },
    {
        "name": "defects_rfdetr_n_640",
        "family": "RF-DETR nano",
        "weights_licence": "Apache-2.0",
        "start": "LibreRFDETRn.pt",
        "data": "те же веса, ONNX с входом 640 px",
        "run": None,
        "compare": "cmp_defects_rfdetr_n_onnx_640",
        "latency": "latency_defects_rfdetr_n_640",
        "note": "модель обучена на 384 px, на 640 px хуже по всем показателям, CoreML на 640 px падает с ошибкой",
    },
    {
        "name": "defects_rfdetr_n_int8",
        "family": "RF-DETR nano",
        "weights_licence": "Apache-2.0",
        "start": "LibreRFDETRn.pt",
        "data": "те же веса, ONNX 384 px, веса MatMul и Gemm в int8 (cv/quantize.py)",
        "run": None,
        "compare": "cmp_defects_rfdetr_n_int8",
        "latency": "latency_defects_rfdetr_n_int8",
        "note": "33.6 МБ вместо 107.6 МБ: файл float32 больше предела GitHub 100 МБ",
    },
    {
        "name": "stand_9t_plus_defects_9t",
        "family": "две модели LibreYOLO9t",
        "weights_licence": "MIT",
        "start": None,
        "data": "модель узлов макета и базовая модель дефектов, рамки объединяются",
        "run": None,
        "compare": "cmp_two_models_9t",
        "latency": None,
        "note": "проверка схемы из двух моделей",
    },
    {
        "name": "stand_9t_plus_defects_9t_v2",
        "family": "две модели LibreYOLO9t",
        "weights_licence": "MIT",
        "start": None,
        "data": "модель узлов макета и defects_9t_v2, рамки объединяются",
        "run": None,
        "compare": "cmp_two_models_9t_v2",
        "latency": None,
        "note": "предыдущий вариант поставки",
    },
    {
        "name": "original_pair",
        "family": "две модели исходной поставки",
        "weights_licence": "MIT, Apache-2.0",
        "start": None,
        "data": "исходные detector.onnx (только рендеры) и defects.onnx (defects_ds_v2, 5 эпох), рамки объединяются",
        "run": None,
        "compare": "cmp_delivered_two_models",
        "latency": None,
        "note": "исходная поставка, замер cv/compare.py; нынешняя поставка - served_delivered в разделе protocol_defects",
    },
)
PROTOCOL_RUNS = (
    {
        "name": "baseline_defects",
        "report": "baseline_defects_onnx",
        "latency": "latency_defects_rfdetr_n_int8",
        "note": "исходная модель дефектов: RF-DETR nano, defects_ds_v2, 5 эпох на mps, int8",
    },
    {
        "name": "baseline_pair",
        "report": "baseline_delivered_pair",
        "latency": None,
        "note": "исходная поставка: модель узлов только на рендерах и исходная модель дефектов, рамки сложены без порогов сервера",
    },
    {
        "name": "rfn384s_int8",
        "report": "kaggle_rfn384s_int8",
        "latency": "latency_kaggle_rfn384s_int8",
        "note": "RF-DETR nano 384 px, defects_ds_v3 и экранные копии, 33 эпохи на Kaggle, int8 - поставленная модель defects.onnx",
    },
    {"name": "rfn384s_pt", "report": "rfn384s_plain", "latency": "latency_kaggle_rfn384s_fp32", "note": "те же веса до сжатия"},
    {
        "name": "rfn384s_flip",
        "report": "rfn384s_flip",
        "latency": None,
        "note": "те же веса плюс отражённый кадр, время вдвое больше",
    },
    {"name": "rfn512s", "report": "rfn512s_plain", "latency": None, "note": "RF-DETR nano 512 px"},
    {
        "name": "rfs512s_int8",
        "report": "kaggle_rfs512s_int8",
        "latency": "latency_kaggle_rfs512s_int8",
        "note": "RF-DETR small 512 px, int8",
    },
    {"name": "rfm576s", "report": "rfm576s_plain", "latency": None, "note": "RF-DETR medium 576 px"},
    {
        "name": "served_original",
        "report": "sel_orig",
        "latency": None,
        "note": "исходная поставка так, как её запускал сервер: обе модели при 0.25, объединение рамок",
    },
    {
        "name": "served_interim",
        "report": "sel_interim",
        "latency": None,
        "note": "промежуточная поставка: модель узлов на рендерах и rfn384s int8, обе при 0.25",
    },
    {
        "name": "served_delivered",
        "report": "delivered_served",
        "latency": None,
        "note": "поставка: detector.onnx (p9t_r4) при 0.25 и defects.onnx (rfn384s int8) при 0.15 по models/models.json",
    },
)
PARTS_RUNS = (
    {
        "name": "parts_baseline",
        "report": "parts_delivered_detector",
        "latency": "latency_parts_delivered",
        "note": "исходная модель узлов, только рендеры макета",
    },
    {
        "name": "parts_p9t_r2",
        "report": "parts_p9t_r2_onnx",
        "latency": "latency_parts_p9t_r2",
        "note": "рендеры и реальные снимки x2",
    },
    {
        "name": "parts_p9s_r2",
        "report": "parts_p9s_r2",
        "latency": "latency_parts_p9s_r2",
        "note": "LibreYOLO9s, рендеры и реальные снимки x2",
    },
    {
        "name": "parts_p9t_r4",
        "report": "parts_p9t_r4_onnx",
        "latency": "latency_parts_p9t_r4",
        "note": "рендеры и реальные снимки x4 - поставленная модель detector.onnx",
    },
    {
        "name": "parts_served_delivered",
        "report": "delivered_served_parts",
        "latency": None,
        "note": "обе поставленные модели с порогами сервера на тесте макета и реальных узлов",
    },
)
DECISION = (
    "Две модели вместо одной общей: модель узлов (stand, LibreYOLO9t, рендеры макета и реальные снимки узлов "
    "parts_real, запуск p9t_r4) и модель реальных дефектов (defects, RF-DETR nano 384 px, defects_ds_v3 и экранные "
    "копии, 33 эпохи на Kaggle, веса MatMul в int8). Модель и эпоха дефектов выбраны только по проверочной части "
    "defects_ds_v3; порог 0.15 для дефектов выбран там же, потому что пропуск дефекта хуже ложной тревоги; модель "
    "узлов работает при 0.25. Пороги записаны в models/models.json и применяются сервером. Отложенные снимки "
    "заказчика, их копии и набор из сети служили только подтверждением: поставка на них не хуже промежуточной "
    "и исходной по найденным дефектам и заметно лучше по ложным тревогам. Отражение кадра и второй этап "
    "проверки вырезок (DINOv2 small) не включены: первое удваивает время без выигрыша на отложенных снимках, "
    "второе не изменило ни одного числа на отложенных наборах. Подгорание клеммной коробки на снимках "
    "заказчика по-прежнему не находится ни одной моделью."
)


def load(path: str):
    """Читает файл JSON или возвращает None, если файла нет."""
    return json.load(open(path, encoding="utf-8")) if os.path.exists(path) else None


def labelled_row(part: dict | None, level: str) -> dict | None:
    """Оставляет от показателей размеченной выборки главное для одного порога уверенности."""
    if not part or level not in part:
        return None
    row = part[level]
    return {
        "images": part["images"],
        "box_precision": row["box_precision"],
        "box_recall": row["box_recall"],
        "image_defect_found": row["image_defect_found"],
        "image_right_class_found": row["image_right_class_found"],
        "classes": row["classes"],
    }


def web_row(part: dict | None, level: str) -> dict | None:
    """Оставляет от показателей тестового набора из сети главное для одного порога уверенности."""
    if not part or level not in part:
        return None
    row = part[level]
    return {
        "defective_images": row["defective_images"],
        "image_recall_any_defect": row["image_recall_any_defect"],
        "image_recall_right_class": row["image_recall_right_class"],
        "clean_images": row["clean_images"],
        "false_alarm_rate": row["false_alarm_rate"],
        "groups": {kind: [group["any_defect"], group["right_class"], group["images"]] for kind, group in row["groups"].items()},
    }


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
        row[level] = {
            "holdout": labelled_row(compare.get("holdout"), level),
            "holdout_screen": labelled_row(compare.get("holdout_screen"), level),
            "web_testset": web_row(compare.get("web_testset"), level),
        }
    row["latency_640"] = latency_row(load(os.path.join(reports, spec["latency"] + ".json"))) if spec["latency"] else None
    return row


def plates_summary(rows: list[dict]) -> dict:
    """Считает долю прочитанных шильдиков по ширине шильдика в кадре."""
    groups = {}
    for low, high in ((0, 60), (60, 100), (100, 10000)):
        part = [row for row in rows if low <= row["px"] < high]
        groups[f"{low}-{high}px" if high < 10000 else f"{low}px+"] = {
            "frames": len(part),
            "located": sum(row["located"] for row in part),
            "serial_exact": sum(row["serial_ok"] for row in part),
            "card_found": sum(row["card_ok"] for row in part),
        }
    return {
        "frames": len(rows),
        "located": sum(row["located"] for row in rows),
        "serial_exact": sum(row["serial_ok"] for row in rows),
        "card_found": sum(row["card_ok"] for row in rows),
        "by_width": groups,
    }


def gauges_summary(rows: list[dict], span: float = 10.0) -> dict:
    """Считает долю прочитанных манометров и ошибку показания по ширине циферблата в кадре."""

    def part_summary(part: list[dict]) -> dict:
        """Сводит одну группу кадров: сколько прочитано и с какой ошибкой."""
        errors = sorted(abs(row["value"] - row["truth"]) for row in part if row["ok"] and row["value"] is not None)
        return {
            "frames": len(part),
            "located": sum(row["located"] for row in part),
            "read": len(errors),
            "median_error_bar": round(errors[len(errors) // 2], 2) if errors else None,
            "within_5pct_of_scale": sum(error <= 0.05 * span for error in errors),
            "error_over_10pct_of_scale": sum(error > 0.1 * span for error in errors),
        }

    summary = part_summary(rows)
    summary["by_width"] = {
        (f"{low}-{high}px" if high < 10000 else f"{low}px+"): part_summary([row for row in rows if low <= row["px"] < high])
        for low, high in ((0, 40), (40, 70), (70, 10000))
    }
    return summary


def protocol_row(spec: dict, reports: str = REPORTS) -> dict:
    """Собирает строку сводки по отчёту единого протокола: показатели наборов на порогах 0.15, 0.25 и сервера."""
    report = load(os.path.join(reports, spec["report"] + ".json")) or {}
    row = {"name": spec["name"], "report": spec["report"], "note": spec["note"], "measured": bool(report), "sets": {}}
    for set_name, part in (report.get("sets") or {}).items():
        if not isinstance(part, dict) or "missing" in part:
            continue
        levels = {}
        for level in ("conf_served", "conf_0.15", "conf_0.25", "conf_0.5"):
            entry = part.get(level)
            if entry:
                levels[level] = {
                    key: entry.get(key)
                    for key in (
                        "box_precision",
                        "box_recall",
                        "image_defect_found",
                        "image_right_class_found",
                        "false_alarm_rate",
                    )
                }
                levels[level]["classes"] = {
                    name: [stats["tp"], stats["fp"], stats["fn"]] for name, stats in (entry.get("classes") or {}).items()
                }
        row["sets"][set_name] = {"images": part.get("images"), "map50": part.get("map50"), "ap50": part.get("ap50"), **levels}
    row["latency"] = latency_row(load(os.path.join(reports, spec["latency"] + ".json"))) if spec["latency"] else None
    return row


def verifier_summary(reports: str = REPORTS) -> dict | None:
    """Оставляет от отчёта второго этапа выбранный режим и показатели детектора и цепочки на каждом наборе."""
    report = load(os.path.join(reports, "verifier.json"))
    if not report:
        return None
    return {
        "operating_point": report.get("operating_point"),
        "rule": report.get("rule"),
        "sets": {name: {key: part.get(key) for key in ("detector", "pipeline")} for name, part in report["sets"].items()},
        "decision": "не включён: на отложенных снимках, их копиях и наборе из сети ни одно число не изменилось",
    }


def roundtrip_summary(reports: str = REPORTS) -> dict | None:
    """Оставляет от замера круга кадр-ответ по WebSocket времена без перечня рамок."""
    report = load(os.path.join(reports, "roundtrip_ws_detect.json"))
    if not report:
        return None
    return {
        "detector": report.get("health"),
        "note": report.get("note"),
        "results": [{key: value for key, value in row.items() if key != "boxes"} for row in report["results"] if row],
    }


def build(reports: str = REPORTS) -> dict:
    """Собирает полную сводку: модель узлов макета, чтение шильдика и манометра, опыты с дефектами."""
    bench = load(os.path.join(reports, "blender_bench_detector_boxes_v2.json"))
    stand = {}
    for level, file in (("conf_0.25", "blender_test_conf025.json"), ("conf_0.5", "blender_test_conf050.json")):
        report = load(os.path.join(reports, file))
        stand[level] = report and {
            "images": report["images"],
            "precision": report["precision"],
            "recall": report["recall"],
            "classes": {name: [row["precision"], row["recall"]] for name, row in report["classes"].items()},
        }
    return {
        "machine": "MacBook Air M4, 16 ГБ, обучение на mps, замер времени в ONNX Runtime",
        "rules": [
            "отложенные снимки заказчика и тестовый набор из сети в обучении и подборе не участвовали",
            "модель, эпоха и пороги выбирались только по проверочной части defects_ds_v3 и по проверке parts_mix_v1",
            "устойчивость проверена только на имитации съёмки с монитора, настоящая съёмка экрана не замерялась",
            "рамка верна, если совпал класс и пересечение с разметкой не меньше половины объединения",
        ],
        "stand_blender_test": stand,
        "stand_blender_test_model": (
            "исходный detector.onnx, обученный только на рендерах (cv/evaluate.py, "
            "blender_test_conf025.json и blender_test_conf050.json); поставленная модель узлов "
            "p9t_r4 - в protocol_parts (parts_p9t_r4 и parts_served_delivered)"
        ),
        "nameplate_blender_test": bench and plates_summary(bench["plates"]),
        "gauge_blender_test": bench and gauges_summary(bench["gauges"]),
        "experiments": [experiment_row(spec, reports) for spec in EXPERIMENTS],
        "protocol_defects": [protocol_row(spec, reports) for spec in PROTOCOL_RUNS],
        "protocol_parts": [protocol_row(spec, reports) for spec in PARTS_RUNS],
        "verifier": verifier_summary(reports),
        "roundtrip_ws_detect": roundtrip_summary(reports),
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
        print(
            f"{row['name']:26s} мин {row['train_minutes']}  отложенные P {hold.get('box_precision')} "
            f"R {hold.get('box_recall')} снимков с дефектом {hold.get('image_defect_found')}  "
            f"экран R {screen.get('box_recall')} снимков {screen.get('image_defect_found')}  "
            f"сеть найдено {web.get('image_recall_any_defect')} ложных {web.get('false_alarm_rate')}  "
            f"время {row['latency_640']}"
        )
    for row in summary["protocol_defects"]:
        parts = []
        for set_name in ("holdout", "holdout_screen", "web", "val"):
            part = row["sets"].get(set_name) or {}
            level = part.get("conf_served") or part.get("conf_0.15") or {}
            parts.append(
                f"{set_name} P {level.get('box_precision')} R {level.get('box_recall')} "
                f"найдено {level.get('image_defect_found')} ложных {level.get('false_alarm_rate')}"
            )
        print(f"{row['name']:18s} " + "; ".join(parts))


if __name__ == "__main__":
    main()
