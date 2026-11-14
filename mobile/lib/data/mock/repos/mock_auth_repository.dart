import '../../api_exception.dart';
import '../../models/admin.dart';
import '../../models/auth.dart';
import '../../models/people.dart';
import '../../repositories/auth_repository.dart';
import '../../repositories/change_feed.dart';
import '../mock_backend.dart';
import '../mock_db.dart';
import '../seed/seed_entry.dart';

/// Вход на демонстрационном сервере; учётные записи и особые состояния описаны в seed_base.dart и seed_entry.dart.
///
/// Недоступный цеховой сервер (offline@kst.demo) отвечает отказом сети на первую попытку, а повторная попытка
/// («Повторить подключение») проходит - как будто связь восстановилась; после успешного входа сбой повторяется снова.
class MockAuthRepository implements AuthRepository {
  /// Создаёт репозиторий поверх [backend].
  MockAuthRepository(this.backend);

  /// Демонстрационный сервер.
  final MockBackend backend;

  MockDb get _db => backend.db;

  EntryDeviceState get _device => entryDeviceOf(backend.db);

  /// Сотрудник по почте входа (без учёта регистра и пробелов по краям) или null.
  AdminUser? _userByEmail(String email) {
    final String key = email.trim().toLowerCase();
    final MockAccount? account = _db.accounts.where((MockAccount a) => a.email == key).firstOrNull;
    return account == null ? null : _db.users.where((AdminUser u) => u.id == account.userId).firstOrNull;
  }

  /// Сотрудник справочника с номером [id] или null.
  Person? _personById(String id) => _db.people.values.where((Person p) => p.id == id).firstOrNull;

  /// Контакт сотрудника справочника с ключом роли дизайна [key]: «Рабочие дни, 09:00-18:00» из графика «5/2 · 09:00-18:00».
  SupportContact _contact(String key) {
    final Person? p = _db.people[key];
    final String shift = p?.shift ?? '';
    final String hours = shift.startsWith('5/2 · ') ? 'Рабочие дни, ${shift.substring(6)}' : shift;
    return SupportContact(
      name: p?.name ?? '',
      role: entryContactRoles[key] ?? p?.roleLabel ?? '',
      phone: p?.phone ?? '',
      email: p?.email ?? '',
      hours: hours,
    );
  }

  AuthSession _sessionFor(AdminUser u) {
    final Role? role = _db.roles.where((Role r) => r.id == u.roleCode).firstOrNull;
    final Person? person = _personById(u.id);
    final String token = 'mock-refresh-${u.id}';
    backend.currentUserId = u.id;
    backend.lastRefreshToken = token;
    return AuthSession(
      user: AppUser(
        id: u.id,
        email: u.email,
        name: u.name,
        roleCode: u.roleCode,
        roleTitle: role?.name ?? u.roleLabel,
        permissions: role?.permissions ?? const <String>[],
        mustChangePassword: u.status == 'temp',
        title: person?.title ?? u.roleLabel,
        phone: person?.phone ?? '',
        shift: person?.shift ?? _db.site.shift,
      ),
      accessToken: 'mock-access-${u.id}',
      refreshToken: token,
      biometricsAllowed: _db.policy?.biometrics ?? true,
    );
  }

  /// Запомнить учётную запись на телефоне после входа по паролю (для биометрии и работы без связи).
  void _remember(AdminUser u) {
    final Person? person = _personById(u.id);
    _device.saved = SavedAccount(email: u.email, name: u.name, title: person?.title ?? u.roleLabel, roleCode: u.roleCode);
  }

  /// Сеанс сотрудника с почтой [email] без проверки пароля и задержки: снимки дизайна и тесты.
  AuthSession demoSession(String email) {
    final MockAccount account = _db.accounts.firstWhere((MockAccount a) => a.email == email.toLowerCase());
    return _sessionFor(_db.users.firstWhere((AdminUser u) => u.id == account.userId));
  }

