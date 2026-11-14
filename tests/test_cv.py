"""Проверки чтения манометра и разбора шильдика без обращения к моделям."""
import json
import math
import os
import sys

import cv2
import numpy as np
import pytest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "cv"))
sys.path.insert(0, os.path.join(ROOT, "blender"))

from build_defects import Writer, mask_to_boxes
from compare import match_boxes
from draw_detections import annotate, merge_same_class, save_small
from gauge import read_gauge
from nameplate import haystack_of, match_equipment, parse_fields, same_model
from summary import experiment_row, gauges_summary, latency_row, plates_summary
from train import parse_args, train_options


def dial_with_needle(tmp_path, value: float, tilt: float = 1.0) -> np.ndarray:
    """Рисует циферблат со стрелкой на заданном значении и при необходимости сжимает его, как при съёмке под углом."""
    import make_textures
    path = str(tmp_path / "dial.png")
    make_textures.gauge_dial(path, size=512)
    dial = cv2.imread(path)
    angle = math.radians((value / 10.0) * 270.0 - 135.0)
    center = 256
    tip = (int(center + 170 * math.sin(angle)), int(center - 170 * math.cos(angle)))
    cv2.line(dial, (center, center), tip, (10, 10, 10), 9)
    canvas = np.full((640, 640, 3), 90, np.uint8)
    mask = np.zeros((512, 512), np.uint8)
    cv2.circle(mask, (center, center), 245, 255, -1)
    canvas[64:576, 64:576][mask > 0] = dial[mask > 0]
    if tilt < 1.0:
        canvas = cv2.resize(canvas, (int(640 * tilt), 640))
    return canvas


@pytest.mark.parametrize("value", [0.5, 2.0, 3.7, 5.0, 6.4, 8.1, 9.5])
def test_gauge_front_view(tmp_path, value):
    """Показание на снимке анфас читается с ошибкой не больше 2% шкалы."""
    answer = read_gauge(dial_with_needle(tmp_path, value))
    assert answer["ok"]
    assert abs(answer["value"] - value) <= 0.2


@pytest.mark.parametrize("value", [1.5, 5.0, 8.5])
def test_gauge_tilted_view(tmp_path, value):
    """Циферблат, сжатый до 70% ширины, выпрямляется, и ошибка остаётся в пределах 5% шкалы."""
    answer = read_gauge(dial_with_needle(tmp_path, value, tilt=0.7))
    assert answer["ok"]
    assert abs(answer["value"] - value) <= 0.5


def test_gauge_without_dial():
    """Кадр без циферблата не даёт выдуманного показания."""
    answer = read_gauge(np.full((200, 200, 3), 40, np.uint8))
    assert answer["value"] is None and not answer["ok"]


def cards() -> list[dict]:
    """Загружает карточки оборудования из файла данных."""
    return json.load(open(os.path.join(ROOT, "data", "equipment.json"), encoding="utf-8"))["equipment"]


def test_nameplate_exact_serial():
    """Серийный номер и модель выделяются из строк шильдика, карточка находится точно."""
    lines = [{"text": "KST DEMO PUMPS"}, {"text": "Type IL 65/160-5,5/2"}, {"text": "No. 2786107-0142"}]
    fields = parse_fields(lines)
    assert fields["serial"] == "2786107-0142"
    assert fields["model"] == "IL 65/160-5,5/2"
    assert match_equipment(fields, cards())["card"]["id"] == "N-101"


def test_nameplate_fuzzy_serial():
    """Одна неверно распознанная цифра не мешает найти оборудование."""
    fields = parse_fields([{"text": "No. 2786107-0148"}])
    match = match_equipment(fields, cards())
    assert match["card"]["id"] == "N-101" and match["by"] == "serial_fuzzy"


def test_nameplate_unknown():
    """Незнакомый номер не подставляет чужую карточку."""
    fields = parse_fields([{"text": "No. 9912345-7777"}])
    assert match_equipment(fields, cards()) is None


