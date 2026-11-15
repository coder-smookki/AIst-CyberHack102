"""Проверки телеметрии: сохранность баз заказчика, полнота и физическая согласованность модельных рядов."""

import itertools
import math
import random
from datetime import UTC, datetime, timedelta

import openpyxl
import pytest

from server.telemetry import CODES, TelemetryDataError, build_player, get_player, loader, synth
from server.telemetry.loader import CUSTOMER_CODES, CustomerRow
from server.telemetry.player import TelemetryPlayer
from server.telemetry.synth import PumpModel

HOUR = timedelta(hours=1)
FIRST = datetime(2026, 11, 10, 8)
CUSTOMER_LAST = datetime(2026, 12, 1, 3)
LAST = datetime(2026, 12, 6, 23)
MODEL = PumpModel(flow_m3h=47.0, head_m=31.7, power_kw=5.5, rated_current_a=11.0)
RUN_HOURS_START = 19190
SERVICE_DUE = 19200
FAULTS = ("imbalance", "misalignment", "bearing_wear", "winding_overheat", "cavitation", "hydraulic_wear", "sensor_drift")
VIBRATION_HEADER = (
    "Дата и время",
    "Обороты (об/мин)",
    "СКЗ общее (мм/с)",
    "Ампл. 1x (мм/с)",
    "Ампл. 2x (мм/с)",
    "ВЧ шум (g)",
    "Диагноз по вибрации",
)
TEMPERATURE_HEADER = (
    "Дата и время",
    "Обороты (об/мин)",
    "Темп. подшипника насоса (°C)",
    "Темп. обмоток ЭД (°C)",
    "Диагноз по температуре",
)


def customer_files():
    """Возвращает пути к двум базам заказчика."""
    return (
        loader.CUSTOMER_DIR.joinpath(*loader.VIBRATION_FILE),
        loader.CUSTOMER_DIR.joinpath(*loader.TEMPERATURE_FILE),
    )


def read_sheet(path):
    """Читает первый лист файла независимо от загрузчика: заголовок и строки как есть."""
    workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
    try:
        lines = [line for line in workbook.worksheets[0].iter_rows(values_only=True)]
    finally:
        workbook.close()
    return lines[0], lines[1:]


def write_sheet(path, header, lines):
    """Записывает маленькую тестовую базу в формате заказчика."""
    path.parent.mkdir(parents=True, exist_ok=True)
    workbook = openpyxl.Workbook()
    sheet = workbook.active
    sheet.append(header)
    for line in lines:
        sheet.append(line)
    workbook.save(path)


def write_bases(base, vibration_lines, temperature_lines, temperature_header=TEMPERATURE_HEADER):
    """Создаёт в папке base обе тестовые базы с именами, как у заказчика."""
    write_sheet(base.joinpath(*loader.VIBRATION_FILE), VIBRATION_HEADER, vibration_lines)
    write_sheet(base.joinpath(*loader.TEMPERATURE_FILE), temperature_header, temperature_lines)


def baseline_rows(count):
    """Готовит условные строки нормального режима для проверок, которым базы заказчика не нужны."""
    values = {
        "rpm": 2950,
        "vib_rms": 1.01,
        "vib_1x": 0.8,
        "vib_2x": 0.3,
        "vib_hf": 0.1,
        "temp_bearing": 50.0,
        "temp_winding": 65.0,
    }
    labels = {"vibration": "Норма", "temperature": "Норма"}
    return [CustomerRow(FIRST + HOUR * index, dict(values), dict(labels)) for index in range(count)]


def hours_of(player):
    """Возвращает все часы ленты от первой записи до последней."""
    first, last = player.bounds()
    return [first + HOUR * index for index in range(int((last - first) / HOUR) + 1)]


def scenario(player, scenario_id):
    """Находит сценарий по идентификатору."""
    return next(item for item in player.scenarios() if item["id"] == scenario_id)


def inside(at, item):
    """Проверяет, что час лежит внутри эпизода: от начала роста отклонения до его конца."""
    return item["onset"] <= at <= item["end"]


def quiet_hours(player):
    """Возвращает часы, не попадающие ни в один эпизод неисправности."""
    faults = [scenario(player, scenario_id) for scenario_id in FAULTS]
    return [at for at in hours_of(player) if not any(inside(at, item) for item in faults)]


def mean_current(values):
    """Средний ток трёх фаз."""
    return (values["current_a"] + values["current_b"] + values["current_c"]) / 3


def efficiency_drop(values):
    """Падение КПД относительно паспортного, %."""
    return (MODEL.nominal_efficiency - values["efficiency"]) / MODEL.nominal_efficiency * 100


def mismatch(values):
    """Отличие электронного датчика давления от стрелочного манометра, %."""
    return abs(values["press_out_true"] - values["press_out"]) / values["press_out_true"] * 100


def beyond(parameter, value, limit):
    """Проверяет, вышло ли значение за уставку с учётом направления параметра."""
    return value > limit if parameter["direction"] == "high" else value < limit


