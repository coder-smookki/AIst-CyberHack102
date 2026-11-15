"""Четвёртая сборка набора реальных дефектов: третья сборка без изменений плюс крупные открытые наборы второго круга.

Запуск:
    python cv/build_defects_v4.py data/open/defects_ds_v4 [--seed 0]

Схема классов прежняя (DEFECT_CLASSES в cv/protocol.py): corrosion, leak, terminal_box_burnt, damage.

Что берётся:
    вся третья сборка data/open/defects_ds_v3 жёсткими ссылками: train (снимки заказчика, их копии "с монитора",
    открытые наборы и повторы редких классов), train_screen, val, holdout и holdout_screen. Части val, holdout и
    holdout_screen не меняются ни на кадр, поэтому показатели всех моделей сравнимы;
    новые открытые наборы из SOURCES_V4 - только в train. Классы сопоставляются по именам из data.yaml
    источника, крупные источники коррозии ограничены квотой, кадры с редкими классами берутся первыми и
    повторяются жёсткими ссылками, для них же строится по одной копии "с монитора" в train_screen;
    исправное оборудование без рамок (трудные отрицательные примеры).

Дополнение (python cv/build_defects_v4.py data/open/defects_ds_v4 --append <разметка.json>): кадры с рамками,
размеченными вручную (например, снимки Wikimedia Commons из data/open/commons-defects), проходят те же проверки
на повторы и дописываются в train уже собранного набора и в images/train_extra для отдельной загрузки на Kaggle.
Файл разметки - список записей {"file": путь от корня проекта, "boxes": [[класс, x1, y1, x2, y2], ...],
"licence": ..., "source": ключ источника}.

Честность проверки:
    каждый новый кадр сравнивается по pHash и dHash (целый кадр, пять кадрирований по 70%, отражение, у
    защищённых снимков ещё повороты) с защищёнными снимками: отложенными снимками заказчика, их копиями,
    data/web_testset, тестом data/open/parts_real и всеми 519 кадрами val третьей сборки. До 10 бит кадр
    выбрасывается, от 11 до 16 бит пара записывается в dedup.json для просмотра глазами;
    повторы внутри обучающей части (новый кадр против уже взятых, в том числе кадров третьей сборки)
    отсекаются по целому кадру при расстоянии до INTRA_BITS бит.
"""
import argparse
import csv
import glob
import json
import os
import random
import re
import shutil
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_defects import ROOT, Writer
from build_defects_v3 import Guard, build_guard, count_split, dhash, phash, read_any
from gen_synth import make_frame
from protocol import DEFECT_CLASSES

OPEN = os.path.join(ROOT, "data", "open")
V3 = os.path.join(OPEN, "defects_ds_v3")
DROP_BITS = 10
REVIEW_BITS = 16
INTRA_BITS = 8
MAX_SIDE = 1024
RUST_NAMES = ("Corrosion", "Corrosion-detection", "Crevice", "Galvanic", "High-corrosion", "Low-corrosion",
              "Medium-corrosion", "Oxidation-Corrosion", "Rust", "cacat_korosi", "corroded-part", "corrosion",
              "moderate-corrosion", "rust", "severe-corrosion", "mild-corrosion", "iron rust", "copper corrosion")

