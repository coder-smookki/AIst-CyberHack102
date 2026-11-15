"""Вторая сборка набора детектора типа оборудования: data/equipment_ds_v1 без изменений плюс новые кадры.

Запуск:
    python cv/build_equipment_v2.py [data/equipment_ds_v2] [--seed 0]

Части val, test и negtest первой сборки переносятся жёсткими ссылками кадр в кадр, поэтому показатели
старой и новой модели на test, нечётных кадрах negtest, data/open/clean-indoor, data/web_testset и рендерах
сравнимы. Новые кадры идут только в train и val (каждый VAL_EVERY-й); части valid и test новых источников
кладутся в отдельную часть newtest (в выборе эпохи и порогов не участвует).
Проверка повторов: каждый новый кадр сравнивается по pHash и dHash (cv/build_defects_v3.Guard, до 10 бит)
с отложенными снимками заказчика, их копиями, data/web_testset, тестом parts_real, data/open/clean-indoor,
всеми кадрами test и negtest первой сборки и тестом рендеров; повторы внутри набора (до 8 бит по целому
кадру) - против всех кадров первой сборки и уже взятых новых.
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
from build_defects_v4 import class_names, parse_rows
from build_equipment import EQUIPMENT_CLASSES, OPEN, VAL_EVERY, EquipmentWriter, equipment_counts, map_source

V1 = os.path.join(ROOT, "data", "equipment_ds_v1")
VALVE_ROBOTICS = {
    name: "valve"
    for name in (
        "Lever Handle Butterfly Valve",
        "Lever Handle Valve Flanged",
        "Lever Handle Valve Threaded",
        "Wheel Handle Butterfly Valve",
        "Wheel Handle Valve Flanged",
        "Wheel Handle Valve Threaded",
        "Wheel Handle Valve Y-Type Flanged",
        "Wheel Handle Valve Y-Type Threaded",
    )
}
NEW_SOURCES = [
    {
        "key": "valverob",
        "folder": "rf-valve-robotics/raw",
        "map": VALVE_ROBOTICS,
        "min_area": 0.002,
        "cap": 400,
        "licence": "CC BY 4.0 (Roboflow valve-robotics-computer-vision/valve-detection-xcwdr v1)",
    },
    {
        "key": "circpump",
        "folder": "rf-valve-pump-eh/raw",
        "map": {"pump": "pump_unit"},
        "skip": ("valve",),
        "cap": 200,
        "licence": "CC BY 4.0 (Roboflow edensharvey/valveandpump v1)",
    },
    {
        "key": "pumpsat",
        "folder": "rf-pumps-at/raw",
        "map": {"pump": "pump_unit"},
        "cap": 60,
        "licence": "CC BY 4.0 (Roboflow alec-tinker/pumps-byij8 v1)",
    },
]
HARD_NEGATIVE_LICENCE = "Wikimedia Commons, лицензия каждого снимка в indoor-negatives/manifest.csv"


def link_v1(out: str) -> None:
    """Переносит все части первой сборки жёсткими ссылками и копирует опись."""
    for kind in ("images", "labels"):
        for split in ("train", "val", "test", "negtest"):
            source = os.path.join(V1, kind, split)
            target = os.path.join(out, kind, split)
            os.makedirs(target, exist_ok=True)
            for name in os.listdir(source):
                os.link(os.path.join(source, name), os.path.join(target, name))
    shutil.copy(os.path.join(V1, "manifest.csv"), os.path.join(out, "manifest.csv"))


def protect_extra(guard) -> int:
    """Добавляет к защищённым снимкам clean-indoor, test и negtest первой сборки и тест рендеров."""
    paths = sorted(glob.glob(os.path.join(OPEN, "clean-indoor", "images", "*")))
    paths += sorted(glob.glob(os.path.join(V1, "images", "test", "*")))
    paths += sorted(glob.glob(os.path.join(V1, "images", "negtest", "*")))
    paths += sorted(glob.glob(os.path.join(ROOT, "data", "blender", "ds", "images", "test", "*")))
    for path in paths:
        image = read_any(path)
        if image is not None:
            guard.protect("protected:" + os.path.relpath(path, ROOT), image)
    return len(paths)


def preload(writer: EquipmentWriter) -> None:
    """Заносит кадры первой сборки в индексы повторов: train и val в train, test и negtest в test."""
    for split, group in (("train", "train"), ("val", "train"), ("test", "test"), ("negtest", "test")):
        for path in sorted(glob.glob(os.path.join(V1, "images", split, "*"))):
            image = cv2.imread(path)
            if image is not None:
                writer.index[group].add(f"v1:{split}/{os.path.basename(path)}", cv2.cvtColor(image, cv2.COLOR_BGR2GRAY))


def add_new_source(writer: EquipmentWriter, source: dict, rng: random.Random) -> dict:
    """Части train источника -> train и val, части valid и test -> newtest; кадры с классами skip не берутся."""
    base = os.path.join(OPEN, source["folder"])
    names = class_names(base)
    taken = {"train": 0, "val": 0, "newtest": 0, "skipped_class": 0}
    for part in ("train", "valid", "test"):
        items = []
        for path in sorted(glob.glob(os.path.join(base, part, "images", "*"))):
            label = os.path.join(base, part, "labels", os.path.splitext(os.path.basename(path))[0] + ".txt")
            rows = parse_rows(open(label).read().splitlines() if os.path.exists(label) else [], names)
            if any(row[0] in source.get("skip", ()) for row in rows):
                taken["skipped_class"] += 1
                continue
            boxes = map_source(source, rows)
            if boxes:
                items.append((path, boxes))
        rng.shuffle(items)
        for index, (path, boxes) in enumerate(items):
            split = ("val" if index % VAL_EVERY == 0 else "train") if part == "train" else "newtest"
            if part == "train" and taken["train"] + taken["val"] >= source["cap"]:
                break
            taken[split] += writer.put(
                split, f"{source['key']}_{part[:2]}{index:05d}", path, boxes, source["key"], source["licence"]
            )
    return taken


def add_hard_negatives(writer: EquipmentWriter, rng: random.Random) -> int:
    """Добавляет в train неиспользованные снимки indoor-negatives (клавиатуры, разъёмы, ручки, краны и т. п.).

    Снимки, которые первая сборка отвела в negtest (каждый 4-й по порядку), и уже взятые в train пропускаются.
    """
    pool = sorted(glob.glob(os.path.join(OPEN, "indoor-negatives", "images", "*")))
    reserved = set(pool[::4])
    used = {row["origin"] for row in csv.DictReader(open(os.path.join(V1, "manifest.csv"), encoding="utf-8"))}
    free = [path for path in pool if path not in reserved and os.path.relpath(path, ROOT) not in used]
    rng.shuffle(free)
    done = 0
    for index, path in enumerate(free):
        done += writer.put("train", f"neg_hard_{index:05d}", path, [], "neg_hard", HARD_NEGATIVE_LICENCE)
    return done


def main() -> None:
    """Собирает вторую сборку, data.yaml, опись, журнал повторов и сводку."""
    parser = argparse.ArgumentParser()
    parser.add_argument("out", nargs="?", default=os.path.join(ROOT, "data", "equipment_ds_v2"))
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()
    rng = random.Random(args.seed)
    if os.path.exists(args.out):
        shutil.rmtree(args.out)
    link_v1(args.out)
    spec = json.load(open(os.path.join(ROOT, "cv", "customer_labels.json"), encoding="utf-8"))
    guard = build_guard(spec)
    extra = protect_extra(guard)
    writer = EquipmentWriter(args.out, guard, rng)
    preload(writer)
    taken = {source["key"]: add_new_source(writer, source, rng) for source in NEW_SOURCES}
    taken["neg_hard"] = {"train": add_hard_negatives(writer, rng)}
    print(json.dumps(taken, ensure_ascii=False), flush=True)
    with open(os.path.join(args.out, "data.yaml"), "w", encoding="utf-8") as handle:
        handle.write(f"path: {os.path.abspath(args.out)}\ntrain: images/train\nval: images/val\ntest: images/test\nnames:\n")
        handle.writelines(f"  {index}: {name}\n" for index, name in enumerate(EQUIPMENT_CLASSES))
    with open(os.path.join(args.out, "manifest.csv"), "a", encoding="utf-8", newline="") as handle:
        csv.DictWriter(handle, fieldnames=["file", "split", "source", "origin", "licence", "classes"]).writerows(writer.manifest)
    json.dump(
        {"dropped": writer.dropped, "twins": writer.twins, "extra_protected": extra},
        open(os.path.join(args.out, "dedup_v2.json"), "w", encoding="utf-8"),
        ensure_ascii=False,
        indent=1,
    )
    summary = {
        "base": "data/equipment_ds_v1",
        "new_sources": taken,
        "splits": {split: equipment_counts(args.out, split) for split in ("train", "val", "test", "negtest", "newtest")},
    }
    json.dump(summary, open(os.path.join(args.out, "summary.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps(summary["splits"], ensure_ascii=False))


if __name__ == "__main__":
    main()
