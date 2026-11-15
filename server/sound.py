"""Анализ звука агрегата, записанного микрофоном телефона во время осмотра.

На вход - WAV PCM 16 бит, моно (стерео сводится в моно), 16-48 кГц, длительностью 2-30 с. Считаются:
относительный уровень (дБ от полной шкалы) и его отличие от собственной нормы агрегата, энергия по полосам
частот, спектральный центроид, эксцесс и коэффициент амплитуды (импульсность - стук, дефект подшипника),
тональные пики и их совпадение с частотой вращения (1x, 2x) и лопаточной частотой, широкополосный
высокочастотный шум, похожий на кавитацию.

Микрофон телефона не калиброван, поэтому абсолютный уровень сравнивается только с записями этого же агрегата,
отмеченными как норма, а без них - с типовым уровнем для типа оборудования. Результат - измерения и признаки-
кандидаты с пояснением по-русски; замечаниями они становятся только после подтверждения инженером.
"""

import io
import itertools
import math
import wave

import numpy as np

MIN_RATE = 16000
MAX_RATE = 48000
MIN_SECONDS = 2.0
MAX_SECONDS = 30.0
MAX_BYTES = 6 * 1024 * 1024
SILENCE_DBFS = -80.0
BANDS = (
    ("low", "Низкие частоты, до 300 Гц", 0.0, 300.0),
    ("mid", "Средние частоты, 300-2000 Гц", 300.0, 2000.0),
    ("high", "Высокие частоты, 2-8 кГц", 2000.0, 8000.0),
    ("ultra", "Очень высокие частоты, выше 8 кГц", 8000.0, None),
)
TYPE_BASELINES = {"inline_centrifugal_pump": -32.0, "progressive_cavity_pump": -34.0}
DEFAULT_BASELINE = -33.0
LOUDER_DB = 6.0
KURTOSIS_LIMIT = 6.0
CREST_LIMIT = 6.0
PEAK_PROMINENCE_DB = 12.0
PEAK_MIN_HZ = 20.0
PEAK_MAX_HZ = 2000.0
MAX_PEAKS = 5
MATCH_SHARE = 0.03
MATCH_MIN_HZ = 1.5
HF_SHARE_LIMIT = 0.5
FLATNESS_LIMIT = 0.3
BASELINE_RECORDINGS = 3
SPECTRUM_POINTS = 96
SIGN_TITLES = {
    "noise_high": "Повышенный шум агрегата",
    "noise_impulsive": "Импульсный шум (стук)",
    "noise_tonal": "Тональный шум на частоте вращения",
    "cavitation_noise": "Шум кавитации",
}
CANDIDATE_NOTE = "Признаки по звуку - кандидаты: замечанием они становятся только после подтверждения инженером"


class SoundError(ValueError):
    """Запись нельзя проанализировать: неверный формат, длительность или пустой сигнал."""


def _number(value: float, digits: int = 1) -> str:
    """Число для русского текста: заданное число знаков после запятой, десятичная запятая."""
    return f"{value:.{digits}f}".replace(".", ",")


