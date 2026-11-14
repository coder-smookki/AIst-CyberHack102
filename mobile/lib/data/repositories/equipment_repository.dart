import '../models/equipment.dart';
import '../models/inspection.dart';

/// Оборудование (GET /equipment, /equipment/{id}, /by-serial, /history, POST /mode).
abstract interface class EquipmentRepository {
  /// Все агрегаты станции.
  Future<List<Equipment>> units();

  /// Агрегат по идентификатору ('N-101') или обозначению ('Н-101').
  Future<Equipment> unit(String id);

  /// Поиск по номеру, модели, серийному номеру.
  Future<List<Equipment>> search(String query);

  /// Агрегат по серийному номеру с шильдика или null.
  Future<Equipment?> bySerial(String serial);

  /// История агрегата, новые сверху.
  Future<List<HistoryEvent>> history(String unitId);

  /// Смена режима агрегата: running, reserve, repair, stopped.
  Future<Equipment> setMode(String unitId, String mode, {String? reason});
}
