import 'package:flutter/foundation.dart';

import 'json.dart';

/// Готовые данные входа демонстрационного сценария: скрытые варианты экрана входа прототипа
/// (a-temp-login, a-blocked-login, a-login-master и другие) открываются с заполненными почтой и паролем.
///
/// Настоящий сервер таких данных не отдаёт: экран входа тогда открывается пустым.
@immutable
class LoginPreset {
  /// Создаёт готовые данные входа.
  const LoginPreset({required this.email, this.password = '', this.biometrics = true});

  /// Почта.
  final String email;

  /// Пароль; пустой - сотрудник вводит его сам.
  final String password;

  /// Кнопка «Войти по биометрии» доступна; false - подсказка «Биометрия - после первого входа с паролем».
  final bool biometrics;
}

/// Учётная запись, сохранённая на телефоне при последнем входе по паролю: по ней работают вход по биометрии
/// и вход без связи с цеховым сервером.
@immutable
class SavedAccount {
  /// Создаёт сохранённую учётную запись.
  const SavedAccount({required this.email, required this.name, this.title = '', this.roleCode = ''});

  /// Почта.
  final String email;

  /// Имя и фамилия.
  final String name;

  /// Должность: «Инженер-диагност».
  final String title;

  /// Код роли: engineer, master, operator, admin, security_admin, senior.
  final String roleCode;
}

/// Контакт сотрудника для экранов входа и связи: администратор ИБ или администратор системы.
@immutable
class SupportContact {
  /// Создаёт контакт.
  const SupportContact({required this.name, required this.role, this.phone = '', this.email = '', this.hours = ''});

  /// Из ответа сервера (поля сотрудника справочника).
  factory SupportContact.fromJson(Map<String, dynamic> j) => SupportContact(
        name: Json.str(j, 'name'),
        role: Json.str(j, 'role_title'),
        phone: Json.str(j, 'phone'),
        email: Json.str(j, 'email'),
        hours: Json.str(j, 'hours'),
      );

  /// Имя и фамилия.
  final String name;

  /// Роль для подписи: «Администратор ИБ».
  final String role;

  /// Телефон.
  final String phone;

  /// Почта.
  final String email;

  /// Часы работы: «Рабочие дни, 09:00-18:00».
  final String hours;

  /// Короткое имя: «Д. Захаров».
  String get short {
    final List<String> p = name.split(' ').where((String w) => w.isNotEmpty).toList();
    return p.length < 2 ? name : '${p[0][0]}. ${p[1]}';
  }
}

/// Сведения о подключении к цеховому серверу, которые телефон хранит у себя: показываются, когда сервер
/// не отвечает, поэтому не требуют связи.
@immutable
class ConnectionInfo {
  /// Создаёт сведения о подключении.
  const ConnectionInfo({
    required this.wifi,
    required this.server,
    required this.address,
    required this.lastExchange,
    required this.readingsAt,
    required this.unreachableSince,
    required this.lastAttempt,
    required this.queue,
    required this.appVersion,
    required this.admin,
  });

  /// Сеть Wi-Fi цеха: «KST-NS2-Field».
  final String wifi;

  /// Имя цехового сервера: «КСТ-СРВ-02».
  final String server;

  /// Адрес сервера: «10.20.4.15».
  final String address;

  /// Последний обмен с сервером: «14.11, 09:37».
  final String lastExchange;

  /// Время последних показаний датчиков на телефоне: «09:37».
  final String readingsAt;

  /// С какого времени сервер не отвечает: «09:38».
  final String unreachableSince;

  /// Время последней попытки связи: «09:41».
  final String lastAttempt;

  /// Сколько записей ждёт отправки на сервер.
  final int queue;

  /// Версия приложения: «1.4.2 (сборка 412)».
  final String appVersion;

  /// Администратор системы, который обслуживает сервер.
  final SupportContact admin;
}

/// Сведения о блокировке учётной записи для экрана «Учётная запись заблокирована».
@immutable
class BlockedAccount {
  /// Создаёт сведения о блокировке.
  const BlockedAccount({required this.email, required this.name, required this.blockedAt, required this.reason});

  /// Из ответа сервера.
  factory BlockedAccount.fromJson(Map<String, dynamic> j) => BlockedAccount(
        email: Json.str(j, 'email'),
        name: Json.str(j, 'name'),
        blockedAt: Json.str(j, 'blocked_at'),
        reason: Json.str(j, 'block_reason'),
      );

  /// Почта учётной записи.
  final String email;

  /// Имя и фамилия сотрудника.
  final String name;

  /// Когда заблокирована: «14.11.2026, 09:41».
  final String blockedAt;

  /// Причина блокировки.
  final String reason;
}

/// Требования к новому паролю сотрудника по политике безопасности и срок его временного пароля.
///
/// Политика сервера задаёт только длину и состав (буквы и цифры); срока действия пароля, истории паролей
/// и обязательного спецсимвола нет.
@immutable
class PasswordRules {
  /// Создаёт требования.
  const PasswordRules({required this.minLength, this.lettersAndDigits = true, this.tempUntil});

  /// Из политики безопасности сервера (GET /security/policy) и сведений о сотруднике.
  factory PasswordRules.fromJson(Map<String, dynamic> j) => PasswordRules(
        minLength: Json.integer(j, 'min_password_length', 10),
        lettersAndDigits: Json.flag(j, 'require_letters_digits', true),
        tempUntil: Json.strOrNull(j, 'temporary_password_until'),
      );

  /// Наименьшая длина пароля.
  final int minLength;

  /// В пароле нужны буквы и цифры.
  final bool lettersAndDigits;

  /// До какого времени действует временный пароль: «15.11 09:08»; null - не известно.
  final String? tempUntil;

  /// Что не так с паролем [password]: длина короче политики, нет букв или цифр, пробел по краям.
  ({bool length, bool classes, bool spaces}) check(String password) => (
        length: password.length >= minLength,
        classes: !lettersAndDigits || (RegExp(r'[A-Za-zА-Яа-яЁё]').hasMatch(password) && RegExp(r'\d').hasMatch(password)),
        spaces: password.trim() == password,
      );
}