SOURCES_V4 = [
    {"key": "rust5k", "folder": "rf-rust-5k/raw", "map": {name: "corrosion" for name in RUST_NAMES},
     "skip_if": {"0", "clean", "non-corrosion"}, "min_area": {"corrosion": 0.002}, "max_cover": 0.9,
     "cap": 900, "licence": "CC BY 4.0 (Roboflow rust-r6xzj/rust-dataset-uk2zn v1)"},
    {"key": "rust10k", "folder": "rf-rust-10k/raw", "map": {name: "corrosion" for name in RUST_NAMES},
     "skip_if": {"car"}, "min_area": {"corrosion": 0.004}, "max_cover": 0.9, "no_mosaic": True,
     "cap": 300, "licence": "CC BY 4.0 (Roboflow rust-detection/rust-detection-38s6e v1)"},
    {"key": "leakage", "folder": "rf-leakage/raw", "map": {"leakage": "leak"}, "only_if": {"leakage"},
     "min_area": {"leak": 0.001}, "cap": 200,
     "licence": "CC BY 4.0 (Roboflow pros-workspace-60obk/leakage-wwjrq v12)"},
    {"key": "leakwc", "folder": "rf-leakage-wc/raw", "map": {"leakage": "leak"}, "min_area": {"leak": 0.0005},
     "cap": 500, "licence": "CC BY 4.0 (Roboflow welcoder/leakage-ry64a v199)"},
    {"key": "spill", "folder": "rf-leakage-kf/raw", "map": {"Spill Detection - v2 2024-01-24 3-05pm": "leak"},
     "cap": 150, "licence": "CC BY 4.0 (Roboflow kuanhan-fu-mri8i/leakage-fw7iy v1)"},
    {"key": "elhazdw", "folder": "rf-electrical-hazard-dw/raw",
     "map": {"burned socket": "terminal_box_burnt", "damage wire": "damage"}, "only_if": {"burned socket"},
     "cap": 200, "licence": "CC BY 4.0 (Roboflow damagewire/electrical-hazard v2)"},
]
SAFENET = {"key": "safenet2", "folder": "safenet-coating/unpacked", "cap": 1200, "crack_area": 0.004,
           "licence": "GPL (Figshare 28190198)"}
NEGATIVES = {"key": "powernormal", "folder": "kg-power-equipment-fault/raw", "cap": 300,
             "licence": "CC0 (Kaggle zayn1999/electrical-power-equipment-fault-image-dataset)"}
EXTRA_FILE = os.path.join(OPEN, "defects_v4_extra.json")
MANUAL_DROP = {"data/open/rf-rust-5k/raw/train/images/000353_jpg.rf.fdaab4fc17c66c5e8950d5119bc4d44e.jpg"}


def class_names(folder: str) -> list[str]:
    """Читает имена классов из data.yaml источника (список в скобках, построчный список или словарь)."""
    text = open(os.path.join(folder, "data.yaml"), encoding="utf-8").read()
    inline = re.search(r"names:\s*\[(.*?)\]", text, re.S)
    if inline:
        return [name.strip().strip("'\"") for name in inline.group(1).split(",") if name.strip()]
    block = text.split("names:", 1)[1]
    names = []
    for line in block.splitlines()[1:]:
        match = re.match(r"^\s+(?:\d+\s*:\s*|-\s*)(.+?)\s*$", line)
        if not match:
            break
        names.append(match.group(1).strip("'\""))
    return names


def parse_rows(lines: list[str], names: list[str]) -> list[tuple]:
    """Переводит строки YOLO (рамки или полигоны) в (имя класса, x1, y1, x2, y2) в долях; битые строки пропускает."""
    rows = []
    for line in lines:
        parts = line.split()
        try:
            cls, values = int(parts[0]), [float(value) for value in parts[1:]]
        except (ValueError, IndexError):
            continue
        if len(values) == 4:
            x, y, w, h = values
            box = (x - w / 2, y - h / 2, x + w / 2, y + h / 2)
        elif len(values) >= 6 and len(values) % 2 == 0:
            box = (min(values[0::2]), min(values[1::2]), max(values[0::2]), max(values[1::2]))
        else:
            continue
        box = tuple(min(1.0, max(0.0, value)) for value in box)
        if box[2] - box[0] > 0.002 and box[3] - box[1] > 0.002 and 0 <= cls < len(names):
            rows.append((names[cls], *box))
    return rows


