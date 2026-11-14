"""Движок диагностики: сопоставляет правила из data/rules.json с камерой, датчиками и ресурсом.

Правило состоит из частей (камера, датчики, ресурс). Все части выполнены - правило сработало
полностью. Выполнена только часть - находка получает статус «требует проверки» и список того,
что осталось проверить; уверенный визуальный признак без подтверждения датчиками остаётся находкой.
"""
import copy
import json
import operator
from functools import lru_cache
from pathlib import Path

from .resource import maintenance_intervals
from .thresholds import NO_DATA_LABEL, NORMAL_LABEL, as_number, temperature_label, vibration_label

RULES_FILE = Path(__file__).resolve().parents[2] / "data" / "rules.json"
WEAK_CONFIDENCE = 0.25
STRONG_CONFIDENCE = 0.5
EQUIPMENT_NODE = "equipment"
CHECKED_PREFIX = "checked:"
GAUGE_READING = "gauge_reading"
HYDRAULIC_FACTOR = 9.81 / 36.0
STATUS_RANK = {"unknown": 0, "ok": 1, "check": 2, "defect": 3}
OPERATORS = {">": operator.gt, ">=": operator.ge, "<": operator.lt, "<=": operator.le}
REQUIRED_RULE_KEYS = ("id", "title", "applies_to", "node", "severity", "diagnosis", "recommendation", "parts")
LABELS = {
    "vibration": ("Диагноз по вибрации", vibration_label, "нет данных вибрации: амплитуды 1x, 2x и ВЧ шум"),
    "temperature": ("Диагноз по температуре", temperature_label, "нет данных температуры подшипника и обмоток"),
}
EARLY_DIAGNOSIS = "Ранний признак по трендам, значения ещё в пределах уставок. Возможный диагноз: "
EARLY_ADVICE = "Усилить наблюдение и осмотреть узел. Действие при подтверждении: "
WEAK_DIAGNOSIS = "Слабый визуальный признак, требуется подтверждение. Возможный диагноз: "
WEAK_ADVICE = "Подойти ближе или показать узел с другой стороны, чтобы подтвердить или снять признак."
PARTIAL_DIAGNOSIS = "Условия правила выполнены частично. Возможный диагноз: "
PARTIAL_ADVICE = "Проверить недостающие условия. Действие при подтверждении: "
NO_CURRENTS = "нет данных: токи фаз двигателя"


def _fmt(value: float, digits: int = 2) -> str:
    """Записывает число с ограниченным количеством знаков после точки и без хвостовых нулей."""
    text = f"{round(value, digits):.{digits}f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def _expand(expr: dict, library: dict) -> dict:
    """Подставляет в выражение правила общие условия вместо ссылок вида {"ref": имя}."""
    if "ref" in expr:
        if expr["ref"] not in library:
            raise RuntimeError(f"В правилах нет общего условия «{expr['ref']}»")
        return _expand(copy.deepcopy(library[expr["ref"]]), library)
    for key in ("all", "any"):
        if key in expr:
            return {key: [_expand(child, library) for child in expr[key]]}
    return expr


def _check(expr: dict, rule_id: str) -> None:
    """Проверяет, что каждое условие выражения относится к известному виду."""
    children = expr.get("all") or expr.get("any")
    if children:
        for child in children:
            _check(child, rule_id)
    elif expr.get("kind") not in LEAVES:
        raise RuntimeError(f"В правиле {rule_id} условие неизвестного вида: {expr.get('kind')}")


@lru_cache(maxsize=1)
def _document() -> dict:
    """Читает файл правил один раз, проверяет состав каждого правила и раскрывает ссылки на общие условия."""
    try:
        with open(RULES_FILE, encoding="utf-8") as file:
            document = json.load(file)
    except FileNotFoundError as error:
        raise RuntimeError(f"Файл правил диагностики не найден: {RULES_FILE}") from error
    except json.JSONDecodeError as error:
        raise RuntimeError(f"Файл правил диагностики повреждён: {RULES_FILE} ({error})") from error
    library = document.get("conditions", {})
    for rule in document.get("rules", []):
        absent = [key for key in REQUIRED_RULE_KEYS if key not in rule]
        if absent:
            raise RuntimeError(f"В правиле {rule.get('id', '?')} нет полей: {', '.join(absent)}")
        for part in rule["parts"]:
            part["expr"] = _expand(part["expr"], library)
            _check(part["expr"], rule["id"])
        if "escalation" in rule:
            rule["escalation"]["expr"] = _expand(rule["escalation"]["expr"], library)
            _check(rule["escalation"]["expr"], rule["id"])
    return document


