import '../../api_exception.dart';
import '../../models/admin.dart';
import '../../repositories/admin_repository.dart';
import '../../repositories/change_feed.dart';
import '../mock_backend.dart';
import '../mock_db.dart';

/// Администрирование цехового сервера в демонстрации.
class MockAdminRepository implements AdminRepository {
  /// Создаёт репозиторий поверх [backend].
  MockAdminRepository(this.backend);

  /// Демонстрационный сервер.
  final MockBackend backend;

  final Map<String, (String, String)> _statusBeforeOff = {};

  MockDb get _db => backend.db;

  @override
  Future<ServerStatus> server() => backend.read(() => _db.server!);

  @override
  Future<void> restartServer() => backend.write([KvDomain.admin], () => backend.pushSysLog('info', 'Сервер', 'Службы сервера перезапущены'));

  @override
  Future<ServerStatus> runUpdate() => backend.write([KvDomain.admin], () {
        final ServerStatus s = _db.server!;
        final ServerStatus updated = ServerStatus(
          name: s.name,
          ip: s.ip,
          version: s.updateAvailable ?? s.version,
          uptime: '0 ч',
          cpu: s.cpu,
          ram: s.ram,
          disk: s.disk,
          clients: s.clients,
          wifi: s.wifi,
          lastBackup: s.lastBackup,
          backupSize: s.backupSize,
        );
        _db.server = updated;
        backend.pushSysLog('ok', 'Обновление', 'Установлена версия ${updated.version}');
        return updated;
      });

  @override
  Future<List<DataSource>> sources() => backend.read(() => List<DataSource>.unmodifiable(_db.sources));

  @override
  Future<DataSource> setSourceEnabled(String id, bool enabled) => backend.write([KvDomain.admin], () {
        final int i = _db.sources.indexWhere((DataSource s) => s.id == id);
        if (i < 0) {
          throw const KvApiException(KvFailure.notFound, 'Источник не найден');
        }
        final DataSource s = _db.sources[i];
        DataSource updated;
        if (enabled) {
          final (String, String) before = _statusBeforeOff.remove(id) ?? ('ok', 'Подключено');
          updated = s.copyWith(enabled: true, status: before.$1, statusLabel: before.$2);
        } else {
          _statusBeforeOff[id] = (s.status, s.statusLabel);
          updated = s.copyWith(enabled: false, status: 'unk', statusLabel: 'Опрос выключен');
        }
        _db.sources[i] = updated;
        backend.pushSysLog(enabled ? 'ok' : 'warn', 'Опрос', '${s.name}: опрос ${enabled ? 'включён' : 'выключен'}');
        return updated;
      });

  @override
  Future<DataSource> addSource({required String name, required String proto, required String addr}) => backend.write([KvDomain.admin], () {
        final DataSource s = DataSource(
          id: 'src-${_db.sources.length + 1}',
          name: name,
          proto: proto,
          addr: addr,
          status: 'ok',
          statusLabel: 'Подключено',
          tags: 0,
          poll: '1 с',
          latency: '60 мс',
          security: 'Только чтение',
        );
        _db.sources.add(s);
        backend.pushSysLog('ok', 'Опрос', 'Добавлен источник $name');
        return s;
      });

  @override
  Future<List<TagBinding>> tags({String? unitId}) =>
      backend.read(() => _db.tags.where((TagBinding t) => unitId == null || t.unitId == unitId).toList(growable: false));

  @override
  Future<TagBinding> saveTag(TagBinding tag) => backend.write([KvDomain.admin], () {
        final int i = _db.tags.indexWhere((TagBinding t) => t.tag == tag.tag);
        if (i < 0) {
          _db.tags.add(tag);
        } else {
          _db.tags[i] = tag;
        }
        backend.pushSysLog('info', 'Теги', 'Привязка ${tag.tag} сохранена');
        return tag;
      });

  @override
  Future<List<RecognitionModel>> models() => backend.read(() => List<RecognitionModel>.unmodifiable(_db.models));

  @override
  Future<RecognitionModel> activateModel(String id) => backend.write([KvDomain.admin], () {
        final int i = _db.models.indexWhere((RecognitionModel m) => m.id == id);
        if (i < 0) {
          throw const KvApiException(KvFailure.notFound, 'Модель не найдена');
        }
        final RecognitionModel target = _db.models[i];
        for (int k = 0; k < _db.models.length; k++) {
          final RecognitionModel m = _db.models[k];
          if (k != i && m.name == target.name && m.status == 'active') {
            _db.models[k] = m.copyWith(status: 'archive');
          }
        }
        _db.models[i] = target.copyWith(status: 'active');
        backend.pushSysLog('ok', 'Модели', '${target.name} ${target.version}: модель включена');
        return _db.models[i];
      });

  @override
  Future<List<SysLogEntry>> syslog() => backend.read(() => List<SysLogEntry>.unmodifiable(_db.syslog));

  @override
  Future<List<Backup>> backups() => backend.read(() => List<Backup>.unmodifiable(_db.backups));

  @override
  Future<Backup> createBackup() => backend.write([KvDomain.admin], () {
        final Backup b = Backup(date: backend.dateNow, time: backend.timeNow, size: '1,8 ГБ', kind: 'Вручную', status: 'ok');
        _db.backups.insert(0, b);
        backend.pushSysLog('ok', 'Резерв', 'Резервная копия 1,8 ГБ создана');
        return b;
      });

  @override
  Future<List<Device>> devices() => backend.read(() => List<Device>.unmodifiable(_db.devices));
}
