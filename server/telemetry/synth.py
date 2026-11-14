"""Модельные ряды насоса Н-101: недостающие параметры на часах баз заказчика и модельные сутки после них.

Значения заказчика здесь не меняются. Всё рассчитанное в этом модуле считается модельным и
получает источник "model". Шум детерминирован: у каждого ряда свой генератор с постоянным зерном.
"""
import math
import random
from dataclasses import dataclass
from datetime import datetime, timedelta

from server.telemetry.loader import CUSTOMER_THRESHOLDS, LABEL_KINDS, CustomerRow

CODES = (
    "rpm", "vib_rms", "vib_1x", "vib_2x", "vib_hf", "vib_axial", "temp_bearing", "temp_winding",
    "current_a", "current_b", "current_c", "current_unbalance", "press_in", "press_out", "press_out_true",
    "flow", "power", "efficiency", "run_hours", "mode",
)
PHASE_CODES = ("current_a", "current_b", "current_c")
SEED = 102
STEP = timedelta(hours=1)
TIMELINE_END = datetime(2026, 12, 6, 23, 0)

RHO = 1000.0
G = 9.80665
PASCAL_PER_BAR = 1.0e5
REFERENCE_RPM = 2950.0

BASELINE = {
    "rpm": (2950.0, 9.3),
    "vib_1x": (0.80, 0.049),
    "vib_2x": (0.30, 0.050),
    "vib_hf": (0.105, 0.052),
    "temp_bearing": (50.0, 0.98),
    "temp_winding": (64.8, 0.90),
    "vib_axial": (0.45, 0.04),
}
RMS_FLOOR = 0.5
RMS_HF_SHARE = 0.2

PRESS_IN_BASE = 1.5
PRESS_IN_MIN = 0.4
PRESS_IN_WARN = 1.0
PRESS_IN_ALARM = 0.5
CAVITATION_INCEPTION = 1.3
CAVITATION_HF_RISE = 3.75
CAVITATION_BROADBAND = 1.3
CAVITATION_FLOW_LOSS = 0.015

UNBALANCE_BASE = 0.6
UNBALANCE_PEAK = 8.5
UNBALANCE_WARN = 5.0
UNBALANCE_ALARM = 10.0
PHASE_PATTERN = (-1.0, 0.56, 0.44)

MISALIGNMENT_LOAD = ((0.0, 0.0), (0.374, 0.05), (1.0, 0.075))
MISALIGNMENT_AXIAL = 4.4
VIBRATION_WARN = 2.8
VIBRATION_ALARM = 4.5
CURRENT_WARN_RATIO = 1.05
CURRENT_ALARM_RATIO = 1.20

WEAR_EFFICIENCY_DROP = ((0.0, 0.0), (0.4, 0.155), (1.0, 0.168))
EFFICIENCY_DROP_WARN = 0.15
EFFICIENCY_DROP_ALARM = 0.20

SENSOR_DRIFT = ((0.0, 0.0), (0.5, 0.20), (1.0, 0.20))
GAUGE_MISMATCH_LIMIT = 0.15

CURRENT_NOISE = 0.002
FLOW_NOISE = 0.002
PRESSURE_NOISE = 0.005
SENSOR_NOISE = 0.005
NOISE_STREAMS = (
    "rpm", "vib_1x", "vib_2x", "vib_hf", "temp_bearing", "temp_winding", "vib_axial",
    "current_a", "current_b", "current_c", "press_in", "press_out_true", "press_out", "flow",
)
NORMAL_HISTORY_HOURS = 9


@dataclass(frozen=True)
class Episode:
    """Эпизод развития неисправности: от первого часа роста отклонения до часа наибольшего отклонения."""

    id: str
    title: str
    description: str
    onset: datetime
    peak: datetime
    rules: tuple[str, ...]
    source: str

    def progress(self, at: datetime) -> float:
        """Возвращает долю развития эпизода от 0 до 1; вне эпизода - 0."""
        if at < self.onset or at > self.peak:
            return 0.0
        return (at - self.onset) / (self.peak - self.onset)


