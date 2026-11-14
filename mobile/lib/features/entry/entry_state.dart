import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state/app_state.dart';
import '../../data/providers.dart';

/// Почта и пароль последней попытки входа. Хранятся только в памяти приложения: по ним экран «Вход · проверка»
/// повторяет вход после сбоя связи, а экран нового пароля сверяет новый пароль с временным.
@immutable
class PendingLogin {
  /// Создаёт данные попытки входа.
  const PendingLogin({required this.email, required this.password});

  /// Почта.
  final String email;

  /// Пароль, введённый на экране входа.
  final String password;
}

/// Последняя попытка входа; null - сотрудник ещё не входил или данные уже не нужны.
class PendingLoginController extends Notifier<PendingLogin?> {
  @override
  PendingLogin? build() => null;

  /// Запомнить попытку входа.
  void remember(String email, String password) => state = PendingLogin(email: email.trim(), password: password);

  /// Забыть попытку входа (пароль сменён, сотрудник вышел).
  void clear() => state = null;
}

/// Последняя попытка входа в памяти приложения.
final NotifierProvider<PendingLoginController, PendingLogin?> entryPendingLoginProvider =
    NotifierProvider<PendingLoginController, PendingLogin?>(PendingLoginController.new);

/// Учётная запись, сохранённая на телефоне: по ней работают вход по биометрии и работа без связи.
final FutureProvider<SavedAccount?> entrySavedAccountProvider = FutureProvider<SavedAccount?>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.auth));
  return ref.watch(authRepositoryProvider).savedAccount();
});

/// Сведения о подключении к цеховому серверу из памяти телефона.
final FutureProvider<ConnectionInfo> entryConnectionProvider = FutureProvider<ConnectionInfo>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.auth));
  return ref.watch(authRepositoryProvider).connectionInfo();
});

/// Контакт администратора ИБ для экранов входа.
final FutureProvider<SupportContact> entrySecurityContactProvider = FutureProvider<SupportContact>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.security));
  return ref.watch(authRepositoryProvider).securityContact();
});

/// Требования к новому паролю и срок временного пароля текущего сотрудника.
final FutureProvider<PasswordRules> entryPasswordRulesProvider = FutureProvider<PasswordRules>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.security));
  ref.watch(sessionProvider.select((AuthSession? s) => s?.user.id));
  return ref.watch(authRepositoryProvider).passwordRules();
});

/// Сведения о блокировке учётной записи с почтой из аргумента.
final entryBlockedAccountProvider = FutureProvider.autoDispose.family<BlockedAccount?, String>((Ref ref, String email) {
  ref.watch(revisionProvider(KvDomain.security));
  return ref.watch(authRepositoryProvider).blockedAccount(email);
});

/// Готовые почта и пароль скрытого варианта входа прототипа (идентификатор экрана в аргументе).
final entryScenarioProvider = FutureProvider.autoDispose.family<LoginPreset?, String>(
  (Ref ref, String scenario) => ref.watch(authRepositoryProvider).scenarioLogin(scenario),
);

/// Сканер отпечатка или лица телефона: подтверждает, что телефоном пользуется владелец сохранённой учётной записи.
abstract interface class KvBioScanner {
  /// Ждёт касания сканера; true - личность подтверждена, false - отпечаток не распознан.
  Future<bool> scan();
}

/// Сканер демонстрации: подтверждает личность сразу. [failNext] задаёт, сколько ближайших попыток не распознаются
/// (снимки дизайна и тесты состояния «Отпечаток не распознан»).
class DemoBioScanner implements KvBioScanner {
  /// Сколько ближайших попыток закончатся отказом.
  int failNext = 0;

  @override
  Future<bool> scan() async {
    if (failNext > 0) {
      failNext--;
      return false;
    }
    return true;
  }
}

/// Сканер биометрии. На устройстве подменяется системным сканером через переопределение провайдера.
final Provider<KvBioScanner> bioScannerProvider = Provider<KvBioScanner>((Ref ref) => DemoBioScanner());
