"""Набор для детектора типа оборудования: насосный агрегат, шкаф управления, трансформатор, двигатель, задвижка,
компрессор.

Запуск:
    python cv/build_equipment.py data/open/equipment_ds_v1 [--seed 0]

Отдельный детектор, а не новые классы модели узлов: модель узлов (11 классов, рендеры макета и parts_real)
остаётся без изменений и не может ухудшиться. Классы EQUIPMENT_CLASSES; рамка обводит агрегат или аппарат целиком.

Источники (папки data/open, у каждой свой SOURCE.txt):
    рендеры макета data/blender/ds: pump_unit - объединение рамок узлов агрегата, motor - рамка двигателя;
    части train, val и test рендеров идут в те же части набора;
    data/open/parts_real: motor и pump_unit (объединение motor и pump_casing, если на снимке размечены оба);
    train -> train, test -> test;
    наборы Roboflow из SOURCES: части train источника -> train (каждый VAL_EVERY-й кадр -> val), части valid и
    test источника -> test, то есть тест состоит из реальных снимков, не участвовавших в обучении.
Каждый кадр train и val сравнивается по pHash и dHash (cv/build_defects_v3.Guard) с защищёнными снимками:
отложенными снимками заказчика, их копиями, data/web_testset и тестом parts_real; до 10 бит кадр выбрасывается.
Повторы внутри train и между train и test отсекаются по хешу целого кадра (до 8 бит).
"""
import argparse
import csv
import glob
import json
import os
import random
import shutil
import sys

import cv2

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_defects import ROOT
from build_defects_v3 import build_guard, read_any
from build_defects_v4 import Index, class_names, parse_rows

OPEN = os.path.join(ROOT, "data", "open")
EQUIPMENT_CLASSES = ("pump_unit", "control_cabinet", "transformer", "motor", "valve", "compressor")
UNIT_PARTS = ("motor", "pump_casing", "flange", "coupling_guard", "coupling_no_guard", "terminal_box", "terminal_box_burnt")
PART_NAMES = ("motor", "pump_casing", "flange", "coupling_guard", "coupling_no_guard", "terminal_box",
              "terminal_box_burnt", "nameplate", "gauge", "leak", "corrosion", "valve")
DROP_BITS = 10
INTRA_BITS = 8
VAL_EVERY = 8
MAX_SIDE = 960

PANEL = {f"Electric_panel-t{number}": "control_cabinet" for number in range(1, 13)}
SOURCES = [
    {"key": "elpanel", "folder": "rf-electric-panel/raw", "map": PANEL, "cap": 700, "test_cap": 80,
     "licence": "MIT (Roboflow objectdetectionseperatemodels/electric-panel)"},
    {"key": "substation", "folder": "rf-substation-equip/raw", "min_area": 0.01, "cap": 300, "test_cap": 50,
     "map": {"Main transformer-": "transformer", "main_power_transformer": "transformer", "Switch cabinet-": "control_cabinet"},
     "licence": "CC BY 4.0 (Roboflow substation-equipment-florence2-datasets/substation-equipment-det-2)"},
    {"key": "valve", "folder": "rf-valve-kmd/raw", "map": {"opened valve": "valve", "closed valve": "valve"},
     "min_area": 0.002, "cap": 300, "test_cap": 40, "licence": "CC BY 4.0 (Roboflow kmd-0u5yp/valve-mo95u)"},
    {"key": "compressor", "folder": "rf-compressor-lms/raw", "map": {"compressor": "compressor"}, "cap": 300,
     "test_cap": 40, "licence": "CC BY 4.0 (Roboflow lms-ynahk/compressor-c238z)"},
]
EXTRA_FILE = os.path.join(OPEN, "equipment_sources.json")


def union_box(rows: list[tuple], names: tuple) -> tuple | None:
    """Возвращает рамку, охватывающую все рамки перечисленных классов, или None, если таких рамок нет."""
    boxes = [row[1:] for row in rows if row[0] in names]
    if not boxes:
        return None
    return (min(b[0] for b in boxes), min(b[1] for b in boxes), max(b[2] for b in boxes), max(b[3] for b in boxes))


def stand_boxes(rows: list[tuple]) -> list[tuple]:
    """Переводит разметку узлов макета в рамки типа оборудования: агрегат целиком и двигатель."""
    out = [("motor", *row[1:]) for row in rows if row[0] == "motor"]
    unit = union_box(rows, UNIT_PARTS)
    if unit and any(row[0] == "pump_casing" for row in rows) and any(row[0] == "motor" for row in rows):
        out.append(("pump_unit", *unit))
    return out


