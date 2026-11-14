import '../models/admin.dart';

/// Администратор ИБ: учётные записи, роли, политика, журнал (/admin/users, /admin/roles, /admin/policy, /admin/security-log).
abstract interface class SecurityRepository {
  /// Учётные записи.
  Future<List<AdminUser>> users();

  /// Учётная запись по номеру.
  Future<AdminUser> user(String id);

  /// Завести учётную запись с временным паролем.
  Future<AdminUser> createUser({required String name, required String email, required String roleCode});

  /// Сменить роль сотрудника.
  Future<AdminUser> changeRole(String userId, String roleCode);

  /// Выдать временный пароль.
  Future<AdminUser> resetPassword(String userId);

  /// Заблокировать: открытые сеансы закрываются.
  Future<AdminUser> block(String userId, {required String reason});

  /// Разблокировать.
  Future<AdminUser> unblock(String userId);

  /// Открытые сеансы; [userId] - одного сотрудника.
  Future<List<UserSession>> sessions({String? userId});

  /// Закрыть сеансы сотрудника или один сеанс [sessionId]; без [userId] - все сеансы кроме своего.
  Future<int> revokeSessions({String? userId, String? sessionId});

  /// Перечень прав.
  Future<List<Permission>> permissions();

  /// Роли.
  Future<List<Role>> roles();

  /// Роль по коду.
  Future<Role> role(String id);

  /// Заготовка новой роли из сценария Г («Старший инженер»).
  Future<Role?> roleTemplate();

  /// Создать роль.
  Future<Role> createRole({required String id, required String name, required List<String> permissions});

  /// Изменить название или права роли.
  Future<Role> updateRole(String id, {String? name, List<String>? permissions});

  /// Удалить пользовательскую роль.
  Future<void> deleteRole(String id);

  /// Политика безопасности.
  Future<SecurityPolicy> policy();

  /// Изменить политику.
  Future<SecurityPolicy> updatePolicy(SecurityPolicy policy);

  /// Журнал безопасности, новые сверху.
  Future<List<SecLogEntry>> securityLog();
}