def load_rules(group: str | None = None) -> list[dict]:
    """Возвращает копию списка правил с раскрытыми условиями.

    Группы: "customer" - 12 правил заказчика R01-R12, "threshold" - уставки его баз S01-S05,
    "visual" - общее правило V01 для дефектных признаков без своего правила. Без group - все.
    """
    rules = _document()["rules"]
    return copy.deepcopy([rule for rule in rules if group is None or rule.get("group") == group])


def defect_signs() -> dict[str, str]:
    """Возвращает дефектные признаки с русскими названиями: классы детектора и ручные отметки инженера.

    Класс детектора, которого нет в этом перечне, диагностика дефектом не считает.
    """
    return dict(_document().get("signs", {}))


def gauge_difference_percent(gauge_value: float, sensor_value: float) -> float:
    """Считает расхождение электронного датчика со стрелочным манометром в процентах от показания манометра.

    При нулевом показании манометра базой служит показание датчика; при двух нулях расхождения нет.
    """
    base = abs(gauge_value) or abs(sensor_value)
    if base == 0:
        return 0.0
    return abs(gauge_value - sensor_value) / base * 100.0


def _numbers(values) -> dict:
    """Оставляет в словаре только конечные числа: пропуски и нечисловые значения считаются отсутствием данных."""
    result = {}
    for key, value in (values or {}).items():
        number = as_number(value)
        if number is not None:
            result[key] = number
    return result


def _nominal_efficiency(specs: dict) -> float | None:
    """Считает паспортный КПД в процентах по подаче, напору и мощности из карточки (перекачивается вода)."""
    flow = as_number(specs.get("flow_m3h"))
    head = as_number(specs.get("head_m"))
    power = as_number(specs.get("power_kw"))
    if not flow or not head or not power:
        return None
    return HYDRAULIC_FACTOR * flow * head / power


