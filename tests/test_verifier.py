"""Проверки второго этапа (классификатора вырезок) без загрузки сетей и тестовых наборов."""
import os
import sys

import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "cv"))

import verifier


def test_box_labels_follow_protocol_matching():
    """Верна только рамка нужного класса с IoU не меньше 0.5; повтор той же цели считается лишним."""
    truth = [("corrosion", (0, 0, 10, 10))]
    predicted = [("corrosion", (0, 0, 10, 9), 0.4), ("corrosion", (0, 0, 10, 10), 0.9),
                 ("leak", (0, 0, 10, 10), 0.8), ("corrosion", (50, 50, 60, 60), 0.7)]
    assert verifier.box_labels(predicted, truth) == [False, True, False, False]


def test_crop_window_adds_context_and_stays_inside_frame():
    """Окно шире рамки на долю CONTEXT, не выходит за кадр и не бывает пустым."""
    left, top, right, bottom = verifier.crop_window((40, 40, 60, 80), 200, 100)
    assert left < 40 and right > 60 and top < 40 and bottom == 90
    assert verifier.crop_window((-5, -5, 300, 300), 200, 100) == (0, 0, 200, 100)
    left, top, right, bottom = verifier.crop_window((199.5, 99.5, 199.6, 99.6), 200, 100)
    assert right - left >= 1 and bottom - top >= 1 and right <= 200 and bottom <= 100


def test_candidates_respect_gate_and_order():
    """Кандидаты отбираются по порогу GATE и идут по убыванию уверенности."""
    predicted = [("leak", (0, 0, 1, 1), 0.05), ("leak", (0, 0, 1, 1), 0.5), ("leak", (0, 0, 1, 1), 0.1)]
    assert verifier.candidates(predicted, 0.08) == [1, 2]
    assert verifier.candidates(predicted, 0.08, top=1) == [1]


def test_rescore_replaces_scores_and_drops_boxes_below_gate():
    """Новая уверенность переносится на свою рамку, рамки без строки в meta и примеры разметки пропадают."""
    records = [{"file": "a", "truth": [], "labelled": None, "group": None,
                "predicted": [("leak", (0, 0, 5, 5), 0.3), ("corrosion", (1, 1, 4, 4), 0.06)]}]
    meta = np.zeros((2, 10), np.float32)
    meta[0, :6] = [0, 0, 1, 0.3, 0, 0]
    meta[1, :6] = [0, -1, 1, 1.0, 1, 1]
    out = verifier.rescore(records, meta, np.array([0.9, 0.1]))
    assert out[0]["predicted"] == [("leak", (0, 0, 5, 5), 0.9)]
    assert records[0]["predicted"][0][2] == 0.3


def test_fusion_and_classifier_inference():
    """Калибровка монотонна по обоим входам, вывод классификатора на numpy совпадает с формулой."""
    fusion = np.array([1.0, 0.5, 0.0])
    low, high = verifier.fused_score(np.array([0.2, 0.2]), np.array([-2.0, 2.0]), fusion)
    assert high > low
    assert verifier.fused_score(np.array([0.5]), np.array([0.0]), fusion)[0] == 0.5
    params = {"kind": "mlp", "w0": np.eye(2, dtype=np.float32), "b0": np.array([0.0, -1.0], np.float32),
              "w1": np.array([[1.0], [2.0]], np.float32), "b1": np.array([0.5], np.float32)}
    assert np.allclose(verifier.classifier_logit(params, np.array([[1.0, 3.0]], np.float32)), [1.0 + 4.0 + 0.5])


def test_fit_fusion_learns_useful_verdict():
    """Если оценка классификатора разделяет верные и лишние рамки, калибровка даёт ей положительный вес."""
    rng = np.random.default_rng(0)
    y = (rng.random(400) < 0.3).astype(np.float32)
    det = np.full(400, 0.3)
    verdict = np.where(y > 0, 2.0, -2.0) + rng.normal(0, 0.5, 400)
    weights = verifier.fit_fusion(det, verdict, y)
    assert weights[1] > 0.5


