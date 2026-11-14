"""Чтение баз заказчика по вибрации и температуре насоса Н-101 без изменения значений."""
import unicodedata
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import openpyxl

CUSTOMER_DIR = Path(__file__).resolve().parents[2] / "data" / "customer"
VIBRATION_FILE = ("Вибрация", "БД значений (вибрация).xlsx")
TEMPERATURE_FILE = ("Температура", "БД значений (температура).xlsx")
TIME_COLUMN = "Дата и время"
RPM_COLUMN = "Обороты (об/мин)"
VIBRATION_COLUMNS = {
    "СКЗ общее (мм/с)": "vib_rms",
    "Ампл. 1x (мм/с)": "vib_1x",
    "Ампл. 2x (мм/с)": "vib_2x",
    "ВЧ шум (g)": "vib_hf",
}
VIBRATION_LABEL_COLUMN = "Диагноз по вибрации"
TEMPERATURE_COLUMNS = {
    "Темп. подшипника насоса (°C)": "temp_bearing",
    "Темп. обмоток ЭД (°C)": "temp_winding",
}
TEMPERATURE_LABEL_COLUMN = "Диагноз по температуре"
TIME_FORMAT = "%Y-%m-%d %H:%M"
CUSTOMER_CODES = ("rpm", "vib_rms", "vib_1x", "vib_2x", "vib_hf", "temp_bearing", "temp_winding")
LABEL_KINDS = ("vibration", "temperature")
NORMAL_LABEL = "Норма"
CUSTOMER_THRESHOLDS = {
    "vib_1x": (2.8, 4.5),
    "vib_2x": (1.8, 3.0),
    "vib_hf": (2.5, 5.0),
    "temp_bearing": (75.0, 90.0),
    "temp_winding": (90.0, 110.0),
}


class TelemetryDataError(RuntimeError):
    """Базы заказчика отсутствуют или не соответствуют ожидаемому формату."""


@dataclass(frozen=True)
class CustomerRow:
    """Одна часовая запись заказчика: время, значения датчиков и два текстовых диагноза."""

    at: datetime
    values: dict[str, float]
    labels: dict[str, str]


def load_customer(base_dir: Path | None = None) -> list[CustomerRow]:
    """Читает обе базы заказчика и объединяет их по времени записи.

    Значения возвращаются в том виде, в каком лежат в файлах. Если файла нет, столбцы не совпадают
    или базы расходятся по времени либо оборотам, возникает TelemetryDataError с пояснением.
    """
    base = Path(base_dir) if base_dir is not None else CUSTOMER_DIR
    vibration = _read_table(_locate(base, VIBRATION_FILE), VIBRATION_COLUMNS, VIBRATION_LABEL_COLUMN)
    temperature = _read_table(_locate(base, TEMPERATURE_FILE), TEMPERATURE_COLUMNS, TEMPERATURE_LABEL_COLUMN)
    if vibration.keys() != temperature.keys():
        raise TelemetryDataError("Базы вибрации и температуры содержат разные отметки времени")
    rows = []
    for at in sorted(vibration):
        vib_values, vib_label = vibration[at]
        temp_values, temp_label = temperature[at]
        if vib_values["rpm"] != temp_values["rpm"]:
            raise TelemetryDataError(f"Обороты в базах вибрации и температуры расходятся на {at:{TIME_FORMAT}}")
        rows.append(CustomerRow(at, {**vib_values, **temp_values}, {"vibration": vib_label, "temperature": temp_label}))
    return rows


def _locate(base: Path, parts: tuple[str, ...]) -> Path:
    """Находит файл по частям пути, сравнивая имена без учёта формы записи букв Юникода."""
    path = base
    for part in parts:
        wanted = unicodedata.normalize("NFC", part)
        entries = sorted(path.iterdir()) if path.is_dir() else []
        match = next((entry for entry in entries if unicodedata.normalize("NFC", entry.name) == wanted), None)
        if match is None:
            raise TelemetryDataError(
                f"Не найдена база заказчика: {base.joinpath(*parts)}. Поместите файлы заказчика в папку {base}"
            )
        path = match
    return path


def _read_table(path: Path, columns: dict[str, str], label_column: str) -> dict[datetime, tuple[dict[str, float], str]]:
    """Читает первый лист базы: время, обороты, перечисленные столбцы значений и столбец диагноза."""
    workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
    try:
        lines = workbook.worksheets[0].iter_rows(values_only=True)
        header = [str(cell).strip() if cell is not None else "" for cell in next(lines, ())]
        wanted = {TIME_COLUMN: "at", RPM_COLUMN: "rpm", **columns, label_column: "label"}
        missing = [name for name in wanted if name not in header]
        if missing:
            raise TelemetryDataError(f"В файле {path.name} нет столбцов: {', '.join(missing)}")
        position = {field: header.index(name) for name, field in wanted.items()}
        table = {}
        for number, line in enumerate(lines, start=2):
            if all(cell is None for cell in line):
                continue
            cells = {field: line[index] if index < len(line) else None for field, index in position.items()}
            at = _parse_time(cells["at"], path, number)
            if at in table:
                raise TelemetryDataError(f"В файле {path.name} время {at:{TIME_FORMAT}} повторяется (строка {number})")
            values = {field: _number(cells[field], path, number) for field in ("rpm", *columns.values())}
            table[at] = (values, str(cells["label"] or "").strip())
    finally:
        workbook.close()
    if not table:
        raise TelemetryDataError(f"В файле {path.name} нет строк с данными")
    return table


def _parse_time(cell: object, path: Path, number: int) -> datetime:
    """Преобразует ячейку времени в datetime: принимает дату Excel или текст вида 2026-11-10 08:00."""
    if isinstance(cell, datetime):
        return cell
    try:
        return datetime.strptime(str(cell).strip(), TIME_FORMAT)
    except ValueError:
        raise TelemetryDataError(f"В файле {path.name}, строка {number}: не удалось разобрать время {cell!r}") from None


def _number(cell: object, path: Path, number: int) -> float:
    """Проверяет, что в ячейке число, и возвращает его без изменений."""
    if isinstance(cell, bool) or not isinstance(cell, (int, float)):
        raise TelemetryDataError(f"В файле {path.name}, строка {number}: ожидалось число, получено {cell!r}")
    return cell