class _Context:
    """Входные данные одного вызова диагностики, приведённые к виду, удобному для проверки условий."""

    def __init__(self, document: dict, equipment: dict, readings, trends, visual, manual):
        """Запоминает входные данные и заранее считает производные величины."""
        self.document = document
        self.equipment = equipment
        self.readings = _numbers(readings)
        self.trends = _numbers(trends)
        self.visual = _numbers(visual)
        self.manual = {str(token) for token in (manual or ())}
        self.nodes = {node["id"]: node for node in equipment.get("nodes") or [] if node.get("id")}
        self.values = {code: (value, self._with_unit(code, value)) for code, value in self.readings.items()}
        self.absent = {}
        self._derive()

    def meta(self, code: str) -> dict:
        """Возвращает название и единицу параметра; для неизвестного кода - сам код без единицы."""
        return self.document.get("parameters", {}).get(code) or {"name": code, "unit": ""}

    def no_data(self, code: str) -> str:
        """Составляет подсказку об отсутствии показаний параметра."""
        return f"нет данных: {self.meta(code)['name']}"

    def _with_unit(self, code: str, value: float) -> str:
        """Записывает значение параметра вместе с единицей измерения."""
        return f"{_fmt(value)} {self.meta(code)['unit']}".strip()

    def _running(self) -> bool:
        """Определяет, в работе ли агрегат: по признаку режима, затем по оборотам, затем по карточке."""
        if "mode" in self.readings:
            return self.readings["mode"] != 0
        if "rpm" in self.readings:
            return self.readings["rpm"] > 0
        return self.equipment.get("mode") != "stopped"

    def _derive(self) -> None:
        """Считает производные величины правил; для несчитанных запоминает, каких данных не хватило."""
        specs = self.equipment.get("specs") or {}
        baselines = dict(self.document.get("baselines", {}).get(self.equipment.get("type"), {}))
        baselines.update(_numbers(self.equipment.get("baselines")))
        self._derive_deviations(baselines)
        self._derive_currents(as_number(specs.get("rated_current_a")))
        self._derive_efficiency(as_number(baselines.get("efficiency")) or _nominal_efficiency(specs))
        gauge, sensor = self.readings.get(GAUGE_READING), self.readings.get("press_out")
        if gauge is not None and sensor is not None:
            difference = gauge_difference_percent(gauge, sensor)
            text = f"манометр {_fmt(gauge)} бар, датчик {_fmt(sensor)} бар, расхождение {_fmt(difference, 1)} %"
            self.values["gauge_diff_pct"] = (difference, text)
        elif gauge is not None:
            self.absent["gauge_diff_pct"] = self.no_data("press_out")

    def _derive_deviations(self, baselines: dict) -> None:
        """Сравнивает температуру подшипника и давление на входе с нормой для типа оборудования."""
        bearing, bearing_norm = self.readings.get("temp_bearing"), as_number(baselines.get("temp_bearing"))
        if bearing is None:
            self.absent["temp_bearing_excess"] = self.no_data("temp_bearing")
        elif bearing_norm is None:
            self.absent["temp_bearing_excess"] = "для этого типа оборудования не задана нормальная температура подшипника"
        else:
            text = f"{_fmt(bearing)} °C при норме {_fmt(bearing_norm)} °C"
            self.values["temp_bearing_excess"] = (bearing - bearing_norm, text)
        inlet, inlet_norm = self.readings.get("press_in"), as_number(baselines.get("press_in"))
        if inlet is None:
            self.absent["press_in_drop_pct"] = self.no_data("press_in")
        elif not inlet_norm:
            self.absent["press_in_drop_pct"] = "для этого типа оборудования не задано нормальное давление на входе"
        else:
            text = f"{_fmt(inlet)} бар при норме {_fmt(inlet_norm)} бар"
            self.values["press_in_drop_pct"] = ((1.0 - inlet / inlet_norm) * 100.0, text)

    def _derive_currents(self, rated: float | None) -> None:
        """Считает средний ток относительно номинального и небаланс фаз, если небаланс не передан готовым."""
        phases = [self.readings.get(code) for code in ("current_a", "current_b", "current_c")]
        if any(phase is None for phase in phases):
            self.absent["current_load_pct"] = NO_CURRENTS
            if "current_unbalance" not in self.readings:
                self.absent["current_unbalance"] = NO_CURRENTS
            return
        mean = sum(phases) / 3.0
        if "current_unbalance" not in self.readings and mean > 0:
            unbalance = max(abs(phase - mean) for phase in phases) / mean * 100.0
            listed = " / ".join(_fmt(phase) for phase in phases)
            self.values["current_unbalance"] = (unbalance, f"{_fmt(unbalance)} % (фазы {listed} А)")
        if rated:
            share = mean / rated * 100.0
            text = f"{_fmt(mean)} А - {_fmt(share, 1)} % от номинального {_fmt(rated)} А"
            self.values["current_load_pct"] = (share, text)
        else:
            self.absent["current_load_pct"] = "в карточке агрегата нет номинального тока двигателя"

    def _derive_efficiency(self, nominal: float | None) -> None:
        """Считает снижение КПД относительно паспортного; для остановленного агрегата оценка не делается."""
        efficiency = self.readings.get("efficiency")
        if efficiency is None:
            self.absent["efficiency_drop_pct"] = self.no_data("efficiency")
        elif not nominal:
            self.absent["efficiency_drop_pct"] = "в карточке агрегата нет подачи, напора и мощности для паспортного КПД"
        elif not self._running():
            self.absent["efficiency_drop_pct"] = "агрегат остановлен - КПД не оценивается"
        else:
            drop = (1.0 - efficiency / nominal) * 100.0
            text = f"{_fmt(efficiency, 1)} % при паспортном {_fmt(nominal, 1)} % (снижение на {_fmt(drop, 1)} %)"
            self.values["efficiency_drop_pct"] = (drop, text)

    def node_for(self, rule: dict) -> str:
        """Выбирает узел правила: основной, затем запасные по порядку; если ни одного нет - агрегат в целом."""
        for node_id in [rule["node"], *rule.get("node_fallbacks", ())]:
            if node_id in self.nodes:
                return node_id
        return EQUIPMENT_NODE

    def node_of_class(self, sign: str) -> str:
        """Находит узел, к которому относится класс детектора; иначе - агрегат в целом."""
        for node_id, node in self.nodes.items():
            if sign in (node.get("classes") or []):
                return node_id
        return EQUIPMENT_NODE


def _evidence(source: str, what: str, value: str, threshold: str | None, met: bool) -> dict:
    """Собирает одну строку оснований находки."""
    return {"source": source, "what": what, "value": value, "threshold": threshold, "met": met}