def real_part_boxes(rows: list[tuple]) -> list[tuple]:
    """Переводит разметку parts_real: двигатель и агрегат, если на снимке есть и двигатель, и корпус насоса."""
    out = [("motor", *row[1:]) for row in rows if row[0] == "motor"]
    if any(row[0] == "pump_casing" for row in rows) and any(row[0] == "motor" for row in rows):
        out.append(("pump_unit", *union_box(rows, ("motor", "pump_casing", "flange", "coupling_guard",
                                                   "coupling_no_guard", "terminal_box"))))
    out += [("valve", *row[1:]) for row in rows if row[0] == "valve"]
    return out


def map_source(source: dict, rows: list[tuple]) -> list[tuple] | None:
    """Сопоставляет классы источника Roboflow классам типа оборудования; None, если подходящих рамок нет."""
    boxes = [(source["map"][name], *box) for name, *box in rows
             if name in source["map"] and (box[2] - box[0]) * (box[3] - box[1]) >= source.get("min_area", 0.0)]
    return boxes or None


class EquipmentWriter:
    """Пишет кадры набора с проверкой на повторы тестовых снимков и внутри набора и ведёт опись."""

    def __init__(self, out: str, guard, rng: random.Random):
        """Запоминает папку набора, защищённые снимки и генератор случайных чисел."""
        self.out, self.guard, self.rng = out, guard, rng
        self.index = {"train": Index(), "test": Index()}
        self.manifest, self.dropped, self.twins = [], [], 0

    def put(self, split: str, name: str, path: str, boxes: list[tuple], source: str, licence: str) -> bool:
        """Читает, уменьшает, проверяет и сохраняет кадр с рамками в формате YOLO; возвращает успех."""
        image = read_any(path)
        if image is None:
            return False
        scale = MAX_SIDE / max(image.shape[:2])
        if scale < 1.0:
            image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        if split != "test" and source not in ("blender", "parts_real"):
            bits, who = self.guard.nearest(image)
            if bits <= DROP_BITS:
                self.dropped.append({"frame": name, "origin": os.path.relpath(path, ROOT), "protected": who, "bits": bits})
                return False
        group = "test" if split == "test" else "train"
        other = "train" if group == "test" else "test"
        if self.index[group].nearest(gray)[0] <= INTRA_BITS or self.index[other].nearest(gray)[0] <= INTRA_BITS:
            self.twins += 1
            return False
        self.index[group].add(name, gray)
        for kind in ("images", "labels"):
            os.makedirs(os.path.join(self.out, kind, split), exist_ok=True)
        cv2.imwrite(os.path.join(self.out, "images", split, name + ".jpg"), image, [cv2.IMWRITE_JPEG_QUALITY, 90])
        with open(os.path.join(self.out, "labels", split, name + ".txt"), "w") as handle:
            for cls, x1, y1, x2, y2 in boxes:
                x1, y1, x2, y2 = (min(1.0, max(0.0, v)) for v in (x1, y1, x2, y2))
                handle.write(f"{EQUIPMENT_CLASSES.index(cls)} {(x1 + x2) / 2:.5f} {(y1 + y2) / 2:.5f} "
                             f"{x2 - x1:.5f} {y2 - y1:.5f}\n")
        self.manifest.append({"file": f"images/{split}/{name}.jpg", "split": split, "source": source,
                              "origin": os.path.relpath(path, ROOT), "licence": licence,
                              "classes": ";".join(sorted({box[0] for box in boxes}))})
        return True


def yolo_items(folder: str, split: str, names: list[str]) -> list[tuple]:
    """Возвращает пары (снимок, рамки по именам классов) части набора YOLO с папками images и labels."""
    items = []
    for path in sorted(glob.glob(os.path.join(folder, "images", split, "*"))):
        label = os.path.join(folder, "labels", split, os.path.splitext(os.path.basename(path))[0] + ".txt")
        lines = open(label).read().splitlines() if os.path.exists(label) else []
        items.append((path, parse_rows(lines, names)))
    return items


def add_stand(writer: EquipmentWriter) -> None:
    """Добавляет рендеры макета: части train, val и test рендеров идут в одноимённые части набора."""
    folder = os.path.join(ROOT, "data", "blender", "ds")
    for split in ("train", "val", "test"):
        for index, (path, rows) in enumerate(yolo_items(folder, split, list(PART_NAMES[:11]))):
            boxes = stand_boxes(rows)
            if boxes:
                writer.put(split, f"bl_{split[:2]}{index:04d}", path, boxes, "blender", "собственные рендеры")


