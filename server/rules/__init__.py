"""Правила диагностики, уставки заказчика, оценка ресурса и прогноз времени до уставки."""
from .engine import (
    EQUIPMENT_NODE,
    GAUGE_READING,
    STRONG_CONFIDENCE,
    WEAK_CONFIDENCE,
    defect_signs,
    diagnose,
    explain_rule,
    gauge_difference_percent,
    load_rules,
    parameter_meta,
)
from .forecast import hours_to_threshold
from .resource import accrue_hours, maintenance_intervals, resource_estimates
from .thresholds import (
    CUSTOMER_THRESHOLDS,
    NO_DATA_LABEL,
    NORMAL_LABEL,
    parameter_level,
    temperature_label,
    vibration_label,
)

__all__ = [
    "CUSTOMER_THRESHOLDS",
    "EQUIPMENT_NODE",
    "GAUGE_READING",
    "NORMAL_LABEL",
    "NO_DATA_LABEL",
    "STRONG_CONFIDENCE",
    "WEAK_CONFIDENCE",
    "accrue_hours",
    "defect_signs",
    "diagnose",
    "explain_rule",
    "gauge_difference_percent",
    "hours_to_threshold",
    "load_rules",
    "maintenance_intervals",
    "parameter_meta",
    "parameter_level",
    "resource_estimates",
    "temperature_label",
    "vibration_label",
]
