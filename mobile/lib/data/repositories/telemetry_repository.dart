import '../models/equipment.dart';

/// Телеметрия (GET /equipment/{id}/telemetry, /telemetry/{code}).
abstract interface class TelemetryRepository {
  /// Текущие показания агрегата по ключам.
  Future<Map<String, Reading>> readings(String unitId);

  /// Ряд значений показания [key] за период.
  Future<TelemetrySeries> series(String unitId, String key, TelemetryPeriod period);

  /// Живые показания: первое событие сразу, затем при каждом изменении.
  Stream<Map<String, Reading>> watchReadings(String unitId);
}
