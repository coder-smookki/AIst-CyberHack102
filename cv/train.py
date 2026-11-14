"""Обучение детектора узлов и дефектов на размеченном наборе.

Запуск:
    python cv/train.py <data.yaml> [эпохи=30] [веса=LibreYOLO9t.pt] [устройство=mps]
                       [--name detector] [--batch 16] [--imgsz 640] [--plain-epochs N] [--warmup N] [--lr X]
                       [--set ключ=значение ...]

Устройство: mps для Apple Silicon, 0 для видеокарты NVIDIA, cpu в остальных случаях.
Параметр --plain-epochs задаёт число последних эпох без мозаики, --warmup число эпох разогрева:
для коротких запусков их нужно уменьшать, иначе мозаика не включится вовсе. Без этих параметров
действуют значения библиотеки для выбранного семейства моделей. Параметр --set передаёт библиотеке
любую её настройку обучения, например --set multi_scale=false для RF-DETR: на mps смена размера входа
на каждом шаге замедляет обучение в разы.
Код и стартовые веса LibreYOLO9 распространяются по лицензии MIT, RF-DETR и D-FINE по Apache-2.0.
"""
import argparse
import json
import os
import time


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Разбирает параметры запуска обучения."""
    parser = argparse.ArgumentParser()
    parser.add_argument("data")
    parser.add_argument("epochs", nargs="?", type=int, default=30)
    parser.add_argument("weights", nargs="?", default="LibreYOLO9t.pt")
    parser.add_argument("device", nargs="?", default="mps")
    parser.add_argument("--name", default="detector")
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--plain-epochs", type=int, default=None)
    parser.add_argument("--warmup", type=int, default=None)
    parser.add_argument("--lr", type=float, default=None)
    parser.add_argument("--set", action="append", default=[], metavar="ключ=значение")
    return parser.parse_args(argv)


def train_options(args: argparse.Namespace) -> dict:
    """Собирает параметры обучения для библиотеки из параметров запуска."""
    options = {"data": args.data, "epochs": args.epochs, "imgsz": args.imgsz, "batch": args.batch,
               "device": args.device, "workers": 4, "project": "runs", "name": args.name, "exist_ok": True}
    if args.plain_epochs is not None:
        options["no_aug_epochs"] = min(args.plain_epochs, max(0, args.epochs - 1))
    if args.warmup is not None:
        options["warmup_epochs"] = min(args.warmup, args.epochs)
    if args.lr is not None:
        options["lr0"] = args.lr
    for item in args.set:
        key, _, value = item.partition("=")
        options[key] = json.loads(value)
    return options


def main() -> None:
    """Запускает обучение, печатает путь к лучшим весам и сохраняет длительность рядом с ними."""
    from libreyolo import LibreYOLO
    args = parse_args()
    started = time.time()
    model = LibreYOLO(args.weights)
    model.train(**train_options(args))
    minutes = round((time.time() - started) / 60, 1)
    folder = os.path.join("runs", args.name)
    os.makedirs(folder, exist_ok=True)
    json.dump({"weights": args.weights, "data": args.data, "epochs": args.epochs, "train_minutes": minutes},
              open(os.path.join(folder, "timing.json"), "w", encoding="utf-8"), ensure_ascii=False)
    print(f"готово за {minutes} мин: {folder}/weights/best.pt")


if __name__ == "__main__":
    main()