def read_wav(data: bytes) -> tuple[np.ndarray, int]:
    """Читает WAV PCM 16 бит и возвращает отсчёты в диапазоне -1..1 (моно) и частоту дискретизации.

    Неподходящий формат, частота вне 16-48 кГц или длительность вне 2-30 с - SoundError с понятным текстом.
    """
    if len(data) > MAX_BYTES:
        raise SoundError(f"Запись больше {MAX_BYTES // (1024 * 1024)} МБ")
    try:
        with wave.open(io.BytesIO(data), "rb") as source:
            channels, width, rate = source.getnchannels(), source.getsampwidth(), source.getframerate()
            if source.getcomptype() != "NONE" or width != 2:
                raise SoundError("Нужна запись WAV PCM 16 бит")
            if channels not in (1, 2):
                raise SoundError("Нужна запись моно")
            frames = source.readframes(source.getnframes())
    except (wave.Error, EOFError) as error:
        raise SoundError("Файл не является записью WAV") from error
    if not MIN_RATE <= rate <= MAX_RATE:
        raise SoundError(f"Частота дискретизации {rate} Гц вне допустимых 16-48 кГц")
    samples = np.frombuffer(frames[: len(frames) // (2 * channels) * 2 * channels], dtype="<i2").astype(np.float64)
    if channels == 2:
        samples = samples.reshape(-1, 2).mean(axis=1)
    seconds = samples.size / rate
    if not MIN_SECONDS <= seconds <= MAX_SECONDS:
        raise SoundError(f"Длительность записи {_number(seconds)} с вне допустимых 2-30 с")
    return samples / 32768.0, rate


def _db(value: float) -> float:
    """Уровень в децибелах от полной шкалы; тишина ограничена снизу."""
    return SILENCE_DBFS if value <= 1e-8 else max(20.0 * math.log10(value), SILENCE_DBFS)


def _spectrum(samples: np.ndarray, rate: int) -> tuple[np.ndarray, np.ndarray]:
    """Средний спектр мощности по окнам Ханна с перекрытием 50 %; разрешение около 1 Гц."""
    size = 1 << int(math.ceil(math.log2(rate)))
    size = min(size, 1 << int(math.floor(math.log2(samples.size))))
    window = np.hanning(size)
    step = size // 2
    power = np.zeros(size // 2 + 1)
    count = 0
    for start in range(0, samples.size - size + 1, step):
        chunk = samples[start : start + size]
        power += np.abs(np.fft.rfft((chunk - chunk.mean()) * window)) ** 2
        count += 1
    freqs = np.fft.rfftfreq(size, 1.0 / rate)
    return freqs, power / max(count, 1)


def _bands(freqs: np.ndarray, power: np.ndarray) -> list[dict]:
    """Доля энергии и уровень по полосам частот."""
    total = float(power[1:].sum()) or 1e-20
    result = []
    for code, title, low, high in BANDS:
        mask = (freqs >= low) & (freqs < (high if high is not None else np.inf)) & (freqs > 0)
        energy = float(power[mask].sum())
        result.append(
            {
                "code": code,
                "title": title,
                "from_hz": low,
                "to_hz": high,
                "share": round(energy / total, 4),
                "db": round(10.0 * math.log10(energy / total) if energy > 0 else SILENCE_DBFS, 1),
            }
        )
    return result


def _flatness(power: np.ndarray) -> float:
    """Спектральная плоскость участка: 1 - белый шум, около 0 - отдельные тона."""
    values = power[power > 0]
    if values.size == 0:
        return 0.0
    return float(np.exp(np.mean(np.log(values))) / np.mean(values))


def _peaks(freqs: np.ndarray, power: np.ndarray) -> list[dict]:
    """Тональные пики 20-2000 Гц, выступающие над соседним фоном не меньше чем на 12 дБ, сильнейшие первыми.

    Частота уточняется параболой по трём соседним отсчётам спектра.
    """
    level = 10.0 * np.log10(power + 1e-20)
    step = freqs[1] - freqs[0]
    half = max(int(round(20.0 / step)), 3)
    found = []
    for index in np.flatnonzero((freqs >= PEAK_MIN_HZ) & (freqs <= PEAK_MAX_HZ)):
        if index < 1 or index >= level.size - 1 or level[index] < level[index - 1] or level[index] < level[index + 1]:
            continue
        around = np.concatenate([level[max(index - half, 0) : max(index - 2, 0)], level[index + 3 : index + half + 1]])
        if around.size == 0:
            continue
        prominence = float(level[index] - np.median(around))
        if prominence < PEAK_PROMINENCE_DB:
            continue
        left, centre, right = level[index - 1], level[index], level[index + 1]
        bend = left - 2 * centre + right
        shift = 0.5 * (left - right) / bend if bend != 0 else 0.0
        found.append({"freq_hz": round(float(freqs[index] + shift * step), 1), "prominence_db": round(prominence, 1)})
    found.sort(key=lambda peak: peak["prominence_db"], reverse=True)
    kept = []
    for peak in found:
        if all(abs(peak["freq_hz"] - other["freq_hz"]) > 3 * step for other in kept):
            kept.append(peak)
        if len(kept) == MAX_PEAKS:
            break
    return kept


def _match(freq: float, shaft: float | None, blades: int | None) -> tuple[str | None, str | None]:
    """Сопоставляет частоту пика с гармониками частоты вращения и лопаточной частотой."""
    if not shaft:
        return None, None
    targets = [(f"{order}x", order * shaft, f"{order}× частоты вращения") for order in (1, 2, 3, 4)]
    if blades:
        targets.insert(0, ("bpf", blades * shaft, f"лопаточной частоте ({blades} лопаток × частота вращения)"))
    for code, target, title in targets:
        if abs(freq - target) <= max(MATCH_MIN_HZ, MATCH_SHARE * target):
            return code, title
    return None, None


def _spectrum_points(freqs: np.ndarray, power: np.ndarray, rate: int) -> list[dict]:
    """Спектр для графика: около 96 точек на логарифмической шкале 20 Гц - половина частоты дискретизации."""
    level = 10.0 * np.log10(power + 1e-20)
    edges = np.geomspace(20.0, rate / 2.0, SPECTRUM_POINTS + 1)
    points = []
    for low, high in itertools.pairwise(edges):
        mask = (freqs >= low) & (freqs < high)
        if mask.any():
            points.append({"f": round(float(np.sqrt(low * high)), 1), "db": round(float(level[mask].max()), 1)})
    return points


def analyse(samples: np.ndarray, rate: int, *, rpm: float | None = None, blades: int | None = None) -> dict:
    """Считает показатели звука: уровень, импульсность, полосы, центроид, тональные пики и их совпадения."""
    centred = samples - samples.mean()
    rms = float(np.sqrt(np.mean(centred**2)))
    if rms <= 1e-6:
        raise SoundError("Запись пустая: сигнала нет")
    peak = float(np.max(np.abs(centred)))
    kurtosis = float(np.mean(centred**4) / rms**4)
    freqs, power = _spectrum(centred, rate)
    total = float(power[1:].sum()) or 1e-20
    centroid = float((freqs * power).sum() / total)
    shaft = rpm / 60.0 if rpm else None
    peaks = []
    for item in _peaks(freqs, power):
        code, title = _match(item["freq_hz"], shaft, blades)
        peaks.append({**item, "match": code, "match_title": title})
    high = (freqs >= 2000.0) & (freqs < 8000.0)
    return {
        "duration_s": round(samples.size / rate, 2),
        "sample_rate": rate,
        "level_dbfs": round(_db(rms), 1),
        "peak_dbfs": round(_db(peak), 1),
        "crest_factor": round(peak / rms, 2),
        "kurtosis": round(kurtosis, 2),
        "centroid_hz": round(centroid, 1),
        "bands": _bands(freqs, power),
        "hf_flatness": round(_flatness(power[high]), 3),
        "rpm": rpm,
        "shaft_hz": round(shaft, 2) if shaft else None,
        "blades": blades,
        "blade_pass_hz": round(blades * shaft, 1) if blades and shaft else None,
        "peaks": peaks,
        "spectrum": _spectrum_points(freqs, power, rate),
    }


def baseline_level(equipment_type: str | None, levels: list[float], specs: dict | None = None) -> dict:
    """Норма уровня для агрегата: среднее первых записей-норм, иначе уровень из карточки, иначе типовой.

    levels - уровни записей этого агрегата, отмеченных как норма, в порядке записи.
    """
    if levels:
        used = levels[:BASELINE_RECORDINGS]
        return {
            "dbfs": round(sum(used) / len(used), 1),
            "source": "recordings",
            "recordings": len(used),
            "title": f"среднее {len(used)} записей этого агрегата, отмеченных как норма",
        }
    card_level = (specs or {}).get("sound_baseline_dbfs")
    if isinstance(card_level, (int, float)):
        return {"dbfs": float(card_level), "source": "card", "recordings": 0, "title": "уровень из карточки агрегата"}
    level = TYPE_BASELINES.get(equipment_type or "", DEFAULT_BASELINE)
    return {
        "dbfs": level,
        "source": "model_default",
        "recordings": 0,
        "title": "типовой уровень для этого типа оборудования (записей-норм ещё нет)",
    }


def candidates(measures: dict, baseline: dict) -> list[dict]:
    """Признаки-кандидаты по измерениям с пояснением по-русски; каждый можно подтвердить как дефект с признаком sign."""
    found = []

    def add(sign: str, text: str, value: float | None) -> None:
        """Добавляет кандидата с готовым запросом подтверждения."""
        found.append(
            {"sign": sign, "title": SIGN_TITLES[sign], "text": text, "value": value, "confirm": {"kind": "defect", "sign": sign}}
        )

    delta = measures["level_dbfs"] - baseline["dbfs"]
    if delta >= LOUDER_DB:
        against = "прошлых осмотров" if baseline["source"] == "recordings" else "типового уровня"
        add("noise_high", f"Повышенный шум относительно {against} +{_number(delta, 0)} дБ", round(delta, 1))
    if measures["kurtosis"] >= KURTOSIS_LIMIT and measures["crest_factor"] >= CREST_LIMIT:
        add(
            "noise_impulsive",
            f"Импульсный шум (стук), коэффициент амплитуды {_number(measures['crest_factor'])}, "
            f"эксцесс {_number(measures['kurtosis'])}",
            measures["crest_factor"],
        )
    for peak in measures["peaks"]:
        if peak["match"]:
            add(
                "noise_tonal", f"Тональная составляющая {_number(peak['freq_hz'], 0)} Гц ≈ {peak['match_title']}", peak["freq_hz"]
            )
            break
    bands = {band["code"]: band for band in measures["bands"]}
    hf_share = bands["high"]["share"] + bands["ultra"]["share"]
    if hf_share >= HF_SHARE_LIMIT and measures["hf_flatness"] >= FLATNESS_LIMIT:
        add(
            "cavitation_noise",
            f"Широкополосный высокочастотный шум, похожий на кавитацию: " f"{_number(hf_share * 100, 0)} % энергии выше 2 кГц",
            round(hf_share, 3),
        )
    return found


def summary(measures: dict, baseline: dict) -> dict:
    """Итог анализа для хранения и ответа: измерения, норма уровня с отличием, кандидаты и оговорка."""
    return {
        **measures,
        "baseline": {**baseline, "delta_db": round(measures["level_dbfs"] - baseline["dbfs"], 1)},
        "candidates": candidates(measures, baseline),
        "note": CANDIDATE_NOTE,
    }
