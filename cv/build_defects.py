"""Сборка набора реальных дефектов для обучения и честной проверки детектора.

Запуск:
    python cv/build_defects.py <папка_набора> [--screen 7] [--rare 7] [--bridge 100] [--stand 60] [--seed 0]

Параметр --screen задаёт число экранных копий снимка заказчика, --rare то же для снимков с редкими
классами (всё, кроме коррозии): так выравнивается перекос классов в обучении.

Источники:
    снимки заказчика с ручной разметкой из cv/customer_labels.json: обучающие идут в набор как есть
    и в виде кадров "съёмка с монитора", отложенные снимки в обучение не попадают никогда;
    Zenodo 11235637 (коррозия на промышленных объектах): маски переводятся в рамки;
    Roboflow corrosion-bi3q3: только снимки с крупной рамкой коррозии;
    кадры макета из Blender: дефекты макета и чистые кадры как отрицательные примеры.
Снимки Zenodo, попавшие в тестовый набор data/web_testset, из обучения исключаются по manifest.csv.
"""

import argparse
import csv
import glob
import json
import os
import random
import re

import cv2
import numpy as np

from gen_synth import make_frame

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
STAND_DEFECTS = ("leak", "corrosion", "terminal_box_burnt")
MAX_SIDE = 1024


def read_image(path: str) -> np.ndarray:
    """Читает изображение по пути с кириллицей и уменьшает длинную сторону до рабочего размера."""
    image = cv2.imdecode(np.fromfile(path, np.uint8), cv2.IMREAD_COLOR)
    scale = MAX_SIDE / max(image.shape[:2])
    if scale < 1.0:
        image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    return image


def mask_to_boxes(mask: np.ndarray, min_share: float = 0.0015, limit: int = 12) -> list[tuple]:
    """Переводит маску дефекта в рамки связных областей в долях изображения.

    Мелкие области отбрасываются. Если после этого не осталось ни одной, берётся общая рамка маски.
    """
    side = 512 / max(mask.shape[:2])
    small = cv2.resize(mask, None, fx=side, fy=side, interpolation=cv2.INTER_NEAREST)
    binary = cv2.morphologyEx((small > 0).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((7, 7), np.uint8))
    height, width = binary.shape
    count, _, stats, _ = cv2.connectedComponentsWithStats(binary)
    parts = sorted((row for row in stats[1:count] if row[4] >= min_share * height * width), key=lambda row: -row[4])
    if not parts and binary.any():
        ys, xs = np.nonzero(binary)
        parts = [(xs.min(), ys.min(), xs.max() - xs.min() + 1, ys.max() - ys.min() + 1, 0)]
    return [(x / width, y / height, (x + w) / width, (y + h) / height) for x, y, w, h, _ in parts[:limit]]


def web_test_members() -> set[tuple]:
    """Возвращает снимки открытого набора Zenodo, занятые тестовым набором, как пары (выборка, имя)."""
    path = os.path.join(ROOT, "data", "web_testset", "manifest.csv")
    taken = set()
    if os.path.exists(path):
        for row in csv.DictReader(open(path, encoding="utf-8")):
            found = re.search(r"ostrava/(train|validation|test)/images/([^/&]+)\.jpg", row.get("download_url", ""))
            if found:
                taken.add((found.group(1), found.group(2)))
    return taken


