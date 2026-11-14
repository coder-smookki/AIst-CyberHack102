"""Обучение детекторов дефектов RF-DETR на наборе defects_ds_v4 в закрытом ноутбуке Kaggle (две видеокарты T4).

Скрипт не запускается на этом компьютере: cv/kaggle_push.py --script cv/kaggle_train_v4.py подставляет список
опытов в EXPERIMENTS, кладёт файл в папку ноутбука и отправляет его на Kaggle. На Kaggle скрипт:
    ставит libreyolo[rfdetr]==1.7.4 (код MIT, веса RF-DETR Apache-2.0);
    находит закрытый набор kstv-v4-data (части train, train_screen и val; отложенных снимков заказчика,
    их копий "с монитора" и набора из сети в нём нет) и распаковывает ds.zip;
    берёт начальные веса либо по имени LibreYOLO (LibreRFDETRn.pt), либо из файла приложенного набора
    (запись "input:<имя файла>", например веса третьей сборки v3_rfn384s_best.pt);
    продолжает прерванный опыт, если к ноутбуку приложен вывод прошлого ноутбука с
    runs/<опыт>/weights/last.pt: папка опыта копируется в рабочую и обучение идёт с resume;
    запускает опыты параллельно, по одному на видеокарту, каждый со своим пределом времени, и
    оставляет в /kaggle/working/runs/<опыт> только best.pt, last.pt, журналы и сводку обучения.
Эпоха и лучшие веса выбираются только по части val; порог уверенности здесь не подбирается.
"""
import csv
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
INPUT = "/kaggle/input"
CLASSES = ("corrosion", "leak", "terminal_box_burnt", "damage")
OWN_KEYS = ("name", "screen", "minutes", "workers", "limit", "weights")
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
    """Возвращает папку набора: распакованную папку с images/train или ds.zip, распакованный во временную папку."""
    for path in glob.glob(os.path.join(INPUT, "**", "images", "train"), recursive=True):
        return os.path.dirname(os.path.dirname(path))
    archives = glob.glob(os.path.join(INPUT, "**", "ds.zip"), recursive=True)
    target = os.path.join(WORK, "ds")
    if not os.path.isdir(os.path.join(target, "images")):
        with zipfile.ZipFile(archives[0]) as archive:
            archive.extractall(target)
    return target


def input_file(name: str) -> str:
    """Находит файл с данным именем среди приложенных наборов и выводов ноутбуков."""
    found = sorted(glob.glob(os.path.join(INPUT, "**", name), recursive=True))
    if not found:
        raise FileNotFoundError(name)
    return found[0]


def resolve_weights(weights: str) -> str:
    """Переводит запись "input:<файл>" в путь внутри приложенных данных, имя LibreYOLO оставляет как есть."""
    return input_file(weights[len("input:"):]) if weights.startswith("input:") else weights


def previous_run(name: str) -> str | None:
    """Копирует папку прерванного опыта из вывода прошлого ноутбука и возвращает путь к её last.pt."""
    found = sorted(glob.glob(os.path.join(INPUT, "**", "runs", name, "weights", "last.pt"), recursive=True))
    if not found:
        return None
    source = os.path.dirname(os.path.dirname(found[0]))
    target = os.path.join(OUT, "runs", name)
    shutil.copytree(source, target, dirs_exist_ok=True)
    return os.path.join(target, "weights", "last.pt")


def link_files(source: str, target: str, limit: int | None = None) -> None:
    """Создаёт в target символьные ссылки на файлы папки source (при limit только на первые limit файлов)."""
    os.makedirs(target, exist_ok=True)
    paths = sorted(glob.glob(os.path.join(source, "*")))
    for path in paths[:limit] if limit else paths:
        destination = os.path.join(target, os.path.basename(path))
        if not os.path.exists(destination):
            os.symlink(path, destination)