def test_nameplate_other_serial_format():
    """Номер винтового насоса с одной цифрой после дефиса находит свой агрегат, а не соседний такой же модели."""
    fields = parse_fields([{"text": "AMS"}, {"text": "PCP60S12/3 01 Ex B1 HNBR DTS"}, {"text": "S/N 21031004-2"}])
    match = match_equipment(fields, cards())
    assert match["card"]["id"] == "AMS-2" and match["by"] == "serial"


def test_nameplate_letters_instead_of_digits():
    """Буквы O и I, прочитанные вместо нуля и единицы, не мешают точному совпадению номера."""
    match = match_equipment(parse_fields([{"text": "S/N 2IO3IOO4-1"}]), cards())
    assert match["card"]["id"] == "AMS-1" and match["by"] == "serial"


def test_nameplate_same_model_needs_choice():
    """Когда номер не прочитан, а модель в реестре у двух агрегатов, выбор остаётся за инженером."""
    fields = parse_fields([{"text": "AMS  PCP60S12/3"}])
    assert match_equipment(fields, cards()) is None
    assert sorted(card["id"] for _, card in same_model(haystack_of(fields), cards())) == ["AMS-1", "AMS-2"]


def test_nameplate_ambiguous_digit():
    """Номер с нечитаемой последней цифрой одинаково похож на оба агрегата и не приписывается ни одному."""
    assert match_equipment(parse_fields([{"text": "S/N 21031004-7"}]), cards()) is None


def test_nameplate_unique_model():
    """Единственная в реестре модель находит карточку и без серийного номера."""
    match = match_equipment(parse_fields([{"text": "CronoLine-IL 65/160-5.5/2"}]), cards())
    assert match["card"]["id"] == "N-101" and match["by"] == "model"



def test_mask_to_boxes_splits_regions():
    """Две отдельные области маски дают две рамки, а мелкая точка отбрасывается."""
    mask = np.zeros((400, 800), np.uint8)
    mask[40:160, 80:240] = 169
    mask[240:360, 560:720] = 169
    mask[10:13, 780:783] = 169
    boxes = sorted(mask_to_boxes(mask))
    assert len(boxes) == 2
    assert boxes[0] == pytest.approx((0.1, 0.1, 0.3, 0.4), abs=0.02)
    assert boxes[1] == pytest.approx((0.7, 0.6, 0.9, 0.9), abs=0.02)


def test_mask_to_boxes_keeps_tiny_defect():
    """Если на маске есть только мелкая область, она не теряется, а пустая маска рамок не даёт."""
    mask = np.zeros((400, 400), np.uint8)
    assert mask_to_boxes(mask) == []
    mask[200:206, 100:106] = 255
    boxes = mask_to_boxes(mask)
    assert len(boxes) == 1 and 0.2 <= boxes[0][0] <= 0.26 and 0.48 <= boxes[0][1] <= 0.52


def test_writer_saves_labels_and_screen_copy(tmp_path):
    """Кадр и его экранная копия сохраняются с рамками в долях кадра, счётчики ведутся по источникам."""
    import random
    random.seed(3)
    np.random.seed(3)
    writer = Writer(str(tmp_path), ["corrosion", "leak"])
    image = np.full((300, 400, 3), 120, np.uint8)
    writer.add("train", "a", image, [("leak", 0.25, 0.25, 0.75, 0.75)], "customer")
    assert open(tmp_path / "labels" / "train" / "a.txt").read().split() == ["1", "0.50000", "0.50000", "0.50000", "0.50000"]
    writer.add_screen("train", "a_s0", image, [("leak", 0.25, 0.25, 0.75, 0.75)], [], "customer_screen")
    rows = [line.split() for line in open(tmp_path / "labels" / "train" / "a_s0.txt")]
    assert len(rows) == 1 and rows[0][0] == "1"
    assert all(0.0 <= float(value) <= 1.0 for value in rows[0][1:])
    assert cv2.imread(str(tmp_path / "images" / "train" / "a_s0.jpg")).shape == (640, 640, 3)
    assert writer.counts["train/customer"] == {"images": 1, "boxes": {"leak": 1}}