def status(parameter, value):
    """Сравнивает значение с уставками параметра: ok, warn или alarm."""
    if parameter["direction"] is None:
        return "ok"
    if beyond(parameter, value, parameter["alarm"]):
        return "alarm"
    return "warn" if beyond(parameter, value, parameter["warn"]) else "ok"


def slope(points):
    """Наклон прямой по методу наименьших квадратов для пар (x, y)."""
    mean_x = sum(x for x, _ in points) / len(points)
    mean_y = sum(y for _, y in points) / len(points)
    return sum((x - mean_x) * (y - mean_y) for x, y in points) / sum((x - mean_x) ** 2 for x, _ in points)


@pytest.fixture(scope="module")
def timeline():
    """Лента по настоящим базам заказчика; без них зависящие от неё тесты пропускаются."""
    if not all(path.exists() for path in customer_files()):
        pytest.skip("нет баз заказчика в data/customer")
    return synth.build_timeline(loader.load_customer(), MODEL, RUN_HOURS_START, SERVICE_DUE)


@pytest.fixture
def player(timeline):
    """Новый проигрыватель с собственным курсором на общей ленте."""
    return TelemetryPlayer("N-101", timeline, MODEL)


@pytest.fixture(scope="module")
def sketch_timeline():
    """Лента по условным строкам нормального режима: для проверок, не зависящих от баз заказчика."""
    return synth.build_timeline(baseline_rows(24), MODEL, RUN_HOURS_START, SERVICE_DUE)


@pytest.fixture
def sketch(sketch_timeline):
    """Проигрыватель на условной ленте."""
    return TelemetryPlayer("N-101", sketch_timeline, MODEL)


def test_missing_customer_files_give_clear_error(tmp_path):
    """Без файлов заказчика загрузчик сообщает, какого файла нет и куда его положить."""
    with pytest.raises(TelemetryDataError) as caught:
        loader.load_customer(tmp_path)
    assert "Не найдена база заказчика" in str(caught.value)
    assert str(tmp_path) in str(caught.value)


def test_loader_keeps_values_and_merges_by_time(tmp_path):
    """Загрузчик объединяет базы по времени и возвращает значения ровно такими, какими они записаны."""
    write_bases(
        tmp_path,
        [("2026-11-10 09:00", 2953, 1.01, 0.81, 0.3, 0.09, "Норма"), ("2026-11-10 08:00", 2963, 1.02, 0.84, 0.22, 0.1, "Норма")],
        [
            ("2026-11-10 08:00", 2963, 50.6, 64.3, "Норма"),
            ("2026-11-10 09:00", 2953, 91.5, 66.2, "Тревога: Перегрев подш. насоса"),
        ],
    )
    rows = loader.load_customer(tmp_path)
    assert [row.at for row in rows] == [FIRST, FIRST + HOUR]
    assert rows[0].values == {
        "rpm": 2963,
        "vib_rms": 1.02,
        "vib_1x": 0.84,
        "vib_2x": 0.22,
        "vib_hf": 0.1,
        "temp_bearing": 50.6,
        "temp_winding": 64.3,
    }
    assert isinstance(rows[0].values["rpm"], int)
    assert rows[1].labels == {"vibration": "Норма", "temperature": "Тревога: Перегрев подш. насоса"}


def test_loader_rejects_inconsistent_bases(tmp_path):
    """Расхождение оборотов или времени между базами и отсутствие столбца дают понятную ошибку."""
    vibration = [("2026-11-10 08:00", 2963, 1.02, 0.84, 0.22, 0.1, "Норма")]
    write_bases(tmp_path / "rpm", vibration, [("2026-11-10 08:00", 2900, 50.6, 64.3, "Норма")])
    with pytest.raises(TelemetryDataError, match="Обороты"):
        loader.load_customer(tmp_path / "rpm")
    write_bases(tmp_path / "time", vibration, [("2026-11-10 09:00", 2963, 50.6, 64.3, "Норма")])
    with pytest.raises(TelemetryDataError, match="разные отметки времени"):
        loader.load_customer(tmp_path / "time")
    write_bases(
        tmp_path / "column",
        vibration,
        [("2026-11-10 08:00", 2963, 50.6, "Норма")],
        temperature_header=TEMPERATURE_HEADER[:3] + TEMPERATURE_HEADER[4:],
    )
    with pytest.raises(TelemetryDataError, match="нет столбцов"):
        loader.load_customer(tmp_path / "column")
    write_bases(tmp_path / "text", vibration, [("2026-11-10 08:00", 2963, "нет", 64.3, "Норма")])
    with pytest.raises(TelemetryDataError, match="ожидалось число"):
        loader.load_customer(tmp_path / "text")


def test_units_without_telemetry_raise_key_error():
    """Для агрегатов без телеметрии и для неизвестных идентификаторов проигрывателя нет."""
    for equipment_id in ("AMS-1", "AMS-2", "нет-такого"):
        with pytest.raises(KeyError):
            build_player(equipment_id)
        with pytest.raises(KeyError):
            get_player(equipment_id)