def map_boxes(source: dict, rows: list[tuple]) -> list[tuple] | None:
    """Переводит рамки источника в классы схемы; None, если снимок не подходит.

    Снимок отбрасывается, если в нём есть класс из skip_if, нет класса из only_if, не осталось ни одной
    рамки после порога площади min_area или все рамки вместе закрывают больше max_cover кадра (снимок
    текстуры целиком, где рамка ничего не локализует).
    """
    present = {row[0] for row in rows}
    if present & source.get("skip_if", set()):
        return None
    if source.get("only_if") and not present & source["only_if"]:
        return None
    boxes = []
    for name, x1, y1, x2, y2 in rows:
        target = source["map"].get(name)
        if target and (x2 - x1) * (y2 - y1) >= source.get("min_area", {}).get(target, 0.0):
            boxes.append((target, x1, y1, x2, y2))
    if not boxes:
        return None
    if source.get("max_cover") and union_share(boxes) > source["max_cover"]:
        return None
    return boxes


def union_share(boxes: list[tuple]) -> float:
    """Возвращает долю кадра, закрытую объединением рамок (по сетке 100 на 100)."""
    grid = np.zeros((100, 100), bool)
    for _, x1, y1, x2, y2 in boxes:
        grid[int(y1 * 100):max(int(y1 * 100) + 1, int(np.ceil(y2 * 100))),
             int(x1 * 100):max(int(x1 * 100) + 1, int(np.ceil(x2 * 100)))] = True
    return float(grid.mean())


def is_mosaic(gray: np.ndarray, jump: float = 28.0) -> bool:
    """Узнаёт склейку четырёх снимков: прямой шов через весь кадр и по строке, и по столбцу.

    Для строки y считается медиана по ширине модуля разности соседних строк; шов есть, если в средней
    части кадра такая медиана больше jump. Склейкой считается кадр, где швы есть в обоих направлениях.
    """
    image = gray.astype(np.int16)
    height, width = image.shape
    rows = np.median(np.abs(np.diff(image, axis=0)), axis=1)[int(height * 0.15):int(height * 0.85)]
    cols = np.median(np.abs(np.diff(image, axis=1)), axis=0)[int(width * 0.15):int(width * 0.85)]
    return bool(rows.size and cols.size and rows.max() > jump and cols.max() > jump)


def rank_items(items: list[tuple], rare: tuple, rng: random.Random) -> list[tuple]:
    """Перемешивает кандидатов и ставит первыми снимки с редкими классами."""
    items = items[:]
    rng.shuffle(items)
    return sorted(items, key=lambda item: 0 if any(box[0] in rare for box in item[1]) else 1)


def roboflow_items(source: dict) -> list[tuple]:
    """Возвращает пары (снимок, рамки) источника Roboflow из всех его частей после сопоставления классов."""
    base = os.path.join(OPEN, source["folder"])
    names = class_names(base)
    items = []
    for part in ("train", "valid", "test"):
        for path in sorted(glob.glob(os.path.join(base, part, "images", "*"))):
            label = os.path.join(base, part, "labels", os.path.splitext(os.path.basename(path))[0] + ".txt")
            lines = open(label).read().splitlines() if os.path.exists(label) else []
            boxes = map_boxes(source, parse_rows(lines, names))
            if boxes is not None:
                items.append((path, boxes))
    return items


def safenet_original(path: str) -> str:
    """Возвращает номер исходной фотографии SAFE-Net по имени кадрирования (Image_832_8538-0_0_... -> Image_832_8538)."""
    match = re.match(r"(Image_\d+_\d+)", os.path.basename(path))
    return match.group(1) if match else os.path.basename(path)


