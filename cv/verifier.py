"""Второй этап проверки рамок дефектов: классификатор вырезок, отсекающий ложные тревоги детектора.

Детектор дефектов (models/defects.onnx) выдаёт рамки с уверенностью. Для каждой рамки вырезается
область кадра с запасом вокруг неё, замороженная сеть DINOv2 small (Apache-2.0,
https://huggingface.co/facebook/dinov2-small) превращает вырезку в вектор признаков, а логистическая
регрессия или небольшой перцептрон по этим признакам, классу и форме рамки оценивает, лежит ли рамка
на настоящем дефекте своего класса или на фоне. Классификатор учится на рамках детектора и разметке
обучающей части defects_ds_v3. Правило объединения (fusion - калиброванная смесь с уверенностью
детектора, veto - запрет рамок с низкой оценкой) и пороги выбираются только по проверочной части.

Итог замера 2026-11-14 (runs/reports/verifier.json): на проверочной части при сохранении полноты
детектора выигрыш в точности рамок 0.341 -> 0.347, на тестовых наборах связка не меняет ни одного
показателя, а при равной точности сдвиг порога самого детектора даёт не меньшую полноту. Второй
этап в нынешнем виде пользы не приносит и в работу не включён.

Шаги запуска (все промежуточные файлы в runs/verifier):
    python cv/verifier.py detect [--sets train,val,holdout,holdout_screen,web]
        прогон детектора с порогом protocol.FLOOR и сохранение рамок;
    python cv/verifier.py features [--sets ...]
        признаки вырезок для всех сохранённых рамок (и размеченных рамок обучающей части);
    python cv/verifier.py fit
        обучение классификатора на обучающей части, калибровка и выбор порога на проверочной;
    python cv/verifier.py report
        показатели детектора и связки детектор + классификатор по cv/protocol.py на всех наборах;
    python cv/verifier.py latency
        задержка признаков одной вырезки на процессоре.

Тестовые наборы (holdout, holdout_screen, web) используются только в шаге report.
"""
import argparse
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import protocol

ROOT = protocol.ROOT
OUT = os.path.join(ROOT, "runs", "verifier")
DETECTOR = os.path.join(ROOT, "models", "defects.onnx")
BACKBONE = "facebook/dinov2-small"
CROP_SIZE = 224
CONTEXT = 0.25
MIN_SIDE = 32
GATE = 0.08
ALL_SETS = ("train", "val", "holdout", "holdout_screen", "web")
TEST_SETS = ("holdout", "holdout_screen", "web")
SET_FOLDERS = {"train": ("data/open/defects_ds_v3", "train"), **protocol.SET_PATHS}


def cache_path(name: str, kind: str) -> str:
    """Возвращает путь промежуточного файла набора name вида kind (boxes или features)."""
    return os.path.join(OUT, f"{kind}_{name}.json" if kind == "boxes" else f"{kind}_{name}.npz")


def image_path(name: str, file: str) -> str:
    """Возвращает путь снимка набора name по имени файла из записи."""
    if name == "web":
        return os.path.join(ROOT, "data", "web_testset", file)
    folder, split = SET_FOLDERS[name]
    return os.path.join(ROOT, folder, "images", split, file)


def detect(sets: list[str], weights: str = DETECTOR) -> None:
    """Прогоняет детектор по наборам и сохраняет записи снимков с рамками в формате cv/protocol.py."""
    from libreyolo import LibreYOLO
    model = LibreYOLO(weights)
    os.makedirs(OUT, exist_ok=True)
    for name in sets:
        started = time.time()
        if name == "web":
            records = protocol.web_records([model], protocol.DEFECT_NAMES)
        else:
            folder, split = SET_FOLDERS[name]
            records = protocol.labelled_records([model], os.path.join(ROOT, folder), split, protocol.DEFECT_NAMES)
        for record in records:
            record["labelled"] = None if record["labelled"] is None else sorted(record["labelled"])
        json.dump({"weights": os.path.relpath(weights, ROOT), "floor": protocol.FLOOR, "records": records},
                  open(cache_path(name, "boxes"), "w", encoding="utf-8"), ensure_ascii=False)
        print(f"{name}: {len(records)} снимков, {sum(len(r['predicted']) for r in records)} рамок, "
              f"{time.time() - started:.0f} с", flush=True)


