"""Укладывает веса языковой модели помощника в ассеты приложения (mobile/assets/llm) и пишет manifest.json.

Файлы весов большие и в git не попадают (assets/llm/*.gguf.*); после чистого клонирования их нужно получить
этим скриптом, иначе помощник работает только поиском по справке.

Примеры:
    python tool/fetch_llm.py add --gguf /path/kv-assistant-q8_0.gguf --id kv-main --title "Основная модель" \
        --min-ram 7000 --min-ios-avail 3000 --context 2048 --snippets 3
    python tool/fetch_llm.py add --gguf /path/kv-assistant-q4_k_m.gguf --id kv-lite --title "Облегчённая модель" \
        --min-ram 3000 --min-ios-avail 1200 --context 1024 --snippets 1
    python tool/fetch_llm.py download --repo Qwen/Qwen3-0.6B-GGUF --file Qwen3-0.6B-Q8_0.gguf --id kv-main \
        --title "Базовая модель" --min-ram 3000
    python tool/fetch_llm.py list
    python tool/fetch_llm.py remove --id kv-main

Уровни в manifest.json идут от сильного к слабому: приложение берёт первый, которому хватает памяти устройства
(min_ram_mb), а без подходящего уровня отвечает поиском по справке. Части по 32 МБ нужны, чтобы при распаковке
на телефоне не держать весь файл в памяти.
"""

import argparse
import hashlib
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets", "llm")
MANIFEST = os.path.join(ASSETS, "manifest.json")
PART = 32 * 1024 * 1024


def load():
    """Читает manifest.json или возвращает пустое описание."""
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding="utf-8") as f:
            return json.load(f)
    return {"tiers": []}


def save(manifest):
    """Пишет manifest.json, уровни по убыванию требуемой памяти."""
    manifest["tiers"].sort(key=lambda t: -t["min_ram_mb"])
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
        f.write("\n")


def drop_parts(tier_id):
    """Удаляет части весов уровня."""
    for name in os.listdir(ASSETS):
        if name.startswith(tier_id + ".gguf."):
            os.remove(os.path.join(ASSETS, name))


def add(args):
    """Режет файл GGUF на части и добавляет уровень."""
    if not os.path.isfile(args.gguf):
        sys.exit("нет файла " + args.gguf)
    with open(args.gguf, "rb") as f:
        if f.read(4) != b"GGUF":
            sys.exit("файл не в формате GGUF")
    os.makedirs(ASSETS, exist_ok=True)
    drop_parts(args.id)
    parts = []
    digest = hashlib.sha256()
    with open(args.gguf, "rb") as src:
        i = 0
        while True:
            chunk = src.read(PART)
            if not chunk:
                break
            digest.update(chunk)
            name = "%s.gguf.%03d" % (args.id, i)
            with open(os.path.join(ASSETS, name), "wb") as dst:
                dst.write(chunk)
            parts.append(name)
            i += 1
    manifest = load()
    manifest["tiers"] = [t for t in manifest["tiers"] if t["id"] != args.id]
    manifest["tiers"].append(
        {
            "id": args.id,
            "title": args.title,
            "parts": parts,
            "bytes": os.path.getsize(args.gguf),
            "version": digest.hexdigest()[:12],
            "min_ram_mb": args.min_ram,
            "context": args.context,
            "threads": args.threads,
            "max_tokens": args.max_tokens,
            "think_prefix": not args.no_think,
            "snippets": args.snippets,
            "min_ios_avail_mb": args.min_ios_avail,
            "source": args.source or os.path.basename(args.gguf),
        }
    )
    save(manifest)
    print("добавлен уровень", args.id, len(parts), "частей", os.path.getsize(args.gguf), "байт")


def download(args):
    """Скачивает GGUF с Hugging Face во временный файл и добавляет уровень."""
    url = "https://huggingface.co/%s/resolve/main/%s" % (args.repo, args.file)
    tmp = os.path.join(ASSETS, ".download.gguf")
    os.makedirs(ASSETS, exist_ok=True)
    print("скачиваю", url)
    urllib.request.urlretrieve(url, tmp)
    args.gguf = tmp
    args.source = args.repo + "/" + args.file
    try:
        add(args)
    finally:
        os.remove(tmp)


def remove(args):
    """Удаляет уровень и его части."""
    drop_parts(args.id)
    manifest = load()
    manifest["tiers"] = [t for t in manifest["tiers"] if t["id"] != args.id]
    save(manifest)


def show(_):
    """Печатает уровни и проверяет, что все части на месте."""
    for t in load()["tiers"]:
        have = sum(os.path.getsize(os.path.join(ASSETS, p)) for p in t["parts"] if os.path.exists(os.path.join(ASSETS, p)))
        state = "есть" if have == t["bytes"] else "нет частей (%d из %d байт)" % (have, t["bytes"])
        print("%s  %s  память >= %d МБ  %s  %s" % (t["id"], t["title"], t["min_ram_mb"], t.get("source", ""), state))


def main():
    """Разбирает команду."""
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("add", "download"):
        s = sub.add_parser(name)
        if name == "add":
            s.add_argument("--gguf", required=True)
            s.add_argument("--source")
        else:
            s.add_argument("--repo", required=True)
            s.add_argument("--file", required=True)
        s.add_argument("--id", required=True)
        s.add_argument("--title", required=True)
        s.add_argument("--min-ram", type=int, required=True)
        s.add_argument("--context", type=int, default=1024)
        s.add_argument("--threads", type=int, default=4)
        s.add_argument("--max-tokens", type=int, default=320)
        s.add_argument("--no-think", action="store_true")
        s.add_argument("--snippets", type=int, default=3)
        s.add_argument("--min-ios-avail", type=int, default=1500)
    r = sub.add_parser("remove")
    r.add_argument("--id", required=True)
    sub.add_parser("list")
    a = p.parse_args()
    {"add": add, "download": download, "remove": remove, "list": show}[a.cmd](a)


if __name__ == "__main__":
    main()