  @override
  Future<AuthSession> login(String email, String password) => backend.write([KvDomain.auth, KvDomain.security], () {
    final String key = email.trim().toLowerCase();
    final MockAccount? account = _db.accounts.where((MockAccount a) => a.email == key).firstOrNull;
    if (account != null && account.offline && !_device.outageShown.contains(key)) {
      _device.outageShown.add(key);
      _device.lastAttempt = backend.timeNow;
      throw const KvApiException(KvFailure.network, 'Цеховой сервер не отвечает');
    }
    final int lockAfter = _db.policy?.lockAfter ?? 10;
    final int failed = _db.failedLogins[key] ?? 0;
    if (failed >= lockAfter) {
      throw KvApiException(
        KvFailure.locked,
        'Слишком много неудачных попыток входа - повторите через ${(_db.policy?.lockMinutes ?? 5) * 60} с',
      );
    }
    final AdminUser? user = account == null ? null : _db.users.where((AdminUser u) => u.id == account.userId).firstOrNull;
    final bool passwordOk = account != null && (account.password == password || (user?.status == 'temp' && user?.tempPassword == password));
    if (user == null || !passwordOk) {
      final int now = failed + 1;
      _db.failedLogins[key] = now;
      backend.pushSecLog('warn', 'Неудачная попытка входа', who: key);
      throw KvApiException(KvFailure.invalidCredentials, 'Неверная почта или пароль', attemptsLeft: lockAfter - now);
    }
    if (user.status == 'blocked') {
      backend.pushSecLog('bad', 'Попытка входа заблокированной учётной записи', who: user.email);
      throw const KvApiException(KvFailure.blocked, 'Учётная запись заблокирована. Обратитесь к администратору ИБ');
    }
    _db.failedLogins.remove(key);
    _device.outageShown.remove(key);
    if (user.status == 'temp') {
      _device.tempPassword = password;
    }
    backend.pushSecLog('ok', 'Вход по паролю', who: user.name);
    _remember(user);
    return _sessionFor(user);
  });

  @override
  Future<AuthSession> loginWithBiometrics(String refreshToken) => backend.write([KvDomain.auth], () {
    if (!(_db.policy?.biometrics ?? true)) {
      throw const KvApiException(KvFailure.forbidden, 'Вход по биометрии запрещён политикой безопасности - войдите по паролю');
    }
    final String id = refreshToken.replaceFirst('mock-refresh-', '');
    final AdminUser? user = _db.users.where((AdminUser u) => u.id == id).firstOrNull;
    if (user == null) {
      throw const KvApiException(KvFailure.invalidCredentials, 'Токен обновления недействителен или истёк - войдите по паролю');
    }
    if (user.status == 'blocked') {
      throw const KvApiException(KvFailure.blocked, 'Учётная запись заблокирована. Обратитесь к администратору ИБ');
    }
    backend.pushSecLog('ok', 'Вход по биометрии', who: user.name);
    return _sessionFor(user);
  });

  @override
  Future<List<String>> passwordProblems(String password) => backend.read(() => _problems(password));

  /// Проверка пароля по политике, как на сервере (security.password_problems).
  List<String> _problems(String password) {
    final int min = _db.policy?.pwdMin ?? 10;
    return [
      if (password.length < min) 'Пароль должен быть не короче $min символов',
      if (!RegExp(r'[A-Za-zА-Яа-яЁё]').hasMatch(password) || !RegExp(r'\d').hasMatch(password)) 'Пароль должен содержать и буквы, и цифры',
      if (password.isNotEmpty && password.trim() != password) 'Пароль не должен начинаться или заканчиваться пробелом',
    ];
  }