EPISODES = (
    Episode(
        "imbalance", "Дисбаланс рабочего колеса",
        "Амплитуда 1x растёт до 5,2 мм/с (база заказчика)",
        datetime(2026, 11, 13, 16), datetime(2026, 11, 17, 19), ("R02",), "customer",
    ),
    Episode(
        "misalignment", "Расцентровка валов",
        "Амплитуда 2x растёт до 4,3 мм/с (база заказчика); модель: осевая вибрация на муфте растёт вместе с 2x, "
        "ток выше на 5-8 %, температуры в норме",
        datetime(2026, 11, 18, 16), datetime(2026, 11, 22, 19), ("R09",), "customer",
    ),
    Episode(
        "bearing_wear", "Износ подшипника",
        "ВЧ шум до 6 g, затем температура подшипника до 98 °C (база заказчика); модель: ток и давление "
        "на входе в норме",
        datetime(2026, 11, 23, 16), datetime(2026, 11, 27, 19), ("R08", "R01", "R03"), "customer",
    ),
    Episode(
        "winding_overheat", "Перегрев обмоток двигателя",
        "Температура обмоток до 121 °C (база заказчика); модель: небаланс токов по фазам 7-9 %",
        datetime(2026, 11, 27, 20), datetime(2026, 12, 1, 3), ("R04",), "customer",
    ),
    Episode(
        "cavitation", "Кавитация",
        "Модель: давление на входе падает с 1,5 до 0,4 бар, ВЧ шум 3-4 g, СКЗ вибрации растёт, "
        "температура подшипника в норме",
        datetime(2026, 12, 2, 0), datetime(2026, 12, 3, 19), ("R07", "R12"), "model",
    ),
    Episode(
        "hydraulic_wear", "Износ проточной части",
        "Модель: подача падает при той же мощности, КПД ниже на 15-18 %, вибрация и температура в норме",
        datetime(2026, 12, 4, 0), datetime(2026, 12, 5, 19), ("R10",), "model",
    ),
    Episode(
        "sensor_drift", "Дрейф датчика давления нагнетания",
        "Модель: электронный датчик показывает на 20 % ниже стрелочного манометра",
        datetime(2026, 12, 6, 0), datetime(2026, 12, 6, 23), ("R05",), "model",
    ),
)
EPISODE_BY_ID = {episode.id: episode for episode in EPISODES}


@dataclass(frozen=True)
class PumpModel:
    """Опорная точка насоса по паспорту и пересчёт режима по законам подобия.

    Паспортные подача, напор, мощность и номинальный ток отнесены к базовой частоте вращения из баз
    заказчика (2950 об/мин). Сеть принята замкнутым контуром с характеристикой H = k * Q^2, поэтому
    рабочая точка при изменении оборотов смещается точно по законам подобия.
    """

    flow_m3h: float
    head_m: float
    power_kw: float
    rated_current_a: float
    reference_rpm: float = REFERENCE_RPM

    @classmethod
    def from_specs(cls, specs: dict) -> "PumpModel":
        """Создаёт модель из блока specs карточки оборудования."""
        return cls(
            float(specs["flow_m3h"]), float(specs["head_m"]), float(specs["power_kw"]), float(specs["rated_current_a"])
        )

    @property
    def pressure_rise_bar(self) -> float:
        """Прирост давления на насосе в опорной точке, бар."""
        return RHO * G * self.head_m / PASCAL_PER_BAR

    @property
    def nominal_efficiency(self) -> float:
        """КПД насоса в опорной точке, %: полезная гидравлическая мощность к потребляемой."""
        return hydraulic_power_kw(self.flow_m3h, self.head_m) / self.power_kw * 100

    def duty(self, rpm: float, flow_factor: float = 1.0, load_factor: float = 1.0) -> tuple[float, float, float]:
        """Возвращает подачу (м3/ч), напор (м) и потребляемую мощность (кВт) при заданных оборотах.

        Законы подобия: Q ~ n, H ~ n^2, P ~ n^3. flow_factor описывает потерю подачи изношенным или
        кавитирующим насосом: точка скользит вниз по параболе сети, напор меняется как квадрат подачи.
        load_factor - прибавка механических потерь на валу, не дающая полезной работы.
        """
        ratio = rpm / self.reference_rpm
        flow = self.flow_m3h * ratio * flow_factor
        head = self.head_m * (ratio * flow_factor) ** 2
        power = self.power_kw * ratio ** 3 * load_factor
        return flow, head, power

    def mean_current(self, power_kw: float) -> float:
        """Средний ток фаз при заданной мощности: вблизи номинала ток пропорционален мощности."""
        return self.rated_current_a * power_kw / self.power_kw

    def power_from_current(self, mean_current: float) -> float:
        """Потребляемая мощность насоса по среднему току фаз (обратный пересчёт mean_current)."""
        return self.power_kw * mean_current / self.rated_current_a


@dataclass(frozen=True)
class FaultState:
    """Состояние моделируемых неисправностей в заданный час."""

    load: float
    axial: float
    unbalance: float
    press_in: float
    cavitation: float
    efficiency_drop: float
    drift: float