def add_parts_real(writer: EquipmentWriter) -> None:
    """Добавляет реальные снимки parts_real: train -> train, test -> test (только снимки с двигателем или агрегатом)."""
    folder = os.path.join(OPEN, "parts_real")
    licences = {row["file"]: row.get("licence", "") for row in csv.DictReader(open(os.path.join(folder, "manifest.csv"), encoding="utf-8"))}
    for split in ("train", "test"):
        for index, (path, rows) in enumerate(yolo_items(folder, split, list(PART_NAMES))):
            boxes = real_part_boxes(rows)
            if boxes:
                writer.put(split, f"pr_{split[:2]}{index:04d}", path, boxes, "parts_real",
                           licences.get(f"images/{split}/{os.path.basename(path)}", "см. parts_real/manifest.csv"))


def add_source(writer: EquipmentWriter, source: dict, rng: random.Random) -> dict:
    """Добавляет источник Roboflow: train источника -> train и val, valid и test источника -> test, с квотами."""
    base = os.path.join(OPEN, source["folder"])
    names = class_names(base)
    flat = source.get("layout") == "flat"
    taken = {"train": 0, "val": 0, "test": 0}
    for part in ("train", "valid", "test"):
        items = []
        folder = os.path.join(base, "images", "val" if part == "valid" else part) if flat else os.path.join(base, part, "images")
        for path in sorted(glob.glob(os.path.join(folder, "*"))):
            stem = os.path.splitext(os.path.basename(path))[0]
            label = (os.path.join(base, "labels", "val" if part == "valid" else part, stem + ".txt") if flat
                     else os.path.join(base, part, "labels", stem + ".txt"))
            boxes = map_source(source, parse_rows(open(label).read().splitlines() if os.path.exists(label) else [], names))
            if boxes:
                items.append((path, boxes))
        rng.shuffle(items)
        for index, (path, boxes) in enumerate(items):
            if part == "train":
                split = "val" if index % VAL_EVERY == 0 else "train"
                if taken["train"] + taken["val"] >= source["cap"]:
                    break
            else:
                split = "test"
                if taken["test"] >= source.get("test_cap", 60):
                    break
            taken[split] += writer.put(split, f"{source['key']}_{part[:2]}{index:05d}", path, boxes, source["key"],
                                       source["licence"])
    return taken


def main() -> None:
    """Собирает набор, data.yaml, опись, журнал повторов и сводку."""
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()
    rng = random.Random(args.seed)
    if os.path.exists(args.out):
        shutil.rmtree(args.out)
    spec = json.load(open(os.path.join(ROOT, "cv", "customer_labels.json"), encoding="utf-8"))
    writer = EquipmentWriter(args.out, build_guard(spec), rng)
    add_stand(writer)
    add_parts_real(writer)
    sources = SOURCES + (json.load(open(EXTRA_FILE, encoding="utf-8")) if os.path.exists(EXTRA_FILE) else [])
    taken = {}
    for source in sources:
        if os.path.isdir(os.path.join(OPEN, source["folder"])):
            taken[source["key"]] = add_source(writer, source, rng)
            print(source["key"], taken[source["key"]], flush=True)
    with open(os.path.join(args.out, "data.yaml"), "w", encoding="utf-8") as handle:
        handle.write(f"path: {os.path.abspath(args.out)}\ntrain: images/train\nval: images/val\ntest: images/test\nnames:\n")
        handle.writelines(f"  {index}: {name}\n" for index, name in enumerate(EQUIPMENT_CLASSES))
    with open(os.path.join(args.out, "manifest.csv"), "w", encoding="utf-8", newline="") as handle:
        table = csv.DictWriter(handle, fieldnames=["file", "split", "source", "origin", "licence", "classes"])
        table.writeheader()
        table.writerows(writer.manifest)
    json.dump({"dropped": writer.dropped, "twins": writer.twins, "drop_bits": DROP_BITS, "intra_bits": INTRA_BITS},
              open(os.path.join(args.out, "dedup.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    summary = {"sources": taken, "splits": {split: equipment_counts(args.out, split) for split in ("train", "val", "test")}}
    json.dump(summary, open(os.path.join(args.out, "summary.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps(summary["splits"], ensure_ascii=False))


def equipment_counts(out: str, split: str) -> dict:
    """Считает кадры и рамки по классам типа оборудования в части набора."""
    row = {"images": 0, "boxes": {name: 0 for name in EQUIPMENT_CLASSES}}
    for label in glob.glob(os.path.join(out, "labels", split, "*.txt")):
        row["images"] += 1
        for line in open(label):
            if line.strip():
                row["boxes"][EQUIPMENT_CLASSES[int(line.split()[0])]] += 1
    return row


if __name__ == "__main__":
    main()