def load_records(name: str) -> list[dict]:
    """Читает сохранённые записи набора и возвращает рамки в виде кортежей, как в cv/protocol.py."""
    data = json.load(open(cache_path(name, "boxes"), encoding="utf-8"))
    records = []
    for row in data["records"]:
        records.append({"file": row["file"], "group": row["group"],
                        "labelled": None if row["labelled"] is None else set(row["labelled"]),
                        "truth": [(n, tuple(b)) for n, b in row["truth"]],
                        "predicted": [(n, tuple(b), float(s)) for n, b, s in row["predicted"]]})
    return records


def box_labels(predicted: list[tuple], truth: list[tuple]) -> list[bool]:
    """Отмечает для каждой рамки, верна ли она по правилу cv/protocol.py (класс совпал, IoU не меньше 0.5).

    Сопоставление жадное по убыванию уверенности, каждая размеченная рамка засчитывается один раз;
    порядок результата совпадает с порядком predicted.
    """
    order = sorted(range(len(predicted)), key=lambda index: -predicted[index][2])
    used, labels = set(), [False] * len(predicted)
    for index in order:
        name, box, _ = predicted[index]
        best, best_iou = None, 0.5
        for t_index, (t_name, t_box) in enumerate(truth):
            value = protocol.iou(box, t_box) if t_index not in used and t_name == name else 0.0
            if value >= best_iou:
                best, best_iou = t_index, value
        if best is not None:
            used.add(best)
            labels[index] = True
    return labels


def crop_window(box: tuple, width: int, height: int, context: float = CONTEXT) -> tuple[int, int, int, int]:
    """Возвращает окно вырезки: рамка, расширенная на долю context с каждой стороны, не меньше MIN_SIDE.

    Окно обрезается границами кадра и всегда имеет ненулевую площадь.
    """
    x1, y1, x2, y2 = box
    w, h = max(x2 - x1, 1.0), max(y2 - y1, 1.0)
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    half_w, half_h = max(w * (1 + 2 * context), MIN_SIDE) / 2, max(h * (1 + 2 * context), MIN_SIDE) / 2
    left, top = int(max(0, np.floor(cx - half_w))), int(max(0, np.floor(cy - half_h)))
    right, bottom = int(min(width, np.ceil(cx + half_w))), int(min(height, np.ceil(cy + half_h)))
    right, bottom = max(right, min(left + 1, width)), max(bottom, min(top + 1, height))
    left, top = min(left, right - 1), min(top, bottom - 1)
    return left, top, right, bottom


def geometry(box: tuple, width: int, height: int) -> list[float]:
    """Возвращает признаки формы рамки: логарифм доли площади кадра, логарифм отношения сторон, центр."""
    x1, y1, x2, y2 = box
    w, h = max(x2 - x1, 1.0), max(y2 - y1, 1.0)
    return [float(np.log(w * h / (width * height))), float(np.log(w / h)),
            float((x1 + x2) / 2 / width), float((y1 + y2) / 2 / height)]