def test_match_boxes_counts():
    """Верная рамка, лишняя рамка и пропущенный дефект попадают в разные счётчики."""
    truth = [("corrosion", (0, 0, 100, 100)), ("leak", (200, 200, 300, 300))]
    predicted = [("corrosion", (5, 5, 100, 100), 0.9), ("corrosion", (400, 400, 450, 450), 0.6),
                 ("damage", (200, 200, 300, 300), 0.5)]
    stats = {}
    match_boxes(predicted, truth, stats)
    assert stats["corrosion"] == {"tp": 1, "fp": 1, "fn": 0}
    assert stats["leak"] == {"tp": 0, "fp": 0, "fn": 1}
    assert stats["damage"] == {"tp": 0, "fp": 1, "fn": 0}


def test_train_options_for_short_run():
    """В коротком запуске эпохи без мозаики и разогрев не превышают длину обучения."""
    options = train_options(parse_args(["set/data.yaml", "4", "LibreYOLO9s.pt", "cpu", "--name", "probe",
                                        "--plain-epochs", "15", "--warmup", "9"]))
    assert options["epochs"] == 4 and options["no_aug_epochs"] == 3 and options["warmup_epochs"] == 4
    assert options["name"] == "probe" and options["device"] == "cpu" and options["imgsz"] == 640
    defaults = train_options(parse_args(["set/data.yaml"]))
    assert "no_aug_epochs" not in defaults and "lr0" not in defaults and defaults["epochs"] == 30
    extra = train_options(parse_args(["set/data.yaml", "--set", "multi_scale=false", "--set", "eval_interval=2"]))
    assert extra["multi_scale"] is False and extra["eval_interval"] == 2


def test_models_manifest_matches_files():
    """Каждая модель из models.json существует, а её классы совпадают с записанными в файле ONNX."""
    path = os.path.join(ROOT, "models", "models.json")
    if not os.path.exists(path):
        pytest.skip("модели ещё не выгружены")
    import onnxruntime
    entries = json.load(open(path, encoding="utf-8"))
    assert isinstance(entries, list) and entries
    for entry in entries:
        file = os.path.join(ROOT, "models", entry["file"])
        assert os.path.exists(file)
        meta = onnxruntime.InferenceSession(file, providers=["CPUExecutionProvider"]).get_modelmeta().custom_metadata_map
        names = json.loads(meta["names"])
        assert entry["classes"] == [names[str(index)] for index in range(len(names))]
        assert entry["imgsz"] == int(meta["imgsz"]) and entry["role"] in ("stand", "defects")


def test_annotated_picture_fits_size_limit(tmp_path):
    """Снимок с рамками уменьшается до заданной стороны, а файл укладывается в 200 КБ."""
    frame = np.random.default_rng(1).integers(0, 255, (1200, 1800, 3), dtype=np.uint8)
    picture = annotate(frame, [("corrosion", [100, 100, 900, 700], 0.81), ("motor", [50, 60, 400, 500], 0.4)], side=900)
    assert picture.shape[:2] == (600, 900)
    assert (picture != cv2.resize(frame, (900, 600), interpolation=cv2.INTER_AREA)).any()
    path = str(tmp_path / "shot.jpg")
    assert save_small(picture, path) == os.path.getsize(path)
    assert cv2.imread(path).shape == picture.shape


def test_latency_report_for_delivered_model():
    """Замер времени вывода возвращает положительные числа для модели из папки models."""
    path = os.path.join(ROOT, "models", "detector.onnx")
    if not os.path.exists(path):
        pytest.skip("модель ещё не выгружена")
    from latency import measure
    row = measure(path, "CPUExecutionProvider", repeats=2)
    assert row["provider"] == "CPUExecutionProvider" and 0 < row["median_ms"] <= row["p90_ms"]
    assert row["input"]["images"] == [1, 3, 640, 640]


