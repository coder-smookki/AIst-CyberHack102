"""Прогноз времени до уставки по линейному тренду последних часов."""

from datetime import datetime

from .thresholds import as_number

MIN_POINTS = 4
MIN_R_SQUARED = 0.5
HORIZON_WINDOWS = 10.0


def hours_to_threshold(points: list[tuple[datetime, float]], threshold: float, direction: str | None = None) -> float | None:
    """Оценивает, через сколько часов после последней точки линейный тренд окна достигнет уставки.

    Прямая подбирается методом наименьших квадратов по всем точкам окна. Возвращает None, когда
    прогноз показывать нельзя: точек меньше четырёх, тренд ровный или уводит от уставки, разброс
    точек слишком велик (коэффициент детерминации ниже 0.5) либо пересечение дальше десяти длин окна.
    direction: "high" - уставка сверху, "low" - снизу; при уже достигнутой уставке вернётся 0.0.
    Без direction сторона определяется по положению тренда относительно уставки: ниже уставки
    ждём роста, выше - снижения. Для параметра с известной стороной уставки direction лучше
    передавать явно, иначе возврат значения к уставке после её превышения тоже даст число.
    """
    limit = as_number(threshold)
    clean = [(moment, as_number(value)) for moment, value in points or []]
    clean = sorted((moment, value) for moment, value in clean if value is not None)
    if limit is None or len(clean) < MIN_POINTS:
        return None
    last_moment = clean[-1][0]
    hours = [(moment - last_moment).total_seconds() / 3600.0 for moment, _ in clean]
    values = [value for _, value in clean]
    span = -hours[0]
    if span <= 0:
        return None
    mean_hour = sum(hours) / len(hours)
    mean_value = sum(values) / len(values)
    spread_hours = sum((hour - mean_hour) ** 2 for hour in hours)
    spread_values = sum((value - mean_value) ** 2 for value in values)
    covariance = sum((hour - mean_hour) * (value - mean_value) for hour, value in zip(hours, values))
    slope = covariance / spread_hours
    fitted_last = mean_value - slope * mean_hour
    if direction is None:
        if fitted_last == limit:
            return None
        rising = fitted_last < limit
    else:
        rising = direction != "low"
        reached = fitted_last >= limit if rising else fitted_last <= limit
        if reached:
            return 0.0
    if spread_values == 0 or (slope <= 0 if rising else slope >= 0):
        return None
    r_squared = covariance * covariance / (spread_hours * spread_values)
    if r_squared < MIN_R_SQUARED:
        return None
    remaining = (limit - fitted_last) / slope
    if remaining > HORIZON_WINDOWS * span:
        return None
    return round(max(remaining, 0.0), 1)
