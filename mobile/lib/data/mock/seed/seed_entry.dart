import '../../models/admin.dart';
import '../../models/auth.dart';
import '../mock_db.dart';

/// Дополнения демонстрационных данных раздела «Вход и первый запуск» поверх истории 14.11.2026.
///
/// Вызывается после seedStory и seedBase. Политика входа приводится к обновлению прототипа и сервера
/// (10 неудачных попыток за 5 минут, сеанс 720 ч), а телефон запоминает учётную запись инженера смены,
/// который входил на нём утром: по ней работают вход по биометрии и работа без связи.
void seedEntry(MockDb db) {
  final SecurityPolicy? policy = db.policy;
  if (policy != null) {
    db.policy = policy.copyWith(lockAfter: 10, lockMinutes: 5, sessionHours: 720);
  }
  final AdminUser? engineer = db.users.where((AdminUser u) => u.id == 'u-101').firstOrNull;
  if (engineer != null) {
    entryDeviceOf(db).saved = SavedAccount(
      email: engineer.email,
      name: engineer.name,
      title: db.people['engineer']?.title ?? engineer.roleLabel,
      roleCode: engineer.roleCode,
    );
  }
}

/// Память телефона демонстрационного сервера: что приложение хранит у себя между входами.
class EntryDeviceState {
  /// Учётная запись, сохранённая при последнем входе по паролю; null - на телефоне никто не входил.
  SavedAccount? saved;

  /// Почты, для которых сбой связи с цеховым сервером уже показан: следующая попытка проходит.
  final Set<String> outageShown = <String>{};

  /// Время последней неудачной попытки связи с сервером: «09:41».
  String? lastAttempt;

  /// Временный пароль, с которым сотрудник вошёл впервые (сервер сверяет с ним новый пароль).
  String? tempPassword;
}

final Expando<EntryDeviceState> _devices = Expando<EntryDeviceState>('entry-device');

/// Память телефона, привязанная к данным демонстрационного сервера [db].
EntryDeviceState entryDeviceOf(MockDb db) => _devices[db] ??= EntryDeviceState();

/// Готовые почта и пароль скрытых вариантов входа прототипа (сценарии и пути ролей): ключ - идентификатор экрана.
const Map<String, LoginPreset> entryScenarioLogins = {
  'a-temp-login': LoginPreset(email: 'p.ershov@kst-energo.ru', password: 'Kv7-pT92-xR', biometrics: false),
  'a-blocked-login': LoginPreset(email: 's.belov@kst-energo.ru', password: 'demo12345'),
  'a-login-master': LoginPreset(email: 'm.orlova@kst-energo.ru', password: 'demo12345'),
  'a-login-operator': LoginPreset(email: 'o.kuznetsova@kst-energo.ru', password: 'demo12345'),
  'a-login-admin': LoginPreset(email: 'i.vlasov@kst-energo.ru', password: 'demo12345'),
  'a-login-sec': LoginPreset(email: 'd.zakharov@kst-energo.ru', password: 'demo12345'),
};

/// Блокировка из сценария Д: администратор ИБ закрывает доступ Сергею Белову в 09:41. Скрытый вариант входа
/// a-blocked-login открывается уже после неё, поэтому применяет её, если в приложении её ещё не сделали.
const ({String userId, String blockedAt, String reason}) entryBlockedScenario = (
  userId: 'u-109',
  blockedAt: '14.11.2026, 09:41',
  reason: 'Перевод в другое подразделение',
);

/// Состояние связи с цеховым сервером, которое телефон помнит с последнего обмена (экран «Сервер недоступен»).
const ({String lastExchange, String readingsAt, String unreachableSince, int queue}) entryConnection = (
  lastExchange: '14.11, 09:37',
  readingsAt: '09:37',
  unreachableSince: '09:38',
  queue: 0,
);

/// Подписи ролей контактов на экранах входа по ключу роли дизайна.
const Map<String, String> entryContactRoles = {'sec': 'Администратор ИБ', 'admin': 'Администратор системы'};