class Backbone:
    """Замороженная сеть DINOv2 small: вектор признаков вырезки из токена CLS и среднего по патчам."""

    def __init__(self, device: str | None = None):
        """Загружает веса из кэша Hugging Face и переводит сеть в режим вывода."""
        import torch
        from transformers import AutoModel
        self.torch = torch
        self.device = device or ("mps" if torch.backends.mps.is_available() else "cpu")
        self.model = AutoModel.from_pretrained(BACKBONE).eval().to(self.device)
        self.mean = np.array([0.485, 0.456, 0.406], np.float32)
        self.std = np.array([0.229, 0.224, 0.225], np.float32)

    def prepare(self, crop: np.ndarray) -> np.ndarray:
        """Переводит вырезку BGR в нормированный массив 3 x CROP_SIZE x CROP_SIZE."""
        import cv2
        rgb = cv2.cvtColor(cv2.resize(crop, (CROP_SIZE, CROP_SIZE), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
        return ((rgb.astype(np.float32) / 255.0 - self.mean) / self.std).transpose(2, 0, 1)

    def __call__(self, crops: list[np.ndarray]) -> np.ndarray:
        """Возвращает признаки вырезок, массив N x 768."""
        if not crops:
            return np.zeros((0, 768), np.float32)
        batch = self.torch.from_numpy(np.stack([self.prepare(crop) for crop in crops])).to(self.device)
        with self.torch.no_grad():
            tokens = self.model(pixel_values=batch).last_hidden_state
        return self.torch.cat([tokens[:, 0], tokens[:, 1:].mean(1)], 1).float().cpu().numpy()


def candidates(predicted: list[tuple], gate: float = GATE, top: int | None = None) -> list[int]:
    """Возвращает индексы рамок с уверенностью не ниже gate по убыванию уверенности (не более top)."""
    order = [i for i in sorted(range(len(predicted)), key=lambda i: -predicted[i][2]) if predicted[i][2] >= gate]
    return order if top is None else order[:top]


def features(sets: list[str], top_train: int = 20, batch: int = 64) -> None:
    """Считает признаки вырезок для рамок детектора с уверенностью не ниже GATE и сохраняет их.

    На обучающей части берётся не более top_train рамок на снимок и добавляются размеченные рамки как
    заведомо верные примеры (source 1); рамки детектора имеют source 0. Метка - верна ли рамка по
    правилу cv/protocol.py.
    """
    backbone = Backbone()
    for name in sets:
        started = time.time()
        records = load_records(name)
        rows, crops, vectors = [], [], []
        for image_index, record in enumerate(records):
            frame = protocol.read_frame(image_path(name, record["file"]))
            if frame is None:
                continue
            height, width = frame.shape[:2]
            order = candidates(record["predicted"], GATE, top_train if name == "train" else None)
            labels = box_labels(record["predicted"], record["truth"])
            items = [(record["predicted"][i], labels[i], 0, i) for i in order]
            if name == "train":
                items += [((t_name, t_box, 1.0), True, 1, -1) for t_name, t_box in record["truth"]]
            for (cls, box, score), label, source, box_index in items:
                left, top_, right, bottom = crop_window(box, width, height)
                crops.append(frame[top_:bottom, left:right])
                rows.append([image_index, box_index, protocol.DEFECT_NAMES.index(cls), score, int(label), source,
                             *geometry(box, width, height)])
                if len(crops) >= batch:
                    vectors.append(backbone(crops))
                    crops = []
        vectors.append(backbone(crops))
        np.savez_compressed(cache_path(name, "features"), meta=np.array(rows, np.float32).reshape(-1, 10),
                            features=np.concatenate(vectors).astype(np.float16))
        print(f"{name}: {len(rows)} вырезок, {time.time() - started:.0f} с", flush=True)


def load_features(name: str) -> tuple[np.ndarray, np.ndarray]:
    """Читает признаки набора: meta (снимок, рамка, класс, уверенность, метка, источник, форма) и векторы."""
    data = np.load(cache_path(name, "features"))
    return data["meta"], data["features"].astype(np.float32)


def design(meta: np.ndarray, vectors: np.ndarray, mean: np.ndarray, std: np.ndarray) -> np.ndarray:
    """Собирает входы классификатора: нормированные признаки сети, класс рамки (one-hot) и форма рамки."""
    onehot = np.eye(len(protocol.DEFECT_NAMES), dtype=np.float32)[meta[:, 2].astype(int)]
    return np.concatenate([(vectors - mean) / std, onehot, meta[:, 6:10]], 1).astype(np.float32)


def logit(p: np.ndarray) -> np.ndarray:
    """Переводит вероятность в логит с ограничением крайних значений."""
    p = np.clip(p, 1e-6, 1 - 1e-6)
    return np.log(p / (1 - p))


def sigmoid(x: np.ndarray) -> np.ndarray:
    """Логистическая функция."""
    return 1.0 / (1.0 + np.exp(-x))


def train_classifier(x: np.ndarray, y: np.ndarray, kind: str, decay: float, epochs: int = 30, seed: int = 0) -> dict:
    """Обучает классификатор вырезок и возвращает его веса в виде массивов numpy.

    kind lr - логистическая регрессия, mlp - один скрытый слой на 256 нейронов. Классы уравновешены
    весом верных рамок; decay - L2 штраф весов (AdamW).
    """
    import torch
    torch.manual_seed(seed)
    tx, ty = torch.from_numpy(x), torch.from_numpy(y.astype(np.float32))
    if kind == "lr":
        net = torch.nn.Linear(x.shape[1], 1)
    else:
        net = torch.nn.Sequential(torch.nn.Linear(x.shape[1], 256), torch.nn.ReLU(), torch.nn.Dropout(0.2),
                                  torch.nn.Linear(256, 1))
    weight = torch.tensor(float((1 - y).sum() / max(y.sum(), 1)))
    loss_fn = torch.nn.BCEWithLogitsLoss(pos_weight=weight)
    optimizer = torch.optim.AdamW(net.parameters(), lr=1e-3, weight_decay=decay)
    for _ in range(epochs):
        net.train()
        for batch in torch.randperm(len(tx)).split(512):
            optimizer.zero_grad()
            loss_fn(net(tx[batch]).squeeze(1), ty[batch]).backward()
            optimizer.step()
    layers = [m for m in (net if kind == "mlp" else [net]) if isinstance(m, torch.nn.Linear)]
    params = {"kind": kind}
    for index, layer in enumerate(layers):
        params[f"w{index}"] = layer.weight.detach().numpy().T.copy()
        params[f"b{index}"] = layer.bias.detach().numpy().copy()
    return params


def classifier_logit(params: dict, x: np.ndarray) -> np.ndarray:
    """Возвращает логит классификатора вырезок для входов x (вывод на numpy, без torch)."""
    if params["kind"] == "lr":
        return (x @ params["w0"] + params["b0"])[:, 0]
    hidden = np.maximum(x @ params["w0"] + params["b0"], 0)
    return (hidden @ params["w1"] + params["b1"])[:, 0]


def fit_fusion(det: np.ndarray, verdict: np.ndarray, y: np.ndarray, steps: int = 500) -> np.ndarray:
    """Подбирает калибровку a * logit(уверенность детектора) + b * логит классификатора + c по меткам y."""
    import torch
    x = torch.from_numpy(np.stack([logit(det), verdict], 1).astype(np.float32))
    ty = torch.from_numpy(y.astype(np.float32))
    weights = torch.zeros(3, requires_grad=True)
    optimizer = torch.optim.LBFGS([weights], max_iter=steps)

    def closure():
        """Шаг LBFGS: логистическая потеря калибровки."""
        optimizer.zero_grad()
        loss = torch.nn.functional.binary_cross_entropy_with_logits(x @ weights[:2] + weights[2], ty)
        loss.backward()
        return loss

    optimizer.step(closure)
    return weights.detach().numpy().astype(np.float64)


def fused_score(det: np.ndarray, verdict: np.ndarray, fusion: np.ndarray) -> np.ndarray:
    """Итоговая уверенность рамки после второго этапа."""
    return sigmoid(fusion[0] * logit(det) + fusion[1] * verdict + fusion[2])


def overlap(a: tuple, b: tuple) -> float:
    """Доля пересечения двух рамок от площади меньшей из них."""
    width = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    height = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    smaller = min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))
    return width * height / smaller if smaller > 0 else 0.0


