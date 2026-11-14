import '../models/admin.dart';

/// Администратор системы: сервер, источники, теги, модели, журнал, резерв (GET /system/status и данные дизайна).
abstract interface class AdminRepository {
  /// Состояние цехового сервера.
  Future<ServerStatus> server();

  /// Перезапуск служб сервера.
  Future<void> restartServer();

  /// Установить доступное обновление.
  Future<ServerStatus> runUpdate();

  /// Источники данных.
  Future<List<DataSource>> sources();

  /// Включить или выключить опрос источника.
  Future<DataSource> setSourceEnabled(String id, bool enabled);

  /// Добавить источник.
  Future<DataSource> addSource({required String name, required String proto, required String addr});

  /// Привязки тегов; [unitId] - по агрегату.
  Future<List<TagBinding>> tags({String? unitId});

  /// Сохранить привязку тега.
  Future<TagBinding> saveTag(TagBinding tag);

  /// Модели распознавания.
  Future<List<RecognitionModel>> models();

  /// Сделать модель рабочей.
  Future<RecognitionModel> activateModel(String id);

  /// Системный журнал, новые сверху.
  Future<List<SysLogEntry>> syslog();

  /// Резервные копии.
  Future<List<Backup>> backups();

  /// Создать резервную копию.
  Future<Backup> createBackup();

  /// Устройства сотрудников.
  Future<List<Device>> devices();
}