  @override
  Future<AuthSession> changePassword(String newPassword, {String? currentPassword}) =>
      backend.write([KvDomain.auth, KvDomain.security], () {
        final int i = _db.users.indexWhere((AdminUser u) => u.id == backend.currentUserId);
        if (i < 0) {
          throw const KvApiException(KvFailure.invalidCredentials, 'Сеанс завершён');
        }
        final AdminUser u = _db.users[i];
        final String? current = currentPassword ?? _device.tempPassword ?? u.tempPassword;
        final List<String> problems = [..._problems(newPassword), if (newPassword == current) 'Новый пароль должен отличаться от текущего'];
        if (problems.isNotEmpty) {
          throw KvApiException(KvFailure.validation, problems.join('; '));
        }
        for (final MockAccount a in _db.accounts.where((MockAccount a) => a.userId == u.id)) {
          a.password = newPassword;
        }
        final AdminUser updated = AdminUser(
          id: u.id,
          name: u.name,
          roleCode: u.roleCode,
          roleLabel: u.roleLabel,
          email: u.email,
          status: 'active',
          lastLogin: '${backend.dateNow.substring(0, 5)} ${backend.timeNow}',
          biometrics: u.biometrics,
          activeSessions: 1,
        );
        _db.users[i] = updated;
        _device.tempPassword = null;
        backend.pushSecLog('ok', 'Смена временного пароля', who: u.name);
        _remember(updated);
        return _sessionFor(updated);
      });

  @override
  Future<void> logout() => backend.write([KvDomain.auth], () {
    backend.currentUserId = null;
  });

  @override
  Future<LoginPreset?> scenarioLogin(String scenario) => backend.write([KvDomain.auth, KvDomain.security, KvDomain.admin], () {
    final LoginPreset? preset = entryScenarioLogins[scenario];
    if (scenario == 'a-blocked-login') {
      final int i = _db.users.indexWhere((AdminUser u) => u.id == entryBlockedScenario.userId);
      if (i >= 0 && _db.users[i].status != 'blocked') {
        _db.users[i] = _db.users[i].copyWith(
          status: 'blocked',
          blockReason: entryBlockedScenario.reason,
          blockedAt: entryBlockedScenario.blockedAt,
          activeSessions: 0,
        );
        _db.sessions.removeWhere((UserSession s) => s.userId == entryBlockedScenario.userId);
      }
    }
    return preset;
  });

  @override
  Future<SavedAccount?> savedAccount() => backend.read(() => _device.saved);

  @override
  Future<ConnectionInfo> connectionInfo() => backend.read(
    () => ConnectionInfo(
      wifi: _db.server?.wifi ?? _db.site.wifi,
      server: _db.site.server,
      address: _db.server?.ip ?? '',
      lastExchange: entryConnection.lastExchange,
      readingsAt: entryConnection.readingsAt,
      unreachableSince: entryConnection.unreachableSince,
      lastAttempt: _device.lastAttempt ?? backend.timeNow,
      queue: entryConnection.queue,
      appVersion: '${_db.settingsDefaults['appVersion'] ?? ''}',
      admin: _contact('admin'),
    ),
  );

  @override
  Future<SupportContact> securityContact() => backend.read(() => _contact('sec'));

  @override
  Future<BlockedAccount?> blockedAccount(String email) => backend.read(() {
    final AdminUser? u = _userByEmail(email);
    if (u == null || u.status != 'blocked') {
      return null;
    }
    return BlockedAccount(email: u.email, name: u.name, blockedAt: u.blockedAt ?? '', reason: u.blockReason ?? '');
  });

  @override
  Future<PasswordRules> passwordRules() => backend.read(() {
    final AdminUser? u = _db.users.where((AdminUser x) => x.id == backend.currentUserId).firstOrNull;
    return PasswordRules(minLength: _db.policy?.pwdMin ?? 10, tempUntil: u?.status == 'temp' ? u?.tempUntil : null);
  });

  @override
  Future<AuthSession> loginOffline(String email) => backend.write([KvDomain.auth], () {
    final AdminUser? user = _userByEmail(email);
    if (user == null) {
      throw const KvApiException(KvFailure.invalidCredentials, 'На этом телефоне нет сохранённой учётной записи - войдите с паролем');
    }
    return _sessionFor(user);
  });

  @override
  Future<void> checkSession() => backend.read(() {
    final AdminUser? user = _db.users.where((AdminUser u) => u.id == backend.currentUserId).firstOrNull;
    if (user == null) {
      throw const KvApiException(KvFailure.invalidCredentials, 'Сеанс завершён - войдите снова');
    }
    if (user.status == 'blocked') {
      throw const KvApiException(KvFailure.blocked, 'Учётная запись заблокирована. Обратитесь к администратору ИБ');
    }
  });
}
