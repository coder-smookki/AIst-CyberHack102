"""Осмотры оборудования: полнота обхода, фиксация результатов, замечания и отчёты."""
from server.inspections.coverage import CoverageTracker, static_priority
from server.inspections.router import router
from server.inspections.service import (
    can_edit,
    current_diagnosis,
    get_inspection,
    node_priority,
    node_route,
    note_gauge_reading,
    report_data,
    tracker_for,
)

__all__ = [
    "CoverageTracker",
    "can_edit",
    "current_diagnosis",
    "get_inspection",
    "node_priority",
    "node_route",
    "note_gauge_reading",
    "report_data",
    "router",
    "static_priority",
    "tracker_for",
]
