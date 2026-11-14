import 'package:flutter/foundation.dart';

import 'json.dart';

/// Роль интерфейса: определяет домашний экран и панель вкладок. Код роли сервера переводится в неё через [KvRole.fromCode].
enum KvRole {
  /// Инженер (engineer).
  engineer('engineer', 'Инженер'),

  /// Мастер (master).
  master('master', 'Мастер'),

  /// Оператор (operator).
  operator('operator', 'Оператор'),

  /// Администратор системы (admin).
  admin('admin', 'Админ'),

  /// Администратор ИБ (security_admin).
  sec('security_admin', 'Админ ИБ'),

  /// Старший инженер - пользовательская роль из сценария Г (senior).
  senior('senior', 'Старший инженер');

  const KvRole(this.code, this.label);

  /// Код роли на сервере.
  final String code;

  /// Подпись роли.
  final String label;

  /// Роль интерфейса по коду роли сервера; неизвестные роли с правом осмотра - инженер.
  static KvRole fromCode(String code) => switch (code) {
        'engineer' => KvRole.engineer,
        'master' => KvRole.master,
        'operator' => KvRole.operator,
        'admin' => KvRole.admin,
        'security_admin' || 'sec' => KvRole.sec,
        'senior' => KvRole.senior,
        _ => KvRole.engineer,
      };
}

/// Сотрудник в сеансе (GET /auth/me, поле user ответа POST /auth/login).
@immutable
class AppUser {
  /// Создаёт сотрудника.
  const AppUser({
    required this.id,
    required this.email,
    required this.name,
    required this.roleCode,
    required this.roleTitle,
    this.permissions = const <String>[],
    this.mustChangePassword = false,
    this.title = '',
    this.phone = '',
    this.shift = '',
  });

  /// Из ответа сервера.
  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: Json.str(j, 'id'),
        email: Json.str(j, 'email'),
        name: Json.str(j, 'name'),
        roleCode: Json.str(j, 'role'),
        roleTitle: Json.str(j, 'role_title'),
        permissions: Json.strings(j, 'permissions'),
        mustChangePassword: Json.flag(j, 'must_change_password'),
        title: Json.str(j, 'title'),
        phone: Json.str(j, 'phone'),
        shift: Json.str(j, 'shift'),
      );

  /// Номер учётной записи.
  final String id;

  /// Почта - логин.
  final String email;

  /// Имя и фамилия.
  final String name;

  /// Код роли сервера.
  final String roleCode;

  /// Название роли.
  final String roleTitle;

  /// Коды прав (server/permissions.py).
  final List<String> permissions;

  /// Нужно сменить временный пароль.
  final bool mustChangePassword;

  /// Должность: «Инженер-диагност».
  final String title;

  /// Телефон.
  final String phone;

  /// Смена: «Смена А · 08:00-20:00».
  final String shift;

  /// Роль интерфейса.
  KvRole get role => KvRole.fromCode(roleCode);

  /// Инициалы: «АС».
  String get initials => name.split(' ').where((String w) => w.isNotEmpty).take(2).map((String w) => w[0]).join();

  /// Короткое имя: «А. Смирнов».
  String get short {
    final List<String> p = name.split(' ');
    return p.length < 2 ? name : '${p[0][0]}. ${p[1]}';
  }

  /// Есть ли право с кодом [code].
  bool can(String code) => permissions.contains(code);
}

/// Сеанс после входа (ответ POST /auth/login и /auth/refresh).
@immutable
class AuthSession {
  /// Создаёт сеанс.
  const AuthSession({
    required this.user,
    required this.accessToken,
    required this.refreshToken,
    this.biometricsAllowed = true,
  });

  /// Из ответа сервера.
  factory AuthSession.fromJson(Map<String, dynamic> j) => AuthSession(
        user: AppUser.fromJson(Json.obj(j, 'user')),
        accessToken: Json.str(j, 'access_token'),
        refreshToken: Json.str(j, 'refresh_token'),
        biometricsAllowed: Json.flag(j, 'biometrics_allowed', true),
      );

  /// Сотрудник.
  final AppUser user;

  /// Токен доступа.
  final String accessToken;

  /// Токен обновления (на телефоне - для входа по биометрии).
  final String refreshToken;

  /// Политика разрешает вход по биометрии.
  final bool biometricsAllowed;

  /// Нужно сменить временный пароль до работы.
  bool get mustChangePassword => user.mustChangePassword;
}

/// Сотрудник в справочнике: инженеры, мастера, авторы записей (KV.data.people).
@immutable
class Person {
  /// Создаёт сотрудника справочника.
  const Person({
    required this.id,
    required this.name,
    required this.roleCode,
    required this.roleLabel,
    this.title = '',
    this.email = '',
    this.phone = '',
    this.shift = '',
  });

  /// Из ответа сервера.
  factory Person.fromJson(Map<String, dynamic> j) => Person(
        id: Json.str(j, 'id'),
        name: Json.str(j, 'name'),
        roleCode: Json.str(j, 'role'),
        roleLabel: Json.str(j, 'role_title'),
        title: Json.str(j, 'title'),
        email: Json.str(j, 'email'),
        phone: Json.str(j, 'phone'),
        shift: Json.str(j, 'shift'),
      );

  /// Номер.
  final String id;

  /// Имя и фамилия.
  final String name;

  /// Код роли.
  final String roleCode;

  /// Подпись роли.
  final String roleLabel;

  /// Должность.
  final String title;

  /// Почта.
  final String email;

  /// Телефон.
  final String phone;

  /// Смена.
  final String shift;

  /// Инициалы.
  String get initials => name.split(' ').where((String w) => w.isNotEmpty).take(2).map((String w) => w[0]).join();

  /// Короткое имя: «М. Орлова».
  String get short {
    final List<String> p = name.split(' ');
    return p.length < 2 ? name : '${p[0][0]}. ${p[1]}';
  }
}

/// Площадка и смена (KV.data.site).
@immutable
class Site {
  /// Создаёт описание площадки.
  const Site({required this.name, required this.shift, required this.shiftShort, required this.server, required this.wifi});

  /// Из ответа сервера.
  factory Site.fromJson(Map<String, dynamic> j) => Site(
        name: Json.str(j, 'name'),
        shift: Json.str(j, 'shift'),
        shiftShort: Json.str(j, 'shift_short'),
        server: Json.str(j, 'server'),
        wifi: Json.str(j, 'wifi'),
      );

  /// «Насосная станция № 2».
  final String name;

  /// «Смена А · 08:00-20:00».
  final String shift;

  /// «смена 08:00-20:00».
  final String shiftShort;

  /// Цеховой сервер: «КСТ-СРВ-02».
  final String server;

  /// Сеть Wi-Fi цеха.
  final String wifi;
}