def test_operating_point_keeps_recall_of_detector():
    """Выбранный порог - наибольший, при котором полнота и доля найденных дефектов не ниже заданных."""
    records = [{"file": "a", "labelled": None, "group": None, "truth": [("leak", (0, 0, 10, 10))],
                "predicted": [("leak", (0, 0, 10, 10), 0.6), ("leak", (20, 20, 30, 30), 0.8)]},
               {"file": "b", "labelled": None, "group": None, "truth": [],
                "predicted": [("leak", (0, 0, 10, 10), 0.3)]}]
    level = verifier.operating_point(records, recall=1.0, found=1.0, grid=50)
    assert 0.3 < level <= 0.6


def test_presence_labels_split_defect_background_and_ambiguous():
    """Рамка на своём дефекте (даже с неточной границей) - 1, на фоне - 0, слабое перекрытие - -1."""
    truth = [("corrosion", (0, 0, 100, 100))]
    predicted = [("corrosion", (0, 0, 100, 100), 0.9), ("corrosion", (10, 10, 40, 40), 0.5),
                 ("corrosion", (200, 200, 260, 260), 0.4), ("leak", (0, 0, 100, 100), 0.3),
                 ("corrosion", (65, 65, 165, 165), 0.2)]
    assert verifier.presence_labels(predicted, truth) == [1, 1, 0, 0, -1]
    assert verifier.overlap((0, 0, 10, 10), (5, 5, 10, 10)) == 1.0


def test_meta_presence_marks_truth_rows_as_defect():
    """Строки размеченных рамок (source 1) всегда получают метку 1, строки детектора - по presence_labels."""
    records = [{"file": "a", "labelled": None, "group": None, "truth": [("leak", (0, 0, 10, 10))],
                "predicted": [("leak", (50, 50, 60, 60), 0.7)]}]
    meta = np.zeros((2, 10), np.float32)
    meta[0, :6] = [0, 0, 1, 0.7, 0, 0]
    meta[1, :6] = [0, -1, 1, 1.0, 1, 1]
    assert verifier.meta_presence(records, meta).tolist() == [0, 1]


def test_veto_rule_keeps_detector_score_and_drops_low_verdict():
    """Правило veto оставляет уверенность детектора и убирает рамки с низкой оценкой классификатора."""
    records = [{"file": "a", "labelled": None, "group": None, "truth": [],
                "predicted": [("leak", (0, 0, 5, 5), 0.3), ("corrosion", (1, 1, 4, 4), 0.2)]}]
    meta = np.zeros((2, 10), np.float32)
    meta[0, :6] = [0, 0, 1, 0.3, 0, 0]
    meta[1, :6] = [0, 1, 0, 0.2, 0, 0]
    model = {"rule": "veto", "threshold": 0.15, "verdict_level": 0.5, "fusion": np.zeros(3)}
    out, level = verifier.pipeline_records(records, meta, np.array([2.0, -2.0]), model)
    assert level == 0.15
    assert [(n, round(s, 3)) for n, _, s in out[0]["predicted"]] == [("leak", 0.3)]


def test_rank_auc_handles_ties_and_single_class():
    """AUC по рангам: идеальное разделение - 1, полная путаница - 0.5, один класс - None."""
    assert verifier.rank_auc(np.array([0, 0, 1, 1]), np.array([0.1, 0.2, 0.8, 0.9])) == 1.0
    assert verifier.rank_auc(np.array([0, 1]), np.array([0.5, 0.5])) == 0.5
    assert verifier.rank_auc(np.array([1, 1]), np.array([0.1, 0.2])) is None


def test_model_round_trip(tmp_path, monkeypatch):
    """save_model и load_model сохраняют правило, пороги и веса классификатора."""
    monkeypatch.setattr(verifier, "OUT", str(tmp_path))
    model = {"params": {"kind": "lr", "w0": np.ones((3, 1), np.float32), "b0": np.zeros(1, np.float32)},
             "mean": np.zeros(2), "std": np.ones(2), "fusion": np.array([1.0, 0.2, -0.5]), "rule": "veto",
             "threshold": 0.15, "verdict_level": 0.0959, "base_level": 0.15}
    verifier.save_model(model)
    loaded = verifier.load_model()
    assert loaded["rule"] == "veto" and loaded["params"]["kind"] == "lr"
    assert loaded["verdict_level"] == 0.0959 and np.allclose(loaded["params"]["w0"], 1.0)
