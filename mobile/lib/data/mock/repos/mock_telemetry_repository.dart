import 'dart:async';

import '../../models/equipment.dart';
import '../../repositories/change_feed.dart';
import '../../repositories/telemetry_repository.dart';
import '../mock_backend.dart';
import '../mock_series.dart';

/// Телеметрия демонстрационного сервера: показания из истории, ряды по формулам прототипа.
class MockTelemetryRepository implements TelemetryRepository {
  /// Создаёт репозиторий поверх [backend].
  MockTelemetryRepository(this.backend);

  /// Демонстрационный сервер.
  final MockBackend backend;

  @override
  Future<Map<String, Reading>> readings(String unitId) => backend.read(() => Map<String, Reading>.unmodifiable(backend.unitOf(unitId).readings));

  @override
  Future<TelemetrySeries> series(String unitId, String key, TelemetryPeriod period) => backend.read(() {
        final Equipment u = backend.unitOf(unitId);
        final TelemetrySeries s = MockSeries.build(u.id, u.readings[key]!, period);
        final ({double value, String label})? logged = backend.db.sensorPeaks['${u.id}/$key'];
        if (logged == null || logged.value <= s.peakValue || (period != TelemetryPeriod.week && period != TelemetryPeriod.month)) {
          return s;
        }
        return TelemetrySeries(
          unitId: s.unitId,
          key: s.key,
          period: s.period,
          values: s.values,
          labels: s.labels,
          label: s.label,
          unit: s.unit,
          digits: s.digits,
          warn: s.warn,
          alarm: s.alarm,
          peakValue: logged.value,
          peakLabel: logged.label,
        );
      });

  @override
  Stream<Map<String, Reading>> watchReadings(String unitId) async* {
    yield await readings(unitId);
    await for (final KvDomain d in backend.changes) {
      if (d == KvDomain.telemetry || d == KvDomain.equipment) {
        yield backend.unitOf(unitId).readings;
      }
    }
  }
}