class Writer:
    """Записывает кадры и разметку набора и считает рамки по источникам."""

    def __init__(self, out: str, classes: list[str]):
        """Запоминает папку набора и список классов."""
        self.out, self.classes, self.counts = out, classes, {}

    def add(self, split: str, name: str, image: np.ndarray, boxes: list[tuple], source: str) -> None:
        """Сохраняет кадр и его рамки. Рамка задана как (класс, x1, y1, x2, y2) в долях кадра."""
        os.makedirs(f"{self.out}/images/{split}", exist_ok=True)
        os.makedirs(f"{self.out}/labels/{split}", exist_ok=True)
        cv2.imwrite(f"{self.out}/images/{split}/{name}.jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 90])
        row = self.counts.setdefault(f"{split}/{source}", {"images": 0, "boxes": {}})
        row["images"] += 1
        with open(f"{self.out}/labels/{split}/{name}.txt", "w") as handle:
            for cls, x1, y1, x2, y2 in boxes:
                x1, y1, x2, y2 = (min(1.0, max(0.0, v)) for v in (x1, y1, x2, y2))
                handle.write(f"{self.classes.index(cls)} {(x1 + x2) / 2:.5f} {(y1 + y2) / 2:.5f} {x2 - x1:.5f} {y2 - y1:.5f}\n")
                row["boxes"][cls] = row["boxes"].get(cls, 0) + 1

    def add_screen(
        self, split: str, name: str, image: np.ndarray, boxes: list[tuple], backgrounds: list[str], source: str
    ) -> None:
        """Сохраняет кадр, имитирующий съёмку изображения с монитора, с пересчитанными рамками."""
        indexed = [(self.classes.index(cls), x1, y1, x2, y2) for cls, x1, y1, x2, y2 in boxes]
        frame, labels = make_frame(image, indexed, backgrounds, scale_range=(0.6, 1.3), center_range=(0.38, 0.62))
        moved = [(self.classes[c], x - w / 2, y - h / 2, x + w / 2, y + h / 2) for c, x, y, w, h in labels]
        self.add(split, name, frame, moved, source)


def add_customer(writer: Writer, spec: dict, screen: int, rare: int, backgrounds: list[str]) -> None:
    """Добавляет снимки заказчика: обучающие, проверочные экранные копии и отложенную выборку.

    Снимки с редкими классами получают rare экранных копий, остальные screen.
    """
    for index, item in enumerate(spec["images"]):
        image = read_image(os.path.join(ROOT, "data", "customer", item["file"]))
        boxes = [tuple(box) for box in item["boxes"]]
        if item["split"] == "holdout":
            writer.add("holdout", f"h{index:02d}", image, boxes, "customer")
            for copy in range(5):
                writer.add_screen("holdout_screen", f"h{index:02d}_{copy}", image, boxes, backgrounds, "customer_screen")
            continue
        writer.add("train", f"c{index:02d}", image, boxes, "customer")
        for copy in range(rare if any(box[0] != "corrosion" for box in boxes) else screen):
            writer.add_screen("train", f"c{index:02d}_s{copy}", image, boxes, backgrounds, "customer_screen")
        for copy in range(2):
            writer.add_screen("val", f"c{index:02d}_v{copy}", image, boxes, backgrounds, "customer_screen")


def add_industrial(writer: Writer) -> None:
    """Добавляет снимки промышленной коррозии с масками: train в обучение, остальное в проверку."""
    taken = web_test_members()
    for folder in sorted(glob.glob(os.path.join(ROOT, "data", "open", "ostrava-corrosion", "unpacked", "*", "*"))):
        part = os.path.basename(folder)
        for path in sorted(glob.glob(os.path.join(folder, "images", "*.jpg"))):
            name = os.path.basename(path)[:-4]
            if (part, name) in taken:
                continue
            mask = cv2.imread(os.path.join(folder, "masks", name + ".png"), cv2.IMREAD_GRAYSCALE)
            boxes = [("corrosion", *box) for box in mask_to_boxes(mask)] if mask is not None else []
            if boxes:
                writer.add("train" if part == "train" else "val", f"o_{part[:2]}{name}", read_image(path), boxes, "ostrava")


def bridge_files() -> tuple[list[tuple], list[str]]:
    """Делит снимки corrosion-bi3q3 на пригодные (есть рамка коррозии от 1% кадра) и фоновые без коррозии."""
    usable, plain = [], []
    folder = os.path.join(ROOT, "data", "open", "corrosion-bi3q3", "train")
    names = [
        line.strip()[2:] for line in open(os.path.join(folder, "..", "data.yaml"), encoding="utf-8") if line.startswith("- ")
    ]
    for path in sorted(glob.glob(os.path.join(folder, "images", "*.jpg"))):
        label = os.path.join(folder, "labels", os.path.basename(path)[:-4] + ".txt")
        rows = [line.split() for line in open(label)] if os.path.exists(label) else []
        boxes = [tuple(float(v) for v in row[1:5]) for row in rows if len(row) >= 5 and names[int(row[0])] == "corrosion"]
        if boxes and max(w * h for _, _, w, h in boxes) >= 0.01:
            usable.append((path, [("corrosion", x - w / 2, y - h / 2, x + w / 2, y + h / 2) for x, y, w, h in boxes]))
        elif not boxes and all(names[int(row[0])] == "Slippage" for row in rows if row):
            plain.append(path)
    return usable, plain


def add_stand(writer: Writer, count: int) -> None:
    """Добавляет кадры макета: рамки дефектов макета сохраняются, исправные узлы становятся фоном."""
    folder = os.path.join(ROOT, "data", "blender", "ds")
    names = [
        line.split(":")[1].strip()
        for line in open(os.path.join(folder, "data.yaml"), encoding="utf-8")
        if line.strip().split(":")[0].isdigit()
    ]
    files = sorted(glob.glob(os.path.join(folder, "images", "train", "*.jpg")))
    for path in random.sample(files, min(count, len(files))):
        label = os.path.join(folder, "labels", "train", os.path.basename(path)[:-4] + ".txt")
        boxes = []
        for line in open(label) if os.path.exists(label) else []:
            cls, x, y, w, h = line.split()[:5]
            x, y, w, h = float(x), float(y), float(w), float(h)
            if names[int(cls)] in STAND_DEFECTS:
                boxes.append((names[int(cls)], x - w / 2, y - h / 2, x + w / 2, y + h / 2))
        writer.add("train", "b_" + os.path.basename(path)[:-4], cv2.imread(path), boxes, "blender")


def main() -> None:
    """Собирает набор, файл data.yaml и сводку количества кадров и рамок по источникам."""
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--screen", type=int, default=7)
    parser.add_argument("--rare", type=int, default=None)
    parser.add_argument("--bridge", type=int, default=100)
    parser.add_argument("--stand", type=int, default=60)
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()
    random.seed(args.seed)
    np.random.seed(args.seed)
    spec = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "customer_labels.json"), encoding="utf-8"))
    writer = Writer(args.out, spec["classes"])
    usable, plain = bridge_files()
    add_customer(writer, spec, args.screen, args.rare if args.rare is not None else args.screen, plain)
    add_industrial(writer)
    for path, boxes in random.sample(usable, min(args.bridge, len(usable))):
        writer.add("train", "r_" + os.path.basename(path)[:24], read_image(path), boxes, "bi3q3")
    add_stand(writer, args.stand)
    with open(f"{args.out}/data.yaml", "w", encoding="utf-8") as handle:
        handle.write(f"path: {os.path.abspath(args.out)}\ntrain: images/train\nval: images/val\nnames:\n")
        handle.writelines(f"  {index}: {name}\n" for index, name in enumerate(spec["classes"]))
    json.dump(writer.counts, open(f"{args.out}/summary.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    for key, row in sorted(writer.counts.items()):
        print(f"{key:32s} кадров {row['images']:4d}  рамок {row['boxes']}")


if __name__ == "__main__":
    main()