def _result(state: str, evidence=(), missing=(), early: bool = False, score: float = 0.0, details=None) -> dict:
    """Собирает итог проверки условия: состояние met, weak, unmet или unknown, основания и подсказки."""
    return {
        "state": state,
        "evidence": list(evidence),
        "missing": list(missing),
        "early": early,
        "score": score,
        "details": details or {},
    }


def _threshold(leaf: dict, context: _Context, node_id: str) -> dict:
    """Сравнивает текущее значение параметра или производной величины с порогом правила."""
    meta = context.meta(leaf["param"])
    what = leaf.get("what") or meta["name"]
    source = leaf.get("source", "sensor")
    limit = f"{leaf['op']} {_fmt(leaf['value'])} {meta['unit']}".strip()
    entry = context.values.get(leaf["param"])
    if entry is None:
        hint = context.absent.get(leaf["param"]) or leaf.get("hint") or context.no_data(leaf["param"])
        return _result("unknown", [_evidence(source, what, "нет данных", limit, False)], [hint])
    value, text = entry
    met = OPERATORS[leaf["op"]](value, leaf["value"])
    return _result("met" if met else "unmet", [_evidence(source, what, text, limit, met)], score=1.0 if met else 0.0)


def _trend(leaf: dict, context: _Context, node_id: str) -> dict:
    """Сравнивает наклон тренда параметра за час с порогом; сработавшее условие считается ранним признаком."""
    meta = context.meta(leaf["param"])
    what = leaf.get("what") or f"Тренд: {meta['name']}"
    unit = f"{meta['unit']}/ч"
    limit = f"{leaf['op']} {_fmt(leaf['value'], 3)} {unit}"
    slope = context.trends.get(leaf["param"])
    if slope is None:
        hint = context.no_data(leaf["param"])
        if leaf["param"] in context.readings:
            hint = f"недостаточно точек для тренда: {meta['name']}"
        return _result("unknown", [_evidence("sensor", what, "нет данных", limit, False)], [hint])
    sign = "+" if slope > 0 else ""
    met = OPERATORS[leaf["op"]](slope, leaf["value"])
    text = f"{sign}{_fmt(slope, 3)} {unit}"
    return _result(
        "met" if met else "unmet", [_evidence("sensor", what, text, limit, met)], early=met, score=1.0 if met else 0.0
    )


def _sign(leaf: dict, context: _Context, node_id: str) -> dict:
    """Проверяет визуальный признак: уверенно виден камерой, отмечен инженером, виден слабо, снят осмотром или неизвестен."""
    titles = context.document.get("signs", {})
    source = leaf.get("source", "camera")
    limit = f">= {STRONG_CONFIDENCE}"
    confirmed = [sign for sign in leaf["signs"] if sign in context.manual]
    if confirmed:
        what = titles.get(confirmed[0], leaf["what"])
        return _result("met", [_evidence("manual", what, "подтверждено инженером", None, True)], score=1.0)
    confidence, best = max((context.visual.get(sign, 0.0), sign) for sign in leaf["signs"])
    what = titles.get(best, leaf["what"])
    if confidence >= STRONG_CONFIDENCE:
        text = f"уверенность {confidence:.2f}"
        return _result("met", [_evidence("camera", what, text, limit, True)], score=confidence)
    if confidence >= WEAK_CONFIDENCE:
        text = f"уверенность {confidence:.2f}, признак слабый"
        hint = f"подойдите ближе или покажите узел с другой стороны - слабый признак: {what}"
        return _result("weak", [_evidence("camera", what, text, limit, False)], [hint], score=confidence)
    seen = any(context.visual.get(cls, 0.0) >= STRONG_CONFIDENCE for cls in leaf.get("normal", ()))
    if seen:
        return _result("unmet", [_evidence("camera", leaf["what"], "узел осмотрен, признак не обнаружен", limit, False)])
    if CHECKED_PREFIX + node_id in context.manual:
        return _result("unmet", [_evidence("manual", leaf["what"], "проверено инженером, признака нет", None, False)])
    return _result("unknown", [_evidence(source, leaf["what"], "нет данных", limit, False)], [leaf["hint"]])


