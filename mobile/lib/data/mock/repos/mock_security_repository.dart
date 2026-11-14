import '../../api_exception.dart';
import '../../models/admin.dart';
import '../../repositories/change_feed.dart';
import '../../repositories/security_repository.dart';
import '../mock_backend.dart';
import '../mock_db.dart';

/// Учётные записи, роли, политика и журнал безопасности в демонстрации.
class MockSecurityRepository implements SecurityRepository {
  /// Создаёт репозиторий поверх [backend].
  MockSecurityRepository(this.backend);

  /// Демонстрационный сервер.
  final MockBackend backend;

  MockDb get _db => backend.db;

  static const List<KvDomain> _sec = [KvDomain.security];

  int _userIndex(String id) {
    final int i = _db.users.indexWhere((AdminUser u) => u.id == id);
    if (i < 0) {
      throw const KvApiException(KvFailure.notFound, 'Учётная запись не найдена');
    }
    return i;
  }

  Role _role(String id) => _db.roles.where((Role r) => r.id == id).firstOrNull ?? (throw KvApiException(KvFailure.notFound, 'Роль «$id» не найдена'));

  void _recount() {
    for (int i = 0; i < _db.roles.length; i++) {
      final Role r = _db.roles[i];
      _db.roles[i] = r.copyWith(users: _db.users.where((AdminUser u) => u.roleCode == r.id).length);
    }
  }

  String _tempPassword() {
    const String alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
    final int seed = _db.users.length * 7919 + _db.seclog.length * 104729;
    String part(int k) => List<String>.generate(3, (int j) => alphabet[(seed + k * 31 + j * 17) % alphabet.length]).join();
    return 'Kv${part(1).substring(1)}-${part(2)}-${part(3).substring(0, 2)}';
  }

  @override
  Future<List<AdminUser>> users() => backend.read(() => List<AdminUser>.unmodifiable(_db.users));

  @override
  Future<AdminUser> user(String id) => backend.read(() => _db.users[_userIndex(id)]);

  @override
  Future<AdminUser> createUser({required String name, required String email, required String roleCode}) => backend.write(_sec, () {
        final String key = email.trim().toLowerCase();
        if (_db.users.any((AdminUser u) => u.email == key)) {
          throw const KvApiException(KvFailure.validation, 'Учётная запись с такой почтой уже есть');
        }
        final Role role = _role(roleCode);
        final String temp = _tempPassword();
        final AdminUser u = AdminUser(
          id: _db.nextId('u-', 111),
          name: name,
          roleCode: role.id,
          roleLabel: role.name,
          email: key,
          status: 'temp',
          lastLogin: 'ещё не входил',
          tempPassword: temp,
          tempUntil: '15.11 ${backend.timeNow}',
        );
        _db.users.add(u);
        _db.accounts.add(MockAccount(email: key, password: temp, userId: u.id));
        _recount();
        backend.pushSecLog(
          'info',
          'Создана учётная запись $key, роль ${role.name}',
          kind: 'change',
          title: 'Создана учётная запись',
          details: [('Кто изменил', backend.currentUserName), ('Учётная запись', key), ('Роль', 'нет → ${role.name}'), ('Пароль', 'временный до 15.11, ${backend.timeNow}')],
          userId: u.id,
        );
        return u;
      });

  @override
  Future<AdminUser> changeRole(String userId, String roleCode) => backend.write([..._sec, KvDomain.auth], () {
        final int i = _userIndex(userId);
        final Role role = _role(roleCode);
        final String before = _db.users[i].roleLabel;
        final AdminUser u = _db.users[i].copyWith(roleCode: role.id, roleLabel: role.name);
        _db.users[i] = u;
        _recount();
        backend.pushSecLog(
          'info',
          '${u.name}: роль изменена на «${role.name}»',
          kind: 'change',
          title: 'Изменена роль',
          details: [('Кто изменил', backend.currentUserName), ('Учётная запись', u.email), ('Роль', '$before → ${role.name}')],
          userId: u.id,
        );
        return u;
      });

  @override
  Future<AdminUser> resetPassword(String userId) => backend.write(_sec, () {
        final int i = _userIndex(userId);
        final String temp = _tempPassword();
        final AdminUser u = _db.users[i].copyWith(status: 'temp', tempPassword: temp, tempUntil: '15.11 ${backend.timeNow}');
        _db.users[i] = u;
        for (final MockAccount a in _db.accounts.where((MockAccount a) => a.userId == userId)) {
          a.password = temp;
        }
        backend.pushSecLog(
          'info',
          '${u.email}: выдан временный пароль',
          kind: 'change',
          title: 'Сброс пароля',
          details: [('Кто изменил', backend.currentUserName), ('Учётная запись', u.email), ('Пароль', 'временный до 15.11, ${backend.timeNow}')],
          userId: u.id,
        );
        return u;
      });

