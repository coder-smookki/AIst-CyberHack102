import 'package:flutter/foundation.dart';

import 'json.dart';

/// Состояние цехового сервера (GET /system/status и данные дизайна).
@immutable
class ServerStatus {
  /// Создаёт состояние.
  const ServerStatus({
    required this.name,
    required this.ip,
    required this.version,
    required this.uptime,
    required this.cpu,
    required this.ram,
    required this.disk,
    required this.clients,
    required this.wifi,
    required this.lastBackup,
    required this.backupSize,
    this.updateAvailable,
    this.updateSize,
    this.updateNotes,
  });

  /// «Цеховой сервер КСТ-СРВ-02».
  final String name;

  /// Адрес.
  final String ip;

  /// Версия ПО.
  final String version;

  /// Время работы «18 сут 6 ч».
  final String uptime;

  /// Загрузка процессора, %.
  final int cpu;

  /// Память, %.
  final int ram;

  /// Диск, %.
  final int disk;

  /// Подключённых устройств.
  final int clients;

  /// Сеть.
  final String wifi;

  /// Последняя резервная копия.
  final String lastBackup;

  /// Размер копии.
  final String backupSize;

  /// Доступная версия обновления.
  final String? updateAvailable;

  /// Размер обновления.
  final String? updateSize;

  /// Что нового.
  final String? updateNotes;
}

/// Источник данных: OPC UA, Modbus.
@immutable
class DataSource {
  /// Создаёт источник.
  const DataSource({
    required this.id,
    required this.name,
    required this.proto,
    required this.addr,
    required this.status,
    required this.statusLabel,
    required this.tags,
    required this.poll,
    required this.latency,
    required this.security,
    this.enabled = true,
  });

  /// Код.
  final String id;

  /// Название.
  final String name;

  /// Протокол.
  final String proto;

  /// Адрес.
  final String addr;

  /// ok, warn, bad, unk.
  final String status;

  /// «Подключено».
  final String statusLabel;

  /// Число тегов.
  final int tags;

  /// Период опроса.
  final String poll;

  /// Задержка.
  final String latency;

  /// Защита канала.
  final String security;

  /// Опрос включён.
  final bool enabled;

  /// Копия с другим состоянием опроса.
  DataSource copyWith({bool? enabled, String? status, String? statusLabel}) => DataSource(
        id: id,
        name: name,
        proto: proto,
        addr: addr,
        status: status ?? this.status,
        statusLabel: statusLabel ?? this.statusLabel,
        tags: tags,
        poll: poll,
        latency: latency,
        security: security,
        enabled: enabled ?? this.enabled,
      );
}

/// Привязка тега источника к показанию агрегата.
@immutable
class TagBinding {
  /// Создаёт привязку.
  const TagBinding({required this.tag, required this.unitId, required this.param, required this.eu, required this.value, required this.sourceId, required this.addr});

  /// Имя тега.
  final String tag;

  /// Агрегат.
  final String unitId;

  /// Показание.
  final String param;

  /// Единица.
  final String eu;

  /// Текущее значение.
  final String value;

  /// Источник.
  final String sourceId;

  /// Адрес регистра или узла.
  final String addr;
}

/// Модель распознавания.
@immutable
class RecognitionModel {
  /// Создаёт модель.
  const RecognitionModel({
    required this.id,
    required this.name,
    required this.version,
    required this.date,
    required this.status,
    required this.metric,
    required this.classes,
    required this.fps,
    required this.size,
  });

  /// Код.
  final String id;

  /// Название.
  final String name;

  /// Версия.
  final String version;

  /// Дата.
  final String date;

  /// active или test.
  final String status;

  /// Главная метрика.
  final String metric;

  /// Классов.
  final int classes;

  /// Скорость.
  final String fps;

  /// Размер.
  final String size;

  /// Копия с другим состоянием.
  RecognitionModel copyWith({String? status}) =>
      RecognitionModel(id: id, name: name, version: version, date: date, status: status ?? this.status, metric: metric, classes: classes, fps: fps, size: size);
}

/// Запись системного журнала.
@immutable
class SysLogEntry {
  /// Создаёт запись.
  const SysLogEntry({
    required this.time,
    required this.level,
    required this.source,
    required this.text,
    this.details = const <(String, String)>[],
    this.ref,
  });

  /// Время.
  final String time;

  /// ok, info, warn, bad.
  final String level;

  /// Подсистема.
  final String source;

  /// Текст.
  final String text;

  /// Подробности события: пары «поле - значение».
  final List<(String, String)> details;

