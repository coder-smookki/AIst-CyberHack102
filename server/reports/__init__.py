"""Отчёты об осмотре оборудования в форматах PDF и Excel."""

from server.reports.pdf import build_pdf, build_story
from server.reports.xlsx import build_xlsx

__all__ = ["build_pdf", "build_story", "build_xlsx"]
