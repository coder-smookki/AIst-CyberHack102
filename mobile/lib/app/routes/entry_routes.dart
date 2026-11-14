import 'package:go_router/go_router.dart';

import '../../features/entry/blocked_screen.dart';
import '../../features/entry/login_screen.dart';
import '../../features/entry/new_password_screen.dart';
import '../../features/entry/offline_screen.dart';
import '../../features/entry/onboarding_screen.dart';
import '../../features/entry/password_saved_screen.dart';
import '../navigation/kv_page.dart';

/// Пути экранов раздела «Вход и первый запуск». Идентификаторы прототипа - имена маршрутов go_router.
///
/// Все экраны раздела доступны без сеанса, поэтому лежат вне путей ролей, включая скрытые варианты входа
/// ролей из сценариев (a-login-master и другие).
abstract final class EntryPaths {
  /// Знакомство · 1 из 3.
  static const String aOnb1 = '/a-onb-1';

  /// Знакомство · 2 из 3.
  static const String aOnb2 = '/a-onb-2';

  /// Знакомство · 3 из 3.
  static const String aOnb3 = '/a-onb-3';

  /// Вход.
  static const String login = '/login';

  /// Вход · проверка: повторяет последнюю попытку входа.
  static const String aLoginLoading = '/a-login-loading';

  /// Сервер недоступен.
  static const String aOffline = '/a-offline';

  /// Учётная запись заблокирована.
  static const String aBlocked = '/a-blocked';

  /// Первый вход · новый пароль.
  static const String aNewPass = '/a-new-pass';

  /// Новый пароль · не по политике (тот же экран нового пароля).
  static const String aNewPassWeak = '/a-new-pass-weak';

  /// Пароль сохранён.
  static const String aPassOk = '/a-pass-ok';

  /// Вход · временный пароль.
  static const String aTempLogin = '/a-temp-login';

  /// Вход · заблокированная запись.
  static const String aBlockedLogin = '/a-blocked-login';

  /// Вход · Мастер.
  static const String aLoginMaster = '/a-login-master';

  /// Вход · Оператор.
  static const String aLoginOperator = '/a-login-operator';

  /// Вход · Админ.
  static const String aLoginAdmin = '/a-login-admin';

  /// Вход · Админ ИБ.
  static const String aLoginSec = '/a-login-sec';

  /// «Учётная запись заблокирована» для почты [email], которой отказано во входе.
  static String blocked(String? email) =>
      email == null || email.isEmpty ? aBlocked : Uri(path: aBlocked, queryParameters: <String, String>{'email': email}).toString();
}

/// Маршрут экрана входа: обычный вход, скрытый вариант сценария или проверка учётной записи.
GoRoute _login(String path, String id, {String? scenario, bool checking = false}) => GoRoute(
  path: path,
  name: id,
  pageBuilder: (_, GoRouterState s) {
    final Object? data = KvNavExtra.of(s)?.data;
    return KvPage<void>.of(
      s,
      LoginScreen(scenario: scenario, checking: checking, email: data is String ? data : null),
      transition: KvTransition.fade,
    );
  },
);

/// Маршрут шага знакомства [step].
GoRoute _onboarding(String path, int step) => GoRoute(
  path: path,
  name: 'a-onb-$step',
  pageBuilder: (_, GoRouterState s) =>
      KvPage<void>.of(s, OnboardingScreen(step: step), transition: step == 1 ? KvTransition.fade : KvTransition.push),
);

/// Экраны раздела поверх оболочек (без панели вкладок): знакомство, вход и его состояния.
final List<RouteBase> entryRootRoutes = <RouteBase>[
  _onboarding(EntryPaths.aOnb1, 1),
  _onboarding(EntryPaths.aOnb2, 2),
  _onboarding(EntryPaths.aOnb3, 3),
  _login(EntryPaths.login, 'login'),
  _login(EntryPaths.aLoginLoading, 'a-login-loading', checking: true),
  GoRoute(
    path: EntryPaths.aOffline,
    name: 'a-offline',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const OfflineScreen(), transition: KvTransition.fade),
  ),
  GoRoute(
    path: EntryPaths.aBlocked,
    name: 'a-blocked',
    pageBuilder: (_, GoRouterState s) =>
        KvPage<void>.of(s, BlockedScreen(email: s.uri.queryParameters['email'] ?? ''), transition: KvTransition.fade),
  ),
  GoRoute(
    path: EntryPaths.aNewPass,
    name: 'a-new-pass',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const NewPasswordScreen()),
  ),
  GoRoute(
    path: EntryPaths.aNewPassWeak,
    name: 'a-new-pass-weak',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const NewPasswordScreen()),
  ),
  GoRoute(
    path: EntryPaths.aPassOk,
    name: 'a-pass-ok',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const PasswordSavedScreen(), transition: KvTransition.fade),
  ),
  _login(EntryPaths.aTempLogin, 'a-temp-login', scenario: 'a-temp-login'),
  _login(EntryPaths.aBlockedLogin, 'a-blocked-login', scenario: 'a-blocked-login'),
  _login(EntryPaths.aLoginMaster, 'a-login-master', scenario: 'a-login-master'),
  _login(EntryPaths.aLoginOperator, 'a-login-operator', scenario: 'a-login-operator'),
  _login(EntryPaths.aLoginAdmin, 'a-login-admin', scenario: 'a-login-admin'),
  _login(EntryPaths.aLoginSec, 'a-login-sec', scenario: 'a-login-sec'),
];
