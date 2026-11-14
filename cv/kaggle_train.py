"""Обучение детекторов дефектов RF-DETR на видеокартах Kaggle (скрипт закрытого ноутбука Kaggle).

Скрипт не запускается на этом компьютере: cv/kaggle_push.py подставляет список опытов в EXPERIMENTS,
складывает файл в папку ноутбука и отправляет его на Kaggle. На Kaggle скрипт:
    ставит libreyolo[rfdetr]==1.7.4 (код MIT, веса RF-DETR Apache-2.0, скачиваются с Hugging Face);
    находит закрытый набор kstv-defects-v3 (только части train, val и train_screen, отложенных снимков
    заказчика и набора из сети в нём нет) и при необходимости распаковывает ds.zip;
    запускает опыты параллельно, по одному на видеокарту, каждый со своим пределом времени;
    оставляет в /kaggle/working/runs/<опыт> только best.pt, last.pt, журналы и сводку обучения.
Эпоха и лучшие веса выбираются только по части val; порог уверенности здесь не подбирается.
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
CHILD = """
import json, sys, time
from libreyolo import LibreYOLO
config = json.loads(sys.argv[1])
started = time.time()
model = LibreYOLO(config.pop("weights"))
model.train(**config)
print("train_minutes", round((time.time() - started) / 60, 1), flush=True)
"""


def install() -> None:
    """Ставит библиотеку обучения нужной версии."""
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "libreyolo[rfdetr]==1.7.4"], check=True)


def unpack() -> str:
    """Возвращает папку набора на Kaggle, распаковывая ds.zip во временную папку, если архив не распакован."""
    for path in glob.glob("/kaggle/input/**/data_rel.yaml", recursive=True):
        return os.path.dirname(path)
    archives = glob.glob("/kaggle/input/**/ds.zip", recursive=True)
    target = os.path.join(WORK, "ds")
    with zipfile.ZipFile(archives[0]) as archive:
        archive.extractall(target)
    return target


def link_files(source: str, target: str) -> None:
    """Создаёт в target символьные ссылки на все файлы папки source."""
    os.makedirs(target, exist_ok=True)
    for path in glob.glob(os.path.join(source, "*")):
        destination = os.path.join(target, os.path.basename(path))
        if not os.path.exists(destination):
            os.symlink(path, destination)


def prepare(source: str, name: str, screen: bool) -> str:
    """Собирает папку опыта из ссылок: train с экранными копиями или без них, val без изменений."""
    root = os.path.join(WORK, "sets", name)
    for kind in ("images", "labels"):
        link_files(os.path.join(source, kind, "train"), os.path.join(root, kind, "train"))
        if screen:
            link_files(os.path.join(source, kind, "train_screen"), os.path.join(root, kind, "train"))
        link_files(os.path.join(source, kind, "val"), os.path.join(root, kind, "val"))
    path = os.path.join(root, "data.yaml")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(f"path: {root}\ntrain: images/train\nval: images/val\nnames:\n")
        handle.writelines(f"  {index}: {label}\n" for index, label in
                          enumerate(("corrosion", "leak", "terminal_box_burnt", "damage")))
    return path


def launch(experiment: dict, source: str, gpu: int) -> tuple:
    """Запускает опыт в отдельном процессе на указанной видеокарте и возвращает процесс и журнал."""
    name = experiment["name"]
    config = {"data": prepare(source, name, experiment.get("screen", True)), "project": os.path.join(OUT, "runs"),
              "name": name, "exist_ok": True, "device": "0", "workers": experiment.get("workers", 2)}
    config.update({key: value for key, value in experiment.items() if key not in ("name", "screen", "minutes", "workers")})
    os.makedirs(os.path.join(OUT, "runs", name), exist_ok=True)
    log = open(os.path.join(OUT, "runs", name, "kaggle_train.log"), "w", encoding="utf-8")
    env = dict(os.environ, CUDA_VISIBLE_DEVICES=str(gpu), PYTHONUNBUFFERED="1")
    process = subprocess.Popen([sys.executable, "-c", CHILD, json.dumps(config)], cwd=WORK, env=env,
                               stdout=log, stderr=subprocess.STDOUT)
    return process, log, time.time() + experiment.get("minutes", 180) * 60


def tidy(name: str) -> None:
    """Удаляет промежуточные контрольные точки опыта, оставляя best.pt и last.pt."""
    for path in glob.glob(os.path.join(OUT, "runs", name, "weights", "*.pt")):
        if os.path.basename(path) not in ("best.pt", "last.pt"):
            os.remove(path)


def main() -> None:
    """Готовит окружение, запускает опыты по очереди видеокарт и ждёт их завершения или предела времени."""
    install()
    os.makedirs(WORK, exist_ok=True)
    source = unpack()
    import torch
    gpus = max(1, torch.cuda.device_count())
    queue = list(EXPERIMENTS)
    running = {}
    status = {}
    while queue or running:
        for gpu in range(gpus):
            if gpu not in running and queue:
                experiment = queue.pop(0)
                running[gpu] = (experiment["name"], *launch(experiment, source, gpu))
                print("старт", experiment["name"], "видеокарта", gpu, flush=True)
        time.sleep(30)
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


if __name__ == "__main__":
    main()
