"""Рисует рамки разметки на изображениях и собирает их в один лист для просмотра.

Запуск:
    python cv/draw_labels.py <папка_изображений> <папка_разметки> <лист.jpg> класс1,класс2,... [сколько=6] [столбцов=3]
"""
import glob
import os
import sys

from PIL import Image, ImageDraw

PALETTE = ["#1E8E5A", "#135AA6", "#8A94A0", "#E39A0C", "#D93B30", "#6B4FBB", "#000000", "#00A3A3", "#C2185B",
           "#3B2F2F", "#B5651D"]


def draw(image_path: str, label_path: str, names: list[str]) -> Image.Image:
    """Возвращает изображение с нанесёнными рамками и подписями классов."""
    image = Image.open(image_path).convert("RGB")
    width, height = image.size
    canvas = ImageDraw.Draw(image)
    for line in open(label_path) if os.path.exists(label_path) else []:
        cls, x, y, w, h = line.split()[:5]
        cls, x, y, w, h = int(cls), float(x) * width, float(y) * height, float(w) * width, float(h) * height
        color = PALETTE[cls % len(PALETTE)]
        canvas.rectangle([x - w / 2, y - h / 2, x + w / 2, y + h / 2], outline=color, width=3)
        canvas.rectangle([x - w / 2, y - h / 2 - 13, x - w / 2 + 7 * len(names[cls]) + 6, y - h / 2], fill=color)
        canvas.text((x - w / 2 + 3, y - h / 2 - 12), names[cls], fill="white")
    return image


def sheet(images: str, labels: str, out: str, names: list[str], count: int = 6, columns: int = 3) -> None:
    """Собирает лист из первых изображений папки."""
    tiles = []
    for path in sorted(glob.glob(images + "/*.jpg"))[:count]:
        tile = draw(path, os.path.join(labels, os.path.basename(path)[:-4] + ".txt"), names)
        tile.thumbnail((660, 500))
        tiles.append(tile)
    tile_w, tile_h = max(t.size[0] for t in tiles), max(t.size[1] for t in tiles)
    rows = (len(tiles) + columns - 1) // columns
    canvas = Image.new("RGB", (columns * tile_w + (columns - 1) * 4, rows * tile_h + (rows - 1) * 4), "white")
    for index, tile in enumerate(tiles):
        canvas.paste(tile, ((index % columns) * (tile_w + 4), (index // columns) * (tile_h + 4)))
    canvas.save(out, quality=88)
    print(out, canvas.size)


if __name__ == "__main__":
    sheet(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split(","),
          int(sys.argv[5]) if len(sys.argv) > 5 else 6, int(sys.argv[6]) if len(sys.argv) > 6 else 3)
