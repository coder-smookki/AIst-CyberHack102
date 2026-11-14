"""Проигрыватель телеметрии: лента значений с курсором времени, окнами, трендами и сценариями."""
import json
import math
import threading
from bisect import bisect_right
from datetime import datetime, timedelta
from pathlib import Path

from server.telemetry import synth
from server.telemetry.loader import (
    CUSTOMER_CODES, CUSTOMER_THRESHOLDS, LABEL_KINDS, TelemetryDataError, load_customer,
)
from server.telemetry.synth import CODES, PumpModel, Timeline, build_timeline

EQUIPMENT_FILE = Path(__file__).resolve().parents[2] / "data" / "equipment.json"
CUSTOMER_UNIT = "N-101"
MIN_TREND_POINTS = 4
HOUR = timedelta(hours=1)
VIBRATION_BASIS = "Уставки заказчика (описание базы вибрации)"
TEMPERATURE_BASIS = "Уставки заказчика (описание базы температуры)"
CURRENT_BASIS = "Принято командой: 105 % и 120 % номинального тока двигателя"


def parameter_catalogue(model: PumpModel) -> list[dict]:
    """Возвращает описание всех параметров: название, единицу, уставки, их направление и обоснование.

    direction "high" - отклонением считается значение выше уставки, "low" - ниже уставки, None -
    уставок нет. baseline - уровень нормального режима. Уставки, которых нет в документах заказчика,
    помечены в basis как принятые командой.
    """
    base = synth.BASELINE
    rms = math.sqrt(base["vib_1x"][0] ** 2 + base["vib_2x"][0] ** 2 + synth.RMS_FLOOR ** 2)
    rms += synth.RMS_HF_SHARE * base["vib_hf"][0]
    discharge = synth.PRESS_IN_BASE + model.pressure_rise_bar
    efficiency = model.nominal_efficiency
    current = (
        round(model.rated_current_a * synth.CURRENT_WARN_RATIO, 2),
        round(model.rated_current_a * synth.CURRENT_ALARM_RATIO, 2),
        "high", model.rated_current_a, CURRENT_BASIS,
    )
    vibration = (synth.VIBRATION_WARN, synth.VIBRATION_ALARM, "high")
    entries = (
        ("rpm", "Частота вращения", "об/мин", None, None, None, base["rpm"][0], None),
        ("vib_rms", "СКЗ виброскорости общее", "мм/с", *vibration, rms,
         "Принято командой: как уставки заказчика для амплитуды 1x"),
        ("vib_1x", "Амплитуда вибрации 1x", "мм/с", *CUSTOMER_THRESHOLDS["vib_1x"], "high", base["vib_1x"][0],
         VIBRATION_BASIS),
        ("vib_2x", "Амплитуда вибрации 2x", "мм/с", *CUSTOMER_THRESHOLDS["vib_2x"], "high", base["vib_2x"][0],
         VIBRATION_BASIS),
        ("vib_hf", "ВЧ шум", "g", *CUSTOMER_THRESHOLDS["vib_hf"], "high", base["vib_hf"][0],
         "Предупреждение - из описания базы вибрации, тревога 5,0 g восстановлена по диагнозам в базе"),
        ("vib_axial", "Осевая вибрация на муфте", "мм/с", *vibration, base["vib_axial"][0],
         "Принято командой: как для общего уровня виброскорости"),
        ("temp_bearing", "Температура подшипника насоса", "°C", *CUSTOMER_THRESHOLDS["temp_bearing"], "high",
         base["temp_bearing"][0], TEMPERATURE_BASIS),
        ("temp_winding", "Температура обмоток двигателя", "°C", *CUSTOMER_THRESHOLDS["temp_winding"], "high",
         base["temp_winding"][0], TEMPERATURE_BASIS),
        ("current_a", "Ток фазы A", "А", *current),
        ("current_b", "Ток фазы B", "А", *current),
        ("current_c", "Ток фазы C", "А", *current),
        ("current_unbalance", "Небаланс токов по фазам", "%", synth.UNBALANCE_WARN, synth.UNBALANCE_ALARM, "high",
         synth.UNBALANCE_BASE, "Предупреждение - порог заказчика 5 % (правило 4), тревога 10 % принята командой"),
        ("press_in", "Давление на входе", "бар", synth.PRESS_IN_WARN, synth.PRESS_IN_ALARM, "low",
         synth.PRESS_IN_BASE, "Принято командой: предупреждение ниже 1,0 бар, тревога ниже 0,5 бар"),
        ("press_out", "Давление нагнетания, электронный датчик", "бар", None, None, None, discharge, None),
        ("press_out_true", "Давление нагнетания, стрелочный манометр", "бар", None, None, None, discharge, None),
        ("flow", "Подача", "м³/ч", None, None, None, model.flow_m3h, None),
        ("power", "Потребляемая мощность насоса", "кВт", None, None, None, model.power_kw, None),
        ("efficiency", "КПД насоса", "%", round(efficiency * (1 - synth.EFFICIENCY_DROP_WARN), 2),
         round(efficiency * (1 - synth.EFFICIENCY_DROP_ALARM), 2), "low", efficiency,
         "Предупреждение - падение на 15 % от паспортного КПД (правило 10), тревога - на 20 %, принята командой"),
        ("run_hours", "Наработка", "ч", None, None, None, None, None),
        ("mode", "Режим работы (1 - в работе, 0 - остановлен)", "", None, None, None, None, None),
    )
    keys = ("code", "name", "unit", "warn", "alarm", "direction", "baseline", "basis")
    catalogue = [dict(zip(keys, entry)) for entry in entries]
    for item in catalogue:
        if item["baseline"] is not None:
            item["baseline"] = round(item["baseline"], 2)
    return catalogue