  /// Связанный объект: «source:src-vib», «tags:AMS-2», «maint»; null - без перехода.
  final String? ref;
}

/// Резервная копия.
@immutable
class Backup {
  /// Создаёт запись.
  const Backup({required this.date, required this.time, required this.size, required this.kind, required this.status});

  /// Дата.
  final String date;

  /// Время.
  final String time;

  /// Размер.
  final String size;

  /// Вид.
  final String kind;

  /// Состояние.
  final String status;
}

/// Устройство сотрудника.
@immutable
class Device {
  /// Создаёт запись.
  const Device({required this.name, required this.who, required this.last, this.version = ''});

  /// Название.
  final String name;

  /// Чьё.
  final String who;

  /// Последний вход.
  final String last;

  /// Версия приложения на устройстве.
  final String version;
}

/// Учётная запись для администратора ИБ (GET /admin/users, user_admin_view).
@immutable
class AdminUser {
  /// Создаёт запись.
  const AdminUser({
    required this.id,
    required this.name,
    required this.roleCode,
    required this.roleLabel,
    required this.email,
    required this.status,
    required this.lastLogin,
    this.biometrics = false,
    this.blockReason,
    this.blockedAt,
    this.tempPassword,
    this.tempUntil,
    this.activeSessions = 0,
  });

  /// Из ответа сервера.
  factory AdminUser.fromJson(Map<String, dynamic> j) => AdminUser(
        id: Json.str(j, 'id'),
        name: Json.str(j, 'name'),
        roleCode: Json.str(j, 'role'),
        roleLabel: Json.str(j, 'role_title'),
        email: Json.str(j, 'email'),
        status: Json.flag(j, 'must_change_password') && Json.flag(j, 'is_active', true) ? 'temp' : Json.str(j, 'status', 'active'),
        lastLogin: Json.str(j, 'last_login_at'),
        activeSessions: Json.integer(j, 'active_sessions'),
      );

  /// Номер.
  final String id;

  /// Имя.
  final String name;

  /// Код роли.
  final String roleCode;

  /// Название роли.
  final String roleLabel;

  /// Почта.
  final String email;

  /// active, temp (временный пароль), blocked.
  final String status;

  /// Последний вход.
  final String lastLogin;

  /// Входит по биометрии.
  final bool biometrics;

  /// Причина блокировки.
  final String? blockReason;

  /// Когда заблокирована.
  final String? blockedAt;

  /// Выданный временный пароль.
  final String? tempPassword;

  /// Срок временного пароля.
  final String? tempUntil;

  /// Открытых сеансов.
  final int activeSessions;

  /// Копия с изменениями.
  AdminUser copyWith({
    String? roleCode,
    String? roleLabel,
    String? status,
    String? blockReason,
    String? blockedAt,
    String? tempPassword,
    String? tempUntil,
    int? activeSessions,
  }) =>
      AdminUser(
        id: id,
        name: name,
        roleCode: roleCode ?? this.roleCode,
        roleLabel: roleLabel ?? this.roleLabel,
        email: email,
        status: status ?? this.status,
        lastLogin: lastLogin,
        biometrics: biometrics,
        blockReason: blockReason ?? this.blockReason,
        blockedAt: blockedAt ?? this.blockedAt,
        tempPassword: tempPassword ?? this.tempPassword,
        tempUntil: tempUntil ?? this.tempUntil,
        activeSessions: activeSessions ?? this.activeSessions,
      );
}

/// Право доступа (GET /admin/permissions).
@immutable
class Permission {
  /// Создаёт право.
  const Permission({required this.key, required this.label, required this.group});

  /// Из ответа сервера.
  factory Permission.fromJson(Map<String, dynamic> j) => Permission(key: Json.str(j, 'code'), label: Json.str(j, 'title'), group: Json.str(j, 'group_title'));

  /// Код.
  final String key;

  /// Название.
  final String label;

  /// Группа.
  final String group;
}

/// Роль (GET /admin/roles, role_view).
@immutable
class Role {
  /// Создаёт роль.
  const Role({required this.id, required this.name, required this.users, required this.system, required this.permissions, this.description = ''});

  /// Из ответа сервера.
  factory Role.fromJson(Map<String, dynamic> j) => Role(
        id: Json.str(j, 'code'),
        name: Json.str(j, 'title'),
        users: Json.integer(j, 'members'),
        system: Json.flag(j, 'is_system'),
        permissions: Json.strings(j, 'permissions'),
        description: Json.str(j, 'description'),
      );

  /// Код.
  final String id;

  /// Название.
  final String name;

