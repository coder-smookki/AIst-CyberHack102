"""Отправка опытов обучения детектора дефектов в закрытый ноутбук Kaggle с видеокартой.

Запуск:
    python cv/kaggle_push.py <ноутбук> <опыты.json> [--dataset shveps/kstv-defects-v3] [--dataset ещё_набор]
        [--script cv/kaggle_train_v4.py] [--source shveps/<прошлый ноутбук>]

Файл опытов - список словарей: name, weights (например LibreRFDETRs.pt), epochs, imgsz, batch,
minutes (предел времени опыта), screen (брать ли экранные копии открытых кадров) и любые настройки
обучения LibreYOLO. Скрипт обучения (по умолчанию cv/kaggle_train.py, ключ --script) копируется
в runs/kaggle/<ноутбук>_src со списком опытов,
рядом пишется kernel-metadata.json (закрытый ноутбук, видеокарта и интернет включены), затем вызывается
kaggle kernels push. Результат забирается командой kaggle kernels output <пользователь>/<ноутбук>
-p runs/kaggle/<ноутбук> и проверяется локально через cv/protocol.py. Ключ --source прикладывает вывод
прошлого ноутбука как входные данные: так cv/kaggle_train_v4.py продолжает опыт, прерванный пределом сессии.
"""
import argparse
import json
import os
import subprocess

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
KAGGLE = os.path.join(ROOT, ".venv", "bin", "kaggle")


def build(kernel: str, experiments: list, dataset: str, script: str = "kaggle_train.py", extra: tuple = (),
          sources: tuple = ()) -> str:
    """Создаёт папку ноутбука со скриптом и описанием и возвращает её путь.

    extra - дополнительные наборы Kaggle, sources - ноутбуки, чей вывод прикладывается как входные данные.
    """
    owner = dataset.split("/")[0]
    folder = os.path.join(ROOT, "runs", "kaggle", kernel + "_src")
    os.makedirs(folder, exist_ok=True)
    code = open(os.path.join(ROOT, "cv", os.path.basename(script)), encoding="utf-8").read()
    code = code.replace("EXPERIMENTS = []", "EXPERIMENTS = " + repr(experiments), 1)
    with open(os.path.join(folder, "train.py"), "w", encoding="utf-8") as handle:
        handle.write(code)
    meta = {"id": f"{owner}/{kernel}", "title": kernel, "code_file": "train.py", "language": "python",
            "kernel_type": "script", "is_private": True, "enable_gpu": True, "enable_internet": True,
            "dataset_sources": [dataset, *extra], "competition_sources": [], "kernel_sources": list(sources)}
    json.dump(meta, open(os.path.join(folder, "kernel-metadata.json"), "w", encoding="utf-8"), indent=1)
    return folder


def main() -> None:
    """Собирает папку ноутбука и отправляет её на Kaggle."""
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel")
    parser.add_argument("experiments")
    parser.add_argument("--dataset", action="append")
    parser.add_argument("--script", default="kaggle_train.py")
    parser.add_argument("--source", action="append", default=[])
    args = parser.parse_args()
    datasets = args.dataset or ["shveps/kstv-defects-v3"]
    experiments = json.load(open(args.experiments, encoding="utf-8"))
    folder = build(args.kernel, experiments, datasets[0], args.script, tuple(datasets[1:]), tuple(args.source))
    subprocess.run([KAGGLE, "kernels", "push", "-p", folder], check=True)


if __name__ == "__main__":
    main()
