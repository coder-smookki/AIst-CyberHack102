"""Справочник правил диагностики и проверка одного правила для агрегата прямо сейчас.

GET /rules - перечень правил из data/rules.json в виде, удобном для справочника приложения: что видит камера,
какие параметры и пороги нужны датчикам, что правило даёт и откуда оно. GET /equipment/{id}/rules/{rule_id} -
разбор одного правила для агрегата на текущий момент ленты телеметрии (с номером осмотра - ещё и с отметками
инженера этого осмотра): применимость, состояние, каждое условие со значением и порогом, основания, рекомендация.
Чтение требует права «Просмотр оборудования» или «Просмотр замечаний».
"""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from server.auth import require_permission
from server.db import get_session
from server.equipment import equipment_card, get_equipment
from server.inspections import get_inspection
from server.inspections.service import SEVERITY_TITLES, WHOLE_UNIT, diagnosis_inputs
from server.rules import defect_signs, explain_rule, load_rules, parameter_meta
from server.telemetry_api import feed_for, node_names, stamp

READ = require_permission("equipment.view", "findings.view", any_of=True)
GROUP_TITLES = {
    "customer": "Правило заказчика",
    "threshold": "Уставка заказчика",
    "visual": "Визуальный признак",
    "sound": "Признак по звуку",
    "demo": "Демонстрационное правило",
}
GROUP_SOURCES = {
    "customer": "12 правил диагностики заказчика (КСТ Энерго Инжиниринг)",
    "threshold": "Уставки из баз значений вибрации и температуры заказчика",
    "visual": "Общее правило для дефектных признаков камеры и отметок инженера без своего правила",
    "sound": "Анализ записи звука микрофоном телефона с подтверждением инженером",
    "demo": "Демонстрационные пороги и формулировки: уточнить по паспорту оборудования",
}
UNCHECKED_TITLE = "Сработавших условий нет, часть условий не проверена - недостаточно данных"
RULE_STATUS_TITLES = {
    "defect": "Правило сработало: признаки возможного дефекта",
    "check": "Правило выполнено частично: рекомендуется проверка",
    "ok": "Условия правила не выполнены",
    "unknown": "Недостаточно данных для проверки правила",
    "not_applicable": "Правило не применяется к этому оборудованию",
}
PART_TITLES = {"camera": "Камера", "sensor": "Датчики", "resource": "Ресурс", "manual": "Инженер", "sound": "Звук"}
KIND_TITLES = {
    "threshold": "порог",
    "trend": "тренд",
    "sign": "признак",
    "label": "диагноз по уставкам",
    "maintenance": "межремонтный интервал",
}

router = APIRouter(tags=["rules"], dependencies=[Depends(READ)])


def _leaves(expr: dict, found: list) -> None:
    """Собирает одиночные условия выражения правила по порядку."""
    for key in ("all", "any"):
        for child in expr.get(key, ()):
            _leaves(child, found)
    if "kind" in expr:
        found.append(expr)


def _condition(leaf: dict, part: dict, parameters: dict, escalation: bool = False) -> dict:
    """Описывает условие правила для справочника: параметр, сравнение, порог и единица измерения."""
    meta = parameters.get(leaf.get("param")) or {}
    unit = meta.get("unit", "")
    if leaf["kind"] == "trend":
        unit = f"{unit}/ч" if unit else "/ч"
    return {
        "kind": leaf["kind"],
        "kind_title": KIND_TITLES.get(leaf["kind"], leaf["kind"]),
        "source": leaf.get("source") or part["source"],
        "qualifier": bool(part.get("qualifier")),
        "escalation": escalation,
        "param": leaf.get("param"),
        "name": leaf.get("what") or meta.get("name"),
        "op": leaf.get("op"),
        "value": leaf.get("value"),
        "unit": unit or None,
        "label": leaf.get("label"),
        "equals": leaf.get("equals"),
    }


def _sign_list(codes: list[str], titles: dict) -> list[dict]:
    """Признаки с кодами и русскими названиями без повторов."""
    return [{"code": code, "title": titles.get(code, code)} for code in dict.fromkeys(codes)]