def test_current_unbalance_formula():
    """Небаланс токов - наибольшее отклонение фазы от среднего, делённое на среднее, в процентах."""
    assert synth.current_unbalance(10.0, 11.0, 12.0) == pytest.approx(1.0 / 11.0 * 100)
    assert synth.current_unbalance(11.0, 11.0, 11.0) == 0.0
    assert synth.current_unbalance(0.0, 0.0, 0.0) == 0.0


def test_hydraulic_power_and_efficiency_formulas():
    """Гидравлическая мощность равна rho * g * Q * H, КПД - её отношение к потребляемой мощности."""
    expected_kw = 1000.0 * 9.80665 * (47.0 / 3600) * 31.7 / 1000
    assert synth.hydraulic_power_kw(47.0, 31.7) == pytest.approx(expected_kw)
    assert MODEL.nominal_efficiency == pytest.approx(expected_kw / 5.5 * 100)
    assert MODEL.nominal_efficiency == pytest.approx(73.79, abs=0.01)
    assert MODEL.pressure_rise_bar == pytest.approx(3.109, abs=0.001)
    assert synth.head_from_pressure(1.5, 1.5 + MODEL.pressure_rise_bar) == pytest.approx(31.7)
    assert synth.efficiency_percent(47.0, 1.5, 1.5 + MODEL.pressure_rise_bar, 5.5) == pytest.approx(MODEL.nominal_efficiency)
    assert synth.efficiency_percent(47.0, 1.5, 4.6, 0.0) == 0.0


def test_affinity_laws_for_speed_change():
    """При изменении оборотов подача меняется как n, напор как n^2, мощность как n^3, КПД не меняется."""
    assert MODEL.duty(2950.0) == pytest.approx((47.0, 31.7, 5.5))
    flow, head, power = MODEL.duty(2950.0 * 0.8)
    assert flow / 47.0 == pytest.approx(0.8)
    assert head / 31.7 == pytest.approx(0.8**2)
    assert power / 5.5 == pytest.approx(0.8**3)
    assert synth.hydraulic_power_kw(flow, head) / power * 100 == pytest.approx(MODEL.nominal_efficiency)
    worn_flow, worn_head, worn_power = MODEL.duty(2950.0, flow_factor=0.94)
    assert worn_power == pytest.approx(5.5)
    assert synth.hydraulic_power_kw(worn_flow, worn_head) / worn_power * 100 == pytest.approx(MODEL.nominal_efficiency * 0.94**3)
    assert MODEL.power_from_current(MODEL.mean_current(4.2)) == pytest.approx(4.2)
    assert MODEL.mean_current(5.5) == pytest.approx(11.0)


def test_run_hours_accumulate_only_while_running():
    """Наработка прирастает на час только за записи с оборотами выше нуля."""
    assert synth.accumulate_run_hours(100, [2950, 2950, 0, 0, 2950]) == [100.0, 101.0, 101.0, 101.0, 102.0]


def test_profile_interpolation():
    """Профиль эпизода линейно соединяет опорные точки и не выходит за крайние значения."""
    points = ((0.0, 0.0), (0.5, 0.2), (1.0, 0.2))
    assert synth.interpolate(-1.0, points) == 0.0
    assert synth.interpolate(0.25, points) == pytest.approx(0.1)
    assert synth.interpolate(0.75, points) == pytest.approx(0.2)
    assert synth.interpolate(2.0, points) == 0.2


def test_window_snapshot_and_trend_semantics(sketch):
    """Окно берёт записи позже at - hours и не позже at; тренд требует не меньше четырёх точек."""
    at = FIRST + HOUR * 10
    window = sketch.window("run_hours", hours=5, at=at)
    assert [moment for moment, _ in window] == [at - HOUR * shift for shift in (4, 3, 2, 1, 0)]
    assert [value for _, value in window] == [RUN_HOURS_START + index for index in range(6, 11)]
    assert sketch.trend("run_hours", hours=12, at=at) == pytest.approx(1.0)
    assert sketch.trend("mode", hours=12, at=at) == pytest.approx(0.0)
    assert len(sketch.window("run_hours", hours=12, at=FIRST + HOUR * 2)) == 3
    assert sketch.trend("run_hours", hours=12, at=FIRST + HOUR * 2) is None
    assert sketch.trend("run_hours", hours=12, at=FIRST + HOUR * 3) == pytest.approx(1.0)
    assert sketch.snapshot(FIRST + HOUR * 1.5) == sketch.snapshot(FIRST + HOUR)
    assert sketch.snapshot(LAST + HOUR * 5) == sketch.snapshot(LAST)
    assert sketch.snapshot(FIRST - HOUR) == {}
    assert sketch.window("rpm", hours=24, at=FIRST - HOUR) == []
    assert sketch.trend("rpm", hours=24, at=FIRST - HOUR) is None