def _label(leaf: dict, context: _Context, node_id: str) -> dict:
    """Проверяет, что диагноз по уставкам заказчика (вибрация или температура) совпадает с ожидаемым, обычно «Норма»."""
    what, function, hint = LABELS[leaf["label"]]
    expected = leaf.get("equals", NORMAL_LABEL)
    label = function(context.readings)
    if label == NO_DATA_LABEL:
        return _result("unknown", [_evidence("sensor", what, "нет данных", expected, False)], [hint])
    met = label == expected
    return _result("met" if met else "unmet", [_evidence("sensor", what, label, expected, met)], score=1.0 if met else 0.0)


def _maintenance(leaf: dict, context: _Context, node_id: str) -> dict:
    """Проверяет межремонтные интервалы агрегата: условие выполнено, если наступил срок хотя бы одного вида ТО."""
    intervals = maintenance_intervals(context.equipment, context.readings.get("run_hours"))
    known = [item for item in intervals if item["state"] != "insufficient_data"]
    if not known:
        return _result("unknown", missing=["нет данных о межремонтных интервалах и наработке агрегата"])
    evidence = []
    for item in known:
        what = f"{item['name']}: наработка после последнего обслуживания"
        value = f"{_fmt(item['since_hours'], 1)} ч"
        limit = f">= {_fmt(item['interval_hours'], 1)} ч"
        evidence.append(_evidence("resource", what, value, limit, item["state"] == "due"))
    due = [item for item in known if item["state"] == "due"]
    if not due:
        return _result("unmet", evidence)
    items = ", ".join(f"{item['name']} (каждые {_fmt(item['interval_hours'], 1)} ч)" for item in due)
    works = " ".join(f"{item['name']}: {item['work'].rstrip('.')}." for item in due if item.get("work"))
    return _result("met", evidence, score=1.0, details={"items": items, "works": works})


LEAVES = {"threshold": _threshold, "trend": _trend, "sign": _sign, "label": _label, "maintenance": _maintenance}


def _merged_details(results: list) -> dict:
    """Объединяет подстановки для текстов диагноза из нескольких условий."""
    details = {}
    for result in results:
        details.update(result["details"])
    return details


def _any(children: list) -> dict:
    """Объединяет условия по «или»: достаточно одного выполненного; в основания идут только сработавшие."""
    met = [child for child in children if child["state"] == "met"]
    if met:
        evidence = [line for child in met for line in child["evidence"]]
        early = all(child["early"] for child in met)
        return _result("met", evidence, early=early, score=max(child["score"] for child in met), details=_merged_details(met))
    weak = [child for child in children if child["state"] == "weak"]
    states = {child["state"] for child in children}
    state = "weak" if weak else "unknown" if "unknown" in states else "unmet"
    evidence = [line for child in children for line in child["evidence"]]
    missing = [hint for child in children for hint in child["missing"]]
    return _result(state, evidence, missing, score=max((child["score"] for child in weak), default=0.0))


def _all(children: list) -> dict:
    """Объединяет условия по «и»: нужны все; невыполненное условие важнее неизвестного, неизвестное - слабого."""
    states = {child["state"] for child in children}
    state = next((name for name in ("unmet", "unknown", "weak") if name in states), "met")
    evidence = [line for child in children for line in child["evidence"]]
    if state == "met":
        early = all(child["early"] for child in children)
        score = min(child["score"] for child in children)
        return _result("met", evidence, early=early, score=score, details=_merged_details(children))
    missing = [hint for child in children for hint in child["missing"]]
    score = min(child["score"] for child in children) if state == "weak" else 0.0
    return _result(state, evidence, missing, score=score)


def _evaluate(expr: dict, context: _Context, node_id: str) -> dict:
    """Вычисляет выражение правила: одиночное условие либо вложенные группы «и» / «или»."""
    if "all" in expr:
        return _all([_evaluate(child, context, node_id) for child in expr["all"]])
    if "any" in expr:
        return _any([_evaluate(child, context, node_id) for child in expr["any"]])
    return LEAVES[expr["kind"]](expr, context, node_id)


def _collect_signs(expr: dict, found: set) -> None:
    """Собирает коды визуальных признаков, которые использует выражение правила."""
    for key in ("all", "any"):
        for child in expr.get(key, ()):
            _collect_signs(child, found)
    found.update(expr.get("signs", ()))


def _unique(items: list) -> list:
    """Убирает повторы, сохраняя порядок."""
    return list(dict.fromkeys(items))


def _fill(text: str, details: dict) -> str:
    """Подставляет в текст диагноза или рекомендации значения, собранные при проверке условий."""
    for key, value in details.items():
        text = text.replace("{" + key + "}", value)
    return text.strip()


