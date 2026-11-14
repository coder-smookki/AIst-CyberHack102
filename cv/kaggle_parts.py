"""Обучение модели узлов LibreYOLO9 на видеокартах Kaggle: отправка закрытого ноутбука и сам скрипт ноутбука.

Запуск на этом компьютере:
    python cv/kaggle_parts.py push <ноутбук> <опыты.json> [--dataset shveps/kstv-parts-mix-v1]
Скрипт копирует себя в runs/kaggle/<ноутбук>_src со списком опытов в EXPERIMENTS, пишет рядом
kernel-metadata.json (закрытый ноутбук, видеокарта и интернет включены) и вызывает kaggle kernels push.
Результат забирается командой kaggle kernels output <пользователь>/<ноутбук> -p runs/kaggle/<ноутбук>
и проверяется локально через cv/protocol.py --mode parts.

На Kaggle (без параметров) скрипт ставит libreyolo==1.7.4 (код и веса LibreYOLO9 по MIT), распаковывает
ds.zip закрытого набора kstv-parts-mix-v1 (сборка cv/build_parts_mix.py: только train и val, тестовых
кадров в нём нет) и запускает опыты параллельно, по одному на видеокарту.

Настройки опыта: name, weights, minutes (предел времени), real_repeat (сколько раз повторить в train
реальные кадры real_*), drop (имена классов, рамки которых убираются из train и val) и любые настройки
обучения LibreYOLO. Эпоха выбирается только по части val, порог уверенности здесь не подбирается.
"""
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import zipfile

EXPERIMENTS = []
WORK = "/tmp/kstv"
OUT = "/kaggle/working"
CLASSES = ("motor", "pump_casing", "flange", "coupling_guard", "coupling_no_guard", "terminal_box",
           "terminal_box_burnt", "nameplate", "gauge", "leak", "corrosion")
CHILD = """
import json, sys, time
from libreyolo import LibreYOLO
config = json.loads(sys.argv[1])
started = time.time()
model = LibreYOLO(config.pop("weights"))
model.train(**config)
print("train_minutes", round((time.time() - started) / 60, 1), flush=True)
"""


def push(kernel: str, experiments: list, dataset: str) -> str:
    """Собирает папку ноутбука со скриптом и описанием, отправляет её на Kaggle и возвращает путь папки."""
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    folder = os.path.join(root, "runs", "kaggle", kernel + "_src")
    os.makedirs(folder, exist_ok=True)
    code = open(os.path.abspath(__file__), encoding="utf-8").read()
    code = code.replace("EXPERIMENTS = []", "EXPERIMENTS = " + repr(experiments), 1)
    with open(os.path.join(folder, "train.py"), "w", encoding="utf-8") as handle:
        handle.write(code)
    meta = {"id": f"{dataset.split('/')[0]}/{kernel}", "title": kernel, "code_file": "train.py",
            "language": "python", "kernel_type": "script", "is_private": True, "enable_gpu": True,
            "enable_internet": True, "dataset_sources": [dataset], "competition_sources": [], "kernel_sources": []}
    json.dump(meta, open(os.path.join(folder, "kernel-metadata.json"), "w", encoding="utf-8"), indent=1)
    subprocess.run([sys.executable, "-m", "kaggle.cli", "kernels", "push", "-p", folder], check=True)
    return folder


def unpack() -> str:
    """Возвращает папку набора: распакованную Kaggle или ds.zip, распакованный во временную папку."""
    for path in glob.glob("/kaggle/input/**/data_rel.yaml", recursive=True):
        return os.path.dirname(path)
    target = os.path.join(WORK, "ds")
    if not os.path.isdir(target):
        with zipfile.ZipFile(glob.glob("/kaggle/input/**/ds.zip", recursive=True)[0]) as archive:
            archive.extractall(target)
    return target


def place(source: str, label: str, root: str, split: str, name: str, drop: set) -> None:
    """Кладёт ссылку на кадр и его разметку в папку опыта, убирая рамки классов из drop."""
    os.symlink(source, os.path.join(root, "images", split, name + os.path.splitext(source)[1]))
    lines = [line for line in open(label, encoding="utf-8")
             if line.split() and CLASSES[int(line.split()[0])] not in drop] if os.path.exists(label) else []
    with open(os.path.join(root, "labels", split, name + ".txt"), "w", encoding="utf-8") as handle:
        handle.writelines(lines)