def test_player_validates_arguments(sketch):
    """Неизвестный параметр, пустое окно, момент вне записи и неверный вид диагноза отклоняются."""
    with pytest.raises(KeyError):
        sketch.window("pressure", hours=24)
    with pytest.raises(KeyError):
        sketch.source("pressure")
    with pytest.raises(ValueError):
        sketch.window("rpm", hours=0)
    with pytest.raises(ValueError):
        sketch.set_cursor(LAST + HOUR)
    with pytest.raises(ValueError):
        sketch.set_cursor(FIRST - HOUR)
    with pytest.raises(TypeError):
        sketch.set_cursor("2026-11-12 10:00")
    with pytest.raises(ValueError):
        sketch.customer_label("noise")
    with pytest.raises(KeyError):
        sketch.select_scenario("нет-такого")
    sketch.set_cursor(datetime(2026, 11, 12, 10, 30, tzinfo=UTC))
    assert sketch.cursor == datetime(2026, 11, 12, 10, 30)
    assert sketch.snapshot() == sketch.snapshot(datetime(2026, 11, 12, 10))


def test_customer_rows_preserved_exactly(player):
    """Все 500 строк обеих баз заказчика лежат в ленте без единого изменения, с их диагнозами."""
    vibration_path, temperature_path = customer_files()
    vibration_header, vibration = read_sheet(vibration_path)
    temperature_header, temperature = read_sheet(temperature_path)
    assert tuple(vibration_header) == VIBRATION_HEADER
    assert tuple(temperature_header) == TEMPERATURE_HEADER
    assert len(vibration) == len(temperature) == 500
    for vib, temp in zip(vibration, temperature):
        at = datetime.strptime(vib[0], "%Y-%m-%d %H:%M")
        assert temp[0] == vib[0]
        values = player.snapshot(at)
        expected = {
            "rpm": vib[1],
            "vib_rms": vib[2],
            "vib_1x": vib[3],
            "vib_2x": vib[4],
            "vib_hf": vib[5],
            "temp_bearing": temp[2],
            "temp_winding": temp[3],
        }
        assert {code: values[code] for code in CUSTOMER_CODES} == expected
        assert player.customer_label("vibration", at) == vib[6]
        assert player.customer_label("temperature", at) == temp[4]
        assert all(player.source(code, at) == "customer" for code in CUSTOMER_CODES)
    assert player.customer_bounds() == (FIRST, CUSTOMER_LAST)


def test_every_hour_has_all_parameter_codes(player):
    """Лента идёт с шагом в час до 06.12 23:00, и в каждой записи есть все коды параметров."""
    assert player.bounds() == (FIRST, LAST)
    hours = hours_of(player)
    assert len(hours) == 640
    assert len(CODES) == 20
    for at in hours:
        values = player.snapshot(at)
        assert tuple(values) == CODES
        assert all(isinstance(value, float) and math.isfinite(value) for value in values.values())
        assert [moment for moment, _ in player.window("rpm", hours=1, at=at)] == [at]


def test_modelled_values_are_flagged(player):
    """Источник "customer" есть только у семи параметров заказчика на его часах, всё остальное - "model"."""
    for at in (FIRST, datetime(2026, 11, 20, 12), CUSTOMER_LAST):
        parameters = player.parameters(at)
        assert [item["code"] for item in parameters] == list(CODES)
        for item in parameters:
            assert item["source"] == ("customer" if item["code"] in CUSTOMER_CODES else "model")
            assert set(item) >= {"code", "name", "unit", "warn", "alarm", "direction", "source"}
            assert item["direction"] in ("high", "low", None)
            assert (item["direction"] is None) == (item["warn"] is None) == (item["alarm"] is None)
    for at in (CUSTOMER_LAST + HOUR, datetime(2026, 12, 3, 19), LAST):
        assert all(item["source"] == "model" for item in player.parameters(at))
        assert all(player.source(code, at) == "model" for code in CODES)
        assert player.customer_label("vibration", at) == ""
        assert player.customer_label("temperature", at) == ""
    player.set_cursor(LAST)
    assert all(item["source"] == "model" for item in player.parameters())


def test_customer_thresholds_in_parameters(player):
    """Уставки пяти параметров заказчика совпадают с его описаниями баз, направление - превышение."""
    parameters = {item["code"]: item for item in player.parameters()}
    expected = {
        "vib_1x": (2.8, 4.5),
        "vib_2x": (1.8, 3.0),
        "vib_hf": (2.5, 5.0),
        "temp_bearing": (75.0, 90.0),
        "temp_winding": (90.0, 110.0),
    }
    for code, (warn, alarm) in expected.items():
        assert (parameters[code]["warn"], parameters[code]["alarm"], parameters[code]["direction"]) == (warn, alarm, "high")
    assert (parameters["current_unbalance"]["warn"], parameters["current_unbalance"]["direction"]) == (5.0, "high")
    assert parameters["press_in"]["direction"] == "low"
    assert parameters["efficiency"]["direction"] == "low"
    assert parameters["efficiency"]["warn"] == pytest.approx(MODEL.nominal_efficiency * 0.85, abs=0.01)


