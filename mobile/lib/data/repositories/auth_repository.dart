import '../models/auth.dart';
import '../models/people.dart';

/// Вход и сеанс (POST /auth/login, /auth/refresh, /auth/logout, /auth/password).
///
/// Ошибки - [KvApiException]: invalidCredentials с attemptsLeft, blocked, locked, network.
abstract interface class AuthRepository {
  /// Вход по почте и паролю.
  Future<AuthSession> login(String email, String password);

  /// Вход по биометрии сохранённым токеном обновления.
  Future<AuthSession> loginWithBiometrics(String refreshToken);

  /// Смена временного пароля при первом входе; возвращает обновлённый сеанс. [currentPassword] - временный
  /// пароль, с которым сотрудник вошёл (сервер проверяет его и то, что новый пароль от него отличается).
  Future<AuthSession> changePassword(String newPassword, {String? currentPassword});

  /// Что не так с паролем по политике безопасности; пустой список - пароль подходит.
  Future<List<String>> passwordProblems(String password);

  /// Выход.
  Future<void> logout();

  /// Готовые почта и пароль демонстрационного сценария [scenario] (идентификатор скрытого варианта входа
  /// прототипа: a-temp-login, a-blocked-login, a-login-master ...); null - сценария нет (настоящий сервер).
  Future<LoginPreset?> scenarioLogin(String scenario);

  /// Учётная запись, сохранённая на телефоне при последнем входе по паролю; null - на телефоне никто не входил.
  Future<SavedAccount?> savedAccount();

  /// Сведения о подключении к цеховому серверу из памяти телефона (доступны без связи).
  Future<ConnectionInfo> connectionInfo();

  /// Контакт администратора ИБ для экранов входа: восстановление пароля, разблокировка.
  Future<SupportContact> securityContact();

  /// Сведения о блокировке учётной записи [email], полученные при отказе во входе (403); null - сведений нет.
  Future<BlockedAccount?> blockedAccount(String email);

  /// Требования к новому паролю текущего сотрудника и срок его временного пароля.
  Future<PasswordRules> passwordRules();

  /// Вход без связи с сервером по учётной записи [email], сохранённой на телефоне. Осмотры встают в очередь.
  Future<AuthSession> loginOffline(String email);

  /// Проверка, что сеанс ещё действует (GET /auth/me). Закрытый сеанс - [KvApiException]: blocked, если учётную
  /// запись заблокировал администратор ИБ, иначе invalidCredentials.
  Future<void> checkSession();
}
