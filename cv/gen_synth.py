"""Создание размеченного набора из нескольких плоских изображений с известными рамками.

Мишень на показе плоская: монитор с фотографией оборудования. Рамки узлов рисуются один раз на каждом
исходном изображении. Затем изображение многократно искажается случайной перспективой, вставляется в
случайный фон и получает помехи съёмки с экрана: блики, муар, размытие, сдвиг экспозиции. Рамки
пересчитываются той же матрицей перспективы, поэтому ручная разметка кадров не нужна.

Запуск:
    python cv/gen_synth.py <описание.json> <папка_набора> --train 1500 --val 200 [--bg папка_с_фонами]

Описание:
    {"classes": ["motor", "pump"],
     "images": [{"file": "pump_ok.jpg", "boxes": [["motor", 0.20, 0.25, 0.51, 0.64]]}]}
Рамки заданы как x1, y1, x2, y2 в долях изображения.
"""
import argparse
import glob
import json
import os
import random

import cv2
import numpy as np

S = 640


def rand_bg(bgs):
    """Возвращает случайный фон: размытый фрагмент фотографии или цветной шум."""
    if bgs and random.random() < 0.7:
        bg = cv2.imread(random.choice(bgs))
        if bg is not None:
            h, w = bg.shape[:2]
            s = max(S / h, S / w) * random.uniform(1.0, 1.6)
            bg = cv2.resize(bg, (int(w * s) + 1, int(h * s) + 1))
            y, x = random.randint(0, bg.shape[0] - S), random.randint(0, bg.shape[1] - S)
            return cv2.GaussianBlur(bg[y:y + S, x:x + S], (0, 0), random.uniform(1, 4))
    base = np.full((S, S, 3), [random.randint(20, 230) for _ in range(3)], np.uint8)
    noise = cv2.resize(np.random.randint(0, 60, (8, 8, 3), np.uint8), (S, S), interpolation=cv2.INTER_CUBIC)
    return cv2.add(base, noise)


def moire(img):
    """Накладывает слабую синусоидальную решётку, похожую на муар и полосы экрана."""
    h, w = img.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    ang, freq = random.uniform(0, np.pi), random.uniform(0.15, 0.9)
    g = 1 + random.uniform(0.03, 0.12) * np.sin((xx * np.cos(ang) + yy * np.sin(ang)) * freq)
    return np.clip(img.astype(np.float32) * g[..., None], 0, 255).astype(np.uint8)


def glare(img):
    """Добавляет мягкое светлое пятно, похожее на блик лампы на экране."""
    h, w = img.shape[:2]
    m = np.zeros((h, w), np.float32)
    cv2.ellipse(m, (random.randint(0, w), random.randint(0, h)), (random.randint(40, 200), random.randint(30, 120)),
                random.uniform(0, 180), 0, 360, 1.0, -1)
    m = cv2.GaussianBlur(m, (0, 0), random.uniform(25, 60)) * random.uniform(60, 150)
    return np.clip(img.astype(np.float32) + m[..., None], 0, 255).astype(np.uint8)


def photometric(img):
    """Меняет яркость, контраст и баланс белого, добавляет размытие, муар, блик и сжатие JPEG."""
    a, b = random.uniform(0.6, 1.4), random.uniform(-35, 35)
    img = np.clip(img.astype(np.float32) * a + b, 0, 255)
    img *= np.array([random.uniform(0.88, 1.12) for _ in range(3)], np.float32)
    img = np.clip(img, 0, 255).astype(np.uint8)
    if random.random() < 0.5:
        img = cv2.GaussianBlur(img, (0, 0), random.uniform(0.4, 1.8))
    if random.random() < 0.3:
        k = random.choice([5, 7, 9])
        kern = np.zeros((k, k), np.float32)
        kern[k // 2] = 1.0 / k
        img = cv2.filter2D(img, -1, kern)
    if random.random() < 0.5:
        img = moire(img)
    if random.random() < 0.35:
        img = glare(img)
    q = random.randint(35, 95)
    return cv2.imdecode(cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])[1], 1)