def safenet_items(used: set, banned: set, per_photo: int = 2) -> list[tuple]:
    """Возвращает кадрирования обучающей части SAFE-Net, не взятые в третью сборку, с теми же правилами, что в v3.

    Снимки с отслоением и вздутием краски не берутся; трещина краски идёт в damage только от 0.4% кадра.
    Части SAFE-Net нарезаны из одних и тех же исходных фотографий, поэтому кадрирования фотографий, чьи
    куски лежат в val третьей сборки (banned), не берутся вовсе, а от одной фотографии берётся не больше
    per_photo кадрирований.
    """
    base = os.path.join(OPEN, SAFENET["folder"])
    items, per = [], {}
    for path in sorted(glob.glob(os.path.join(base, "images", "train", "*"))):
        original = safenet_original(path)
        if os.path.relpath(path, ROOT) in used or original in banned or per.get(original, 0) >= per_photo:
            continue
        label = os.path.join(base, "labels", "train", os.path.splitext(os.path.basename(path))[0] + ".txt")
        lines = open(label).read().splitlines() if os.path.exists(label) else []
        rows = parse_rows(lines, ["corrosion", "crack", "flaking", "blistering"])
        if {row[0] for row in rows} & {"flaking", "blistering"}:
            continue
        boxes = [("corrosion", *row[1:]) for row in rows if row[0] == "corrosion"]
        boxes += [("damage", *row[1:]) for row in rows
                  if row[0] == "crack" and (row[3] - row[1]) * (row[4] - row[2]) >= SAFENET["crack_area"]]
        if boxes:
            items.append((path, boxes))
            per[original] = per.get(original, 0) + 1
    return items


def negative_items() -> list[tuple]:
    """Возвращает снимки исправного оборудования (папки Normal набора zayn1999) без рамок, поровну по видам."""
    groups = {}
    for path in sorted(glob.glob(os.path.join(OPEN, NEGATIVES["folder"], "**", "Normal", "**", "*.*"), recursive=True)):
        if path.lower().endswith((".jpg", ".jpeg", ".png")):
            groups.setdefault(os.path.basename(os.path.dirname(path)), []).append((path, []))
    return [item for group in zip(*[members for _, members in sorted(groups.items())]) for item in group]


def extra_sources() -> list[dict]:
    """Читает описания дополнительных источников из data/open/defects_v4_extra.json, если файл есть."""
    if not os.path.exists(EXTRA_FILE):
        return []
    sources = json.load(open(EXTRA_FILE, encoding="utf-8"))
    for source in sources:
        for key in ("skip_if", "only_if"):
            if key in source:
                source[key] = set(source[key])
    return sources


class Index:
    """Хеши целых кадров обучающей части для отсева повторов внутри набора."""

    def __init__(self):
        """Создаёт пустой список хешей."""
        self.codes, self.names = [], []
        self.stack = None

    def add(self, name: str, gray: np.ndarray) -> None:
        """Добавляет кадр в список."""
        self.codes.append((phash(gray), dhash(gray)))
        self.names.append(name)
        self.stack = None

    def nearest(self, gray: np.ndarray) -> tuple[int, str]:
        """Возвращает расстояние до ближайшего кадра (большее из pHash и dHash) и его имя."""
        if not self.codes:
            return 64, ""
        if self.stack is None:
            self.stack = np.array(self.codes, dtype=np.uint64)
        mine = np.array([phash(gray), dhash(gray)], dtype=np.uint64)
        distance = np.bitwise_count(np.bitwise_xor(self.stack, mine)).max(axis=1)
        index = int(distance.argmin())
        return int(distance[index]), self.names[index]