def test_summary_of_plates_and_gauges():
    """Сводка чтения шильдика и манометра считает кадры по ширине узла и не учитывает непрочитанные показания."""
    plates = [{"px": 30, "located": True, "serial_ok": False, "card_ok": False},
              {"px": 80, "located": True, "serial_ok": False, "card_ok": True},
              {"px": 140, "located": True, "serial_ok": True, "card_ok": True},
              {"px": 150, "located": False, "serial_ok": False, "card_ok": False}]
    summary = plates_summary(plates)
    assert summary["frames"] == 4 and summary["located"] == 3 and summary["serial_exact"] == 1 and summary["card_found"] == 2
    assert summary["by_width"]["100px+"] == {"frames": 2, "located": 1, "serial_exact": 1, "card_found": 1}
    gauges = [{"px": 50, "located": True, "ok": True, "value": 5.2, "truth": 5.0},
              {"px": 90, "located": True, "ok": True, "value": 9.0, "truth": 2.0},
              {"px": 90, "located": True, "ok": False, "value": 1.0, "truth": 7.0},
              {"px": 20, "located": False, "ok": False, "value": None, "truth": 3.0}]
    summary = gauges_summary(gauges)
    assert summary["frames"] == 4 and summary["located"] == 3 and summary["read"] == 2
    assert summary["within_5pct_of_scale"] == 1 and summary["error_over_10pct_of_scale"] == 1
    assert summary["by_width"]["0-40px"]["read"] == 0 and summary["by_width"]["0-40px"]["median_error_bar"] is None


def test_summary_row_without_reports(tmp_path):
    """Опыт без отчётов попадает в сводку с пустыми значениями, а не с выдуманными числами."""
    spec = {"name": "probe", "family": "LibreYOLO9t", "weights_licence": "MIT", "start": "LibreYOLO9t.pt",
            "data": "нет", "run": "probe", "compare": "cmp_probe", "latency": "latency_probe", "note": ""}
    row = experiment_row(spec, str(tmp_path), str(tmp_path))
    assert row["measured"] is False and row["train_minutes"] is None and row["latency_640"] is None
    assert row["conf_0.25"] == {"holdout": None, "holdout_screen": None, "web_testset": None}


def test_summary_row_reads_reports(tmp_path):
    """Строка сводки берёт длительность обучения, показатели и время вывода из файлов отчётов."""
    os.makedirs(tmp_path / "probe")
    json.dump({"epochs": 3, "train_minutes": 1.5}, open(tmp_path / "probe" / "timing.json", "w"))
    level = {"box_precision": 0.5, "box_recall": 0.25, "image_defect_found": 0.75, "image_right_class_found": 0.5,
             "classes": {"leak": {"tp": 1, "fp": 1, "fn": 3}}}
    web = {"defective_images": 4, "image_recall_any_defect": 0.5, "image_recall_right_class": 0.25, "clean_images": 2,
           "false_alarm_rate": 0.5, "groups": {"leak": {"images": 4, "any_defect": 2, "right_class": 1}}}
    json.dump({"holdout": {"images": 8, "conf_0.25": level, "conf_0.5": level}, "holdout_screen": None,
               "web_testset": {"images": 6, "conf_0.25": web, "conf_0.5": web}}, open(tmp_path / "cmp_probe.json", "w"))
    json.dump({"model": "probe.onnx", "size_mb": 8.4, "runs": [
        {"provider": "CPUExecutionProvider", "median_ms": 30.0, "p90_ms": 33.0, "input": {"images": [1, 3, 640, 640]}},
        {"provider": "CoreMLExecutionProvider", "error": "не поддерживается"}]}, open(tmp_path / "latency_probe.json", "w"))
    spec = {"name": "probe", "family": "LibreYOLO9t", "weights_licence": "MIT", "start": "LibreYOLO9t.pt",
            "data": "нет", "run": "probe", "compare": "cmp_probe", "latency": "latency_probe", "note": ""}
    row = experiment_row(spec, str(tmp_path), str(tmp_path))
    assert row["measured"] and row["epochs"] == 3 and row["train_minutes"] == 1.5
    assert row["conf_0.25"]["holdout"]["box_recall"] == 0.25 and row["conf_0.25"]["holdout_screen"] is None
    assert row["conf_0.5"]["web_testset"]["groups"] == {"leak": [2, 1, 4]}
    assert row["latency_640"] == {"model": "probe.onnx", "size_mb": 8.4, "cpu_ms": 30.0, "input": [1, 3, 640, 640],
                                  "coreml_ms": None, "coreml_ms_error": "не поддерживается"}
    assert latency_row(None) is None