def presence_labels(predicted: list[tuple], truth: list[tuple], high: float = 0.3, low: float = 0.1) -> list[int]:
    """Отмечает для каждой рамки, лежит ли она на настоящем дефекте своего класса.

    1 - рамка верна по cv/protocol.py или перекрывает размеченную рамку того же класса не меньше чем
    на долю high (неточная граница, дробление пятна); 0 - перекрытие с рамками своего класса меньше
    low (фон, другой предмет, чистый снимок); -1 - промежуточный случай, в обучении не участвует.
    """
    exact = box_labels(predicted, truth)
    labels = []
    for (name, box, _), ok in zip(predicted, exact):
        same = max([overlap(box, t_box) for t_name, t_box in truth if t_name == name], default=0.0)
        labels.append(1 if ok or same >= high else (0 if same < low else -1))
    return labels


def meta_presence(records: list[dict], meta: np.ndarray) -> np.ndarray:
    """Возвращает метки presence_labels для строк meta; размеченные рамки (source 1) получают 1."""
    cache, out = {}, np.ones(len(meta), np.int8)
    for row_index, row in enumerate(meta):
        if row[5] != 0:
            continue
        image = int(row[0])
        if image not in cache:
            cache[image] = presence_labels(records[image]["predicted"], records[image]["truth"])
        out[row_index] = cache[image][int(row[1])]
    return out


