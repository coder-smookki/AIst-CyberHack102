"""Чтение стрелочного манометра по кадру средствами OpenCV.

Запуск:
    python cv/gauge.py <изображение> [минимум=0] [максимум=10] [развёртка_шкалы_в_градусах=270]
"""

import math
import sys

import cv2
import numpy as np

SIZE = 320
WORK = 360
RADIUS = SIZE * 0.47
BAND = (0.15, 0.48)
MIN_COVERAGE = 0.6
MIN_RATIO = 0.5
MIN_CONTRAST = 40.0


def dial_ellipse(gray: np.ndarray):
    """Ищет обод циферблата: эллипс, вдоль которого перепады яркости идут почти по всей окружности.

    Каждый контур перепадов даёт пробный эллипс. Эллипс оценивается по всем перепадам кадра: считается доля
    направлений из центра, в которых на его линии есть перепад. Из самых полных берутся самые однородные внутри, а из них самый крупный: очертание всего корпуса
    включает тёмную боковую стенку и уступает лицевой стороне циферблата.
    Возвращает центр, оси и угол в координатах исходного кадра.
    """
    scale = WORK / max(gray.shape)
    work = cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_CUBIC)
    height, width = work.shape
    edges = cv2.Canny(cv2.GaussianBlur(work, (5, 5), 0), 40, 120)
    ys, xs = np.nonzero(edges)
    points = np.stack([xs, ys], axis=1).astype(np.float32)
    contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_NONE)
    candidates = []
    for contour in contours:
        if len(contour) < 40:
            continue
        (cx, cy), (d1, d2), angle = cv2.fitEllipse(contour)
        small, large = min(d1, d2), max(d1, d2)
        if not (small >= 0.2 * min(height, width) and small >= MIN_RATIO * large and large <= 1.15 * max(height, width)):
            continue
        if not (0.2 * width < cx < 0.8 * width and 0.2 * height < cy < 0.8 * height):
            continue
        t = math.radians(angle)
        rel = points - np.array([cx, cy], np.float32)
        u = (rel[:, 0] * math.cos(t) + rel[:, 1] * math.sin(t)) / (d1 / 2)
        v = (-rel[:, 0] * math.sin(t) + rel[:, 1] * math.cos(t)) / (d2 / 2)
        on_line = np.abs(np.hypot(u, v) - 1.0) < 0.04
        coverage = len(np.unique((np.degrees(np.arctan2(v[on_line], u[on_line])) // 5).astype(int))) / 72
        if coverage >= MIN_COVERAGE:
            inside = np.zeros(work.shape, np.uint8)
            cv2.ellipse(inside, ((cx, cy), (d1 * 0.94, d2 * 0.94), angle), 255, -1)
            values = work[inside > 0].astype(np.int16)
            evenness = float((np.abs(values - np.median(values)) < 30).mean())
            candidates.append((coverage, evenness, small, ((cx / scale, cy / scale), (d1 / scale, d2 / scale), angle)))
    if not candidates:
        return None
    complete = [c for c in candidates if c[0] >= max(c[0] for c in candidates) - 0.1]
    even = [c for c in complete if c[1] >= max(c[1] for c in complete) - 0.07]
    best = max(even, key=lambda c: c[2])[3]
    return best


def rectify(image: np.ndarray) -> np.ndarray | None:
    """Находит циферблат и приводит его к кругу фиксированного размера.

    Циферблат, снятый под углом, виден как эллипс. Изображение растягивается вдоль осей эллипса так,
    чтобы он стал окружностью, без поворота вокруг центра.
    """
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    found = dial_ellipse(gray)
    if found is None:
        return None
    (cx, cy), (d1, d2), angle = found
    a = math.radians(angle)
    rot = np.array([[math.cos(a), math.sin(a)], [-math.sin(a), math.cos(a)]])
    scale = np.diag([2 * RADIUS / d1, 2 * RADIUS / d2])
    m = rot.T @ scale @ rot
    shift = np.array([SIZE / 2, SIZE / 2]) - m @ np.array([cx, cy])
    return cv2.warpAffine(
        gray, np.hstack([m, shift[:, None]]), (SIZE, SIZE), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE
    )


def needle_axis(dial: np.ndarray, coarse_deg: float, sign: float) -> float:
    """Уточняет угол стрелки по направлению её оси.

    Вдоль найденного луча собираются точки стрелки, и через них проводится прямая.
    Направление прямой не зависит от того, насколько точно найден центр циферблата.
    """
    c = SIZE / 2
    t = math.radians(coarse_deg)
    along = np.array([math.sin(t), -math.cos(t)])
    ys, xs = np.mgrid[0:SIZE, 0:SIZE]
    rel = np.stack([xs - c, ys - c], axis=-1).astype(np.float32)
    radial = rel @ along
    lateral = np.abs(rel @ np.array([along[1], -along[0]]))
    strip = (radial > 0.1 * RADIUS) & (radial < 0.62 * RADIUS) & (lateral < 0.09 * RADIUS)
    values = cv2.GaussianBlur(dial, (3, 3), 0).astype(np.float32)[strip]
    weight = np.clip(sign * (np.median(values) - values), 0, None)
    weight = np.where(weight > 0.5 * weight.max(), weight, 0.0)
    if weight.sum() <= 0:
        return coarse_deg
    pts = rel[strip]
    mean = (pts * weight[:, None]).sum(0) / weight.sum()
    cov = ((pts - mean) * weight[:, None]).T @ (pts - mean) / weight.sum()
    vals, vecs = np.linalg.eigh(cov)
    axis = vecs[:, int(vals.argmax())]
    if axis @ along < 0:
        axis = -axis
    fine = math.degrees(math.atan2(axis[0], -axis[1]))
    return fine if abs(fine - coarse_deg) <= 8.0 else coarse_deg


def needle_angle(dial: np.ndarray, sweep_deg: float) -> tuple[float, float]:
    """Ищет направление стрелки и возвращает угол от вертикали по часовой стрелке и контраст.

    Циферблат разворачивается в полярные координаты. Для каждого направления берётся отличие яркости от
    типичной на том же расстоянии от центра, поэтому круговые детали значения не имеют. Стрелка отличается
    от фона почти по всей длине луча, а цифры, надписи и короткий хвост стрелки только на его части, поэтому
    направление оценивается по нижней трети значений вдоль луча. Сначала ищется тёмная стрелка. Светлая
    ищется, только если тёмной не нашлось: так блики на стекле и металле за стрелку не принимаются.
    """
    c = SIZE / 2
    blurred = cv2.GaussianBlur(dial, (3, 3), 0)
    polar = cv2.warpPolar(blurred, (int(RADIUS), 720), (c, c), RADIUS, cv2.WARP_POLAR_LINEAR).astype(np.float32)
    band = polar[:, int(BAND[0] * RADIUS) : int(BAND[1] * RADIUS)]
    ring = np.median(band, axis=0, keepdims=True)
    angles = (np.arange(720) * 0.5 + 90.0 + 180.0) % 360.0 - 180.0
    allowed = np.abs(angles) <= sweep_deg / 2 + 6.0
    found = None
    for sign in (1.0, -1.0):
        diff = np.clip(sign * (ring - band), 0, None)
        spread = cv2.dilate(np.vstack([diff[-8:], diff, diff[:8]]), np.ones((5, 1), np.uint8))
        score = np.convolve(np.percentile(spread, 30, axis=1), np.ones(5) / 5, mode="same")[8:-8]
        best = int(np.where(allowed, score, -1.0).argmax())
        contrast = float(score[best] - np.median(score[allowed]))
        if found is None or contrast > found[1]:
            found = (float(angles[best]), contrast, sign)
        if contrast >= MIN_CONTRAST:
            break
    return needle_axis(dial, found[0], found[2]), found[1]


def read_gauge(image: np.ndarray, vmin: float = 0.0, vmax: float = 10.0, sweep_deg: float = 270.0) -> dict:
    """Возвращает показание манометра, угол стрелки и признак надёжности результата."""
    dial = rectify(image)
    if dial is None:
        return {"value": None, "ok": False, "reason": "циферблат не найден"}
    angle, contrast = needle_angle(dial, sweep_deg)
    angle = max(-sweep_deg / 2, min(sweep_deg / 2, angle))
    value = vmin + (angle + sweep_deg / 2) / sweep_deg * (vmax - vmin)
    return {
        "value": round(value, 2),
        "angle_deg": round(angle, 1),
        "contrast": round(contrast, 1),
        "ok": contrast >= MIN_CONTRAST,
    }


if __name__ == "__main__":
    frame = cv2.imdecode(np.fromfile(sys.argv[1], np.uint8), cv2.IMREAD_COLOR)
    args = [float(v) for v in sys.argv[2:5]]
    print(read_gauge(frame, *args))
