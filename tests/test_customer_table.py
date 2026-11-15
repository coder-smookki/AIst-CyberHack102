"""Сверка правил диагностики со всеми строками таблиц заказчика по вибрации и температуре.

Каждая строка обеих баз прогоняется через настоящий движок правил (data/rules.json, правила уставок S01-S05):
по сработавшим правилам выводится диагноз в формулировке заказчика и сравнивается с его колонкой диагноза.
Без файлов заказчика (data/customer не входит в репозиторий) проверка пропускается.
"""

import pytest

from server.rules import CUSTOMER_THRESHOLDS, NORMAL_LABEL, diagnose, load_rules
from server.telemetry import loader
from test_rules import _pump


@pytest.fixture(scope="module")
def customer_rows():
    """Строки обеих баз заказчика, объединённые по времени; без файлов - пропуск."""
    try:
        rows = loader.load_customer()
    except loader.TelemetryDataError as error:
        pytest.skip(f"нет баз заказчика: {type(error).__name__}")
    if not rows:
        pytest.skip("базы заказчика пусты")
    return rows


def _threshold_rules() -> dict[str, str]:
    """Правило уставки для каждого параметра: код параметра -> номер правила."""
    return {rule["parts"][0]["expr"]["param"]: rule["id"] for rule in load_rules() if rule.get("group") == "threshold"}


def _label_from_engine(findings: list[dict], kind: str, by_param: dict[str, str]) -> tuple[str, dict | None]:
    """Диагноз заказчика, выведенный из находок движка: тревоги раньше предупреждений, в порядке таблицы уставок."""
    by_rule = {finding["rule_id"]: finding for finding in findings}
    rows = [row for row in CUSTOMER_THRESHOLDS if row["kind"] == kind]
    for status, level in (("defect", "alarm_label"), ("check", "warn_label")):
        for row in rows:
            finding = by_rule.get(by_param[row["code"]])
            if finding and finding["status"] == status:
                return row[level], finding
    return NORMAL_LABEL, None


def test_rules_reproduce_every_customer_row(customer_rows):
    """Движок правил даёт диагноз заказчика на каждой строке обеих баз, а текст находки цитирует этот диагноз."""
    by_param = _threshold_rules()
    assert set(by_param) == {row["code"] for row in CUSTOMER_THRESHOLDS}
    pump, checked, wrong = _pump(), 0, []
    for row in customer_rows:
        result = diagnose(pump, dict(row.values), {}, {})
        for kind in ("vibration", "temperature"):
            label, finding = _label_from_engine(result["findings"], kind, by_param)
            checked += 1
            if label != row.labels[kind] or (finding and f"«{label}»" not in finding["diagnosis"]):
                wrong.append((row.at.isoformat(), kind, row.labels[kind], label))
    assert checked == 2 * len(customer_rows)
    assert wrong == [], wrong[:10]


def test_every_customer_label_is_reachable(customer_rows):
    """Все формулировки диагнозов, встречающиеся в базах, известны правилам; лишних нет."""
    seen = {row.labels[kind] for row in customer_rows for kind in ("vibration", "temperature")}
    known = {NORMAL_LABEL} | {row[key] for row in CUSTOMER_THRESHOLDS for key in ("warn_label", "alarm_label")}
    assert seen <= known and NORMAL_LABEL in seen