@dataclass(frozen=True)
class Timeline:
    """Готовая лента телеметрии: часы, ряды по кодам параметров, диагнозы заказчика и сценарии."""

    times: list[datetime]
    series: dict[str, list[float]]
    customer_count: int
    labels: dict[str, list[str]]
    scenarios: list[dict]


def interpolate(progress: float, points: tuple[tuple[float, float], ...]) -> float:
    """Кусочно-линейный профиль: значение в точке progress по опорным парам (доля, значение)."""
    if progress <= points[0][0]:
        return points[0][1]
    for (left, low), (right, high) in zip(points, points[1:]):
        if progress <= right:
            return low + (high - low) * (progress - left) / (right - left)
    return points[-1][1]


def current_unbalance(phase_a: float, phase_b: float, phase_c: float) -> float:
    """Небаланс токов, %: наибольшее отклонение фазы от среднего, делённое на среднее.

    Для остановленного агрегата (токи равны нулю) возвращает 0.
    """
    mean = (phase_a + phase_b + phase_c) / 3
    if mean <= 0:
        return 0.0
    return max(abs(phase_a - mean), abs(phase_b - mean), abs(phase_c - mean)) / mean * 100


def head_from_pressure(press_in_bar: float, press_out_bar: float) -> float:
    """Напор насоса в метрах по давлениям на входе и на нагнетании: H = dp / (rho * g)."""
    return (press_out_bar - press_in_bar) * PASCAL_PER_BAR / (RHO * G)


def hydraulic_power_kw(flow_m3h: float, head_m: float) -> float:
    """Полезная гидравлическая мощность, кВт: rho * g * Q * H."""
    return RHO * G * (flow_m3h / 3600) * head_m / 1000


def efficiency_percent(flow_m3h: float, press_in_bar: float, press_out_bar: float, power_kw: float) -> float:
    """КПД насоса, %: гидравлическая мощность к потребляемой; для остановленного агрегата - 0."""
    if power_kw <= 0:
        return 0.0
    return hydraulic_power_kw(flow_m3h, head_from_pressure(press_in_bar, press_out_bar)) / power_kw * 100


def gauge_mismatch(press_out_bar: float, press_out_true_bar: float) -> float:
    """Доля, на которую электронный датчик давления отличается от стрелочного манометра."""
    if press_out_true_bar <= 0:
        return 0.0
    return abs(press_out_true_bar - press_out_bar) / press_out_true_bar


def fault_state(at: datetime) -> FaultState:
    """Рассчитывает отклонения, которые модель добавляет к нормальному режиму в заданный час.

    Расцентровка: механические потери и осевая вибрация растут вместе с амплитудой 2x заказчика.
    Перегрев обмоток: перегрев пропорционален квадрату небаланса токов, а температура у заказчика
    растёт линейно, поэтому небаланс растёт как корень из доли развития эпизода.
    Кавитация: давление на входе падает линейно; ниже порога начала кавитации её интенсивность
    растёт как корень из дефицита давления. Износ проточной части и дрейф датчика заданы профилями.
    """
    misalignment = EPISODE_BY_ID["misalignment"].progress(at)
    winding = EPISODE_BY_ID["winding_overheat"].progress(at)
    press_in = PRESS_IN_BASE - (PRESS_IN_BASE - PRESS_IN_MIN) * EPISODE_BY_ID["cavitation"].progress(at)
    deficit = (CAVITATION_INCEPTION - press_in) / (CAVITATION_INCEPTION - PRESS_IN_MIN)
    return FaultState(
        load=interpolate(misalignment, MISALIGNMENT_LOAD),
        axial=MISALIGNMENT_AXIAL * misalignment,
        unbalance=math.sqrt(UNBALANCE_BASE ** 2 + (UNBALANCE_PEAK ** 2 - UNBALANCE_BASE ** 2) * winding),
        press_in=press_in,
        cavitation=math.sqrt(min(1.0, max(0.0, deficit))),
        efficiency_drop=interpolate(EPISODE_BY_ID["hydraulic_wear"].progress(at), WEAR_EFFICIENCY_DROP),
        drift=interpolate(EPISODE_BY_ID["sensor_drift"].progress(at), SENSOR_DRIFT),
    )


def accumulate_run_hours(start: float, rpm_by_hour: list[float]) -> list[float]:
    """Счётчик наработки: первое значение равно start, далее +1 за каждый час записи с оборотами выше нуля."""
    result = []
    total = float(start)
    for index, rpm in enumerate(rpm_by_hour):
        if index and rpm > 0:
            total += 1.0
        result.append(total)
    return result