def _texts(rule: dict, active: list, full: bool) -> tuple:
    """Выбирает статус, критичность и тексты находки по тому, какие части правила выполнены.

    Правило, выполненное только за счёт трендов, даёт раннее предупреждение, а не дефект.
    Возвращает также признак «сработала только камера»: от него зависит расчёт уверенности.
    """
    lone_camera = not full and all(part["source"] == "camera" for part, _ in active)
    if full:
        if all(result["early"] for _, result in active):
            return "check", 1, EARLY_DIAGNOSIS + rule["diagnosis"], EARLY_ADVICE + rule["recommendation"], False
        return rule.get("status", "defect"), rule["severity"], rule["diagnosis"], rule["recommendation"], False
    if lone_camera and all(result["state"] == "met" for _, result in active) and "camera_only" in rule:
        block = rule["camera_only"]
        return block["status"], block["severity"], block["diagnosis"], block["recommendation"], True
    if lone_camera and any(result["state"] == "weak" for _, result in active):
        return "check", 1, WEAK_DIAGNOSIS + rule["diagnosis"], WEAK_ADVICE, True
    block = rule.get("partial", {})
    diagnosis = block.get("diagnosis") or PARTIAL_DIAGNOSIS + rule["diagnosis"]
    recommendation = block.get("recommendation") or PARTIAL_ADVICE + rule["recommendation"]
    return "check", 1, diagnosis, recommendation, lone_camera


def _finding(rule: dict, context: _Context) -> dict | None:
    """Проверяет одно правило и возвращает находку, если выполнена хотя бы одна его определяющая часть.

    Уточняющие части (qualifier) сами находку не порождают: они только подтверждают диагноз.
    """
    node_id = context.node_for(rule)
    variants = rule.get("node_variants")
    if variants:
        attribute = context.nodes.get(node_id, {}).get(variants["attr"])
        rule = {**rule, **variants["values"].get(attribute, {})}
    parts = rule["parts"]
    results = [_evaluate(part["expr"], context, node_id) for part in parts]
    active = [
        (part, result)
        for part, result in zip(parts, results)
        if not part.get("qualifier") and result["state"] in ("met", "weak")
    ]
    if not active:
        return None
    full = all(result["state"] == "met" for result in results)
    status, severity, diagnosis, recommendation, lone_camera = _texts(rule, active, full)
    evidence = [line for result in results for line in result["evidence"]]
    escalation = rule.get("escalation")
    if escalation and full:
        extra = _evaluate(escalation["expr"], context, node_id)
        evidence.extend(extra["evidence"])
        if extra["state"] == "met":
            status, severity = escalation["status"], escalation["severity"]
            diagnosis, recommendation = escalation["diagnosis"], escalation["recommendation"]
    if lone_camera:
        confidence = max(result["score"] for _, result in active)
    else:
        confidence = sum(result["score"] for result in results if result["state"] in ("met", "weak")) / len(results)
    details = _merged_details(results)
    return {
        "rule_id": rule["id"],
        "title": rule["title"],
        "node_id": node_id,
        "status": status,
        "severity": severity,
        "diagnosis": _fill(diagnosis, details),
        "recommendation": _fill(recommendation, details),
        "confidence": round(confidence, 2),
        "evidence": evidence,
        "missing": _unique([hint for result in results if result["state"] != "met" for hint in result["missing"]]),
    }


def _visual_findings(rule: dict, context: _Context, consumed: set) -> list:
    """Строит находки по дефектным признакам, которые не входят ни в одно правило с датчиками.

    Так уверенный признак камеры или отметка инженера не теряются, даже если под них нет правила.
    """
    titles = context.document.get("signs", {})
    seen = {}
    for sign, confidence in context.visual.items():
        if sign in titles and sign not in consumed and confidence >= WEAK_CONFIDENCE:
            seen[sign] = ("camera", confidence)
    for token in sorted(context.manual):
        if token not in consumed and not token.startswith(CHECKED_PREFIX):
            seen[token] = ("manual", 1.0)
    findings = []
    for sign, (source, confidence) in seen.items():
        title = titles.get(sign, sign)
        strong = confidence >= STRONG_CONFIDENCE
        value = "подтверждено инженером" if source == "manual" else f"уверенность {confidence:.2f}"
        limit = None if source == "manual" else f">= {STRONG_CONFIDENCE}"
        diagnosis = rule["diagnosis"] if strong else WEAK_DIAGNOSIS + "{sign}"
        findings.append(
            {
                "rule_id": rule["id"],
                "title": title,
                "node_id": context.node_of_class(sign),
                "status": rule.get("status", "defect") if strong else "check",
                "severity": rule["severity"] if strong else 1,
                "diagnosis": _fill(diagnosis, {"sign": title[:1].lower() + title[1:]}),
                "recommendation": rule["recommendation"] if strong else WEAK_ADVICE,
                "confidence": round(confidence, 2),
                "evidence": [_evidence(source, title, value, limit, strong)],
                "missing": [] if strong else [f"подойдите ближе или покажите узел с другой стороны - слабый признак: {title}"],
            }
        )
    return findings