def test_merge_same_class_keeps_best_box():
    """Две модели дали одну и ту же коррозию: остаётся уверенная рамка, другой класс и дальняя рамка не трогаются."""
    rows = [("corrosion", [100, 100, 300, 300], 0.4), ("corrosion", [110, 105, 310, 300], 0.7),
            ("leak", [100, 100, 300, 300], 0.3), ("corrosion", [500, 500, 600, 600], 0.3)]
    kept = merge_same_class(rows)
    assert [(name, score) for name, _, score in kept] == [("corrosion", 0.7), ("leak", 0.3), ("corrosion", 0.3)]
    assert merge_same_class([]) == []


def test_quantize_keeps_metadata_and_output(tmp_path):
    """Сжатие весов до int8 сохраняет сведения о классах и почти не меняет ответ сети."""
    import onnx
    import onnxruntime
    from onnx import TensorProto, helper, numpy_helper
    from quantize import quantize
    weights = np.random.default_rng(3).normal(size=(64, 32)).astype(np.float32)
    graph = helper.make_graph([helper.make_node("MatMul", ["x", "w"], ["y"])], "probe",
                              [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 64])],
                              [helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, 32])],
                              [numpy_helper.from_array(weights, "w")])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)])
    model.metadata_props.add(key="names", value='{"0": "corrosion"}')
    model.metadata_props.add(key="imgsz", value="384")
    source, target = str(tmp_path / "f32.onnx"), str(tmp_path / "int8.onnx")
    onnx.save(model, source)
    assert quantize(source, target) == os.path.getsize(target)
    meta = onnx.load(target).metadata_props
    assert {item.key: item.value for item in meta}["imgsz"] == "384"
    feed = {"x": np.random.default_rng(4).normal(size=(1, 64)).astype(np.float32)}
    exact = onnxruntime.InferenceSession(source, providers=["CPUExecutionProvider"]).run(None, feed)[0]
    packed = onnxruntime.InferenceSession(target, providers=["CPUExecutionProvider"]).run(None, feed)[0]
    assert np.abs(exact - packed).max() < 0.05 * np.abs(exact).max()


def test_protocol_match_skips_unlabelled_classes():
    """Рамка класса, не размеченного на снимке, не считается ни верной, ни лишней."""
    from protocol import match
    truth = [("motor", (0, 0, 100, 100))]
    predicted = [("motor", (2, 2, 100, 100), 0.9), ("gauge", (300, 300, 350, 350), 0.8), ("motor", (400, 0, 500, 90), 0.4)]
    assert match(predicted, truth, {"motor"}) == [("motor", 0.9, True), ("motor", 0.4, False)]
    assert len(match(predicted, truth)) == 3


def test_protocol_average_precision():
    """AP50 равна 1 при идеальном порядке, падает при лишней рамке впереди и пуста без разметки."""
    from protocol import average_precision
    assert average_precision([(0.9, True), (0.8, True)], 2) == 1.0
    assert average_precision([(0.9, False), (0.8, True)], 1) == 0.5
    assert average_precision([(0.9, True)], 2) == 0.5
    assert average_precision([], 3) == 0.0
    assert average_precision([(0.9, False)], 0) is None


