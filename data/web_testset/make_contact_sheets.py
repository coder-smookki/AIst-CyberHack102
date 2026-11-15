"""Вспомогательный просмотр кандидатов для build_testset.py (нужна библиотека Pillow).

Команды:
  sheets [пул ...]   собирает контактные листы _work/sheets/<пул>_NN.jpg из
                     _work/previews и указатель <пул>_index.tsv (номер, идентификатор,
                     лицензия, заголовок)
  resolve            превращает _work/picks.tsv (пул:номер, класс, примечание)
                     в selection.tsv (идентификатор, класс, примечание)
  final [класс ...]  собирает листы _work/final/<класс>_NN.jpg из загруженных
                     снимков images/<класс>/ для итоговой проверки

Снимки только декодируются библиотекой Pillow.
"""

import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(ROOT, "_work")
NUMBERS = os.path.join(WORK, "numbers.json")
Image.MAX_IMAGE_PIXELS = 120_000_000


def numbering():
    """Возвращает кандидатов и устойчивые номера внутри каждого пула."""
    with open(os.path.join(WORK, "candidates.json"), encoding="utf-8") as f:
        cands = json.load(f)
    nums = {}
    if os.path.exists(NUMBERS):
        with open(NUMBERS, encoding="utf-8") as f:
            nums = json.load(f)
    last = {}
    for cid, n in nums.items():
        if cid in cands:
            pool = cands[cid]["pool"]
            last[pool] = max(last.get(pool, 0), n)
    for cid, c in cands.items():
        if cid not in nums:
            last[c["pool"]] = last.get(c["pool"], 0) + 1
            nums[cid] = last[c["pool"]]
    with open(NUMBERS, "w", encoding="utf-8") as f:
        json.dump(nums, f)
    return cands, nums


def grid(items, out_prefix, cols, rows, cell, font_size):
    """Собирает листы из пар (подпись, путь) и возвращает пути к листам."""
    font = ImageFont.load_default(size=font_size)
    lab = font_size + 8
    per = cols * rows
    paths = []
    for s in range(0, len(items), per):
        chunk = items[s : s + per]
        nrows = (len(chunk) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * cell, nrows * (cell + lab)), (30, 30, 30))
        draw = ImageDraw.Draw(sheet)
        for k, (label, path) in enumerate(chunk):
            x, y = (k % cols) * cell, (k // cols) * (cell + lab)
            try:
                with Image.open(path) as im:
                    im = ImageOps.exif_transpose(im).convert("RGB")
                    im.thumbnail((cell - 6, cell - 6))
                    sheet.paste(im, (x + (cell - im.width) // 2, y + lab + (cell - im.height) // 2))
            except Exception as e:
                draw.text((x + 6, y + lab + 20), "ERR %s" % str(e)[:30], fill=(255, 80, 80), font=font)
            draw.rectangle([x, y, x + cell - 1, y + lab - 1], fill=(0, 0, 0))
            draw.text((x + 6, y + 2), label, fill=(255, 255, 0), font=font)
        out = "%s_%02d.jpg" % (out_prefix, s // per + 1)
        sheet.save(out, quality=82)
        paths.append(out)
    return paths


def cmd_sheets(pools):
    """Строит контактные листы и указатели по пулам кандидатов."""
    cands, nums = numbering()
    out_dir = os.path.join(WORK, "sheets")
    os.makedirs(out_dir, exist_ok=True)
    for pool in sorted(set(c["pool"] for c in cands.values())):
        if pools and pool not in pools:
            continue
        rows = sorted((nums[cid], cid) for cid, c in cands.items() if c["pool"] == pool)
        items = []
        with open(os.path.join(out_dir, pool + "_index.tsv"), "w", encoding="utf-8") as f:
            for n, cid in rows:
                c = cands[cid]
                path = os.path.join(WORK, "previews", pool, cid + ".img")
                if os.path.exists(path):
                    items.append(("%d" % n, path))
                    f.write("%d\t%s\t%s\t%s\t%s\n" % (n, cid, c["licence"], c["title"][-70:], c.get("desc", "")[:90]))
        for p in grid(items, os.path.join(out_dir, pool), 6, 5, 300, 22):
            print(p)


def cmd_resolve(_):
    """Переводит отметки вида пул:номер в идентификаторы кандидатов."""
    cands, nums = numbering()
    by_num = {(cands[cid]["pool"], n): cid for cid, n in nums.items() if cid in cands}
    out = []
    with open(os.path.join(WORK, "picks.tsv"), encoding="utf-8") as f:
        for ln in f:
            if not ln.strip():
                continue
            ref, cls, note = ln.rstrip("\n").split("\t")
            pool, n = ref.split(":")
            out.append("%s\t%s\t%s\n" % (by_num[(pool, int(n))], cls, note))
    with open(os.path.join(ROOT, "selection.tsv"), "w", encoding="utf-8") as f:
        f.writelines(out)
    print("selection rows:", len(out))


def cmd_final(classes):
    """Строит листы из загруженных снимков для итоговой проверки."""
    out_dir = os.path.join(WORK, "final")
    os.makedirs(out_dir, exist_ok=True)
    img_root = os.path.join(ROOT, "images")
    for cls in sorted(os.listdir(img_root)):
        d = os.path.join(img_root, cls)
        if not os.path.isdir(d) or (classes and cls not in classes):
            continue
        items = [(os.path.splitext(fn)[0][-12:], os.path.join(d, fn)) for fn in sorted(os.listdir(d)) if not fn.startswith(".")]
        for p in grid(items, os.path.join(out_dir, cls), 5, 4, 360, 22):
            print(p)


if __name__ == "__main__":
    cmds = {"sheets": cmd_sheets, "resolve": cmd_resolve, "final": cmd_final}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    cmds[sys.argv[1]](sys.argv[2:])
