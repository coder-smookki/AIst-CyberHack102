"""Третья сборка набора реальных дефектов: прежние источники, новые открытые наборы и трудные чистые кадры.

Запуск:
    python cv/build_defects_v3.py data/open/defects_ds_v3 [--seed 0]

Схема классов дефектов прежняя (DEFECT_CLASSES в cv/protocol.py): corrosion, leak, terminal_box_burnt,
damage. Новых классов нет: ни для отсутствующего кожуха муфты, ни для ослабленных болтов не нашлось
открытого набора хотя бы со 150 пригодными рамками без утечки тестовых снимков.

Источники и сопоставление классов перечислены в SOURCES ниже и в data/DATASETS.txt. Снимки без рамок
(шильдики, манометры, исправные двигатели, тени на оборудовании) входят как трудные отрицательные примеры.

Честность проверки:
    отложенные снимки заказчика и их копии "с монитора" берутся без изменений из первой сборки
    data/open/defects_ds (жёсткие ссылки), чтобы все модели сравнивались на одних и тех же кадрах;
    каждый обучающий и проверочный кадр сравнивается по pHash и dHash (весь кадр, пять кадрирований,
    отражение и повороты) со всеми защищёнными снимками: отложенными снимками заказчика, их копиями,
    data/web_testset и тестовой частью data/open/parts_real. При расстоянии до 10 бит кадр выбрасывается,
    пары от 11 до 16 бит записываются в dedup.json для просмотра глазами;
    копии обучающих снимков заказчика в проверочную часть больше не кладутся, так как они завышали mAP.
"""
import argparse
import csv
import glob
import json
import os
import random
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_defects import ROOT, Writer, add_industrial, add_stand, bridge_files, mask_to_boxes, read_image
from gen_synth import make_frame
from protocol import DEFECT_CLASSES

OPEN = os.path.join(ROOT, "data", "open")
DROP_BITS = 10
REVIEW_BITS = 16

SOURCES = [
    {"key": "safenet", "folder": "safenet-coating/unpacked", "kind": "yolo_flat_splits",
     "map": {0: "corrosion", 1: "damage"}, "skip_if": {2, 3}, "min_area": {"damage": 0.004},
     "train": 700, "val": 100, "licence": "GPL (Figshare)"},
    {"key": "shipcorr", "folder": "kg-ship-corrosion/corrosion detect", "kind": "yolo_single",
     "map": {1: "corrosion"}, "train": 240, "val": 28, "licence": "MIT (Kaggle)"},
    {"key": "substation", "folder": "rf-substation-defects", "kind": "roboflow",
     "map": {20: "corrosion", 27: "leak", 28: "leak", 29: "leak"}, "negative_only": {26},
     "train": 600, "val": 80, "licence": "CC BY 4.0 (Roboflow)"},
    {"key": "indleak", "folder": "rf-industrial-leak", "kind": "roboflow",
     "map": {3: "leak", 4: "leak", 5: "leak"}, "skip_if": {0, 1, 2, 6, 7},
     "train": 450, "val": 60, "licence": "CC BY 4.0 (Roboflow)"},
    {"key": "oilleak", "folder": "rf-oil-leak", "kind": "roboflow", "map": {0: "leak"},
     "train": 80, "val": 15, "licence": "CC BY 4.0 (Roboflow)"},
    {"key": "elhaz", "folder": "rf-electrical-hazards", "kind": "roboflow",
     "map": {1: "terminal_box_burnt", 2: "damage"}, "skip_if": {3}, "dedup_bits": 8,
     "train": 400, "val": 50, "licence": "Public Domain (Roboflow)"},
    {"key": "adapters", "folder": "rf-burnt-adapters", "kind": "roboflow", "map": {0: "terminal_box_burnt"},
     "train": 60, "val": 0, "licence": "CC BY 4.0 (Roboflow)"},
    {"key": "pipedef", "folder": "rf-pipe-defects", "kind": "roboflow", "map": {0: "damage", 1: "damage", 2: "damage"},
     "train": 100, "val": 10, "licence": "CC BY 4.0 (Roboflow)"},
    {"key": "pipecorr", "folder": "rf-pipe-corrosion", "kind": "roboflow", "map": {0: "corrosion"}, "skip_if": {1},
     "train": 150, "val": 20, "licence": "CC BY 4.0 (Roboflow)"},
    {"key": "rusty3", "folder": "rf-rusty3", "kind": "roboflow", "map": {0: "corrosion"},
     "train": 120, "val": 15, "licence": "CC BY 4.0 (Roboflow)"},
    {"key": "insul", "folder": "rf-pipe-insulation-damage", "kind": "roboflow", "map": {1: "damage"},
     "min_area": {"damage": 0.001}, "train": 150, "val": 20, "licence": "CC BY 4.0 (Roboflow)"},
    {"key": "plate", "folder": "rf-nameplate", "kind": "roboflow", "map": {}, "negative": True,
     "train": 150, "val": 25, "licence": "CC BY 4.0 (Roboflow)"},
    {"key": "gauge", "folder": "kg-analog-gauge", "kind": "roboflow", "map": {}, "negative": True,
     "train": 80, "val": 15, "licence": "CC BY 4.0 (Kaggle)"},
    {"key": "motor", "folder": "rf-motor-housing", "kind": "roboflow", "map": {}, "negative": True, "skip_if": {1},
     "train": 50, "val": 10, "licence": "CC BY 4.0 (Roboflow)"},
]


