"""Сборка набора для модели узлов: кадры макета из Blender и реальные снимки узлов parts_real.

Запуск:
    python cv/build_parts_mix.py data/open/parts_mix_v1 [--val-every 7]

Классы прежние, 11 штук, как у models/detector.onnx (PART_CLASSES в cv/protocol.py). Рамки класса
valve из parts_real отбрасываются: в обучающей части он один, а новый класс сломал бы совместимость
с сервером.

Состав:
    train - обучающая часть data/blender/ds (имена bl_*) и обучающая часть data/open/parts_real
            (имена real_*), кроме кадров, отложенных в val;
    val - проверочная часть data/blender/ds и каждый N-й снимок обучающей части parts_real; по val
          выбирается эпоха, порог здесь не подбирается.
Тестовые кадры (тест Blender и тест parts_real) в набор не входят. Каждый реальный кадр сравнивается
по pHash и dHash со всеми защищёнными снимками (отложенные снимки заказчика, их копии, data/web_testset,
тест parts_real): при расстоянии до 10 бит кадр выбрасывается, от 11 до 16 бит пара пишется
в dedup.json для просмотра глазами.

Разметка parts_real неполная: на снимке размечены только классы из manifest.csv, остальные узлы
на нём (например, шильдик на двигателе) при обучении считаются фоном. Это известная слабость набора.
"""
import argparse
import csv
import glob
import json
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_defects_v3 import DROP_BITS, REVIEW_BITS, build_guard, read_any
from protocol import PART_CLASSES

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BLENDER = os.path.join(ROOT, "data", "blender", "ds")
REAL = os.path.join(ROOT, "data", "open", "parts_real")


def copy_pair(image: str, label: str, out: str, split: str, name: str, keep: int) -> dict:
    """Копирует кадр и его разметку под новым именем, оставляя классы с номером меньше keep.

    Возвращает число рамок по именам классов.
    """
    os.makedirs(os.path.join(out, "images", split), exist_ok=True)
    os.makedirs(os.path.join(out, "labels", split), exist_ok=True)
    extension = os.path.splitext(image)[1].lower()
    shutil.copy2(image, os.path.join(out, "images", split, name + extension))
    rows, counts = [], {}
    if os.path.exists(label):
        for line in open(label, encoding="utf-8"):
            parts = line.split()
            if len(parts) == 5 and int(parts[0]) < keep:
                rows.append(line.strip())
                counts[PART_CLASSES[int(parts[0])]] = counts.get(PART_CLASSES[int(parts[0])], 0) + 1
    with open(os.path.join(out, "labels", split, name + ".txt"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(rows) + ("\n" if rows else ""))
    return counts


def add_counts(total: dict, counts: dict) -> None:
    """Прибавляет счётчики рамок к общему счётчику."""
    for key, value in counts.items():
        total[key] = total.get(key, 0) + value


def main() -> None:
    """Собирает набор, data.yaml, data_rel.yaml, manifest.csv, dedup.json и summary.json."""
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--val-every", type=int, default=7)
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    if os.path.isdir(out):
        shutil.rmtree(out)
    spec = json.load(open(os.path.join(ROOT, "cv", "customer_labels.json"), encoding="utf-8"))
    guard = build_guard(spec)
    manifest = [("file", "split", "source", "origin", "licence")]
    boxes = {"train": {}, "val": {}}
    images = {"train": {"blender": 0, "real": 0}, "val": {"blender": 0, "real": 0}}
    dropped, review = [], []
    for split in ("train", "val"):
        for path in sorted(glob.glob(os.path.join(BLENDER, "images", split, "*.jpg"))):
            stem = os.path.splitext(os.path.basename(path))[0]
            name = "bl_" + stem
            add_counts(boxes[split], copy_pair(path, os.path.join(BLENDER, "labels", split, stem + ".txt"),
                                               out, split, name, len(PART_CLASSES)))
            images[split]["blender"] += 1
            manifest.append((f"images/{split}/{name}.jpg", split, "blender", os.path.relpath(path, ROOT),
                             "собственные данные проекта"))
    rows = [row for row in csv.DictReader(open(os.path.join(REAL, "manifest.csv"), encoding="utf-8"))
            if row["split"] == "train"]
    rows.sort(key=lambda row: row["file"])
    for index, row in enumerate(rows):
        path = os.path.join(REAL, row["file"])
        distance, who = guard.nearest(read_any(path))
        if distance <= DROP_BITS:
            dropped.append((row["file"], who, distance))
            continue
        if distance <= REVIEW_BITS:
            review.append((row["file"], who, distance))
        split = "val" if index % args.val_every == args.val_every - 1 else "train"
        stem = os.path.splitext(os.path.basename(path))[0]
        name = "real_" + stem
        add_counts(boxes[split], copy_pair(path, os.path.join(REAL, "labels", "train", stem + ".txt"),
                                           out, split, name, len(PART_CLASSES)))
        images[split]["real"] += 1
        manifest.append((f"images/{split}/{name}{os.path.splitext(path)[1].lower()}", split, row["source"],
                         row["page_url"], row["licence"]))
    names = "".join(f"  {index}: {label}\n" for index, label in enumerate(PART_CLASSES))
    with open(os.path.join(out, "data.yaml"), "w", encoding="utf-8") as handle:
        handle.write(f"path: {out}\ntrain: images/train\nval: images/val\nnames:\n{names}")
    with open(os.path.join(out, "data_rel.yaml"), "w", encoding="utf-8") as handle:
        handle.write(f"train: images/train\nval: images/val\nnames:\n{names}")
    with open(os.path.join(out, "manifest.csv"), "w", encoding="utf-8", newline="") as handle:
        csv.writer(handle).writerows(manifest)
    json.dump({"dropped": dropped, "review": review, "drop_bits": DROP_BITS, "review_bits": REVIEW_BITS},
              open(os.path.join(out, "dedup.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    summary = {"date": time.strftime("%Y-%m-%d"), "classes": list(PART_CLASSES), "images": images, "boxes": boxes,
               "dropped_near_test": len(dropped), "review_pairs": len(review), "val_every": args.val_every}
    json.dump(summary, open(os.path.join(out, "summary.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == "__main__":
    main()