def build_timeline(
    rows: list[CustomerRow], model: PumpModel, run_hours_start: float, service_due_hours: float | None = None
) -> Timeline:
    """Собирает ленту: строки заказчика как есть, модельные параметры на те же часы и модельные сутки после них.

    service_due_hours - наработка, при которой наступает ближайший срок обслуживания; по ней
    строятся опорные сценарии "нормальный режим" и "срок обслуживания".
    """
    if not rows:
        raise ValueError("Нет строк баз заказчика - строить ряды не из чего")
    times = [row.at for row in rows]
    while times[-1] < TIMELINE_END:
        times.append(times[-1] + STEP)
    noise = _noise(len(times))
    series = {code: [] for code in CODES}
    for index, at in enumerate(times):
        state = fault_state(at)
        values = dict(rows[index].values) if index < len(rows) else _extension_measurements(index, state, noise)
        values.update(_modelled(index, values["rpm"], state, model, noise))
        for code, value in values.items():
            series[code].append(value)
    series["run_hours"] = accumulate_run_hours(run_hours_start, series["rpm"])
    series["mode"] = [1.0 if rpm > 0 else 0.0 for rpm in series["rpm"]]
    labels = {kind: [row.labels[kind] for row in rows] for kind in LABEL_KINDS}
    return Timeline(times, series, len(rows), labels, _scenarios(times, series, model, service_due_hours))


def _noise(count: int) -> dict[str, list[float]]:
    """Готовит стандартный нормальный шум для каждого ряда: отдельный генератор с постоянным зерном."""
    result = {}
    for name in NOISE_STREAMS:
        generator = random.Random(f"{SEED}:{name}")
        result[name] = [generator.gauss(0.0, 1.0) for _ in range(count)]
    return result


def _draw(code: str, index: int, noise: dict[str, list[float]]) -> float:
    """Нормальное значение ряда: базовый уровень плюс шум с разбросом из спокойных строк заказчика."""
    mean, deviation = BASELINE[code]
    return mean + deviation * noise[code][index]


def _extension_measurements(index: int, state: FaultState, noise: dict[str, list[float]]) -> dict[str, float]:
    """Моделирует на часах после баз заказчика те же семь параметров, что в них измерены.

    Уровни и разброс взяты из спокойных строк заказчика, округление то же. СКЗ считается по
    зависимости, которой подчиняются строки заказчика: sqrt(1x^2 + 2x^2 + 0,5^2) + 0,2 * ВЧ.
    Кавитация добавляет ВЧ шум и широкополосную составляющую виброскорости.
    """
    first = _draw("vib_1x", index, noise)
    second = _draw("vib_2x", index, noise)
    high = max(0.0, _draw("vib_hf", index, noise) + CAVITATION_HF_RISE * state.cavitation)
    broadband = CAVITATION_BROADBAND * state.cavitation
    overall = math.sqrt(first ** 2 + second ** 2 + RMS_FLOOR ** 2 + broadband ** 2) + RMS_HF_SHARE * high
    return {
        "rpm": round(_draw("rpm", index, noise)),
        "vib_rms": round(overall, 2),
        "vib_1x": round(first, 2),
        "vib_2x": round(second, 2),
        "vib_hf": round(high, 2),
        "temp_bearing": round(_draw("temp_bearing", index, noise), 1),
        "temp_winding": round(_draw("temp_winding", index, noise), 1),
    }


