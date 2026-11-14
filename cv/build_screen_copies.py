"""Копии обучающих кадров открытых наборов с имитацией съёмки с монитора для третьей сборки набора дефектов.

Запуск:
    python cv/build_screen_copies.py data/open/defects_ds_v3 [--share 0.5] [--seed 1]

Для доли share уникальных обучающих кадров открытых наборов строится один кадр "съёмка с монитора":
перспектива, фон вокруг экрана, муар, блик, размытие, сдвиг цвета и сжатие JPEG (gen_synth.make_frame).
Кадры заказчика пропускаются, у них такие копии уже есть; кадры макета и повторы редких классов тоже.
Результат пишется в отдельные папки images/train_screen и labels/train_screen и в screen_manifest.csv,
поэтому обучение можно запускать и с этими копиями, и без них. Проверочная, отложенная части и набор из
сети не затрагиваются; исходные кадры уже прошли проверку на повторы тестовых снимков при сборке набора.
"""
import argparse
import csv
import glob
import os
import random
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_defects import bridge_files, read_image
from gen_synth import make_frame


def is_open_frame(name: str) -> bool:
    """Возвращает True для кадра открытого набора: не заказчик, не макет и не повтор редкого класса."""
    if "_x" in name or name.startswith("b_"):
        return False
    return not (name[0] == "c" and name[1:3].isdigit())


def read_rows(path: str) -> list[tuple]:
    """Читает разметку YOLO как (класс, x1, y1, x2, y2) в долях кадра."""
    rows = []
    for line in open(path, encoding="utf-8"):
        parts = line.split()
        if len(parts) == 5:
            cls, x, y, w, h = int(parts[0]), *map(float, parts[1:])
            rows.append((cls, x - w / 2, y - h / 2, x + w / 2, y + h / 2))
    return rows


def build(folder: str, share: float, seed: int) -> dict:
    """Строит экранные копии и возвращает число кадров и рамок по классам."""
    random.seed(seed)
    np.random.seed(seed)
    _, backgrounds = bridge_files()
    out_images = os.path.join(folder, "images", "train_screen")
    out_labels = os.path.join(folder, "labels", "train_screen")
    os.makedirs(out_images, exist_ok=True)
    os.makedirs(out_labels, exist_ok=True)
    names = sorted(os.path.basename(path)[:-4] for path in glob.glob(os.path.join(folder, "labels", "train", "*.txt")))
    picked = [name for name in names if is_open_frame(name) and random.random() < share]
    counts = {"images": 0, "empty_images": 0, "boxes": {}}
    manifest = []
    for name in picked:
        image = read_image(os.path.join(folder, "images", "train", name + ".jpg"))
        if image is None:
            continue
        rows = read_rows(os.path.join(folder, "labels", "train", name + ".txt"))
        frame, labels = make_frame(image, rows, backgrounds, scale_range=(0.6, 1.3), center_range=(0.38, 0.62))
        if rows and not labels:
            continue
        cv2.imwrite(os.path.join(out_images, name + "_s.jpg"), frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
        with open(os.path.join(out_labels, name + "_s.txt"), "w", encoding="utf-8") as handle:
            handle.writelines(f"{c} {x:.6f} {y:.6f} {w:.6f} {h:.6f}\n" for c, x, y, w, h in labels)
        counts["images"] += 1
        counts["empty_images"] += not labels
        for c, *_ in labels:
            counts["boxes"][c] = counts["boxes"].get(c, 0) + 1
        manifest.append({"file": f"images/train_screen/{name}_s.jpg", "from": f"images/train/{name}.jpg"})
    with open(os.path.join(folder, "screen_manifest.csv"), "w", encoding="utf-8", newline="") as handle:
        table = csv.DictWriter(handle, fieldnames=["file", "from"])
        table.writeheader()
        table.writerows(manifest)
    return counts


def main() -> None:
    """Разбирает параметры, строит копии и печатает сводку."""
    parser = argparse.ArgumentParser()
    parser.add_argument("folder")
    parser.add_argument("--share", type=float, default=0.5)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    print(build(args.folder, args.share, args.seed))


if __name__ == "__main__":
    main()