def rescore(records: list[dict], meta: np.ndarray, scores: np.ndarray, keep: np.ndarray | None = None) -> list[dict]:
    """Возвращает копии записей, где рамки детектора заменены рамками-кандидатами с новой уверенностью.

    Рамки с уверенностью детектора ниже GATE (их нет в meta) отбрасываются; при заданной маске keep
    отбрасываются и рамки, для которых она ложна.
    """
    out = [{**record, "predicted": []} for record in records]
    for index, (row, score) in enumerate(zip(meta, scores)):
        if row[5] != 0 or (keep is not None and not keep[index]):
            continue
        record = records[int(row[0])]
        name, box, _ = record["predicted"][int(row[1])]
        out[int(row[0])]["predicted"].append((name, box, float(score)))
    return out


def gate_only(records: list[dict], gate: float = GATE) -> list[dict]:
    """Возвращает копии записей только с рамками детектора не ниже gate (для честного сравнения mAP50)."""
    return [{**record, "predicted": [row for row in record["predicted"] if row[2] >= gate]} for record in records]


def operating_point(records: list[dict], recall: float, found: float, grid: int = 400) -> float | None:
    """Выбирает наибольший порог, при котором полнота рамок и доля найденных дефектов не ниже заданных."""
    scores = np.array([s for record in records for _, _, s in record["predicted"]])
    if scores.size == 0:
        return None
    levels = tuple(sorted({round(float(v), 4) for v in np.quantile(scores, np.linspace(0, 1, grid))}))
    report = protocol.summarize(records, protocol.DEFECT_CLASSES, levels)
    best = None
    for level in levels:
        row = report[f"conf_{level}"]
        if (row["box_recall"] or 0) >= recall and (row["image_defect_found"] or 0) >= found:
            best = level
    return best


def veto_point(records: list[dict], meta: np.ndarray, prob: np.ndarray, base: dict,
               det_levels: tuple = (0.08, 0.1, 0.12, 0.15), grid: int = 60) -> tuple | None:
    """Подбирает правило запрета: рамка остаётся, если уверенность детектора не ниже det_level и оценка
    классификатора не ниже verdict_level.

    Из пар порогов, при которых полнота рамок и доля найденных дефектов не ниже, а доля ложных тревог
    не выше, чем у детектора в опорной точке base, выбирается пара с наибольшей точностью рамок.
    Возвращает (det_level, verdict_level, показатели) или None.
    """
    det = meta[:, 3]
    pool = prob[(meta[:, 5] == 0) & (det >= min(det_levels))]
    levels = sorted({0.0, *(round(float(v), 4) for v in np.quantile(pool, np.linspace(0, 0.9, grid)))})
    best = None
    for verdict_level in levels:
        kept = rescore(records, meta, det, prob >= verdict_level)
        report = protocol.summarize(kept, protocol.DEFECT_CLASSES, det_levels)
        for det_level in det_levels:
            row = report[f"conf_{det_level}"]
            if ((row["box_recall"] or 0) >= base["box_recall"] and (row["image_defect_found"] or 0) >= base["image_defect_found"]
                    and (row["false_alarm_rate"] or 0) <= (base["false_alarm_rate"] or 0)):
                key = (row["box_precision"] or 0, -verdict_level)
                if best is None or key > best[0]:
                    best = (key, det_level, verdict_level, short(report, det_level))
    return None if best is None else best[1:]


def short(report: dict, level: float) -> dict:
    """Выбирает главные показатели набора на пороге level."""
    row = report[f"conf_{level}"]
    keys = ("box_precision", "box_recall", "image_defect_found", "image_right_class_found", "false_alarm_rate")
    return {"threshold": level, "map50": report["map50"], **{key: row[key] for key in keys},
            "classes": {name: [v["tp"], v["fp"], v["fn"]] for name, v in row["classes"].items()}}


def pipeline_records(records: list[dict], meta: np.ndarray, verdict: np.ndarray, model: dict) -> tuple[list[dict], float]:
    """Применяет второй этап к записям набора и возвращает новые записи и порог, на котором их считать.

    Правило fusion заменяет уверенность рамки откалиброванной смесью; правило veto сохраняет
    уверенность детектора и убирает рамки с оценкой классификатора ниже verdict_level.
    """
    if model["rule"] == "veto":
        return rescore(records, meta, meta[:, 3], sigmoid(verdict) >= model["verdict_level"]), model["threshold"]
    return rescore(records, meta, fused_score(meta[:, 3], verdict, model["fusion"])), model["threshold"]