class TelemetryPlayer:
    """Лента телеметрии одного агрегата с курсором времени.

    Курсор задаёт "текущий момент" для всего сервера: снимок, окна и тренды по умолчанию берутся на
    него. Время - местное, без часового пояса, как в базах заказчика.
    """

    def __init__(self, equipment_id: str, timeline: Timeline, model: PumpModel):
        """Принимает готовую ленту и ставит курсор на опорный сценарий "нормальный режим"."""
        self.equipment_id = equipment_id
        self._timeline = timeline
        self._catalogue = parameter_catalogue(model)
        self._scenarios = {item["id"]: item for item in timeline.scenarios}
        normal = self._scenarios.get("normal")
        self._cursor = normal["peak"] if normal else timeline.times[0]

    @property
    def cursor(self) -> datetime:
        """Текущий момент ленты."""
        return self._cursor

    def set_cursor(self, at: datetime) -> None:
        """Переставляет курсор; момент вне записи отклоняется с ValueError."""
        moment = self._moment(at)
        first, last = self.bounds()
        if not first <= moment <= last:
            raise ValueError(f"Время вне записи телеметрии: доступно с {first:%d.%m.%Y %H:%M} по {last:%d.%m.%Y %H:%M}")
        self._cursor = moment

    def bounds(self) -> tuple[datetime, datetime]:
        """Возвращает время первой и последней записи ленты."""
        return self._timeline.times[0], self._timeline.times[-1]

    def customer_bounds(self) -> tuple[datetime, datetime]:
        """Возвращает время первой и последней записи из баз заказчика; после неё все значения модельные."""
        return self._timeline.times[0], self._timeline.times[self._timeline.customer_count - 1]

    def parameters(self, at: datetime | None = None) -> list[dict]:
        """Возвращает описание параметров; source показывает происхождение значения в записи на момент at.

        "customer" - значение взято из баз заказчика, "model" - рассчитано моделью. Для семи параметров
        заказчика источник становится "model" на часах после окончания его баз.
        """
        index = self._index(self._moment(at))
        return [dict(item, source=self._source(item["code"], index)) for item in self._catalogue]

    def source(self, code: str, at: datetime | None = None) -> str:
        """Возвращает происхождение значения параметра в записи на момент at: "customer" или "model"."""
        self._check_code(code)
        return self._source(code, self._index(self._moment(at)))

    def snapshot(self, at: datetime | None = None) -> dict[str, float]:
        """Возвращает значения всех параметров из последней записи не позже at (по умолчанию - курсора).

        Если записей до этого момента нет, возвращает пустой словарь.
        """
        index = self._index(self._moment(at))
        if index < 0:
            return {}
        return {code: float(self._timeline.series[code][index]) for code in CODES}

    def window(self, code: str, hours: float = 24, at: datetime | None = None) -> list[tuple[datetime, float]]:
        """Возвращает точки параметра за последние hours часов: время записи больше at - hours и не больше at."""
        self._check_code(code)
        if hours <= 0:
            raise ValueError("Длина окна должна быть больше нуля часов")
        moment = self._moment(at)
        times = self._timeline.times
        values = self._timeline.series[code]
        low = bisect_right(times, moment - timedelta(hours=hours))
        high = bisect_right(times, moment)
        return [(times[index], float(values[index])) for index in range(low, high)]

    def trend(self, code: str, hours: float = 12, at: datetime | None = None) -> float | None:
        """Возвращает наклон параметра за окно по методу наименьших квадратов, единиц в час.

        Если в окне меньше четырёх точек, тренд не оценивается и возвращается None.
        """
        points = self.window(code, hours, at)
        if len(points) < MIN_TREND_POINTS:
            return None
        origin = points[0][0]
        offsets = [(moment - origin) / HOUR for moment, _ in points]
        mean_offset = sum(offsets) / len(offsets)
        mean_value = sum(value for _, value in points) / len(points)
        spread = sum((offset - mean_offset) ** 2 for offset in offsets)
        if spread == 0:
            return None
        return sum((offset - mean_offset) * (value - mean_value) for offset, (_, value) in zip(offsets, points)) / spread

    def scenarios(self) -> list[dict]:
        """Возвращает сценарии демонстрации: эпизоды неисправностей и опорные точки без неисправностей."""
        return [dict(item, expected_rules=list(item["expected_rules"])) for item in self._timeline.scenarios]

    def select_scenario(self, scenario_id: str) -> dict:
        """Ставит курсор на час наибольшего отклонения сценария и возвращает его описание."""
        if scenario_id not in self._scenarios:
            raise KeyError(f"Сценарий {scenario_id} не найден")
        item = self._scenarios[scenario_id]
        self._cursor = item["peak"]
        return dict(item, expected_rules=list(item["expected_rules"]))

    def customer_label(self, kind: str, at: datetime | None = None) -> str:
        """Возвращает диагноз заказчика из его базы для записи на момент at.

        kind - "vibration" или "temperature". Для часов, которых нет в базах заказчика, возвращает
        пустую строку: диагноза заказчика для них не существует.
        """
        if kind not in LABEL_KINDS:
            raise ValueError("Вид диагноза должен быть vibration или temperature")
        index = self._index(self._moment(at))
        if not 0 <= index < self._timeline.customer_count:
            return ""
        return self._timeline.labels[kind][index]

    def _moment(self, at: datetime | None) -> datetime:
        """Приводит момент к времени ленты: None заменяется курсором, часовой пояс отбрасывается."""
        if at is None:
            return self._cursor
        if not isinstance(at, datetime):
            raise TypeError("Момент времени должен быть значением datetime")
        return at.replace(tzinfo=None)

    def _index(self, moment: datetime) -> int:
        """Возвращает номер последней записи не позже момента или -1, если таких записей нет."""
        return bisect_right(self._timeline.times, moment) - 1

    def _source(self, code: str, index: int) -> str:
        """Определяет происхождение значения: из баз заказчика только их семь параметров на их часах."""
        return "customer" if code in CUSTOMER_CODES and index < self._timeline.customer_count else "model"

    def _check_code(self, code: str) -> None:
        """Отклоняет неизвестный код параметра."""
        if code not in self._timeline.series:
            raise KeyError(f"Неизвестный параметр телеметрии: {code}")


