import 'dart:async';
import 'dart:math' as math;

import '../../core/format/kv_format.dart';
import '../clock.dart';
import '../models/admin.dart';
import '../models/equipment.dart';
import '../models/inspection.dart';
import '../models/workflow.dart';
import '../repositories/change_feed.dart';
import 'mock_db.dart';
import 'seed/seed_admins.dart';
import 'seed/seed_base.dart';
import 'seed/seed_engineer_inspect.dart';
import 'seed/seed_engineer_service.dart';
import 'seed/seed_entry.dart';
import 'seed/seed_master_operator.dart';
import 'seed/seed_story.dart';

/// Задержка ответов демонстрационного сервера.
class MockLatency {
  /// Задержка от [min] до [max] миллисекунд.
  const MockLatency(this.min, this.max);

  /// Как у цехового сервера по Wi-Fi: 250-400 мс, чтобы состояния загрузки были видны, но коротко.
  static const MockLatency network = MockLatency(250, 400);

  /// Без задержки: тесты и снимки дизайна.
  static const MockLatency none = MockLatency(0, 0);

  /// Нижняя граница, мс.
  final int min;

  /// Верхняя граница, мс.
  final int max;
}

/// Демонстрационный сервер в памяти: хранит историю 14.11.2026, применяет изменения ролей и сообщает о них.
///
/// Все репозитории Mock* работают через него, поэтому сценарии между ролями сходятся: сообщение оператора
/// видно мастеру, задание мастера - инженеру, завершённый осмотр закрывает задание. Состояние живёт до
/// перезапуска приложения.
class MockBackend implements KvChangeFeed {
  /// Создаёт сервер и наполняет его историей и дополнениями разделов.
  MockBackend({KvClock? clock, this.latency = MockLatency.network, int seed = 14}) : clock = clock ?? StoryClock(), _random = math.Random(seed) {
    seedStory(db);
    seedBase(db);
    seedEntry(db);
    seedEngineerInspect(db);
    seedEngineerService(db);
    seedMasterOperator(db);
    seedAdmins(db);
  }

  /// Данные.
  final MockDb db = MockDb();

  /// Часы истории.
  final KvClock clock;

  /// Задержка ответов.
  final MockLatency latency;

  final math.Random _random;
  final StreamController<KvDomain> _changes = StreamController<KvDomain>.broadcast();

  /// Номер сотрудника текущего сеанса.
  String? currentUserId;

  /// Токен обновления последнего входа - для входа по биометрии.
  String? lastRefreshToken;

  @override
  Stream<KvDomain> get changes => _changes.stream;

  /// Имя сотрудника текущего сеанса или «Система».
  String get currentUserName {
    for (final AdminUser u in db.users) {
      if (u.id == currentUserId) {
        return u.name;
      }
    }
    return 'Система';
  }

  /// Время истории «09:41».
  String get timeNow => KvFormat.time(clock.now());

  /// Дата истории «14.11.2026».
  String get dateNow => KvFormat.date(clock.now());

  Future<void> _delay() {
    if (latency.max <= 0) {
      return Future<void>.value();
    }
    final int ms = latency.min + _random.nextInt(math.max(1, latency.max - latency.min + 1));
    return Future<void>.delayed(Duration(milliseconds: ms));
  }

  /// Чтение с задержкой сети.
  Future<T> read<T>(T Function() body) async {
    await _delay();
    return body();
  }

  /// Изменение с задержкой сети; после него сообщается об изменении разделов [domains].
  Future<T> write<T>(List<KvDomain> domains, T Function() body) async {
    await _delay();
    final T result = body();
    domains.forEach(notify);
    return result;
  }

  /// Сообщить об изменении раздела.
  void notify(KvDomain domain) {
    if (!_changes.isClosed) {
      _changes.add(domain);
    }
  }

  /// Агрегат по идентификатору или обозначению.
  Equipment unitOf(String id) => db.units.firstWhere((Equipment u) => u.id == id || u.code == id);

  /// Заменить агрегат обновлённой копией.
  void putUnit(Equipment unit) {
    final int i = db.units.indexWhere((Equipment u) => u.id == unit.id);
    db.units[i] = unit;
  }

  /// Добавить уведомление в ленту роли [roleKey] (engineer, master, operator, admin, sec).
  void pushNotification(String roleKey, {required String kind, required String title, required String text, String? target}) {
    final List<AppNotification> list = db.notifications.putIfAbsent(roleKey, () => <AppNotification>[]);
    list.insert(0, AppNotification(id: db.nextId('n-', 0), time: timeNow, kind: kind, title: title, text: text, target: target));
  }

  /// Добавить событие в историю агрегата.
  void pushHistory(String unitId, {required String status, required String title, required String text, String? who}) {
    db.history[unitId] = [
      HistoryEvent(date: dateNow, time: timeNow, status: status, title: title, text: text, who: who ?? currentUserName),
      ...?db.history[unitId],
    ];
  }

  /// Добавить запись в журнал безопасности.
  void pushSecLog(
    String level,
    String text, {
    String? who,
    String kind = '',
    String? title,
    List<(String, String)> details = const <(String, String)>[],
    String? userId,
  }) {
    db.seclog.insert(
      0,
      SecLogEntry(time: timeNow, level: level, who: who ?? currentUserName, text: text, kind: kind, title: title, details: details, userId: userId),
    );
  }

  /// Добавить запись в системный журнал.
  void pushSysLog(String level, String source, String text) {
    db.syslog.insert(0, SysLogEntry(time: timeNow, level: level, source: source, text: text));
  }

  /// Закрыть поток изменений.
  void dispose() => _changes.close();
}
