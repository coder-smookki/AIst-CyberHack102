import 'package:go_router/go_router.dart';

import '../../features/entry/login_screen.dart';
import '../navigation/kv_page.dart';
import '../navigation/placeholder.dart';

/// Пути экранов раздела «Вход и первый запуск». Идентификаторы прототипа - имена маршрутов go_router.
abstract final class EntryPaths {
  /// Знакомство · 1 из 3.
  static const String aOnb1 = '/a-onb-1';
  /// Знакомство · 2 из 3.
  static const String aOnb2 = '/a-onb-2';
  /// Знакомство · 3 из 3.
  static const String aOnb3 = '/a-onb-3';
  /// Вход.
  static const String login = '/login';
  /// Вход · проверка.
  static const String aLoginLoading = '/a-login-loading';
  /// Сервер недоступен.
  static const String aOffline = '/a-offline';
  /// Учётная запись заблокирована.
  static const String aBlocked = '/a-blocked';
  /// Первый вход · новый пароль.
  static const String aNewPass = '/a-new-pass';
  /// Новый пароль · не по политике.
  static const String aNewPassWeak = '/a-new-pass-weak';
  /// Пароль сохранён.
  static const String aPassOk = '/a-pass-ok';
  /// Вход · временный пароль.
  static const String aTempLogin = '/a-temp-login';
  /// Вход · заблокированная запись.
  static const String aBlockedLogin = '/a-blocked-login';
  /// Вход · Мастер.
  static const String aLoginMaster = '/master/a-login-master';
  /// Вход · Оператор.
  static const String aLoginOperator = '/operator/a-login-operator';
  /// Вход · Админ.
  static const String aLoginAdmin = '/admin/a-login-admin';
  /// Вход · Админ ИБ.
  static const String aLoginSec = '/sec/a-login-sec';
}

/// Экраны раздела поверх оболочек (без панели вкладок): формы, камера, вход.
final List<RouteBase> entryRootRoutes = <RouteBase>[
  kvPlaceholderRoute('/a-onb-1', id: 'a-onb-1', title: 'Знакомство · 1 из 3'),
  kvPlaceholderRoute('/a-onb-2', id: 'a-onb-2', title: 'Знакомство · 2 из 3'),
  kvPlaceholderRoute('/a-onb-3', id: 'a-onb-3', title: 'Знакомство · 3 из 3'),
  GoRoute(
    path: '/login',
    name: 'login',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const LoginScreen(), transition: KvTransition.fade),
  ),
  kvPlaceholderRoute('/a-login-loading', id: 'a-login-loading', title: 'Вход · проверка', transition: KvTransition.fade),
  kvPlaceholderRoute('/a-offline', id: 'a-offline', title: 'Сервер недоступен'),
  kvPlaceholderRoute('/a-blocked', id: 'a-blocked', title: 'Учётная запись заблокирована'),
  kvPlaceholderRoute('/a-new-pass', id: 'a-new-pass', title: 'Первый вход · новый пароль'),
  kvPlaceholderRoute('/a-new-pass-weak', id: 'a-new-pass-weak', title: 'Новый пароль · не по политике'),
  kvPlaceholderRoute('/a-pass-ok', id: 'a-pass-ok', title: 'Пароль сохранён', transition: KvTransition.fade),
  kvPlaceholderRoute('/a-temp-login', id: 'a-temp-login', title: 'Вход · временный пароль', transition: KvTransition.fade),
  kvPlaceholderRoute('/a-blocked-login', id: 'a-blocked-login', title: 'Вход · заблокированная запись', transition: KvTransition.fade),
  kvPlaceholderRoute('/master/a-login-master', id: 'a-login-master', title: 'Вход · Мастер', transition: KvTransition.fade),
  kvPlaceholderRoute('/operator/a-login-operator', id: 'a-login-operator', title: 'Вход · Оператор', transition: KvTransition.fade),
  kvPlaceholderRoute('/admin/a-login-admin', id: 'a-login-admin', title: 'Вход · Админ', transition: KvTransition.fade),
  kvPlaceholderRoute('/sec/a-login-sec', id: 'a-login-sec', title: 'Вход · Админ ИБ', transition: KvTransition.fade),
];