def test_protocol_summary_levels_and_images():
    """Сводка считает рамки, найденные дефекты и ложные тревоги отдельно для каждого порога."""
    from protocol import summarize
    box = (10, 10, 110, 110)
    records = [
        {"truth": [("corrosion", box)], "predicted": [("corrosion", box, 0.3)], "labelled": None, "group": None},
        {"truth": [("leak", box)], "predicted": [("corrosion", box, 0.6)], "labelled": None, "group": None},
        {"truth": [], "predicted": [("damage", box, 0.2)], "labelled": None, "group": None},
        {"truth": [], "predicted": [("leak", box, 0.9)], "labelled": set(), "group": "leak"},
        {"truth": [], "predicted": [], "labelled": set(), "group": "gauge"},
    ]
    report = summarize(records, ("corrosion", "leak", "terminal_box_burnt", "damage"), (0.15, 0.25, 0.5))
    low, high = report["conf_0.15"], report["conf_0.5"]
    assert low["classes"]["corrosion"] == {"tp": 1, "fp": 1, "fn": 0, "precision": 0.5, "recall": 1.0}
    assert low["classes"]["leak"]["fn"] == 1 and low["classes"]["damage"]["fp"] == 1
    assert low["defective_images"] == 3 and low["image_defect_found"] == 1.0
    assert low["image_right_class_found"] == round(2 / 3, 3)
    assert low["clean_images"] == 2 and low["false_alarm_rate"] == 0.5
    assert report["conf_0.25"]["false_alarm_rate"] == 0.0
    assert high["classes"]["corrosion"] == {"tp": 0, "fp": 1, "fn": 1, "precision": 0.0, "recall": 0.0}
    assert high["image_defect_found"] == round(2 / 3, 3) and high["groups"]["leak"]["right_class"] == 1
    assert report["ap50"]["corrosion"] == 0.5 and report["ap50"]["leak"] == 0.0 and report["boxes"] == {"corrosion": 1, "leak": 1}


def test_protocol_run_writes_parts_report(tmp_path, monkeypatch):
    """Прогон по набору YOLO с поддельной моделью даёт отчёт с неполной разметкой по классам."""
    import protocol

    class Boxes:
        """Рамки в том виде, в каком их отдаёт LibreYOLO."""

        def __init__(self):
            """Одна рамка двигателя и одна рамка манометра."""
            self.xyxy, self.cls, self.conf = [(0, 0, 50, 50), (60, 60, 90, 90)], [0, 8], [0.7, 0.3]

    class Model:
        """Поддельная модель с фиксированным ответом."""

        def __call__(self, frame, conf):
            """Возвращает одинаковые рамки для любого кадра."""
            result = type("Result", (), {})()
            result.boxes, result.names = Boxes(), dict(enumerate(protocol.PART_CLASSES))
            return result

    folder = tmp_path / "parts"
    (folder / "images" / "test").mkdir(parents=True)
    (folder / "labels" / "test").mkdir(parents=True)
    cv2.imwrite(str(folder / "images" / "test" / "a.jpg"), np.full((100, 100, 3), 90, np.uint8))
    (folder / "labels" / "test" / "a.txt").write_text("0 0.25 0.25 0.5 0.5\n")
    (folder / "data.yaml").write_text("names:\n" + "".join(f"  {i}: {n}\n" for i, n in enumerate(protocol.PART_CLASSES)))
    monkeypatch.setitem(protocol.SET_PATHS, "parts", (str(folder), "test"))
    monkeypatch.setitem(protocol.SET_PATHS, "val", (str(tmp_path / "absent"), "val"))
    monkeypatch.setattr(protocol, "parts_labelled", lambda: {"images/test/a.jpg": {"motor"}})
    report = protocol.run([Model()], ["parts", "val"], "parts")
    row = report["parts"]["conf_0.25"]
    assert row["classes"]["motor"]["tp"] == 1 and "gauge" not in row["classes"]
    assert report["parts"]["ap50"]["motor"] == 1.0
    assert report["parts"]["conf_0.5"]["classes"]["motor"]["recall"] == 1.0
    assert "missing" in report["val"]


