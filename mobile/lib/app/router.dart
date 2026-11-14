import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers.dart';
import 'navigation/kv_page.dart';
import 'routes/admins_routes.dart';
import 'routes/engineer_inspect_routes.dart';
import 'routes/engineer_service_routes.dart';
import 'routes/entry_routes.dart';
import 'routes/master_operator_routes.dart';
import 'shell/role_shell.dart';
import 'shell/role_tabs.dart';
import 'state/app_state.dart';

/// Ключ корневого навигатора: экраны без панели вкладок, листы и диалоги.
final GlobalKey<NavigatorState> kvRootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

/// Префиксы путей ролей; всё остальное - экраны входа и первого запуска, доступные без сеанса.
const List<String> _rolePrefixes = ['/engineer', '/senior', '/master', '/operator', '/admin', '/sec'];

bool _isEntry(String path) => !_rolePrefixes.any((String p) => path == p || path.startsWith('$p/'));

bool _isPasswordFlow(String path) => path == EntryPaths.aNewPass || path == EntryPaths.aNewPassWeak || path == EntryPaths.aPassOk;

/// Уведомляет маршрутизатор о смене сеанса и настроек, чтобы пересчитать перенаправления.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    ref.listen<AuthSession?>(sessionProvider, (AuthSession? a, AuthSession? b) => notifyListeners());
    ref.listen<bool>(deviceSettingsProvider.select((DeviceSettings s) => s.onboardingSeen), (bool? a, bool b) => notifyListeners());
  }
}

/// Оболочка роли как ShellRoute: свой навигатор, панель вкладок, переход наплывом при входе в роль.
ShellRoute _shell(KvRole role, List<RouteBase> routes) => ShellRoute(
      navigatorKey: GlobalKey<NavigatorState>(debugLabel: role.name),
      pageBuilder: (BuildContext context, GoRouterState state, Widget child) => KvPage<void>(
        key: ValueKey<String>('shell-${role.name}'),
        name: 'shell-${role.name}',
        transition: KvTransition.fade,
        child: RoleShell(role: role, location: state.uri.path, child: child),
      ),
      routes: routes,
    );

/// Маршрутизатор приложения. Первый запуск - знакомство, без сеанса - вход, после входа - домашний экран роли.
final Provider<GoRouter> routerProvider = Provider<GoRouter>((Ref ref) {
  final _RouterRefresh refresh = _RouterRefresh(ref);
  final GoRouter router = GoRouter(
    navigatorKey: kvRootNavigatorKey,
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (BuildContext context, GoRouterState state) {
      final String path = state.uri.path;
      final AuthSession? session = ref.read(sessionProvider);
      final bool seen = ref.read(deviceSettingsProvider).onboardingSeen;
      if (session == null) {
        if (_isEntry(path) && path != '/') {
          return null;
        }
        return seen ? EntryPaths.login : EntryPaths.aOnb1;
      }
      if (session.mustChangePassword) {
        return _isPasswordFlow(path) ? null : EntryPaths.aNewPass;
      }
      if (path == '/' || path == EntryPaths.login) {
        return kvRoleHome(session.user.role);
      }
      return null;
    },
    routes: <RouteBase>[
      GoRoute(path: '/', redirect: (BuildContext context, GoRouterState state) => EntryPaths.login),
      ...entryRootRoutes,
      ...engineerInspectRootRoutes,
      ...engineerServiceRootRoutes,
      ...masterOperatorRootRoutes,
      ...adminsRootRoutes,
      _shell(KvRole.engineer, <RouteBase>[...engineerInspectEngineerShellRoutes, ...engineerServiceEngineerShellRoutes]),
      _shell(KvRole.senior, engineerServiceSeniorShellRoutes),
      _shell(KvRole.master, masterOperatorMasterShellRoutes),
      _shell(KvRole.operator, masterOperatorOperatorShellRoutes),
      _shell(KvRole.admin, adminsAdminShellRoutes),
      _shell(KvRole.sec, adminsSecShellRoutes),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});