def build_player(equipment_id: str, customer_dir: Path | None = None) -> TelemetryPlayer:
    """Строит новый проигрыватель: читает карточку агрегата и базы заказчика, досоздаёт модельные ряды.

    Для агрегата без телеметрии возникает KeyError, при отсутствии или порче баз - TelemetryDataError.
    """
    if equipment_id != CUSTOMER_UNIT:
        raise KeyError(f"Для оборудования {equipment_id} нет телеметрии")
    card = _equipment_card(equipment_id)
    model = PumpModel.from_specs(card["specs"])
    due = min((item["last_at_hours"] + item["interval_hours"] for item in card.get("maintenance", [])), default=None)
    timeline = build_timeline(load_customer(customer_dir), model, card["run_hours"], due)
    return TelemetryPlayer(equipment_id, timeline, model)


_players: dict[str, TelemetryPlayer] = {}
_players_lock = threading.Lock()


def get_player(equipment_id: str) -> TelemetryPlayer:
    """Возвращает общий для сервера проигрыватель агрегата; строит его при первом обращении."""
    with _players_lock:
        if equipment_id not in _players:
            _players[equipment_id] = build_player(equipment_id)
        return _players[equipment_id]


def _equipment_card(equipment_id: str) -> dict:
    """Читает карточку агрегата из data/equipment.json."""
    try:
        with open(EQUIPMENT_FILE, encoding="utf-8") as file:
            cards = json.load(file)["equipment"]
    except FileNotFoundError:
        raise TelemetryDataError(f"Не найден файл карточек оборудования: {EQUIPMENT_FILE}") from None
    for card in cards:
        if card["id"] == equipment_id:
            return card
    raise KeyError(f"Оборудование {equipment_id} не найдено в карточках")