def prepare(source: str, experiment: dict) -> str:
    """Собирает папку опыта с повтором реальных кадров в train и возвращает путь к data.yaml."""
    root = os.path.join(WORK, "sets", experiment["name"])
    drop = set(experiment.get("drop", ()))
    for split in ("train", "val"):
        os.makedirs(os.path.join(root, "images", split), exist_ok=True)
        os.makedirs(os.path.join(root, "labels", split), exist_ok=True)
        for path in sorted(glob.glob(os.path.join(source, "images", split, "*"))):
            stem = os.path.splitext(os.path.basename(path))[0]
            label = os.path.join(source, "labels", split, stem + ".txt")
            repeat = experiment.get("real_repeat", 1) if split == "train" and stem.startswith("real_") else 1
            for copy in range(repeat):
                place(path, label, root, split, stem if copy == 0 else f"{stem}_r{copy}", drop)
    path = os.path.join(root, "data.yaml")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(f"path: {root}\ntrain: images/train\nval: images/val\nnames:\n")
        handle.writelines(f"  {index}: {label}\n" for index, label in enumerate(CLASSES))
    return path


def launch(experiment: dict, source: str, gpu: int) -> tuple:
    """Запускает опыт в отдельном процессе на указанной видеокарте и возвращает процесс, журнал и срок."""
    name = experiment["name"]
    config = {"data": prepare(source, experiment), "project": os.path.join(OUT, "runs"), "name": name,
              "exist_ok": True, "device": "0", "workers": 2}
    config.update({key: value for key, value in experiment.items()
                   if key not in ("name", "minutes", "real_repeat", "drop")})
    os.makedirs(os.path.join(OUT, "runs", name), exist_ok=True)
    log = open(os.path.join(OUT, "runs", name, "kaggle_train.log"), "w", encoding="utf-8")
    env = dict(os.environ, CUDA_VISIBLE_DEVICES=str(gpu), PYTHONUNBUFFERED="1")
    process = subprocess.Popen([sys.executable, "-c", CHILD, json.dumps(config)], cwd=WORK, env=env,
                               stdout=log, stderr=subprocess.STDOUT)
    return process, log, time.time() + experiment.get("minutes", 100) * 60


def tidy(name: str) -> None:
    """Удаляет промежуточные контрольные точки опыта, оставляя best.pt и last.pt."""
    for path in glob.glob(os.path.join(OUT, "runs", name, "weights", "*.pt")):
        if os.path.basename(path) not in ("best.pt", "last.pt"):
            os.remove(path)


def train() -> None:
    """Готовит окружение, запускает опыты по очереди видеокарт и ждёт их завершения или предела времени."""
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "libreyolo==1.7.4"], check=True)
    os.makedirs(WORK, exist_ok=True)
    source = unpack()
    import torch
    gpus = max(1, torch.cuda.device_count())
    queue, running, status = list(EXPERIMENTS), {}, {}
    while queue or running:
        for gpu in range(gpus):
            if gpu not in running and queue:
                experiment = queue.pop(0)
                running[gpu] = (experiment["name"], *launch(experiment, source, gpu))
                print("старт", experiment["name"], "видеокарта", gpu, flush=True)
        time.sleep(20)
        for gpu, (name, process, log, deadline) in list(running.items()):
            code = process.poll()
            if code is None and time.time() > deadline:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    process.kill()
                code = "deadline"
            if code is not None:
                log.close()
                tidy(name)
                status[name] = code
                print("конец", name, code, flush=True)
                del running[gpu]
    json.dump(status, open(os.path.join(OUT, "status.json"), "w"), ensure_ascii=False)
    shutil.rmtree(os.path.join(WORK, "sets"), ignore_errors=True)


def main() -> None:
    """Отправляет ноутбук при запуске с параметром push, иначе обучает (режим ноутбука Kaggle)."""
    if len(sys.argv) > 1 and sys.argv[1] == "push":
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument("mode")
        parser.add_argument("kernel")
        parser.add_argument("experiments")
        parser.add_argument("--dataset", default="shveps/kstv-parts-mix-v1")
        args = parser.parse_args()
        print(push(args.kernel, json.load(open(args.experiments, encoding="utf-8")), args.dataset))
    else:
        train()


if __name__ == "__main__":
    main()