  /// Сотрудников с ролью.
  final int users;

  /// Системная роль.
  final bool system;

  /// Коды прав.
  final List<String> permissions;

  /// Описание.
  final String description;

  /// Копия с изменениями.
  Role copyWith({String? name, int? users, List<String>? permissions}) =>
      Role(id: id, name: name ?? this.name, users: users ?? this.users, system: system, permissions: permissions ?? this.permissions, description: description);
}

/// Политика безопасности (GET /admin/policy).
@immutable
class SecurityPolicy {
  /// Создаёт политику.
  const SecurityPolicy({
    required this.pwdMin,
    required this.pwdClasses,
    required this.pwdExpireDays,
    required this.lockAfter,
    required this.lockMinutes,
    required this.sessionHours,
    required this.idleMinutes,
    required this.biometrics,
    required this.tempPwdHours,
    required this.twoFactorAdmins,
  });

  /// Из ответа сервера.
  factory SecurityPolicy.fromJson(Map<String, dynamic> j) => SecurityPolicy(
        pwdMin: Json.integer(j, 'min_password_length', 10),
        pwdClasses: Json.flag(j, 'require_letters_digits', true) ? 'буквы, цифры и символ' : 'любые',
        pwdExpireDays: Json.integer(j, 'password_expire_days', 90),
        lockAfter: Json.integer(j, 'lockout_attempts', 5),
        lockMinutes: Json.integer(j, 'lockout_minutes', 30),
        sessionHours: Json.integer(j, 'session_hours', 12),
        idleMinutes: Json.integer(j, 'idle_minutes', 15),
        biometrics: Json.flag(j, 'biometrics_allowed', true),
        tempPwdHours: Json.integer(j, 'temp_password_hours', 24),
        twoFactorAdmins: Json.flag(j, 'two_factor_admins', true),
      );

  /// Минимальная длина пароля.
  final int pwdMin;

  /// Состав пароля.
  final String pwdClasses;

  /// Срок действия пароля, дней.
  final int pwdExpireDays;

  /// Блокировка после неудачных попыток.
  final int lockAfter;

  /// На сколько минут.
  final int lockMinutes;

  /// Длительность сеанса, ч.
  final int sessionHours;

  /// Выход при бездействии, мин.
  final int idleMinutes;

  /// Вход по биометрии разрешён.
  final bool biometrics;

  /// Срок временного пароля, ч.
  final int tempPwdHours;

  /// Второй фактор для администраторов.
  final bool twoFactorAdmins;

  /// Копия с изменениями.
  SecurityPolicy copyWith({int? pwdMin, int? lockAfter, int? lockMinutes, int? sessionHours, int? idleMinutes, bool? biometrics}) => SecurityPolicy(
        pwdMin: pwdMin ?? this.pwdMin,
        pwdClasses: pwdClasses,
        pwdExpireDays: pwdExpireDays,
        lockAfter: lockAfter ?? this.lockAfter,
        lockMinutes: lockMinutes ?? this.lockMinutes,
        sessionHours: sessionHours ?? this.sessionHours,
        idleMinutes: idleMinutes ?? this.idleMinutes,
        biometrics: biometrics ?? this.biometrics,
        tempPwdHours: tempPwdHours,
        twoFactorAdmins: twoFactorAdmins,
      );
}

/// Запись журнала безопасности (GET /admin/security-log).
@immutable
class SecLogEntry {
  /// Создаёт запись.
  const SecLogEntry({
    required this.time,
    required this.level,
    required this.who,
    required this.text,
    this.kind = '',
    this.title,
    this.details = const <(String, String)>[],
    this.userId,
  });

  /// Время или дата.
  final String time;

  /// ok, info, warn, bad.
  final String level;

  /// Кто или почта.
  final String who;

  /// Что произошло.
  final String text;

  /// Вид события: login, fail, change, block; пусто - по [level].
  final String kind;

  /// Короткий заголовок события: «Вход по биометрии».
  final String? title;

  /// Подробности: пары «поле - значение».
  final List<(String, String)> details;

  /// Учётная запись, к которой относится событие.
  final String? userId;
}

/// Открытый сеанс сотрудника (GET /admin/users/{id}/sessions).
@immutable
class UserSession {
  /// Создаёт сеанс.
  const UserSession({required this.id, required this.userId, required this.device, required this.since, this.method = ''});

  /// Семейство токенов.
  final String id;

  /// Сотрудник.
  final String userId;

  /// Устройство.
  final String device;

  /// С какого времени.
  final String since;

  /// Способ входа: «Пароль», «Биометрия».
  final String method;
}