def _rank(status: str) -> int:
    """Возвращает вес статуса для выбора наихудшего."""
    return STATUS_RANK[status]


def _order(finding: dict) -> tuple:
    """Задаёт порядок находок: сначала дефекты, затем по критичности, уверенности и номеру правила."""
    return (-STATUS_RANK[finding["status"]], -finding["severity"], -finding["confidence"], finding["rule_id"])


def _node_states(context: _Context, findings: list) -> dict:
    """Сводит находки по узлам; узел без находок считается исправным на вид, только если его видели камера, датчики или инженер."""
    titles = context.document.get("signs", {})
    by_node = {}
    for finding in findings:
        by_node.setdefault(finding["node_id"], []).append(finding)
    states = {}
    for node_id in list(context.nodes) + [key for key in by_node if key not in context.nodes]:
        own = by_node.get(node_id)
        if own:
            status = max((finding["status"] for finding in own), key=_rank)
            reasons = [f"{finding['title']} ({finding['rule_id']})" for finding in own]
            states[node_id] = {"status": status, "reasons": reasons}
            continue
        node = context.nodes[node_id]
        reasons = []
        if CHECKED_PREFIX + node_id in context.manual:
            reasons.append("Проверено инженером: замечаний нет")
        classes = [cls for cls in node.get("classes") or [] if cls not in titles]
        if any(context.visual.get(cls, 0.0) >= STRONG_CONFIDENCE for cls in classes):
            reasons.append("Камера: видимых проблем не обнаружено")
        seen = bool(reasons)
        parameters = node.get("parameters") or []
        if parameters and all(code in context.readings for code in parameters):
            reasons.append("Датчики: отклонений по правилам не выявлено")
            if classes and not seen:
                reasons.append("Камерой узел не осмотрен")
        if reasons:
            states[node_id] = {"status": "ok", "reasons": reasons}
        else:
            states[node_id] = {"status": "unknown", "reasons": ["Узел не осмотрен камерой, данных датчиков по нему нет"]}
    return states


def diagnose(equipment: dict, readings: dict, trends: dict, visual: dict, manual=frozenset()) -> dict:
    """Определяет фактическое состояние агрегата по камере, датчикам, трендам и отметкам инженера.

    readings - текущие значения по кодам параметров; сюда же передаётся показание стрелочного
    манометра, считанное камерой (ключ gauge_reading, бар). trends - наклон за час по тем же кодам.
    visual - класс детектора и лучшая уверенность. manual - признаки, подтверждённые инженером
    вручную; отметка "checked:<узел>" означает, что узел осмотрен и признаков на нём нет.
    Возвращает общий статус, находки с основаниями и подсказками, состояние каждого узла.
    """
    document = _document()
    context = _Context(document, equipment, readings, trends, visual, manual)
    kind = equipment.get("type")
    rules = [rule for rule in document["rules"] if "*" in rule["applies_to"] or kind in rule["applies_to"]]
    consumed = set()
    for rule in rules:
        for part in rule["parts"]:
            _collect_signs(part["expr"], consumed)
    findings = []
    for rule in rules:
        if rule.get("group") == "visual":
            findings.extend(_visual_findings(rule, context, consumed))
            continue
        finding = _finding(rule, context)
        if finding:
            findings.append(finding)
    findings.sort(key=_order)
    if findings:
        status = max((finding["status"] for finding in findings), key=_rank)
    elif context.readings or context.visual or context.manual:
        status = "ok"
    else:
        status = "unknown"
    return {"status": status, "findings": findings, "nodes": _node_states(context, findings)}