def _modelled(
    index: int, rpm: float, state: FaultState, model: PumpModel, noise: dict[str, list[float]]
) -> dict[str, float]:
    """Рассчитывает параметры, которых нет в базах заказчика, для одного часа.

    Токи фаз получаются из мощности на валу, небаланс и мощность пересчитываются уже из округлённых
    токов, КПД - из округлённых подачи, давлений и мощности, поэтому сохранённые значения согласованы
    между собой точно. КПД считается по истинному давлению нагнетания, а не по электронному датчику.
    """
    flow_factor = (1.0 - state.efficiency_drop) ** (1 / 3) * (1.0 - CAVITATION_FLOW_LOSS * state.cavitation ** 2)
    flow, head, shaft_power = model.duty(rpm, flow_factor, 1.0 + state.load)
    mean_current = model.mean_current(shaft_power)
    currents = [
        round(mean_current * (1.0 + state.unbalance / 100 * share + CURRENT_NOISE * noise[code][index]), 2)
        for code, share in zip(PHASE_CODES, PHASE_PATTERN)
    ]
    power = round(model.power_from_current(sum(currents) / 3), 2)
    suction = state.press_in + PRESSURE_NOISE * noise["press_in"][index]
    discharge = suction + RHO * G * head / PASCAL_PER_BAR + PRESSURE_NOISE * noise["press_out_true"][index]
    press_in = round(suction, 2)
    press_out_true = round(discharge, 2)
    measured_flow = round(flow * (1.0 + FLOW_NOISE * noise["flow"][index]), 1)
    axial = _draw("vib_axial", index, noise) + state.axial if rpm > 0 else 0.0
    return {
        "vib_axial": round(max(0.0, axial), 2),
        "current_a": currents[0],
        "current_b": currents[1],
        "current_c": currents[2],
        "current_unbalance": round(current_unbalance(*currents), 2),
        "press_in": press_in,
        "press_out": round(discharge * (1.0 - state.drift) + SENSOR_NOISE * noise["press_out"][index], 2),
        "press_out_true": press_out_true,
        "flow": measured_flow,
        "power": power,
        "efficiency": round(efficiency_percent(measured_flow, press_in, press_out_true, power), 1),
    }


def _breached(episode_id: str, values: dict[str, float], model: PumpModel) -> bool:
    """Проверяет, вышел ли ведущий параметр эпизода за уставку предупреждения в данной записи."""
    if episode_id == "imbalance":
        return values["vib_1x"] > CUSTOMER_THRESHOLDS["vib_1x"][0]
    if episode_id == "misalignment":
        return values["vib_2x"] > CUSTOMER_THRESHOLDS["vib_2x"][0]
    if episode_id == "bearing_wear":
        return values["vib_hf"] > CUSTOMER_THRESHOLDS["vib_hf"][0]
    if episode_id == "winding_overheat":
        return values["temp_winding"] > CUSTOMER_THRESHOLDS["temp_winding"][0]
    if episode_id == "cavitation":
        return values["press_in"] < PRESS_IN_WARN
    if episode_id == "hydraulic_wear":
        return values["efficiency"] < model.nominal_efficiency * (1.0 - EFFICIENCY_DROP_WARN)
    if episode_id == "sensor_drift":
        return gauge_mismatch(values["press_out"], values["press_out_true"]) > GAUGE_MISMATCH_LIMIT
    raise KeyError(f"Для эпизода {episode_id} не задан ведущий параметр")


def _scenarios(
    times: list[datetime], series: dict[str, list[float]], model: PumpModel, service_due_hours: float | None
) -> list[dict]:
    """Составляет список сценариев: семь эпизодов неисправностей и опорные точки без неисправностей.

    start - первый час эпизода, когда ведущий параметр вышел за уставку предупреждения; onset - час,
    с которого отклонение начало расти; peak и end - час наибольшего отклонения перед возвратом к норме.
    """
    result = []
    for episode in EPISODES:
        inside = [index for index, at in enumerate(times) if episode.onset <= at <= episode.peak]
        breached = [
            index for index in inside if _breached(episode.id, {code: series[code][index] for code in CODES}, model)
        ]
        result.append({
            "id": episode.id, "title": episode.title, "description": episode.description,
            "onset": episode.onset, "start": times[breached[0]] if breached else episode.peak,
            "end": episode.peak, "peak": episode.peak,
            "expected_rules": list(episode.rules), "source": episode.source, "kind": "fault",
        })
    quiet_end = max(0, sum(1 for at in times if at < EPISODES[0].onset) - 1)
    due_index = None
    if service_due_hours is not None:
        due_index = next(
            (index for index in range(quiet_end + 1) if series["run_hours"][index] >= service_due_hours), None
        )
    normal_index = due_index - 1 if due_index else min(NORMAL_HISTORY_HOURS, quiet_end)
    description = "Все параметры датчиков в норме"
    if due_index:
        description += ", срок обслуживания по наработке ещё не наступил"
    result.append({
        "id": "normal", "title": "Нормальный режим", "description": description,
        "onset": times[0], "start": times[0], "end": times[normal_index], "peak": times[normal_index],
        "expected_rules": [], "source": "customer", "kind": "reference",
    })
    if due_index is not None:
        result.append({
            "id": "maintenance_due", "title": "Срок обслуживания по наработке",
            "description": f"Модель: счётчик наработки достигает {service_due_hours:.0f} ч - наступает срок ТО",
            "onset": times[0], "start": times[due_index], "end": times[due_index], "peak": times[due_index],
            "expected_rules": ["R11"], "source": "model", "kind": "reference",
        })
    return result