def phash(gray: np.ndarray) -> int:
    """Возвращает 64-битный перцептивный хеш по низким частотам DCT серого кадра."""
    small = cv2.resize(gray, (32, 32), interpolation=cv2.INTER_AREA).astype(np.float32)
    low = cv2.dct(small)[:8, :8].flatten()
    bits = low > np.median(low[1:])
    return int(sum(1 << index for index, bit in enumerate(bits) if bit))


def dhash(gray: np.ndarray) -> int:
    """Возвращает 64-битный разностный хеш серого кадра."""
    small = cv2.resize(gray, (9, 8), interpolation=cv2.INTER_AREA).astype(np.int16)
    bits = (small[:, 1:] > small[:, :-1]).flatten()
    return int(sum(1 << index for index, bit in enumerate(bits) if bit))


def views(image: np.ndarray, turns: bool) -> list[np.ndarray]:
    """Даёт варианты кадра для сравнения: целиком, пять кадрирований по 70%, отражение и при turns повороты."""
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) if image.ndim == 3 else image
    height, width = gray.shape
    h, w = int(height * 0.7), int(width * 0.7)
    out = [gray, gray[(height - h) // 2:(height + h) // 2, (width - w) // 2:(width + w) // 2],
           gray[:h, :w], gray[:h, width - w:], gray[height - h:, :w], gray[height - h:, width - w:], gray[:, ::-1]]
    if turns:
        out += [np.rot90(gray, 1), np.rot90(gray, 2), np.rot90(gray, 3)]
    return out


def signature(image: np.ndarray, turns: bool = False) -> np.ndarray:
    """Возвращает массив пар (pHash, dHash) для всех вариантов кадра.

    Почти однотонный вариант (стандартное отклонение яркости меньше 12) даёт случайный хеш и ложные
    совпадения, поэтому вместо него повторяется хеш целого кадра.
    """
    rows = []
    for index, view in enumerate(views(image, turns)):
        view = np.ascontiguousarray(view)
        if index and float(view.std()) < 12.0:
            rows.append(rows[0])
        else:
            rows.append((phash(view), dhash(view)))
    return np.array(rows, dtype=np.uint64)


def distance_pairs(left: np.ndarray, right: np.ndarray) -> np.ndarray:
    """Расстояние пары вариантов - большее из расстояний pHash и dHash: совпасть должны оба хеша."""
    return popcount(np.bitwise_xor(left, right)).max(axis=-1)


def popcount(values: np.ndarray) -> np.ndarray:
    """Считает число единичных битов в каждом 64-битном числе."""
    return np.bitwise_count(values).astype(np.int64)


class Guard:
    """Хранит хеши защищённых тестовых снимков и находит к ним близкие кадры."""

    def __init__(self):
        """Создаёт пустой список защищённых снимков."""
        self.names, self.hashes, self.stack = [], [], None

    def protect(self, name: str, image: np.ndarray) -> None:
        """Добавляет защищённый снимок со всеми его вариантами, включая повороты."""
        self.names.append(name)
        self.hashes.append(signature(image, turns=True))
        self.stack = None

    def nearest(self, image: np.ndarray) -> tuple[int, str]:
        """Возвращает наименьшее расстояние до защищённых снимков и имя ближайшего.

        Расстояние - большее из pHash и dHash по лучшей паре вариантов; варианты кадра сравниваются
        с целым защищённым снимком, а целый кадр с вариантами защищённого, так ловятся кадрирования
        в обе стороны.
        """
        if not self.hashes:
            return 64, ""
        if self.stack is None:
            self.stack = np.stack(self.hashes)
        mine = signature(image)
        first = distance_pairs(mine[None, :, :], self.stack[:, :1, :]).min(axis=1)
        second = distance_pairs(mine[None, :1, :], self.stack).min(axis=1)
        distance = np.minimum(first, second)
        index = int(distance.argmin())
        return int(distance[index]), self.names[index]


def read_any(path: str) -> np.ndarray | None:
    """Читает изображение любого формата по пути с кириллицей."""
    data = np.fromfile(path, np.uint8)
    return cv2.imdecode(data, cv2.IMREAD_COLOR) if data.size else None


def build_guard(spec: dict) -> Guard:
    """Собирает защищённые снимки: отложенные снимки заказчика, их копии, web_testset и тест parts_real."""
    guard = Guard()
    for item in spec["images"]:
        if item["split"] == "holdout":
            guard.protect("customer:" + item["file"], read_any(os.path.join(ROOT, "data", "customer", item["file"])))
    for path in sorted(glob.glob(os.path.join(OPEN, "defects_ds", "images", "holdout_screen", "*.jpg"))):
        guard.protect("holdout_screen:" + os.path.basename(path), cv2.imread(path))
    for row in csv.DictReader(open(os.path.join(ROOT, "data", "web_testset", "manifest.csv"), encoding="utf-8")):
        path = os.path.join(ROOT, "data", "web_testset", row["file"])
        if os.path.exists(path):
            guard.protect("web:" + row["file"], read_any(path))
    for path in sorted(glob.glob(os.path.join(OPEN, "parts_real", "images", "test", "*"))):
        guard.protect("parts_test:" + os.path.basename(path), read_any(path))
    return guard


def yolo_rows(path: str) -> list[tuple]:
    """Читает разметку YOLO (рамки или полигоны) как (класс, x1, y1, x2, y2) в долях; битые строки пропускает."""
    rows = []
    for line in open(path) if os.path.exists(path) else []:
        parts = line.split()
        try:
            cls, values = int(parts[0]), [float(v) for v in parts[1:]]
        except (ValueError, IndexError):
            continue
        if len(values) == 4:
            x, y, w, h = values
            box = (x - w / 2, y - h / 2, x + w / 2, y + h / 2)
        elif len(values) >= 6 and len(values) % 2 == 0:
            box = (min(values[0::2]), min(values[1::2]), max(values[0::2]), max(values[1::2]))
        else:
            continue
        box = tuple(min(1.0, max(0.0, v)) for v in box)
        if box[2] - box[0] > 0.002 and box[3] - box[1] > 0.002 and max(values) <= 1.5:
            rows.append((cls, *box))
    return rows


def source_files(source: dict) -> dict:
    """Возвращает пары (снимок, разметка) источника, разложенные по частям исходного набора."""
    base = os.path.join(OPEN, source["folder"])
    parts = {}
    if source["kind"] == "roboflow":
        for part in ("train", "valid", "test"):
            parts[part] = [(p, os.path.join(base, part, "labels", os.path.splitext(os.path.basename(p))[0] + ".txt"))
                           for p in sorted(glob.glob(os.path.join(base, part, "images", "*")))]
    elif source["kind"] == "yolo_flat_splits":
        for part in ("train", "val", "test"):
            parts[part] = [(p, os.path.join(base, "labels", part, os.path.splitext(os.path.basename(p))[0] + ".txt"))
                           for p in sorted(glob.glob(os.path.join(base, "images", part, "*")))]
    else:
        files = sorted(glob.glob(os.path.join(base, "images", "*")))
        parts["all"] = [(p, os.path.join(base, "labels", os.path.splitext(os.path.basename(p))[0] + ".txt")) for p in files]
    return parts


def mapped_boxes(source: dict, rows: list[tuple]) -> list[tuple] | None:
    """Переводит рамки источника в классы схемы дефектов; None, если снимок не подходит по составу классов."""
    present = {row[0] for row in rows}
    if present & source.get("skip_if", set()):
        return None
    if source.get("negative"):
        return []
    boxes = []
    for cls, x1, y1, x2, y2 in rows:
        name = source["map"].get(cls)
        if name and (x2 - x1) * (y2 - y1) >= source.get("min_area", {}).get(name, 0.0):
            boxes.append((name, x1, y1, x2, y2))
    if boxes:
        return boxes
    if present and present <= source.get("negative_only", set()):
        return []
    return None


def candidates(source: dict, rng: random.Random) -> dict:
    """Отбирает снимки источника для train и val: val берётся из проверочных частей источника."""
    parts = source_files(source)
    if "all" in parts:
        pool = parts["all"][:]
        rng.shuffle(pool)
        cut = max(0, len(pool) - source["val"]) if source["val"] else len(pool)
        groups = {"train": pool[:cut], "val": pool[cut:]}
    else:
        groups = {"train": parts.get("train", []), "val": parts.get("valid", parts.get("val", [])) + parts.get("test", [])}
        if not source["val"]:
            groups = {"train": groups["train"] + groups["val"], "val": []}
    picked = {}
    for split, pool in groups.items():
        usable = []
        for image, label in pool:
            boxes = mapped_boxes(source, yolo_rows(label))
            if boxes is not None:
                usable.append((image, boxes))
        rng.shuffle(usable)
        picked[split] = usable
    return picked


def vt_items(rng: random.Random) -> dict:
    """Готовит снимки Virginia Tech: полигоны всех степеней коррозии переводятся в рамки через маску."""
    base = os.path.join(OPEN, "vt-corrosion-cs", "unpacked", "Corrosion Condition State Classification", "original")
    out = {}
    for part, split in (("Train", "train"), ("Test", "val")):
        items = []
        for path in sorted(glob.glob(os.path.join(base, part, "json", "*.json"))):
            data = json.load(open(path, encoding="utf-8"))
            height, width = data["imageHeight"], data["imageWidth"]
            mask = np.zeros((height, width), np.uint8)
            for shape in data["shapes"]:
                if "Corrosion" in shape["label"] and len(shape["points"]) >= 3:
                    cv2.fillPoly(mask, [np.array(shape["points"], np.int32)], 255)
            image = os.path.join(base, part, "images", data["imagePath"])
            if mask.any() and os.path.exists(image):
                items.append((image, [("corrosion", *box) for box in mask_to_boxes(mask, min_share=0.004)]))
        rng.shuffle(items)
        out[split] = items
    return out


class Builder:
    """Пишет кадры в набор через проверку на повторы тестовых снимков и ведёт журнал."""

    def __init__(self, writer: Writer, guard: Guard):
        """Запоминает запись набора и защищённые снимки."""
        self.writer, self.guard = writer, guard
        self.dropped, self.review, self.manifest = [], [], []

    def clean(self, name: str, image: np.ndarray, origin: str) -> bool:
        """Проверяет кадр на близость к защищённым снимкам; при совпадении записывает его в журнал."""
        distance, who = self.guard.nearest(image)
        if distance <= DROP_BITS:
            self.dropped.append({"frame": name, "origin": origin, "protected": who, "bits": distance})
            return False
        if distance <= REVIEW_BITS:
            self.review.append({"frame": name, "origin": origin, "protected": who, "bits": distance})
        return True

    def put(self, split: str, name: str, image: np.ndarray, boxes: list[tuple], source: str, origin: str,
            licence: str) -> bool:
        """Сохраняет кадр после проверки на повторы и записывает строку описи."""
        if not self.clean(name, image, origin):
            return False
        self.writer.add(split, name, image, boxes, source)
        self.manifest.append({"file": f"images/{split}/{name}.jpg", "split": split, "source": source,
                              "origin": os.path.relpath(origin, ROOT), "licence": licence,
                              "classes": ";".join(sorted({box[0] for box in boxes}))})
        return True


def add_source(builder: Builder, source: dict, picked: dict) -> None:
    """Добавляет отобранные снимки источника, отсекая повторы внутри источника при dedup_bits."""
    seen = []
    for split in ("train", "val"):
        written = 0
        for index, (path, boxes) in enumerate(picked.get(split, [])):
            if written >= source[split]:
                break
            image = read_any(path)
            if image is None:
                continue
            scale = 1024 / max(image.shape[:2])
            if scale < 1.0:
                image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
            if source.get("dedup_bits"):
                code = phash(cv2.cvtColor(image, cv2.COLOR_BGR2GRAY))
                if any((code ^ other).bit_count() <= source["dedup_bits"] for other in seen):
                    continue
                seen.append(code)
            name = f"{source['key']}_{split[0]}{index:05d}"
            written += builder.put(split, name, image, boxes, source["key"], path, source["licence"])


def add_customer_train(builder: Builder, spec: dict, screen: int, rare: int, backgrounds: list[str]) -> None:
    """Добавляет обучающие снимки заказчика и их копии "с монитора"; отложенные снимки сюда не попадают."""
    classes = builder.writer.classes
    for index, item in enumerate(spec["images"]):
        if item["split"] != "train":
            continue
        path = os.path.join(ROOT, "data", "customer", item["file"])
        image = read_image(path)
        boxes = [tuple(box) for box in item["boxes"]]
        if not builder.put("train", f"c{index:02d}", image, boxes, "customer", path, "материалы заказчика"):
            continue
        for copy in range(rare if any(box[0] != "corrosion" for box in boxes) else screen):
            indexed = [(classes.index(c), x1, y1, x2, y2) for c, x1, y1, x2, y2 in boxes]
            frame, labels = make_frame(image, indexed, backgrounds, scale_range=(0.6, 1.3), center_range=(0.38, 0.62))
            moved = [(classes[c], x - w / 2, y - h / 2, x + w / 2, y + h / 2) for c, x, y, w, h in labels]
            builder.writer.add("train", f"c{index:02d}_s{copy}", frame, moved, "customer_screen")


def sweep(builder: Builder, out: str) -> None:
    """Проверяет на повторы кадры Ostrava и макета, записанные прежними функциями, и удаляет совпавшие."""
    for split in ("train", "val"):
        for path in sorted(glob.glob(os.path.join(out, "images", split, "*.jpg"))):
            name = os.path.basename(path)[:-4]
            if not name.startswith(("o_", "b_")):
                continue
            source = "ostrava" if name.startswith("o_") else "blender"
            if builder.clean(name, cv2.imread(path), source):
                licence = "CC BY 4.0 (Zenodo 11235637)" if source == "ostrava" else "собственные рендеры"
                builder.manifest.append({"file": f"images/{split}/{name}.jpg", "split": split, "source": source,
                                         "origin": source, "licence": licence, "classes": ""})
            else:
                os.remove(path)
                os.remove(os.path.join(out, "labels", split, name + ".txt"))


def link_holdout(out: str) -> None:
    """Переносит отложенные снимки и их копии из первой сборки жёсткими ссылками, без пересоздания."""
    for split in ("holdout", "holdout_screen"):
        for kind in ("images", "labels"):
            target = os.path.join(out, kind, split)
            os.makedirs(target, exist_ok=True)
            for path in glob.glob(os.path.join(OPEN, "defects_ds", kind, split, "*")):
                destination = os.path.join(target, os.path.basename(path))
                if not os.path.exists(destination):
                    os.link(path, destination)


def oversample(out: str, rare: dict) -> dict:
    """Повторяет обучающие кадры с редкими классами жёсткими ссылками: rare задаёт число добавочных копий."""
    added = {}
    classes = list(DEFECT_CLASSES)
    for label in sorted(glob.glob(os.path.join(out, "labels", "train", "*.txt"))):
        name = os.path.basename(label)[:-4]
        if "_x" in name or name.startswith("b_") or (name[0] == "c" and name[1:3].isdigit()):
            continue
        present = {classes[int(line.split()[0])] for line in open(label) if line.strip()}
        copies = max([rare.get(cls, 0) for cls in present] or [0])
        for copy in range(copies):
            for kind, ext in (("images", ".jpg"), ("labels", ".txt")):
                source = os.path.join(out, kind, "train", name + ext)
                target = os.path.join(out, kind, "train", f"{name}_x{copy}{ext}")
                if not os.path.exists(target):
                    os.link(source, target)
            for cls in present:
                added[cls] = added.get(cls, 0) + 1
    return added


def count_split(out: str, split: str) -> dict:
    """Считает кадры, кадры без рамок и рамки по классам в части набора."""
    classes = list(DEFECT_CLASSES)
    row = {"images": 0, "empty_images": 0, "boxes": {name: 0 for name in classes}, "images_with": {name: 0 for name in classes}}
    for label in glob.glob(os.path.join(out, "labels", split, "*.txt")):
        lines = [line.split() for line in open(label) if line.strip()]
        row["images"] += 1
        row["empty_images"] += not lines
        for cls in {int(parts[0]) for parts in lines}:
            row["images_with"][classes[cls]] += 1
        for parts in lines:
            row["boxes"][classes[int(parts[0])]] += 1
    return row


def main() -> None:
    """Собирает набор, журнал повторов, опись, data.yaml и сводку."""
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--screen", type=int, default=6)
    parser.add_argument("--rare", type=int, default=18)
    args = parser.parse_args()
    random.seed(args.seed)
    np.random.seed(args.seed)
    rng = random.Random(args.seed)
    spec = json.load(open(os.path.join(ROOT, "cv", "customer_labels.json"), encoding="utf-8"))
    assert spec["classes"] == list(DEFECT_CLASSES)
    guard = build_guard(spec)
    writer = Writer(args.out, list(DEFECT_CLASSES))
    builder = Builder(writer, guard)
    usable, plain = bridge_files()
    add_customer_train(builder, spec, args.screen, args.rare, plain)
    link_holdout(args.out)
    add_industrial(writer)
    for path, boxes in rng.sample(usable, min(40, len(usable))):
        builder.put("train", "r_" + os.path.basename(path)[:24], read_image(path), boxes, "bi3q3", path, "CC BY 4.0 (Roboflow)")
    add_stand(writer, 60)
    sweep(builder, args.out)
    vt = vt_items(rng)
    add_source(builder, {"key": "vt", "train": 396, "val": 44, "licence": "CC0 (Virginia Tech)"}, vt)
    for source in SOURCES:
        add_source(builder, source, candidates(source, rng))
        print(source["key"], {k: v for k, v in writer.counts.items() if k.endswith("/" + source["key"])})
    added = oversample(args.out, {"terminal_box_burnt": 1, "damage": 1})
    with open(f"{args.out}/data.yaml", "w", encoding="utf-8") as handle:
        handle.write(f"path: {os.path.abspath(args.out)}\ntrain: images/train\nval: images/val\nnames:\n")
        handle.writelines(f"  {index}: {name}\n" for index, name in enumerate(DEFECT_CLASSES))
    with open(f"{args.out}/manifest.csv", "w", encoding="utf-8", newline="") as handle:
        table = csv.DictWriter(handle, fieldnames=["file", "split", "source", "origin", "licence", "classes"])
        table.writeheader()
        table.writerows(builder.manifest)
    json.dump({"dropped": builder.dropped, "review": builder.review, "drop_bits": DROP_BITS, "review_bits": REVIEW_BITS,
               "protected_images": len(guard.names)},
              open(f"{args.out}/dedup.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    summary = {"by_source": writer.counts, "oversampled_copies": added,
               "splits": {split: count_split(args.out, split) for split in ("train", "val", "holdout", "holdout_screen")}}
    json.dump(summary, open(f"{args.out}/summary.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps(summary["splits"], ensure_ascii=False))
    print(f"выброшено повторов {len(builder.dropped)}, на просмотр {len(builder.review)}")


if __name__ == "__main__":
    main()
