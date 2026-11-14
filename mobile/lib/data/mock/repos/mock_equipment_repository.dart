import '../../api_exception.dart';
import '../../models/equipment.dart';
import '../../models/inspection.dart';
import '../../repositories/change_feed.dart';
import '../../repositories/equipment_repository.dart';
import '../mock_backend.dart';

/// Оборудование демонстрационного сервера.
class MockEquipmentRepository implements EquipmentRepository {
  /// Создаёт репозиторий поверх [backend].
  MockEquipmentRepository(this.backend);

  /// Демонстрационный сервер.
  final MockBackend backend;

  Equipment _unit(String id) {
    for (final Equipment u in backend.db.units) {
      if (u.id == id || u.code == id) {
        return u;
      }
    }
    throw const KvApiException(KvFailure.notFound, 'Оборудование не найдено');
  }

  @override
  Future<List<Equipment>> units() => backend.read(() => List<Equipment>.unmodifiable(backend.db.units));

  @override
  Future<Equipment> unit(String id) => backend.read(() => _unit(id));

  @override
  Future<List<Equipment>> search(String query) => backend.read(() {
        final String q = query.trim().toLowerCase().replaceAll('ё', 'е');
        if (q.isEmpty) {
          return List<Equipment>.unmodifiable(backend.db.units);
        }
        return backend.db.units
            .where((Equipment u) => [u.id, u.code, u.model, u.modelShort, u.serial, u.name].any((String f) => f.toLowerCase().contains(q)))
            .toList(growable: false);
      });

  @override
  Future<Equipment?> bySerial(String serial) => backend.read(() => backend.db.units.where((Equipment u) => u.serial == serial).firstOrNull);

  @override
  Future<List<HistoryEvent>> history(String unitId) => backend.read(() => List<HistoryEvent>.unmodifiable(backend.db.history[_unit(unitId).id] ?? const <HistoryEvent>[]));

  @override
  Future<Equipment> setMode(String unitId, String mode, {String? reason}) =>
      backend.write([KvDomain.equipment, KvDomain.notifications], () {
        final Equipment u = _unit(unitId);
        final (String label, String? status, String? statusLabel) = switch (mode) {
          'repair' => ('На ремонте', 'info', 'На ремонте'),
          'reserve' => ('В резерве', null, null),
          'stopped' => ('Остановлен', null, null),
          _ => ('В работе', u.status == 'info' ? 'ok' : null, u.status == 'info' ? 'Норма' : null),
        };
        final Equipment updated = u.copyWith(mode: mode, modeLabel: label, status: status, statusLabel: statusLabel);
        backend.putUnit(updated);
        backend.pushHistory(u.id, status: 'info', title: 'Режим: ${label.toLowerCase()}', text: reason ?? 'Решение мастера');
        backend.pushNotification('operator', kind: 'info', title: '${u.code}: ${label.toLowerCase()}', text: reason ?? 'Режим изменён мастером', target: '/operator/objects');
        return updated;
      });
}