def prepare(source: str, name: str, screen: bool, limit: int | None = None) -> str:
    """Собирает папку опыта из ссылок: train с экранными копиями или без них, val без изменений.

    Кадры из папок images/train_extra и labels/train_extra любого приложенного набора (дополнение к сборке,
    загруженное отдельно) тоже идут в train. Путь папки зависит только от имени опыта, поэтому продолженный
    опыт находит набор там же, где прерванный.
    """
    root = os.path.join(WORK, "sets", name)
    for kind in ("images", "labels"):
        link_files(os.path.join(source, kind, "train"), os.path.join(root, kind, "train"), limit)
        if screen and not limit:
            link_files(os.path.join(source, kind, "train_screen"), os.path.join(root, kind, "train"))
        for extra in sorted(glob.glob(os.path.join(INPUT, "**", kind, "train_extra"), recursive=True)):
            link_files(extra, os.path.join(root, kind, "train"))
        link_files(os.path.join(source, kind, "val"), os.path.join(root, kind, "val"))
    path = os.path.join(root, "data.yaml")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(f"path: {root}\ntrain: images/train\nval: images/val\nnames:\n")
        handle.writelines(f"  {index}: {label}\n" for index, label in enumerate(CLASSES))
    return path


def child_config(experiment: dict, source: str) -> dict:
    """Готовит настройки обучения опыта: набор, папку вывода, начальные веса и продолжение прерванного опыта."""
    name = experiment["name"]
    config = {"data": prepare(source, name, experiment.get("screen", True), experiment.get("limit")),
              "project": os.path.join(OUT, "runs"), "name": name, "exist_ok": True, "device": "0",
              "workers": experiment.get("workers", 2)}
    config.update({key: value for key, value in experiment.items() if key not in OWN_KEYS})
    resume = previous_run(name)
    if resume:
        config["weights"], config["resume"] = resume, resume
    else:
        config["weights"] = resolve_weights(experiment["weights"])
    return config


def launch(experiment: dict, source: str, gpu: int) -> tuple:
    """Запускает опыт в отдельном процессе на указанной видеокарте и возвращает процесс, журнал и срок."""
    name = experiment["name"]
    config = child_config(experiment, source)
    os.makedirs(os.path.join(OUT, "runs", name), exist_ok=True)
    log = open(os.path.join(OUT, "runs", name, "kaggle_train.log"), "a", encoding="utf-8")
    log.write(json.dumps({key: value for key, value in config.items() if key != "data"}) + "\n")
    log.flush()
    env = dict(os.environ, CUDA_VISIBLE_DEVICES=str(gpu), PYTHONUNBUFFERED="1")
    process = subprocess.Popen([sys.executable, "-c", CHILD, json.dumps(config)], cwd=WORK, env=env,
                               stdout=log, stderr=subprocess.STDOUT)
    return process, log, time.time() + experiment.get("minutes", 180) * 60


def last_epoch(name: str) -> int:
    """Возвращает номер последней законченной эпохи опыта по results.csv (0, если файла нет)."""
    path = os.path.join(OUT, "runs", name, "results.csv")
    if not os.path.exists(path):
        return 0
    rows = list(csv.DictReader(open(path, encoding="utf-8")))
    return int(float(rows[-1]["epoch"])) if rows else 0


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
    print("видеокарт", gpus, [torch.cuda.get_device_name(i) for i in range(torch.cuda.device_count())],
          "набор", source, "train", len(os.listdir(os.path.join(source, "images", "train"))), flush=True)
    queue = list(EXPERIMENTS)
    running, status = {}, {}
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
                status[name] = {"code": code, "last_epoch": last_epoch(name)}
                print("конец", name, status[name], flush=True)
                del running[gpu]
    json.dump(status, open(os.path.join(OUT, "status.json"), "w"), ensure_ascii=False)
    shutil.rmtree(os.path.join(WORK, "sets"), ignore_errors=True)


if __name__ == "__main__":
    main()