class Builder4:
    """Добавляет новые кадры в обучающую часть через проверки на повторы и ведёт журнал и опись."""

    def __init__(self, out: str, guard: Guard, index: Index):
        """Запоминает папку набора, защищённые снимки и хеши уже взятых кадров."""
        self.writer = Writer(out, list(DEFECT_CLASSES))
        self.guard, self.index = guard, index
        self.dropped, self.review, self.intra, self.rejected = [], [], {}, {}
        self.manifest, self.taken = [], []

    def put(self, source: dict, index: int, path: str, boxes: list[tuple]) -> bool:
        """Читает, уменьшает и проверяет кадр; при успехе сохраняет его в train и пишет строку описи.

        Кадры из MANUAL_DROP не берутся: при просмотре пар глазами они оказались той же сценой, что кадр val.
        """
        if os.path.relpath(path, ROOT) in MANUAL_DROP:
            return False
        image = read_any(path)
        if image is None:
            self.rejected[source["key"] + ":unreadable"] = self.rejected.get(source["key"] + ":unreadable", 0) + 1
            return False
        scale = MAX_SIDE / max(image.shape[:2])
        if scale < 1.0:
            image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
        if source.get("no_mosaic") and is_mosaic(gray):
            self.rejected[source["key"] + ":mosaic"] = self.rejected.get(source["key"] + ":mosaic", 0) + 1
            return False
        name = f"{source['key']}_{index:05d}"
        distance, who = self.guard.nearest(image)
        if distance <= DROP_BITS:
            self.dropped.append({"frame": name, "origin": os.path.relpath(path, ROOT), "protected": who, "bits": distance})
            return False
        if distance <= REVIEW_BITS:
            self.review.append({"frame": name, "origin": os.path.relpath(path, ROOT), "protected": who, "bits": distance})
        twin, other = self.index.nearest(gray)
        if twin <= INTRA_BITS:
            self.intra.setdefault(source["key"], []).append({"frame": name, "twin": other, "bits": twin})
            return False
        self.index.add(name, gray)
        self.writer.add("train", name, image, boxes, source["key"])
        self.taken.append((name, image, boxes))
        self.manifest.append({"file": f"images/train/{name}.jpg", "split": "train", "source": source["key"],
                              "origin": os.path.relpath(path, ROOT), "licence": source["licence"],
                              "classes": ";".join(sorted({box[0] for box in boxes}))})
        return True

    def add_items(self, source: dict, items: list[tuple]) -> int:
        """Добавляет кандидатов источника до квоты cap и квот по классам cap_class; возвращает число взятых."""
        written, per_class = 0, {}
        limits = source.get("cap_class", {})
        for index, (path, boxes) in enumerate(items):
            if written >= source["cap"]:
                break
            classes = {box[0] for box in boxes}
            if classes and all(per_class.get(name, 0) >= limits.get(name, 10 ** 9) for name in classes):
                continue
            if self.put(source, index, path, boxes):
                written += 1
                for name in classes:
                    per_class[name] = per_class.get(name, 0) + 1
        return written


def link_tree(source: str, target: str) -> int:
    """Переносит файлы папки жёсткими ссылками и возвращает их число."""
    os.makedirs(target, exist_ok=True)
    count = 0
    for path in glob.glob(os.path.join(source, "*")):
        destination = os.path.join(target, os.path.basename(path))
        if not os.path.exists(destination):
            os.link(path, destination)
        count += 1
    return count


def link_v3(out: str) -> dict:
    """Переносит всю третью сборку жёсткими ссылками и возвращает число файлов по частям."""
    counts = {}
    for split in ("train", "train_screen", "val", "holdout", "holdout_screen"):
        for kind in ("images", "labels"):
            counts[f"{kind}/{split}"] = link_tree(os.path.join(V3, kind, split), os.path.join(out, kind, split))
    return counts


def v3_index(guard: Guard) -> Index:
    """Добавляет кадры val третьей сборки в защищённые и собирает хеши уникальных кадров train третьей сборки."""
    for path in sorted(glob.glob(os.path.join(V3, "images", "val", "*.jpg"))):
        guard.protect("v3_val:" + os.path.basename(path), cv2.imread(path))
    index = Index()
    for path in sorted(glob.glob(os.path.join(V3, "images", "train", "*.jpg"))):
        name = os.path.basename(path)[:-4]
        if "_x" in name or re.fullmatch(r"c\d\d_s\d+", name):
            continue
        index.add("v3:" + name, cv2.cvtColor(cv2.imread(path), cv2.COLOR_BGR2GRAY))
    return index


def oversample_new(out: str, taken: list[tuple], copies: dict) -> dict:
    """Повторяет новые кадры с редкими классами жёсткими ссылками; copies задаёт число копий по классу."""
    added = {}
    for name, _, boxes in taken:
        present = {box[0] for box in boxes}
        repeat = max([copies.get(cls, 0) for cls in present] or [0])
        for copy in range(repeat):
            for kind, ext in (("images", ".jpg"), ("labels", ".txt")):
                target = os.path.join(out, kind, "train", f"{name}_x{copy}{ext}")
                if not os.path.exists(target):
                    os.link(os.path.join(out, kind, "train", name + ext), target)
            for cls in present:
                added[cls] = added.get(cls, 0) + 1
    return added


