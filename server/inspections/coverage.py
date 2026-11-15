"""Полнота осмотра при обходе агрегата: накопление рамок детектора между кадрами по узлам.

Инженер обходит агрегат и показывает его со всех сторон. По каждому узлу карточки считается, в скольких
кадрах он был виден уверенно и достаточно крупно; набрав порог, узел считается осмотренным и больше не
сбрасывается. Дефектный признак, увиденный уверенно хотя бы с одной стороны, запоминается и не снимается
кадрами, где он не виден.
"""

import math
from threading import Lock

from server.rules import STRONG_CONFIDENCE, WEAK_CONFIDENCE, defect_signs, load_rules

MIN_CONFIDENCE = STRONG_CONFIDENCE
MIN_AREA = 0.015
MIN_FRAMES = 5
CLOSE_AREA = 0.04
CLOSE_FRAMES = 3
WEAK_DEFECT_FRAMES = 3
ALL_DONE_HINT = "Все узлы осмотрены"
NOTHING_TO_TRACK_HINT = "У этого оборудования нет узлов, которые распознаёт камера - отметьте результаты осмотра вручную"


def static_priority(equipment: dict) -> list[str]:
    """Возвращает коды узлов в порядке важности для диагностики, когда текущих данных об агрегате нет.

    Выше стоит узел, к которому относится правило с большей критичностью; при равенстве сохраняется
    порядок узлов в карточке.
    """
    codes = [node["id"] for node in equipment.get("nodes") or [] if node.get("id")]
    weights = dict.fromkeys(codes, 0)
    kind = equipment.get("type")
    for rule in load_rules():
        if rule.get("group") == "visual" or not ("*" in rule["applies_to"] or kind in rule["applies_to"]):
            continue
        target = next((code for code in [rule["node"], *rule.get("node_fallbacks", [])] if code in weights), None)
        if target is not None:
            weights[target] = max(weights[target], int(rule["severity"]))
    return sorted(codes, key=lambda code: (-weights[code], codes.index(code)))


def _number(value) -> float | None:
    """Приводит значение к конечному числу; всё остальное считается отсутствием значения."""
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