def test_delivered_applies_server_thresholds_and_merge():
    """Проверка поставки применяет пороги из models.json и объединяет рамки моделей так же, как сервер."""
    from delivered import combine, served
    entries = [{"file": "stand.onnx", "conf_check": 0.25, "thresholds": {"leak": 0.5}}, {"file": "defects.onnx", "conf_check": 0.15}]
    stand = [("leak", (0, 0, 100, 100), 0.45), ("motor", (0, 0, 300, 300), 0.3), ("corrosion", (200, 200, 260, 260), 0.2)]
    defects = [("leak", (2, 2, 100, 100), 0.4), ("leak", (0, 0, 99, 99), 0.35), ("corrosion", (500, 0, 560, 60), 0.14)]
    assert served([stand, defects], entries) == [("leak", (2, 2, 100, 100), 0.4), ("motor", (0, 0, 300, 300), 0.3)]
    record = {"file": "a.jpg", "truth": [("leak", (0, 0, 100, 100))], "labelled": None, "group": None}
    rows = combine([[{**record, "predicted": stand}], [{**record, "predicted": defects}]], entries)
    assert rows[0]["truth"] == record["truth"] and [name for name, _, _ in rows[0]["predicted"]] == ["leak", "motor"]


def test_summary_reads_protocol_and_roundtrip_reports(tmp_path):
    """Сводка берёт из отчёта протокола показатели наборов и уровень сервера, из замера круга - времена без рамок."""
    from summary import protocol_row, roundtrip_summary
    level = {"box_precision": 0.6, "box_recall": 0.5, "image_defect_found": 0.75, "image_right_class_found": 0.6,
             "false_alarm_rate": None, "classes": {"leak": {"tp": 1, "fp": 0, "fn": 1}}}
    report = {"sets": {"holdout": {"images": 8, "map50": 0.4, "ap50": {"leak": 0.4}, "conf_0.15": level, "conf_served": level},
                       "val": {"missing": "нет"}}}
    (tmp_path / "rep.json").write_text(json.dumps(report), encoding="utf-8")
    row = protocol_row({"name": "x", "report": "rep", "latency": None, "note": ""}, str(tmp_path))
    assert row["measured"] and list(row["sets"]) == ["holdout"]
    assert row["sets"]["holdout"]["conf_served"]["classes"] == {"leak": [1, 0, 1]} and "conf_0.25" not in row["sets"]["holdout"]
    assert protocol_row({"name": "y", "report": "absent", "latency": None, "note": ""}, str(tmp_path))["measured"] is False
    trip = {"health": {"ready": True}, "results": [{"set": "holdout", "trip_median_ms": 170.0, "boxes": {"a.jpg": []}}]}
    (tmp_path / "roundtrip_ws_detect.json").write_text(json.dumps(trip), encoding="utf-8")
    assert roundtrip_summary(str(tmp_path))["results"] == [{"set": "holdout", "trip_median_ms": 170.0}]


def test_truth_boxes_read_next_to_dataset_image(tmp_path):
    """Разметка YOLO рядом со снимком набора читается в пиксели и рисуется; у снимка вне набора её нет."""
    from draw_detections import truth_boxes
    (tmp_path / "images" / "holdout").mkdir(parents=True)
    (tmp_path / "labels" / "holdout").mkdir(parents=True)
    (tmp_path / "data.yaml").write_text("names:\n  0: corrosion\n  1: leak\n", encoding="utf-8")
    (tmp_path / "labels" / "holdout" / "h.txt").write_text("1 0.5 0.5 0.5 0.5\n")
    frame = np.full((200, 400, 3), 90, np.uint8)
    path = str(tmp_path / "images" / "holdout" / "h.jpg")
    assert truth_boxes(path, frame) == [("leak", [100, 50, 300, 150])]
    assert truth_boxes(str(tmp_path / "loose.jpg"), frame) == []
    picture = annotate(frame, [], side=400, truth=truth_boxes(path, frame))
    assert (picture[50, 100:300] == 255).all()
