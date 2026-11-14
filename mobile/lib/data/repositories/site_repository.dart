import '../models/people.dart';

/// Площадка, смена и сотрудники.
abstract interface class SiteRepository {
  /// Площадка и смена.
  Future<Site> site();

  /// Сотрудники по ключу роли дизайна: engineer, master, operator, admin, sec.
  Future<Map<String, Person>> people();

  /// Инженеры смены для назначения осмотров.
  Future<List<Person>> engineers();

  /// Проверка связи с цеховым сервером: время отклика в миллисекундах.
  Future<int> ping();
}