def test_scenarios_follow_the_plan(player):
    """Семь эпизодов идут в порядке плана, их даты совпадают с планом, пик лежит внутри эпизода."""
    scenarios = player.scenarios()
    assert [item["id"] for item in scenarios[:7]] == list(FAULTS)
    assert [item["id"] for item in scenarios[7:]] == ["normal", "maintenance_due"]
    days = {
        "imbalance": ((11, 15), (11, 17)),
        "misalignment": ((11, 20), (11, 22)),
        "bearing_wear": ((11, 25), (11, 27)),
        "winding_overheat": ((11, 29), (12, 1)),
        "cavitation": ((12, 2), (12, 3)),
        "hydraulic_wear": ((12, 4), (12, 5)),
        "sensor_drift": ((12, 6), (12, 6)),
    }
    rules = {
        "imbalance": ["R02"],
        "misalignment": ["R09"],
        "bearing_wear": ["R08", "R01", "R03"],
        "winding_overheat": ["R04"],
        "cavitation": ["R07", "R12"],
        "hydraulic_wear": ["R10"],
        "sensor_drift": ["R05"],
        "normal": [],
        "maintenance_due": ["R11"],
    }
    for item in scenarios:
        assert set(item) >= {"id", "title", "start", "end", "peak", "expected_rules", "source"}
        assert item["onset"] <= item["start"] <= item["peak"] <= item["end"]
        assert item["expected_rules"] == rules[item["id"]]
        assert item["title"] and item["description"]
        assert not {chr(0x2013), chr(0x2014)} & set(item["title"] + item["description"])
    for item in scenarios[:7]:
        start_day, end_day = days[item["id"]]
        assert (item["start"].month, item["start"].day) == start_day
        assert (item["end"].month, item["end"].day) == end_day
        assert item["source"] == ("customer" if item["peak"] <= CUSTOMER_LAST else "model")
    assert [item["source"] for item in scenarios[:7]] == ["customer"] * 4 + ["model"] * 3


def test_customer_episode_starts_match_customer_labels(player):
    """Начало эпизодов заказчика - первый час с его диагнозом не "Норма"; вне эпизодов диагнозы "Норма"."""
    kinds = {
        "imbalance": "vibration",
        "misalignment": "vibration",
        "bearing_wear": "vibration",
        "winding_overheat": "temperature",
    }
    for scenario_id, kind in kinds.items():
        item = scenario(player, scenario_id)
        flagged = [at for at in hours_of(player) if inside(at, item) and player.customer_label(kind, at) != "Норма"]
        assert flagged[0] == item["start"]
        assert flagged[-1] == item["end"] == item["peak"]
    for at in quiet_hours(player):
        if at <= CUSTOMER_LAST:
            assert player.customer_label("vibration", at) == "Норма"
            assert player.customer_label("temperature", at) == "Норма"


def test_values_are_normal_outside_episodes(player):
    """Вне эпизодов все параметры в пределах уставок, а модельные держатся у своих базовых значений."""
    parameters = player.parameters()
    quiet = quiet_hours(player)
    assert len(quiet) == 148
    for at in quiet:
        values = player.snapshot(at)
        assert all(status(item, values[item["code"]]) == "ok" for item in parameters)
        assert mean_current(values) / MODEL.rated_current_a == pytest.approx(1.0, abs=0.04)
        assert values["current_unbalance"] < 2.0
        assert values["press_in"] == pytest.approx(1.5, abs=0.03)
        assert values["flow"] == pytest.approx(47.0, rel=0.03)
        assert abs(efficiency_drop(values)) < 2.0
        assert mismatch(values) < 1.0
        assert values["vib_axial"] < 0.7
        assert values["mode"] == 1.0


def test_imbalance_peak(player):
    """Дисбаланс: 1x выше тревоги по данным заказчика, модельные параметры остаются в норме."""
    values = player.snapshot(scenario(player, "imbalance")["peak"])
    assert values["vib_1x"] > 4.5
    assert values["vib_axial"] < 0.7
    assert mean_current(values) / MODEL.rated_current_a == pytest.approx(1.0, abs=0.04)
    assert values["current_unbalance"] < 2.0
    assert abs(efficiency_drop(values)) < 2.0
    assert values["press_in"] == pytest.approx(1.5, abs=0.03)


def test_misalignment_peak(player):
    """Расцентровка: осевая вибрация растёт вместе с 2x, ток выше на 5-8 %, температуры в норме."""
    item = scenario(player, "misalignment")
    values = player.snapshot(item["peak"])
    assert values["vib_2x"] > 3.0
    assert values["vib_axial"] > 4.5
    assert player.trend("vib_axial", hours=12, at=item["peak"]) > 0.02
    assert 1.04 <= mean_current(values) / MODEL.rated_current_a <= 1.10
    assert 1.05 <= mean_current(values) / MODEL.mean_current(MODEL.duty(values["rpm"])[2]) <= 1.08
    assert values["temp_bearing"] < 75.0 and values["temp_winding"] < 90.0
    assert values["current_unbalance"] < 2.0
    assert efficiency_drop(values) < 10.0
    for at in hours_of(player):
        if item["start"] <= at <= item["end"]:
            now = player.snapshot(at)
            assert 1.045 <= mean_current(now) / MODEL.mean_current(MODEL.duty(now["rpm"])[2]) <= 1.08
    axial = [value for _, value in player.window("vib_axial", hours=100, at=item["peak"])]
    second = [value for _, value in player.window("vib_2x", hours=100, at=item["peak"])]
    assert slope(list(zip(second, axial))) == pytest.approx(1.1, abs=0.1)


