import 'dart:math' as math;

import '../models/equipment.dart';

/// Ряды телеметрии демонстрации: та же математика, что D.series в js/data.js, поэтому графики совпадают с макетом.
///
/// Время отсчитывается в часах от 15.10.2026 00:00; «сейчас» - 14.11 09:41. Последняя точка ряда равна текущему показанию.
abstract final class MockSeries {
  static const double _tNow = 30 * 24 + 9 + 41 / 60;

  static double _ss(double e0, double e1, double x) {
    final double t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  static double _noise(double t, double a, [double k = 0]) =>
      a * (0.55 * math.sin(t * 0.9 + k) + 0.3 * math.sin(t * 2.3 + 1 + k) + 0.2 * math.sin(t * 5.1 + 2 + k * 2));

  static double _smooth(double t, double a, double k) => a * (0.6 * math.sin(t * 0.35 + k) + 0.4 * math.sin(t * 0.83 + 2 * k));

  static double _gauss(double t, double c, double w) => math.exp(-math.pow((t - c) / w, 2).toDouble());

  static double Function(double)? _model(String unitId, String key) {
    switch ('$unitId/$key') {
      case 'N-101/vib1x':
        return (double t) => 1.95 + 0.35 * t / 730 + 2.5 * _gauss(t, 632, 6) + 0.8 * _ss(676, _tNow, t) + _noise(t, 0.09);
      case 'N-101/vib2x':
        return (double t) => 1.0 + 0.12 * t / 730 + 0.5 * _gauss(t, 632, 7) + 0.08 * _ss(676, _tNow, t) + _noise(t, 0.05, 1);
      case 'N-101/vibHf':
        return (double t) => 1.35 + 0.25 * t / 730 + 0.9 * _gauss(t, 633, 7) + 0.3 * _ss(670, _tNow, t) + _noise(t, 0.06, 2);
      case 'N-101/tBearing':
        return (double t) => 60 + 8 * t / 730 + 6 * _gauss(t, 636, 10) + 9 * _ss(600, _tNow, t) + _noise(t, 0.7, 3);
      case 'N-101/tWinding':
        return (double t) => 79 + 3 * math.sin(t / 24 * 2 * math.pi) + 7 * _gauss(t, 716, 2.6) + _noise(t, 0.6, 4);
      case 'N-101/pressOut':
        return (double t) => 4.6 + _noise(t, 0.05, 5);
      case 'N-101/current':
        return (double t) => 9.6 + 0.2 * t / 730 + _noise(t, 0.12, 6);
      case 'AMS-2/tWinding':
        return (double t) => 82 + 30 * _ss(_tNow - 30, _tNow - 2, t) + _smooth(t, 0.6, 1);
      case 'AMS-2/tBearing':
        return (double t) => 62 + 9 * _ss(_tNow - 30, _tNow - 2, t) + _smooth(t, 0.5, 2);
      case 'AMS-2/vib1x':
        return (double t) => 1.6 + 0.6 * _ss(_tNow - 30, _tNow - 2, t) + _smooth(t, 0.05, 3);
    }
    return null;
  }

  static const Map<TelemetryPeriod, (double, int, List<String>)> _periods = {
    TelemetryPeriod.hour: (1, 60, ['08:41', '09:01', '09:21', '09:41']),
    TelemetryPeriod.day: (24, 72, ['09:41', '15:41', '21:41', '03:41', '09:41']),
    TelemetryPeriod.week: (168, 84, ['08.11', '10.11', '12.11', '14.11']),
    TelemetryPeriod.month: (720, 90, ['15.10', '22.10', '29.10', '05.11', '14.11']),
  };

  /// Ряд показания [r] агрегата [unitId] за период [period].
  static TelemetrySeries build(String unitId, Reading r, TelemetryPeriod period) {
    final (double span, int n, List<String> labels) = _periods[period]!;
    final double Function(double) f = _model(unitId, r.key) ?? (double t) => r.value * (1 + _smooth(t, 0.03, r.value % 7));
    final double t0 = _tNow - span;
    List<double> vals = [for (int i = 0; i < n; i++) f(t0 + span * i / (n - 1))];
    final double corr = r.value - vals.last;
    vals = [for (int i = 0; i < n; i++) math.max(0, vals[i] + corr * (i / (n - 1)))];
    int pi = 0;
    for (int i = 0; i < n; i++) {
      if (vals[i] > vals[pi]) {
        pi = i;
      }
    }
    final double tPeak = t0 + span * pi / (n - 1);
    final int day = (tPeak / 24).floor();
    final int dd = day < 17 ? 15 + day : day - 16;
    final String mm = day < 17 ? '10' : '11';
    return TelemetrySeries(
      unitId: unitId,
      key: r.key,
      period: period,
      values: List<double>.unmodifiable(vals),
      labels: labels,
      label: r.label,
      unit: r.unit,
      digits: r.digits,
      warn: r.warn,
      alarm: r.alarm,
      peakValue: vals[pi],
      peakLabel: '${dd < 10 ? '0' : ''}$dd.$mm',
    );
  }
}