def score_set(name: str, model: dict) -> tuple[list[dict], np.ndarray, np.ndarray]:
    """Возвращает записи набора, meta рамок-кандидатов и логит классификатора для каждой строки meta."""
    meta, vectors = load_features(name)
    return load_records(name), meta, classifier_logit(model["params"], design(meta, vectors, model["mean"], model["std"]))


def fit(base_level: float = 0.15) -> dict:
    """Обучает варианты классификатора на обучающей части и выбирает вариант, правило и пороги по проверочной.

    Классификатор учится отличать рамки на настоящих дефектах своего класса от рамок на фоне
    (presence_labels). Опорная точка - детектор один при пороге base_level на проверочной части:
    связка должна давать полноту рамок и долю найденных дефектов не ниже, а долю ложных тревог на
    чистых снимках не выше. Среди вариантов и двух правил (fusion, veto) выбирается вариант с
    наибольшей точностью рамок.
    """
    meta, vectors = load_features("train")
    train_y = meta_presence(load_records("train"), meta)
    mean, std = vectors.mean(0), vectors.std(0) + 1e-6
    use = train_y >= 0
    x, y = design(meta, vectors, mean, std)[use], train_y[use].astype(np.float32)
    val_records = load_records("val")
    val_meta, val_vectors = load_features("val")
    val_x = design(val_meta, val_vectors, mean, std)
    val_y = meta_presence(val_records, val_meta)
    base = short(protocol.summarize(gate_only(val_records), protocol.DEFECT_CLASSES, (base_level,)), base_level)
    print(f"детектор один, проверочная, порог {base_level}: R {base['box_recall']}, найден {base['image_defect_found']}, "
          f"ЛТ {base['false_alarm_rate']}, P {base['box_precision']}; обучение {len(y)} вырезок, на дефекте {int(y.sum())}")
    variants = []
    for kind, decay in (("lr", 1e-2), ("lr", 1e-1), ("mlp", 1e-2), ("mlp", 1e-1)):
        started = time.time()
        params = train_classifier(x, y, kind, decay)
        verdict = classifier_logit(params, val_x)
        known = (val_meta[:, 5] == 0) & (val_y >= 0)
        auc = rank_auc(val_y[known], verdict[known])
        fusion = fit_fusion(val_meta[known, 3], verdict[known], val_y[known])
        fused = rescore(val_records, val_meta, fused_score(val_meta[:, 3], verdict, fusion))
        level = operating_point(fused, base["box_recall"], base["image_defect_found"])
        row = short(protocol.summarize(fused, protocol.DEFECT_CLASSES, (level,)), level) if level else None
        variants.append({"kind": kind, "decay": decay, "rule": "fusion", "fusion": fusion.tolist(), "val": row,
                         "val_auc_presence": auc, "params": params})
        veto = veto_point(val_records, val_meta, sigmoid(verdict), base)
        variants.append({"kind": kind, "decay": decay, "rule": "veto", "fusion": fusion.tolist(),
                         "verdict_level": None if veto is None else veto[1], "val": None if veto is None else veto[2],
                         "val_auc_presence": auc, "params": params})
        for item in variants[-2:]:
            print(kind, decay, item["rule"], f"AUC {auc}", "проверочная:",
                  {k: v for k, v in (item["val"] or {}).items() if k != "classes"},
                  f"verdict_level {item.get('verdict_level')}", f"{time.time() - started:.0f} с", flush=True)
    usable = [v for v in variants if v["val"] and (v["val"]["false_alarm_rate"] or 0) <= (base["false_alarm_rate"] or 0)]
    best = max(usable or [v for v in variants if v["val"]],
               key=lambda v: (v["val"]["box_precision"], -v["val"]["false_alarm_rate"]))
    model = {"params": best["params"], "mean": mean, "std": std, "fusion": np.array(best["fusion"]),
             "rule": best["rule"], "threshold": best["val"]["threshold"],
             "verdict_level": best.get("verdict_level") or 0.0, "base_level": base_level}
    save_model(model)
    summary = {"base_val": base, "train_crops": len(y), "train_on_defect": int(y.sum()),
               "train_ambiguous_dropped": int((~use).sum()),
               "variants": [{k: v for k, v in item.items() if k != "params"} for item in variants],
               "chosen": {"kind": best["kind"], "decay": best["decay"], "rule": best["rule"],
                          "threshold": model["threshold"], "verdict_level": model["verdict_level"]}}
    json.dump(summary, open(os.path.join(OUT, "fit.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    return summary


def rank_auc(y: np.ndarray, score: np.ndarray) -> float | None:
    """Площадь под ROC-кривой по рангам (доля пар верная-лишняя рамка, упорядоченных правильно)."""
    positive, negative = int((y > 0).sum()), int((y <= 0).sum())
    if not positive or not negative:
        return None
    from scipy.stats import rankdata
    ranks = rankdata(score)
    return round(float((ranks[y > 0].sum() - positive * (positive + 1) / 2) / (positive * negative)), 3)


def save_model(model: dict) -> None:
    """Сохраняет классификатор, нормировку, правило, калибровку и пороги в runs/verifier/verifier.npz."""
    params = {f"p_{k}": v for k, v in model["params"].items() if k != "kind"}
    np.savez(os.path.join(OUT, "verifier.npz"), kind=model["params"]["kind"], mean=model["mean"], std=model["std"],
             fusion=model["fusion"], rule=model["rule"], threshold=model["threshold"],
             verdict_level=model["verdict_level"], base_level=model["base_level"], **params)


def load_model(path: str | None = None) -> dict:
    """Читает модель второго этапа, сохранённую save_model."""
    data = np.load(path or os.path.join(OUT, "verifier.npz"))
    params = {"kind": str(data["kind"])}
    params.update({k[2:]: data[k] for k in data.files if k.startswith("p_")})
    return {"params": params, "mean": data["mean"], "std": data["std"], "fusion": data["fusion"],
            "rule": str(data["rule"]), "threshold": float(data["threshold"]),
            "verdict_level": float(data["verdict_level"]), "base_level": float(data["base_level"])}


def report(sets: list[str]) -> dict:
    """Считает по cv/protocol.py показатели детектора одного и связки на всех наборах и пишет отчёт."""
    model = load_model()
    base_level = model["base_level"]
    out = {"name": "verifier", "detector": os.path.relpath(DETECTOR, ROOT), "backbone": BACKBONE,
           "classifier": model["params"]["kind"], "rule": model["rule"], "gate": GATE, "iou": 0.5,
           "date": time.strftime("%Y-%m-%d"),
           "operating_point": {"detector_alone": base_level, "pipeline": model["threshold"],
                               "verdict_level": model["verdict_level"] if model["rule"] == "veto" else None,
                               "chosen_on": "val: наибольшая точность рамок при полноте рамок и доле найденных "
                                            "дефектов не ниже и доле ложных тревог не выше, чем у детектора при 0.15"},
           "sets": {}}
    for name in sets:
        records, meta, verdict = score_set(name, model)
        alone = protocol.summarize(gate_only(records), protocol.DEFECT_CLASSES, (base_level, 0.25))
        rescored, level = pipeline_records(records, meta, verdict, model)
        both = protocol.summarize(rescored, protocol.DEFECT_CLASSES, (level,))
        entry = {"note": protocol.SET_NOTES.get(name, ""), "detector": short(alone, base_level),
                 "detector_0.25": short(alone, 0.25), "pipeline": short(both, level),
                 "crops_per_image": round(float((meta[:, 5] == 0).sum()) / max(len(records), 1), 2)}
        detector_row, pipeline_row = entry["detector"], entry["pipeline"]
        entry["recall_kept"] = all((pipeline_row[key] or 0) >= (detector_row[key] or 0)
                                   for key in ("box_recall", "image_defect_found"))
        if name == "web":
            entry["pipeline_groups"] = both[f"conf_{level}"]["groups"]
            entry["detector_groups"] = alone[f"conf_{base_level}"]["groups"]
        out["sets"][name] = entry
        for key in ("detector", "detector_0.25", "pipeline"):
            row = entry[key]
            print(f"{name:15s} {key:14s} t={row['threshold']:.3f} mAP50 {row['map50']} P {row['box_precision']} "
                  f"R {row['box_recall']} найден {row['image_defect_found']} класс {row['image_right_class_found']} "
                  f"ЛТ {row['false_alarm_rate']}")
    out["val_tradeoff"] = tradeoff(model)
    path = os.path.join(ROOT, "runs", "reports", "verifier.json")
    json.dump(out, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("отчёт:", path)
    return out


def tradeoff(model: dict, det_levels: tuple = (0.08, 0.1, 0.12, 0.15),
             shares: tuple = (0.0, 0.05, 0.1, 0.2, 0.3, 0.5)) -> list[dict]:
    """Сравнивает на проверочной части детектор один при разных порогах и запрет по классификатору.

    Для каждой доли shares убирается такая доля рамок-кандидатов с наименьшей оценкой классификатора
    (доля 0 - детектор один), затем показатели считаются при порогах детектора det_levels. Если
    при равной точности рамок связка не даёт большей полноты, чем простой сдвиг порога детектора,
    второй этап пользы не приносит.
    """
    records, meta, verdict = score_set("val", model)
    prob = sigmoid(verdict)
    rows = []
    for share in shares:
        level = float(np.quantile(prob[meta[:, 5] == 0], share)) if share else 0.0
        report_ = protocol.summarize(rescore(records, meta, meta[:, 3], prob >= level), protocol.DEFECT_CLASSES, det_levels)
        for det_level in det_levels:
            row = report_[f"conf_{det_level}"]
            rows.append({"removed_share": share, "verdict_level": round(level, 4), "det_level": det_level,
                         **{key: row[key] for key in ("box_precision", "box_recall", "image_defect_found", "false_alarm_rate")}})
    return rows


def latency(runs: int = 50) -> dict:
    """Измеряет на процессоре задержку признаков одной вырезки: torch и ONNX Runtime (экспорт в runs/verifier)."""
    import onnxruntime
    import torch
    torch.set_num_threads(os.cpu_count() or 4)
    backbone = Backbone("cpu")
    crop = np.random.default_rng(0).integers(0, 255, (180, 240, 3), dtype=np.uint8)
    result = {}
    for size in (1, 4):
        crops = [crop] * size
        backbone(crops)
        times = []
        for _ in range(runs):
            started = time.perf_counter()
            backbone(crops)
            times.append((time.perf_counter() - started) * 1000)
        result[f"torch_cpu_batch{size}_ms"] = round(float(np.median(times)), 1)
    path = os.path.join(OUT, "dinov2s.onnx")
    if not os.path.exists(path):
        torch.onnx.export(backbone.model, (torch.zeros(1, 3, CROP_SIZE, CROP_SIZE),), path,
                          input_names=["pixel_values"], output_names=["tokens"],
                          dynamic_axes={"pixel_values": {0: "n"}, "tokens": {0: "n"}}, opset_version=17, dynamo=False)
    session = onnxruntime.InferenceSession(path, providers=["CPUExecutionProvider"])
    for size in (1, 4):
        batch = np.stack([backbone.prepare(crop)] * size)
        session.run(None, {"pixel_values": batch})
        times = []
        for _ in range(runs):
            started = time.perf_counter()
            session.run(None, {"pixel_values": batch})
            times.append((time.perf_counter() - started) * 1000)
        result[f"onnx_cpu_batch{size}_ms"] = round(float(np.median(times)), 1)
    model = load_model()
    x = np.zeros((1, model["mean"].size + len(protocol.DEFECT_NAMES) + 4), np.float32)
    started = time.perf_counter()
    for _ in range(1000):
        classifier_logit(model["params"], x)
    result["classifier_ms"] = round((time.perf_counter() - started), 3)
    result["onnx_mb"] = round(os.path.getsize(path) / 1e6, 1)
    result["note"] = "медиана, процессор M4, машина одновременно загружена другими задачами"
    json.dump(result, open(os.path.join(ROOT, "runs", "reports", "latency_verifier.json"), "w"), ensure_ascii=False, indent=1)
    print(result)
    return result


def main() -> None:
    """Разбирает аргументы командной строки и запускает нужный шаг."""
    parser = argparse.ArgumentParser()
    parser.add_argument("step", choices=("detect", "features", "fit", "report", "latency"))
    parser.add_argument("--sets", default=None)
    args = parser.parse_args()
    if args.step == "detect":
        detect(args.sets.split(",") if args.sets else list(ALL_SETS))
    elif args.step == "features":
        features(args.sets.split(",") if args.sets else list(ALL_SETS))
    elif args.step == "fit":
        fit()
    elif args.step == "report":
        report(args.sets.split(",") if args.sets else ["val", *TEST_SETS])
    elif args.step == "latency":
        latency()


if __name__ == "__main__":
    main()