def test_bearing_wear_peak(player):
    """Износ подшипника: ВЧ шум и температура подшипника выше тревоги, ток и давление на входе в норме."""
    item = scenario(player, "bearing_wear")
    values = player.snapshot(item["peak"])
    assert values["vib_hf"] > 5.0 and values["temp_bearing"] > 90.0
    assert player.trend("vib_hf", hours=12, at=item["peak"]) > 0
    assert player.trend("temp_bearing", hours=12, at=item["peak"]) > 0
    for at in hours_of(player):
        if inside(at, item):
            now = player.snapshot(at)
            assert mean_current(now) / MODEL.rated_current_a == pytest.approx(1.0, abs=0.04)
            assert now["press_in"] == pytest.approx(1.5, abs=0.03)
            assert now["current_unbalance"] < 2.0


def test_winding_overheat_peak(player):
    """Перегрев обмоток: в фазе тревоги заказчика небаланс токов 7-9 % при неизменном среднем токе."""
    item = scenario(player, "winding_overheat")
    values = player.snapshot(item["peak"])
    assert values["temp_winding"] > 110.0
    assert 7.0 <= values["current_unbalance"] <= 9.0
    assert values["current_a"] < values["current_c"] < values["current_b"]
    assert mean_current(values) / MODEL.rated_current_a == pytest.approx(1.0, abs=0.04)
    assert player.trend("current_unbalance", hours=12, at=item["peak"]) > 0
    alarm = [at for at in hours_of(player) if player.customer_label("temperature", at) == "Тревога: Перегрев обмоток ЭД"]
    assert len(alarm) == 16
    assert all(7.0 <= player.snapshot(at)["current_unbalance"] <= 9.0 for at in alarm)
    assert player.snapshot(item["start"])["current_unbalance"] > 5.0


def test_current_unbalance_exceeds_limit_only_in_winding_episode(player):
    """Небаланс токов выше 5 % встречается только в эпизоде перегрева обмоток."""
    item = scenario(player, "winding_overheat")
    above = [at for at in hours_of(player) if player.snapshot(at)["current_unbalance"] > 5.0]
    assert above and all(inside(at, item) for at in above)
    assert all(player.snapshot(at)["current_unbalance"] > 5.0 for at in hours_of(player) if item["start"] <= at <= item["end"])
    outside = [player.snapshot(at)["current_unbalance"] for at in hours_of(player) if not inside(at, item)]
    assert max(outside) < 2.0


def test_cavitation_peak(player):
    """Кавитация: давление на входе падает с 1,5 до 0,4 бар, ВЧ шум 3-4 g, СКЗ растёт, подшипник не греется."""
    item = scenario(player, "cavitation")
    values = player.snapshot(item["peak"])
    assert player.snapshot(item["onset"])["press_in"] == pytest.approx(1.5, abs=0.02)
    assert values["press_in"] == pytest.approx(0.4, abs=0.03)
    assert 3.0 <= values["vib_hf"] <= 4.0
    assert values["vib_rms"] > 2.0
    assert player.trend("vib_rms", hours=12, at=item["peak"]) > 0.01
    assert player.trend("vib_hf", hours=12, at=item["peak"]) > 0.02
    assert player.trend("press_in", hours=12, at=item["peak"]) < -0.02
    assert values["press_out_true"] - values["press_in"] == pytest.approx(MODEL.pressure_rise_bar * 0.97, abs=0.06)
    assert mean_current(values) / MODEL.rated_current_a == pytest.approx(1.0, abs=0.04)
    for at in hours_of(player):
        if inside(at, item):
            now = player.snapshot(at)
            assert now["temp_bearing"] < 56.0 and now["temp_winding"] < 70.0
            assert now["vib_1x"] < 1.0 and now["vib_2x"] < 0.5
            assert now["vib_hf"] < 5.0
            assert efficiency_drop(now) < 8.0


def test_hydraulic_wear_peak(player):
    """Износ проточной части: подача падает при той же мощности, КПД ниже на 15-18 %, остальное в норме."""
    item = scenario(player, "hydraulic_wear")
    values = player.snapshot(item["peak"])
    assert 15.0 <= efficiency_drop(values) <= 18.0
    assert values["flow"] < 47.0 * 0.96
    assert values["power"] == pytest.approx(MODEL.duty(values["rpm"])[2], rel=0.02)
    for at in hours_of(player):
        if inside(at, item):
            now = player.snapshot(at)
            assert now["vib_rms"] < 1.3 and now["vib_hf"] < 0.5 and now["vib_axial"] < 0.7
            assert now["temp_bearing"] < 56.0 and now["temp_winding"] < 70.0
            assert now["press_in"] == pytest.approx(1.5, abs=0.03)
            assert now["power"] == pytest.approx(MODEL.duty(now["rpm"])[2], rel=0.02)
        if item["start"] <= at <= item["end"]:
            assert 14.5 <= efficiency_drop(player.snapshot(at)) <= 18.0