def make_frame(src, boxes, bgs):
    """Строит один кадр: искажает изображение перспективой и пересчитывает рамки.

    Рамка сохраняется, только если после искажения в кадре видно больше половины её площади.
    """
    h, w = src.shape[:2]
    scale = random.uniform(0.45, 1.25)
    tw = S * scale
    th = tw * h / w
    cx, cy = random.uniform(0.3, 0.7) * S, random.uniform(0.3, 0.7) * S
    quad = np.float32([[cx - tw / 2, cy - th / 2], [cx + tw / 2, cy - th / 2], [cx + tw / 2, cy + th / 2], [cx - tw / 2, cy + th / 2]])
    quad += np.float32([[random.uniform(-0.12, 0.12) * tw, random.uniform(-0.12, 0.12) * th] for _ in range(4)])
    H = cv2.getPerspectiveTransform(np.float32([[0, 0], [w, 0], [w, h], [0, h]]), quad)
    frame = rand_bg(bgs)
    warped = cv2.warpPerspective(src, H, (S, S), flags=cv2.INTER_AREA if scale < 1 else cv2.INTER_LINEAR)
    mask = cv2.warpPerspective(np.full((h, w), 255, np.uint8), H, (S, S))
    frame[mask > 0] = warped[mask > 0]
    labels = []
    for cls, x1, y1, x2, y2 in boxes:
        pts = np.float32([[x1 * w, y1 * h], [x2 * w, y1 * h], [x2 * w, y2 * h], [x1 * w, y2 * h]]).reshape(-1, 1, 2)
        p = cv2.perspectiveTransform(pts, H).reshape(-1, 2)
        full = (p[:, 0].max() - p[:, 0].min()) * (p[:, 1].max() - p[:, 1].min())
        bx1, by1, bx2, by2 = np.clip([p[:, 0].min(), p[:, 1].min(), p[:, 0].max(), p[:, 1].max()], 0, S)
        vis = (bx2 - bx1) * (by2 - by1)
        if full > 0 and vis / full > 0.55 and bx2 - bx1 > 8 and by2 - by1 > 8:
            labels.append((cls, (bx1 + bx2) / 2 / S, (by1 + by2) / 2 / S, (bx2 - bx1) / S, (by2 - by1) / S))
    return photometric(frame), labels


def main():
    """Читает описание, создаёт обучающую и проверочную выборки и файл набора."""
    ap = argparse.ArgumentParser()
    ap.add_argument("spec")
    ap.add_argument("out")
    ap.add_argument("--train", type=int, default=1500)
    ap.add_argument("--val", type=int, default=200)
    ap.add_argument("--bg", default=None)
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    random.seed(a.seed)
    np.random.seed(a.seed)
    spec = json.load(open(a.spec, encoding="utf-8"))
    root = os.path.dirname(os.path.abspath(a.spec))
    classes = spec["classes"]
    items = []
    for it in spec["images"]:
        img = cv2.imdecode(np.fromfile(os.path.join(root, it["file"]), np.uint8), 1)
        if max(img.shape[:2]) > 1600:
            f = 1600 / max(img.shape[:2])
            img = cv2.resize(img, None, fx=f, fy=f, interpolation=cv2.INTER_AREA)
        items.append((img, [(classes.index(b[0]), *b[1:]) for b in it["boxes"]]))
    bgs = sorted(glob.glob(os.path.join(a.bg, "*"))) if a.bg else []
    for split, n in (("train", a.train), ("val", a.val)):
        os.makedirs(f"{a.out}/images/{split}", exist_ok=True)
        os.makedirs(f"{a.out}/labels/{split}", exist_ok=True)
        for i in range(n):
            src, boxes = random.choice(items)
            frame, labels = make_frame(src, boxes, bgs)
            if random.random() < 0.06:
                frame, labels = photometric(rand_bg(bgs)), []
            cv2.imwrite(f"{a.out}/images/{split}/{i:05d}.jpg", frame)
            with open(f"{a.out}/labels/{split}/{i:05d}.txt", "w") as f:
                f.writelines(f"{c} {x:.5f} {y:.5f} {w:.5f} {h:.5f}\n" for c, x, y, w, h in labels)
    with open(f"{a.out}/data.yaml", "w", encoding="utf-8") as f:
        f.write(f"path: {os.path.abspath(a.out)}\ntrain: images/train\nval: images/val\nnames:\n")
        f.writelines(f"  {i}: {c}\n" for i, c in enumerate(classes))
    print("done", a.out, "classes", classes)


if __name__ == "__main__":
    main()
