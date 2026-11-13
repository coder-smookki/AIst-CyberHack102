"""Проверка чтения шильдика и манометра на кадрах макета из Blender.

Запуск:
    python cv/bench_blender.py <папка_набора> <выборка> <зерно> [веса_детектора] [отчёт.json]

Для каждого кадра известны истинные значения: серийный номер на шильдике и показание манометра.
Узел вырезается по рамке из разметки, а если заданы веса детектора, то по рамке, найденной моделью.
"""
import json
import os
import sys

import cv2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gauge import read_gauge
from nameplate import identify


def crop(frame, box, margin: float):
    """Вырезает область рамки с запасом по краям. Рамка задана в долях кадра."""
    height, width = frame.shape[:2]
    x1, y1, x2, y2 = box
    dx, dy = (x2 - x1) * margin, (y2 - y1) * margin
    return frame[max(0, int((y1 - dy) * height)):int((y2 + dy) * height), max(0, int((x1 - dx) * width)):int((x2 + dx) * width)]


def detected_boxes(model, frame) -> dict:
    """Возвращает для каждого класса самую уверенную рамку модели в долях кадра."""
    height, width = frame.shape[:2]
    result = model(frame, conf=0.25)
    result = result[0] if isinstance(result, (list, tuple)) else result
    names = getattr(result, "names", None) or getattr(model, "names", {})
    best = {}
    for box, cls, conf in zip(result.boxes.xyxy, result.boxes.cls, result.boxes.conf):
        name = names[int(cls)]
        if name not in best or float(conf) > best[name][1]:
            best[name] = ([float(box[0]) / width, float(box[1]) / height, float(box[2]) / width, float(box[3]) / height], float(conf))
    return {name: value[0] for name, value in best.items()}


def main() -> None:
    """Считает долю верно прочитанных шильдиков и ошибку показаний манометра."""
    root, split, seed = sys.argv[1], sys.argv[2], sys.argv[3]
    model = None
    if len(sys.argv) > 4 and sys.argv[4] != "-":
        from libreyolo import LibreYOLO
        model = LibreYOLO(sys.argv[4])
    truth = json.load(open(os.path.join(root, "textures_truth.json"), encoding="utf-8"))
    cards = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "equipment.json"),
                           encoding="utf-8"))["equipment"]
    meta = json.load(open(os.path.join(root, f"meta_{split}_{seed}.json"), encoding="utf-8"))
    plates, gauges = [], []
    for item in meta["frames"]:
        frame = cv2.imread(os.path.join(root, "images", split, item["file"]))
        labelled = {obj["cls"]: obj["box"] for obj in item["objects"]}
        found = detected_boxes(model, frame) if model else labelled
        if "nameplate" in labelled:
            row = {"file": item["file"], "px": round((labelled["nameplate"][2] - labelled["nameplate"][0]) * frame.shape[1]),
                   "located": "nameplate" in found, "serial_ok": False, "card_ok": False, "by": None}
            if row["located"]:
                answer = identify(crop(frame, found["nameplate"], 0.12), cards)
                row["serial_ok"] = answer["fields"]["serial"] == truth["serial"]
                row["card_ok"] = bool(answer["match"]) and answer["match"]["card"]["serial"] == truth["serial"]
                row["by"] = answer["match"]["by"] if answer["match"] else None
            plates.append(row)
        if "gauge" in labelled:
            row = {"file": item["file"], "truth": item["gauge_bar"], "az": item["az_deg"],
                   "px": round((labelled["gauge"][2] - labelled["gauge"][0]) * frame.shape[1]), "located": "gauge" in found,
                   "value": None, "ok": False}
            if row["located"]:
                answer = read_gauge(crop(frame, found["gauge"], 0.04), truth["gauge"]["min"], truth["gauge"]["max"],
                                    truth["gauge"]["sweep_deg"])
                row["value"], row["ok"] = answer["value"], bool(answer.get("ok"))
            gauges.append(row)
    report = {"plates": plates, "gauges": gauges}
    if len(sys.argv) > 5:
        json.dump(report, open(sys.argv[5], "w", encoding="utf-8"), ensure_ascii=False, indent=0)

    print(f"шильдик виден на {len(plates)} кадрах")
    for low, high in ((0, 60), (60, 100), (100, 160), (160, 10000)):
        group = [p for p in plates if low <= p["px"] < high]
        if group:
            print(f"  ширина {low}-{high} px: кадров {len(group)}, найден {sum(p['located'] for p in group)}, "
                  f"номер прочитан точно {sum(p['serial_ok'] for p in group)}, карточка найдена {sum(p['card_ok'] for p in group)}")
    print(f"манометр виден на {len(gauges)} кадрах")
    span = truth["gauge"]["max"] - truth["gauge"]["min"]
    for low, high in ((0, 40), (40, 70), (70, 120), (120, 10000)):
        group = [g for g in gauges if low <= g["px"] < high]
        read = [g for g in group if g["value"] is not None and g["ok"]]
        if group:
            errors = sorted(abs(g["value"] - g["truth"]) for g in read)
            median = errors[len(errors) // 2] if errors else None
            within = sum(e <= 0.05 * span for e in errors)
            print(f"  ширина {low}-{high} px: кадров {len(group)}, прочитано {len(read)}, "
                  f"медиана ошибки {median} бар, в пределах 5% шкалы {within}")


if __name__ == "__main__":
    main()