def test_efficiency_drops_only_in_hydraulic_wear_episode(player):
    """Падение КПД на 15 % и больше встречается только в эпизоде износа проточной части."""
    item = scenario(player, "hydraulic_wear")
    dropped = [at for at in hours_of(player) if efficiency_drop(player.snapshot(at)) >= 15.0]
    assert len(dropped) >= 20 and all(inside(at, item) for at in dropped)
    assert dropped[0] == item["start"]
    outside = [efficiency_drop(player.snapshot(at)) for at in hours_of(player) if not inside(at, item)]
    assert max(outside) < 10.0


def test_sensor_drift_peak(player):
    """Дрейф датчика: электронный датчик показывает на 20 % ниже манометра, КПД при этом не меняется."""
    item = scenario(player, "sensor_drift")
    values = player.snapshot(item["peak"])
    assert values["press_out"] < values["press_out_true"]
    assert mismatch(values) == pytest.approx(20.0, abs=1.0)
    assert values["press_out_true"] == pytest.approx(1.5 + MODEL.pressure_rise_bar, abs=0.08)
    assert abs(efficiency_drop(values)) < 2.0
    assert mismatch(player.snapshot(item["onset"])) < 1.0


def test_gauge_mismatch_exceeds_limit_only_in_drift_episode(player):
    """Расхождение датчика и манометра больше 15 % встречается только в эпизоде дрейфа датчика."""
    item = scenario(player, "sensor_drift")
    above = [at for at in hours_of(player) if mismatch(player.snapshot(at)) > 15.0]
    assert above and all(inside(at, item) for at in above)
    assert above[0] == item["start"] and above[-1] == item["end"]
    outside = [mismatch(player.snapshot(at)) for at in hours_of(player) if not inside(at, item)]
    assert max(outside) < 1.0


def test_run_hours_cross_service_interval_on_tenth_hour(player):
    """Наработка 19190 ч в первой записи, +1 за каждый час работы, 19200 ч - на десятом часу."""
    hours = hours_of(player)
    run_hours = [player.snapshot(at)["run_hours"] for at in hours]
    assert run_hours[0] == 19190.0
    assert run_hours[9] == 19199.0 and run_hours[10] == 19200.0
    assert all(later - earlier == 1.0 for earlier, later in itertools.pairwise(run_hours))
    assert all(player.snapshot(at)["mode"] == 1.0 and player.snapshot(at)["rpm"] > 0 for at in hours)
    assert scenario(player, "maintenance_due")["peak"] == hours[10]
    assert scenario(player, "normal")["peak"] == hours[9]


def test_trend_sign(player):
    """Тренд положителен на растущем отрезке, отрицателен на падающем и близок к нулю в покое."""
    imbalance = scenario(player, "imbalance")["peak"]
    assert player.trend("vib_1x", hours=12, at=imbalance) == pytest.approx(0.045, abs=0.015)
    assert player.trend("vib_1x", hours=24, at=imbalance) > 0
    assert player.trend("temp_winding", hours=12, at=CUSTOMER_LAST) > 0.3
    assert player.trend("press_in", hours=12, at=scenario(player, "cavitation")["peak"]) < 0
    assert abs(player.trend("vib_1x", hours=24, at=datetime(2026, 11, 12, 12))) < 0.01
    assert player.trend("vib_1x", hours=12, at=FIRST + HOUR * 2) is None
    points = player.window("vib_1x", hours=12, at=imbalance)
    assert len(points) == 12 and points[-1][0] == imbalance
    assert player.trend("vib_1x", hours=12, at=imbalance) == pytest.approx(
        slope([((moment - points[0][0]) / HOUR, value) for moment, value in points])
    )


def test_series_are_internally_consistent(player):
    """Небаланс, мощность и КПД в каждой записи точно следуют из сохранённых токов, подачи и давлений."""
    for at in hours_of(player):
        values = player.snapshot(at)
        currents = [values["current_a"], values["current_b"], values["current_c"]]
        mean = sum(currents) / 3
        unbalance = max(abs(current - mean) for current in currents) / mean * 100
        assert values["current_unbalance"] == pytest.approx(unbalance, abs=0.0051)
        assert values["power"] == pytest.approx(5.5 * mean / 11.0, abs=0.0051)
        head = (values["press_out_true"] - values["press_in"]) * 1.0e5 / (1000.0 * 9.80665)
        hydraulic_kw = 1000.0 * 9.80665 * (values["flow"] / 3600) * head / 1000
        assert values["efficiency"] == pytest.approx(hydraulic_kw / values["power"] * 100, abs=0.051)