def screen_new(builder: Builder4, rare: set, backgrounds: list[str]) -> int:
    """Строит по одной копии "с монитора" для новых кадров с редкими классами в train_screen."""
    classes = builder.writer.classes
    made = 0
    for name, image, boxes in builder.taken:
        if not {box[0] for box in boxes} & rare:
            continue
        indexed = [(classes.index(c), x1, y1, x2, y2) for c, x1, y1, x2, y2 in boxes]
        frame, labels = make_frame(image, indexed, backgrounds, scale_range=(0.6, 1.3), center_range=(0.38, 0.62))
        moved = [(classes[c], x - w / 2, y - h / 2, x + w / 2, y + h / 2) for c, x, y, w, h in labels]
        builder.writer.add("train_screen", name + "_s", frame, moved, "screen_v4")
        made += 1
    return made


def append(out: str, labels: str) -> None:
    """Дописывает размеченные вручную кадры в train собранного набора и в папку train_extra.

    Защищённые снимки те же, что при сборке; повторы внутри train ищутся среди кадров третьей сборки и уже
    дописанных. Опись, журнал повторов и сводка обновляются, кадры с terminal_box_burnt и damage повторяются
    так же, как новые кадры основной сборки, и получают копию "с монитора".
    """
    spec = json.load(open(os.path.join(ROOT, "cv", "customer_labels.json"), encoding="utf-8"))
    guard = build_guard(spec)
    builder = Builder4(out, guard, v3_index(guard))
    for number, entry in enumerate(json.load(open(labels, encoding="utf-8"))):
        source = {"key": entry["source"], "licence": entry["licence"]}
        builder.put(source, number, os.path.join(ROOT, entry["file"]), [tuple(box) for box in entry["boxes"]])
    backgrounds = sorted(glob.glob(os.path.join(OPEN, "corrosion-bi3q3", "train", "images", "*")))[:213]
    screens = screen_new(builder, {"terminal_box_burnt", "damage", "leak"}, backgrounds)
    added = oversample_new(out, builder.taken, {"terminal_box_burnt": 2, "damage": 1, "leak": 1})
    for name, _, _ in builder.taken:
        for kind, ext in (("images", ".jpg"), ("labels", ".txt")):
            names = [name] + [f"{name}_x{copy}" for copy in range(3)]
            for item in names:
                path = os.path.join(out, kind, "train", item + ext)
                if os.path.exists(path):
                    link_tree_file(path, os.path.join(out, kind, "train_extra"))
            screen = os.path.join(out, kind, "train_screen", name + "_s" + ext)
            if os.path.exists(screen):
                link_tree_file(screen, os.path.join(out, kind, "train_extra"))
    with open(f"{out}/manifest.csv", "a", encoding="utf-8", newline="") as handle:
        csv.DictWriter(handle, fieldnames=["file", "split", "source", "origin", "licence", "classes"]).writerows(builder.manifest)
    log = json.load(open(f"{out}/dedup.json", encoding="utf-8"))
    log["append"] = {"dropped": builder.dropped, "review": builder.review, "intra_duplicates": builder.intra,
                     "rejected": builder.rejected, "taken": len(builder.taken)}
    json.dump(log, open(f"{out}/dedup.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    summary = json.load(open(f"{out}/summary.json", encoding="utf-8"))
    summary["append"] = {"by_source": builder.writer.counts, "screen_copies": screens, "oversampled_copies": added}
    summary["splits"] = {split: count_split(out, split)
                         for split in ("train", "train_screen", "train_extra", "val", "holdout", "holdout_screen")}
    json.dump(summary, open(f"{out}/summary.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps(summary["append"], ensure_ascii=False), len(builder.dropped), "выброшено")


def link_tree_file(path: str, folder: str) -> None:
    """Создаёт в folder жёсткую ссылку на файл, если её ещё нет."""
    os.makedirs(folder, exist_ok=True)
    target = os.path.join(folder, os.path.basename(path))
    if not os.path.exists(target):
        os.link(path, target)


def main() -> None:
    """Собирает набор, журнал повторов, опись, data.yaml и сводку (или дописывает ручную разметку при --append)."""
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--append")
    args = parser.parse_args()
    if args.append:
        append(args.out, args.append)
        return
    random.seed(args.seed)
    np.random.seed(args.seed)
    rng = random.Random(args.seed)
    if os.path.exists(args.out):
        shutil.rmtree(args.out)
    linked = link_v3(args.out)
    spec = json.load(open(os.path.join(ROOT, "cv", "customer_labels.json"), encoding="utf-8"))
    guard = build_guard(spec)
    index = v3_index(guard)
    builder = Builder4(args.out, guard, index)
    v3_rows = list(csv.DictReader(open(os.path.join(V3, "manifest.csv"), encoding="utf-8")))
    used = {row["origin"] for row in v3_rows}
    rare = ("terminal_box_burnt", "damage", "leak")
    taken = {}
    for source in SOURCES_V4 + extra_sources():
        if not os.path.isdir(os.path.join(OPEN, source["folder"])):
            continue
        items = rank_items(roboflow_items(source), rare, rng)
        taken[source["key"]] = {"candidates": len(items), "taken": builder.add_items(source, items)}
        print(source["key"], taken[source["key"]], flush=True)
    banned = {safenet_original(row["origin"]) for row in v3_rows if row["source"] == "safenet" and row["split"] == "val"}
    items = rank_items(safenet_items(used, banned), rare, rng)
    taken[SAFENET["key"]] = {"candidates": len(items), "taken": builder.add_items(SAFENET, items)}
    items = negative_items()
    taken[NEGATIVES["key"]] = {"candidates": len(items), "taken": builder.add_items(NEGATIVES, items)}
    print(taken, flush=True)
    backgrounds = sorted(glob.glob(os.path.join(OPEN, "corrosion-bi3q3", "train", "images", "*")))[:213]
    screens = screen_new(builder, {"terminal_box_burnt", "damage", "leak"}, backgrounds)
    added = oversample_new(args.out, builder.taken, {"terminal_box_burnt": 2, "damage": 1, "leak": 1})
    with open(f"{args.out}/data.yaml", "w", encoding="utf-8") as handle:
        handle.write(f"path: {os.path.abspath(args.out)}\ntrain: images/train\nval: images/val\nnames:\n")
        handle.writelines(f"  {number}: {name}\n" for number, name in enumerate(DEFECT_CLASSES))
    with open(f"{args.out}/manifest.csv", "w", encoding="utf-8", newline="") as handle:
        table = csv.DictWriter(handle, fieldnames=["file", "split", "source", "origin", "licence", "classes"])
        table.writeheader()
        table.writerows(v3_rows + builder.manifest)
    json.dump({"dropped": builder.dropped, "review": builder.review, "intra_duplicates": builder.intra,
               "rejected": builder.rejected, "drop_bits": DROP_BITS, "review_bits": REVIEW_BITS,
               "intra_bits": INTRA_BITS, "protected_images": len(guard.names)},
              open(f"{args.out}/dedup.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    v3_summary = json.load(open(os.path.join(V3, "summary.json"), encoding="utf-8"))
    summary = {"v3_linked_files": linked, "v3_by_source": v3_summary["by_source"], "new_by_source": builder.writer.counts,
               "new_sources": taken, "new_screen_copies": screens, "new_oversampled_copies": added,
               "splits": {split: count_split(args.out, split)
                          for split in ("train", "train_screen", "val", "holdout", "holdout_screen")}}
    json.dump(summary, open(f"{args.out}/summary.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(json.dumps(summary["splits"], ensure_ascii=False))
    print(f"выброшено повторов тестовых снимков {len(builder.dropped)}, на просмотр {len(builder.review)}, "
          f"повторов внутри train {sum(len(v) for v in builder.intra.values())}")


if __name__ == "__main__":
    main()