class CoverageTracker:
    """Счётчик полноты осмотра одного агрегата: принимает рамки кадра и возвращает накопленное состояние.

    Узел осмотрен, когда он был виден не менее чем в 5 кадрах с уверенностью от 0,5 и площадью рамки от
    1,5 % кадра, либо не менее чем в 3 кадрах с площадью от 4 %. Узел можно отметить осмотренным и вручную.
    В общий счёт входят узлы, у которых есть классы детектора; остальные оцениваются по датчикам.
    Подсказка называет следующий неосмотренный узел по приоритету диагностики.
    """

    def __init__(self, equipment: dict, priority: list[str] | None = None):
        """Принимает карточку оборудования и необязательный порядок узлов для подсказок."""
        self._lock = Lock()
        self._signs = defect_signs()
        self._nodes = {}
        self._by_class = {}
        for node in equipment.get("nodes") or []:
            code = node.get("id")
            if not code:
                continue
            classes = [str(cls) for cls in node.get("classes") or []]
            self._nodes[code] = {
                "name": node.get("name") or code,
                "classes": classes,
                "trackable": bool(classes),
                "by_camera": any(cls not in self._signs for cls in classes),
                "seen": 0,
                "close": 0,
                "glimpses": 0,
                "best_conf": 0.0,
                "best_area": 0.0,
                "inspected": False,
                "manual": False,
                "defect_classes": {},
                "last_frame": 0,
                "last_conf": 0.0,
                "last_area": 0.0,
            }
            for cls in classes:
                self._by_class.setdefault(cls, []).append(code)
        self._static = static_priority(equipment)
        self._order = list(self._static)
        self._frames = 0
        self._visual = {}
        self._weak_frames = {}
        self._weak_best = {}
        if priority:
            self.set_priority(priority)

    def set_priority(self, codes: list[str]) -> None:
        """Задаёт порядок узлов для подсказок: сначала перечисленные, затем остальные по важности правил."""
        with self._lock:
            known = [code for code in dict.fromkeys(codes) if code in self._nodes]
            self._order = known + [code for code in self._static if code not in known]

    @property
    def visual(self) -> dict[str, float]:
        """Лучшая накопленная уверенность по классам детектора - вход диагностики."""
        with self._lock:
            return dict(self._visual)

    def node_for(self, cls: str) -> str | None:
        """Возвращает код узла, к которому относится класс детектора, или None для класса вне карточки."""
        codes = self._by_class.get(cls)
        return codes[0] if codes else None

    def observe(self, boxes: list[dict], frame_w: float, frame_h: float) -> dict:
        """Учитывает рамки одного кадра и возвращает накопленное состояние осмотра.

        Рамка - словарь {cls, conf, x1, y1, x2, y2} в пикселях кадра. Рамки без площади и с нечисловыми
        полями пропускаются; неположительный размер кадра - ошибка вызывающего.
        """
        width, height = _number(frame_w), _number(frame_h)
        if width is None or height is None or width <= 0 or height <= 0:
            raise ValueError("Размер кадра должен быть положительным")
        sightings, peaks = {}, {}
        for box in boxes or []:
            sighting = self._sighting(box, width, height)
            if sighting is None:
                continue
            cls, conf, area = sighting
            best = sightings.get(cls)
            if best is None or self._quality(conf, area) > self._quality(*best):
                sightings[cls] = (conf, area)
            peaks[cls] = max(peaks.get(cls, 0.0), conf)
        with self._lock:
            self._frames += 1
            for cls, conf in peaks.items():
                self._note_class(cls, conf)
            for node in self._nodes.values():
                own = [sightings[cls] for cls in node["classes"] if cls in sightings]
                if own:
                    self._note_node(node, own, max(peaks[cls] for cls in node["classes"] if cls in peaks))
                node["defect_classes"] = {
                    cls: self._visual[cls] for cls in node["classes"] if cls in self._signs and cls in self._visual
                }
            return self._state()

    def mark_checked(self, code: str) -> dict:
        """Отмечает узел осмотренным вручную - так закрываются узлы, которые камера подтвердить не может."""
        with self._lock:
            if code not in self._nodes:
                raise KeyError(f"Узел {code} не найден в карточке оборудования")
            self._nodes[code]["inspected"] = True
            self._nodes[code]["manual"] = True
            return self._state()

    def state(self) -> dict:
        """Возвращает накопленное состояние без нового кадра."""
        with self._lock:
            return self._state()

    @staticmethod
    def _sighting(box: dict, width: float, height: float) -> tuple[str, float, float] | None:
        """Разбирает рамку: класс, уверенность и доля площади кадра; негодная рамка даёт None."""
        if not isinstance(box, dict) or not box.get("cls"):
            return None
        conf = _number(box.get("conf"))
        corners = [_number(box.get(key)) for key in ("x1", "y1", "x2", "y2")]
        if conf is None or conf <= 0 or None in corners:
            return None
        left, right = sorted((min(max(corners[0], 0.0), width), min(max(corners[2], 0.0), width)))
        top, bottom = sorted((min(max(corners[1], 0.0), height), min(max(corners[3], 0.0), height)))
        area = (right - left) * (bottom - top) / (width * height)
        if area <= 0:
            return None
        return str(box["cls"]), min(conf, 1.0), area

    @staticmethod
    def _quality(conf: float, area: float) -> tuple[bool, float, float]:
        """Задаёт, какая из рамок одного класса в кадре лучше: сначала уверенная, затем более крупная."""
        return conf >= MIN_CONFIDENCE, area, conf

    def _note_class(self, cls: str, conf: float) -> None:
        """Запоминает лучшую уверенность класса; слабый дефектный признак принимается после повторения в кадрах."""
        if cls not in self._signs:
            self._visual[cls] = max(self._visual.get(cls, 0.0), conf)
            return
        if conf >= STRONG_CONFIDENCE:
            self._visual[cls] = max(self._visual.get(cls, 0.0), conf)
            return
        if conf < WEAK_CONFIDENCE:
            return
        self._weak_frames[cls] = self._weak_frames.get(cls, 0) + 1
        self._weak_best[cls] = max(self._weak_best.get(cls, 0.0), conf)
        if self._weak_frames[cls] >= WEAK_DEFECT_FRAMES:
            self._visual[cls] = max(self._visual.get(cls, 0.0), self._weak_best[cls])

    def _note_node(self, node: dict, sightings: list[tuple[float, float]], peak: float) -> None:
        """Учитывает появление узла в кадре: счётчики кадров, лучшая уверенность и признак «осмотрен».

        sightings - лучшая рамка каждого класса узла в кадре, peak - наибольшая уверенность среди всех его рамок.
        """
        conf, area = max(sightings, key=lambda sighting: self._quality(*sighting))
        node["glimpses"] += 1
        node["best_conf"] = max(node["best_conf"], peak)
        node["last_frame"], node["last_conf"], node["last_area"] = self._frames, conf, area
        if conf < MIN_CONFIDENCE or area < MIN_AREA:
            return
        node["seen"] += 1
        node["best_area"] = max(node["best_area"], area)
        if area >= CLOSE_AREA:
            node["close"] += 1
        if node["seen"] >= MIN_FRAMES or node["close"] >= CLOSE_FRAMES:
            node["inspected"] = True

    def _pending(self) -> list[str]:
        """Возвращает неосмотренные узлы строго в порядке приоритета диагностики."""
        return [code for code in self._order if self._nodes[code]["trackable"] and not self._nodes[code]["inspected"]]

    def _counted_now(self, node: dict) -> bool:
        """Проверяет, что узел есть в последнем кадре и этот кадр ему засчитан."""
        return (
            self._frames > 0
            and node["last_frame"] == self._frames
            and node["last_conf"] >= MIN_CONFIDENCE
            and node["last_area"] >= MIN_AREA
        )

    def _hint_node(self, pending: list[str]) -> str | None:
        """Выбирает узел для подсказки: тот, что сейчас засчитывается в кадре, иначе первый по приоритету.

        Пока инженер держит камеру на неосмотренном узле, подсказка не уводит его к другому узлу.
        """
        held = next((code for code in pending if self._counted_now(self._nodes[code])), None)
        return held or (pending[0] if pending else None)

    def _hint(self, code: str | None) -> str:
        """Составляет подсказку по выбранному узлу: показать, подойти ближе, показать с другой стороны, удержать."""
        if not any(node["trackable"] for node in self._nodes.values()):
            return NOTHING_TO_TRACK_HINT
        if code is None:
            return ALL_DONE_HINT
        node = self._nodes[code]
        name = node["name"]
        if self._counted_now(node):
            return f"Удерживайте камеру на узле «{name}» - засчитано кадров: {node['seen']} из {MIN_FRAMES}"
        if not node["by_camera"]:
            return f"Осмотрите узел «{name}» и отметьте результат вручную - камера распознаёт на нём только дефекты"
        if node["glimpses"] == 0:
            return f"Покажите узел «{name}»"
        if node["last_frame"] == self._frames or node["seen"] == 0:
            if node["last_conf"] < MIN_CONFIDENCE:
                return f"Покажите узел «{name}» с другой стороны - распознавание неуверенное"
            return f"Подойдите ближе к узлу «{name}»"
        return f"Вернитесь к узлу «{name}» - осмотр не завершён"

    def _state(self) -> dict:
        """Собирает состояние осмотра для ответа клиенту; вызывается под замком."""
        tracked = [node for node in self._nodes.values() if node["trackable"]]
        inspected = sum(1 for node in tracked if node["inspected"])
        pending = self._pending()
        hint_node = self._hint_node(pending)
        nodes = {}
        for code, node in self._nodes.items():
            nodes[code] = {
                "name": node["name"],
                "seen": node["seen"],
                "close": node["close"],
                "best_conf": round(node["best_conf"], 3),
                "best_area": round(node["best_area"] * 100, 1),
                "inspected": node["inspected"],
                "manual": node["manual"],
                "trackable": node["trackable"],
                "by_camera": node["by_camera"],
                "defect_classes": {cls: round(conf, 3) for cls, conf in node["defect_classes"].items()},
            }
        return {
            "percent": round(100 * inspected / len(tracked)) if tracked else 0,
            "inspected": inspected,
            "total": len(tracked),
            "frames": self._frames,
            "nodes": nodes,
            "visual": {cls: round(conf, 3) for cls, conf in self._visual.items()},
            "hint": self._hint(hint_node),
            "hint_node": hint_node,
            "next_node": pending[0] if pending else None,
            "pending": pending,
        }
