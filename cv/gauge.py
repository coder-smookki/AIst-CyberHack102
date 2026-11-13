"""Чтение стрелочного манометра по кадру средствами OpenCV.

Запуск:
    python cv/gauge.py <изображение> [минимум=0] [максимум=10] [развёртка_шкалы_в_градусах=270]
"""
import math
import sys

import cv2
import numpy as np

SIZE = 320


def rectify(image: np.ndarray) -> np.ndarray | None:
    """Находит светлый циферблат и приводит его к кругу фиксированного размера.

    Циферблат, снятый под углом, виден как эллипс. Эллипс вписывается в самый крупный светлый контур,
    после чего изображение поворачивается и растягивается так, чтобы эллипс стал окружностью.
    """
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    blur = cv2.GaussianBlur(gray, (5, 5), 0)
    _, mask = cv2.threshold(blur, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    contours = [c for c in contours if len(c) >= 5 and cv2.contourArea(c) > 0.08 * gray.size]
    if not contours:
        return None
    (cx, cy), (d1, d2), angle = cv2.fitEllipse(max(contours, key=cv2.contourArea))
    if min(d1, d2) < 24:
        return None
    a = math.radians(angle)
    rot = np.array([[math.cos(a), math.sin(a)], [-math.sin(a), math.cos(a)]])
    scale = np.diag([SIZE * 0.94 / d1, SIZE * 0.94 / d2])
    m = rot.T @ scale @ rot
    shift = np.array([SIZE / 2, SIZE / 2]) - m @ np.array([cx, cy])
    return cv2.warpAffine(gray, np.hstack([m, shift[:, None]]), (SIZE, SIZE), flags=cv2.INTER_LINEAR, borderValue=255)


def needle_angle(dial: np.ndarray, sweep_deg: float) -> tuple[float, float]:
    """Ищет направление стрелки и возвращает угол от вертикали по часовой стрелке и контраст.

    Для каждого направления в пределах шкалы суммируется темнота вдоль луча от центра.
    Луч берётся короче внутреннего края цифр, поэтому цифры и деления в сумму не попадают.
    """
    c = SIZE / 2
    radius = SIZE * 0.47
    dark = 255.0 - cv2.GaussianBlur(dial, (3, 3), 0).astype(np.float32)
    radii = np.linspace(0.16 * radius, 0.44 * radius, 40)
    angles = np.arange(-sweep_deg / 2 - 4, sweep_deg / 2 + 4.01, 0.5)
    scores = []
    for deg in angles:
        t = math.radians(deg)
        xs = np.clip(c + radii * math.sin(t), 0, SIZE - 1).astype(int)
        ys = np.clip(c - radii * math.cos(t), 0, SIZE - 1).astype(int)
        scores.append(float(dark[ys, xs].mean()))
    scores = np.array(scores)
    smooth = np.convolve(scores, np.ones(5) / 5, mode="same")
    best = int(smooth.argmax())
    contrast = float(smooth[best] - np.median(smooth))
    return float(angles[best]), contrast


def read_gauge(image: np.ndarray, vmin: float = 0.0, vmax: float = 10.0, sweep_deg: float = 270.0) -> dict:
    """Возвращает показание манометра, угол стрелки и признак надёжности результата."""
    dial = rectify(image)
    if dial is None:
        return {"value": None, "ok": False, "reason": "циферблат не найден"}
    angle, contrast = needle_angle(dial, sweep_deg)
    angle = max(-sweep_deg / 2, min(sweep_deg / 2, angle))
    value = vmin + (angle + sweep_deg / 2) / sweep_deg * (vmax - vmin)
    return {"value": round(value, 2), "angle_deg": round(angle, 1), "contrast": round(contrast, 1), "ok": contrast >= 18.0}


if __name__ == "__main__":
    frame = cv2.imdecode(np.fromfile(sys.argv[1], np.uint8), cv2.IMREAD_COLOR)
    args = [float(v) for v in sys.argv[2:5]]
    print(read_gauge(frame, *args))