def test_series_follow_affinity_laws(player):
    """На часах без гидравлических неисправностей подача, напор и мощность следуют оборотам как n, n^2, n^3."""
    excluded = [scenario(player, scenario_id) for scenario_id in ("misalignment", "cavitation", "hydraulic_wear")]
    hours = [at for at in hours_of(player) if not any(inside(at, item) for item in excluded)]
    snapshots = [player.snapshot(at) for at in hours]
    speed = [math.log(values["rpm"]) for values in snapshots]
    flow = slope(list(zip(speed, (math.log(values["flow"]) for values in snapshots))))
    rise = slope(list(zip(speed, (math.log(values["press_out_true"] - values["press_in"]) for values in snapshots))))
    power = slope(list(zip(speed, (math.log(values["power"]) for values in snapshots))))
    assert flow == pytest.approx(1.0, abs=0.2)
    assert rise == pytest.approx(2.0, abs=0.2)
    assert power == pytest.approx(3.0, abs=0.2)
    for values in snapshots:
        expected_flow, expected_head, expected_power = MODEL.duty(values["rpm"])
        assert values["flow"] == pytest.approx(expected_flow, rel=0.01)
        assert values["power"] == pytest.approx(expected_power, rel=0.01)
        assert values["press_out_true"] - values["press_in"] == pytest.approx(1000.0 * 9.80665 * expected_head / 1.0e5, abs=0.03)


def test_extension_reproduces_customer_baseline(player):
    """Модельные сутки повторяют уровни спокойных строк заказчика и его зависимость СКЗ от составляющих."""
    quiet = quiet_hours(player)
    customer = [player.snapshot(at) for at in quiet if at <= CUSTOMER_LAST]
    modelled = [player.snapshot(at) for at in quiet if at > CUSTOMER_LAST]
    assert len(customer) == 120 and len(modelled) == 28
    tolerance = {
        "rpm": 6.0,
        "vib_rms": 0.03,
        "vib_1x": 0.03,
        "vib_2x": 0.03,
        "vib_hf": 0.03,
        "temp_bearing": 0.6,
        "temp_winding": 0.6,
    }
    for code, allowed in tolerance.items():
        customer_mean = sum(values[code] for values in customer) / len(customer)
        modelled_mean = sum(values[code] for values in modelled) / len(modelled)
        assert modelled_mean == pytest.approx(customer_mean, abs=allowed)
        if code in synth.BASELINE:
            assert customer_mean == pytest.approx(synth.BASELINE[code][0], abs=allowed)
    cavitation = scenario(player, "cavitation")
    for at in hours_of(player):
        if inside(at, cavitation):
            continue
        values = player.snapshot(at)
        overall = math.sqrt(values["vib_1x"] ** 2 + values["vib_2x"] ** 2 + 0.5**2) + 0.2 * values["vib_hf"]
        assert values["vib_rms"] == pytest.approx(overall, abs=0.016)


def test_two_builds_are_identical(timeline):
    """Повторная сборка даёт те же ряды и сценарии и не зависит от состояния общего генератора случайных чисел."""
    random.seed(1)
    again = build_player("N-101")
    random.seed(2)
    third = synth.build_timeline(loader.load_customer(), MODEL, RUN_HOURS_START, SERVICE_DUE)
    assert third.times == timeline.times
    assert third.series == timeline.series
    assert third.scenarios == timeline.scenarios
    assert third.labels == timeline.labels
    reference = TelemetryPlayer("N-101", timeline, MODEL)
    for at in timeline.times:
        assert again.snapshot(at) == reference.snapshot(at)
    assert again.scenarios() == reference.scenarios()
    assert again.parameters() == reference.parameters()


def test_cursor_and_scenario_selection(player):
    """Курсор стартует в нормальном режиме, выбор сценария ставит его на пик, снимок по умолчанию берётся на курсор."""
    assert player.cursor == scenario(player, "normal")["peak"] == FIRST + HOUR * 9
    for item in player.scenarios():
        chosen = player.select_scenario(item["id"])
        assert chosen == item
        assert player.cursor == item["peak"]
        assert player.snapshot() == player.snapshot(item["peak"])
    player.set_cursor(datetime(2026, 11, 26, 17, 30))
    assert player.cursor == datetime(2026, 11, 26, 17, 30)
    assert player.snapshot()["temp_bearing"] == 75.2
    assert player.customer_label("temperature") == "Пред: Рост темп. подш."
    assert player.customer_label("vibration") == "Пред: Износ/Шум"
    assert len(player.window("temp_bearing")) == 24
    assert player.trend("temp_bearing") > 0
    scenarios = player.scenarios()
    scenarios[0]["expected_rules"].append("R99")
    assert player.scenarios()[0]["expected_rules"] == ["R02"]


def test_shared_player_is_cached(timeline):
    """get_player отдаёт один общий проигрыватель Н-101 с полной лентой."""
    shared = get_player("N-101")
    assert get_player("N-101") is shared
    assert shared.equipment_id == "N-101"
    assert shared.bounds() == (FIRST, LAST)
    assert shared.snapshot(LAST) == TelemetryPlayer("N-101", timeline, MODEL).snapshot(LAST)