  @override
  Future<AdminUser> block(String userId, {required String reason}) => backend.write([..._sec, KvDomain.auth], () {
        final int i = _userIndex(userId);
        final AdminUser u = _db.users[i].copyWith(status: 'blocked', blockReason: reason, blockedAt: '${backend.dateNow}, ${backend.timeNow}', activeSessions: 0);
        _db.users[i] = u;
        _db.sessions.removeWhere((UserSession s) => s.userId == userId);
        backend.pushSecLog(
          'bad',
          'Заблокирована учётная запись ${u.email}',
          kind: 'block',
          title: 'Блокировка входа',
          details: [('Кто изменил', backend.currentUserName), ('Учётная запись', u.email), ('Статус', 'активна → заблокирована'), if (reason.isNotEmpty) ('Причина', reason)],
          userId: u.id,
        );
        return u;
      });

  @override
  Future<AdminUser> unblock(String userId) => backend.write(_sec, () {
        final int i = _userIndex(userId);
        final AdminUser u = _db.users[i].copyWith(status: 'active');
        _db.users[i] = u;
        backend.pushSecLog(
          'ok',
          'Разблокирована учётная запись ${u.email}',
          kind: 'change',
          title: 'Разблокировка входа',
          details: [('Кто изменил', backend.currentUserName), ('Учётная запись', u.email), ('Статус', 'заблокирована → активна')],
          userId: u.id,
        );
        return u;
      });

  @override
  Future<List<UserSession>> sessions({String? userId}) =>
      backend.read(() => _db.sessions.where((UserSession s) => userId == null || s.userId == userId).toList(growable: false));

  @override
  Future<int> revokeSessions({String? userId, String? sessionId}) => backend.write([..._sec, KvDomain.auth], () {
        final int before = _db.sessions.length;
        _db.sessions.removeWhere(
          (UserSession s) => sessionId != null ? s.id == sessionId : (userId != null ? s.userId == userId : s.userId != backend.currentUserId),
        );
        final int closed = before - _db.sessions.length;
        for (int i = 0; i < _db.users.length; i++) {
          final AdminUser u = _db.users[i];
          _db.users[i] = u.copyWith(activeSessions: _db.sessions.where((UserSession s) => s.userId == u.id).length);
        }
        backend.pushSecLog(
          'info',
          'Закрыто сеансов: $closed',
          kind: 'change',
          title: 'Завершены сеансы',
          details: [('Кто изменил', backend.currentUserName), ('Завершено сеансов', '$closed')],
          userId: userId,
        );
        return closed;
      });

  @override
  Future<List<Permission>> permissions() => backend.read(() => List<Permission>.unmodifiable(_db.permissions));

  @override
  Future<List<Role>> roles() => backend.read(() => List<Role>.unmodifiable(_db.roles));

  @override
  Future<Role> role(String id) => backend.read(() => _role(id));

  @override
  Future<Role?> roleTemplate() => backend.read(() => _db.roles.any((Role r) => r.id == _db.seniorRoleTemplate?.id) ? null : _db.seniorRoleTemplate);

  @override
  Future<Role> createRole({required String id, required String name, required List<String> permissions}) => backend.write(_sec, () {
        if (_db.roles.any((Role r) => r.id == id)) {
          throw const KvApiException(KvFailure.validation, 'Роль с таким кодом уже есть');
        }
        final Role r = Role(id: id, name: name, users: 0, system: false, permissions: permissions);
        _db.roles.add(r);
        backend.pushSecLog(
          'info',
          'Создана роль «$name», прав: ${permissions.length}',
          kind: 'change',
          title: 'Создана роль',
          details: [('Кто изменил', backend.currentUserName), ('Роль', name), ('Прав', '${permissions.length}')],
        );
        return r;
      });

  @override
  Future<Role> updateRole(String id, {String? name, List<String>? permissions}) => backend.write(_sec, () {
        final int i = _db.roles.indexWhere((Role r) => r.id == id);
        if (i < 0) {
          throw KvApiException(KvFailure.notFound, 'Роль «$id» не найдена');
        }
        final Role r = _db.roles[i].copyWith(name: name, permissions: permissions);
        _db.roles[i] = r;
        backend.pushSecLog(
          'info',
          'Изменена роль «${r.name}»',
          kind: 'change',
          title: 'Изменены права роли',
          details: [('Кто изменил', backend.currentUserName), ('Роль', r.name), ('Прав', '${r.permissions.length}')],
        );
        return r;
      });

  @override
  Future<void> deleteRole(String id) => backend.write(_sec, () {
        final Role r = _role(id);
        if (r.system || _db.users.any((AdminUser u) => u.roleCode == id)) {
          throw const KvApiException(KvFailure.validation, 'Нельзя удалить системную роль или роль с сотрудниками');
        }
        _db.roles.removeWhere((Role x) => x.id == id);
        backend.pushSecLog(
          'info',
          'Удалена роль «${r.name}»',
          kind: 'change',
          title: 'Удалена роль',
          details: [('Кто изменил', backend.currentUserName), ('Роль', r.name)],
        );
      });

  @override
  Future<SecurityPolicy> policy() => backend.read(() => _db.policy!);

  @override
  Future<SecurityPolicy> updatePolicy(SecurityPolicy policy) => backend.write(_sec, () {
        _db.policy = policy;
        backend.pushSecLog(
          'info',
          'Изменена политика безопасности',
          kind: 'change',
          title: 'Изменена политика',
          details: [('Кто изменил', backend.currentUserName)],
        );
        return policy;
      });

  @override
  Future<List<SecLogEntry>> securityLog() => backend.read(() => List<SecLogEntry>.unmodifiable(_db.seclog));
}