def rule_item(rule: dict, titles: dict, parameters: dict) -> dict:
    """Одна запись справочника правил: поля data/rules.json, разложенные по камере, датчикам и итогу.

    titles - русские названия признаков, parameters - названия и единицы параметров.
    """
    camera_signs, manual_signs, sound_signs, sensor = [], [], [], []
    for part in rule["parts"]:
        leaves = []
        _leaves(part["expr"], leaves)
        for leaf in leaves:
            if leaf["kind"] == "sign":
                if part["source"] == "sound":
                    target = sound_signs
                else:
                    target = manual_signs if leaf.get("source") == "manual" else camera_signs
                target.extend(leaf["signs"])
            else:
                sensor.append(_condition(leaf, part, parameters))
    escalation = rule.get("escalation")
    if escalation:
        leaves = []
        _leaves(escalation["expr"], leaves)
        sensor.extend(_condition(leaf, {"source": "sensor"}, parameters, escalation=True) for leaf in leaves)
    visual = rule.get("group") == "visual"
    variants = []
    for name in ("camera_only", "partial"):
        block = rule.get(name)
        if block:
            variants.append(
                {
                    "when": name,
                    "status": block.get("status", "check"),
                    "severity": block.get("severity", 1),
                    "diagnosis": block.get("diagnosis"),
                    "recommendation": block.get("recommendation"),
                }
            )
    if escalation:
        variants.append(
            {
                "when": "escalation",
                "status": escalation["status"],
                "severity": escalation["severity"],
                "diagnosis": escalation["diagnosis"],
                "recommendation": escalation["recommendation"],
            }
        )
    group = rule.get("group")
    return {
        "id": rule["id"],
        "title": rule["title"],
        "group": group,
        "group_title": GROUP_TITLES.get(group, group),
        "applies_to": list(rule["applies_to"]),
        "node": rule["node"],
        "node_fallbacks": list(rule.get("node_fallbacks") or []),
        "camera": {
            "text": rule.get("camera_text"),
            "signs": _sign_list(camera_signs, titles),
            "manual_signs": _sign_list(manual_signs, titles),
            "any_defect_sign": visual,
        },
        "sensor": {"text": rule.get("sensor_text"), "conditions": sensor},
        "sound": {"signs": _sign_list(sound_signs, titles)},
        "status": {
            "status": rule.get("status", "defect"),
            "status_title": RULE_STATUS_TITLES.get(rule.get("status", "defect")),
            "diagnosis": rule["diagnosis"],
            "variants": variants,
        },
        "severity": rule["severity"],
        "severity_title": SEVERITY_TITLES.get(rule["severity"]),
        "recommendation": rule["recommendation"],
        "source": {
            "group": group,
            "title": rule.get("source_note") or GROUP_SOURCES.get(group, group),
            "customer": group == "customer",
            "thresholds": group == "threshold",
            "visual": visual,
            "demo": group == "demo",
        },
    }


@router.get("/rules")
def rules() -> list[dict]:
    """Справочник правил диагностики: по одной записи на правило из data/rules.json."""
    titles, parameters = defect_signs(), parameter_meta()
    return [rule_item(rule, titles, parameters) for rule in load_rules()]


@router.get("/equipment/{equipment_id}/rules/{rule_id}")
def evaluate(
    equipment_id: str,
    rule_id: str,
    session: Annotated[Session, Depends(get_session)],
    inspection_id: Annotated[int | None, Query(ge=1)] = None,
) -> dict:
    """Проверка одного правила для агрегата сейчас - сработало оно или нет - с разбором по условиям.

    Без inspection_id учитываются датчики и ресурс на текущий момент ленты. С номером осмотра этого агрегата -
    ещё отметки инженера (подтверждённые признаки, проверенные узлы), а у идущего осмотра также показание
    манометра и узлы, увиденные камерой. Отклонённые находки не учитываются. Неизвестный агрегат или правило - 404.
    """
    item = get_equipment(session, equipment_id)
    rule = next((entry for entry in load_rules() if entry["id"] == rule_id), None)
    if rule is None:
        raise HTTPException(status_code=404, detail="Правило не найдено")
    feed = feed_for(item.id)
    if inspection_id is None:
        card, readings, trends, visual, marks = equipment_card(item), feed.readings, feed.trends, {}, set()
    else:
        inspection = get_inspection(session, inspection_id)
        if inspection.equipment_id != item.id:
            raise HTTPException(status_code=422, detail="Осмотр относится к другому оборудованию")
        inputs = diagnosis_inputs(session, inspection)
        card, readings, trends = inputs["card"], inputs["readings"], inputs["trends"]
        visual, marks = inputs["visual"], inputs["marks"]
    result = explain_rule(card, readings, trends, visual, marks, rule_id)
    names = node_names(item)
    signs = defect_signs()
    confirmed = sorted(mark for mark in marks if mark in signs)
    for part in result["parts"]:
        part["source_title"] = PART_TITLES.get(part["source"], part["source"])
    for condition in result["conditions"]:
        condition["source_title"] = PART_TITLES.get(condition["source"], condition["source"])
    return {
        "equipment_id": item.id,
        "rule_id": rule["id"],
        "title": rule["title"],
        "group": rule.get("group"),
        "group_title": GROUP_TITLES.get(rule.get("group")),
        "inspection_id": inspection_id,
        "at": stamp(feed.at),
        "telemetry": feed.player is not None,
        "telemetry_reason": feed.reason,
        "confirmed_signs": [{"code": code, "title": signs[code]} for code in confirmed],
        **result,
        "node_name": names.get(result["node_id"], WHOLE_UNIT),
        "status_title": (
            UNCHECKED_TITLE
            if result["status"] == "unknown" and any(part["state"] == "unmet" for part in result["parts"])
            else RULE_STATUS_TITLES[result["status"]]
        ),
        "severity_title": SEVERITY_TITLES.get(result["severity"]) if result["severity"] else None,
        "camera_text": rule.get("camera_text"),
        "sensor_text": rule.get("sensor_text"),
    }
