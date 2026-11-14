import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/admins/admin/adm_devices_screen.dart';
import '../../features/admins/admin/adm_log_screen.dart';
import '../../features/admins/admin/adm_maint_screen.dart';
import '../../features/admins/admin/adm_model_screen.dart';
import '../../features/admins/admin/adm_models_screen.dart';
import '../../features/admins/admin/adm_profile_screen.dart';
import '../../features/admins/admin/adm_server_screen.dart';
import '../../features/admins/admin/adm_source_form_screen.dart';
import '../../features/admins/admin/adm_source_screen.dart';
import '../../features/admins/admin/adm_sources_screen.dart';
import '../../features/admins/admin/adm_system_screen.dart';
import '../../features/admins/admin/adm_tags_screen.dart';
import '../../features/admins/admin/adm_update_run_screen.dart';
import '../../features/admins/role_scope_screen.dart';
import '../../features/admins/sec/sec_log_screen.dart';
import '../../features/admins/sec/sec_policy_screen.dart';
import '../../features/admins/sec/sec_profile_screen.dart';
import '../../features/admins/sec/sec_role_new_screen.dart';
import '../../features/admins/sec/sec_role_screen.dart';
import '../../features/admins/sec/sec_roles_screen.dart';
import '../../features/admins/sec/sec_sessions_screen.dart';
import '../../features/admins/sec/sec_user_new_screen.dart';
import '../../features/admins/sec/sec_user_screen.dart';
import '../../features/admins/sec/sec_user_search_screen.dart';
import '../../features/admins/sec/sec_users_screen.dart';
import '../navigation/kv_page.dart';

/// Пути экранов раздела «Админ и Админ ИБ». Идентификаторы прототипа - имена маршрутов go_router.
///
/// Варианты прототипа по объектам (e-src-vib/opc/plc, e-tags/-ams1/-ams2, e-model-*, e-user-*, e-role-*) - один
/// экран с параметром; состояния учётной записи (заблокирована, новая роль) берутся из данных сервера.
abstract final class AdminsPaths {
  /// Система.
  static const String admSystem = '/admin/system';

  /// Цеховой сервер.
  static const String eAdmServer = '/admin/e-adm-server';

  /// Устройства.
  static const String eAdmDevices = '/admin/e-adm-devices';

  /// Источники данных.
  static const String admSources = '/admin/sources';

  /// Источник данных: src-vib, src-opc, src-plc (e-src-vib, e-src-opc, e-src-plc).
  static String source(String sourceId) => '/admin/e-src/$sourceId';

  /// Параметры источника (e-src-vib-edit и другие).
  static String sourceEdit(String sourceId) => '/admin/e-src-edit/$sourceId';

  /// Новый источник.
  static const String eSrcAdd = '/admin/e-src-add';

  /// Источник подключён.
  static const String eSrcAddOk = '/admin/e-src-add-ok';

  /// Привязка тегов агрегата: N-101, AMS-1, AMS-2 (e-tags, e-tags-ams1, e-tags-ams2).
  static String tags(String unitId) => '/admin/e-tags/$unitId';

  /// Модели распознавания.
  static const String admModels = '/admin/models';

  /// Модель распознавания: m-det, m-gauge, m-plate, m-det-next (e-model-*).
  static String model(String modelId) => '/admin/e-model/$modelId';

  /// Системный журнал.
  static const String admLog = '/admin/log';

  /// Обновления и резерв.
  static const String eAdmMaint = '/admin/e-adm-maint';

  /// Установка обновления.
  static const String eUpdateRun = '/admin/e-update-run';

  /// Профиль администратора.
  static const String admProfile = '/admin/profile';

  /// Права роли Админ.
  static const String eAdmScope = '/admin/e-adm-scope';

  /// Пользователи.
  static const String secUsers = '/sec/users';

  /// Поиск пользователя.
  static const String eUserSearch = '/sec/e-user-search';

  /// Карточка сотрудника (e-user-smirnov и другие); [assigned] - показать плашку о назначенной роли.
  static String user(String userId, {bool assigned = false}) => '/sec/e-user/$userId${assigned ? '?assigned=1' : ''}';

  /// Новый пользователь.
  static const String eUserNew = '/sec/e-user-new';

  /// Учётная запись создана; [userId] - созданная запись.
  static String userNewDone(String userId) => '/sec/e-user-new-done?user=$userId';

  /// Роли.
  static const String secRoles = '/sec/roles';

  /// Роль (e-role-engineer и другие); [fresh] - только что создана (e-role-senior-new).
  static String role(String roleId, {bool fresh = false}) => '/sec/e-role/$roleId${fresh ? '?fresh=1' : ''}';

  /// Новая роль.
  static const String eRoleNew = '/sec/e-role-new';

  /// Журнал безопасности.
  static const String secLog = '/sec/log';

  /// Журнал безопасности с открытой первой записью вида [kind] (e-slog-fail).
  static String secLogOpen(String kind) => '/sec/log?open=$kind';

  /// Политика безопасности.
  static const String secPolicy = '/sec/policy';

  /// Требования к паролю.
  static const String ePolicyPwd = '/sec/e-policy-pwd';

  /// Профиль администратора ИБ.
  static const String secProfile = '/sec/profile';

  /// Права роли Админ ИБ.
  static const String eSecScope = '/sec/e-sec-scope';

  /// Активные сеансы.
  static const String eSecSessions = '/sec/e-sec-sessions';
}

GoRoute _route(String path, String name, Widget Function(GoRouterState s) build, {KvTransition transition = KvTransition.push}) => GoRoute(
      path: path,
      name: name,
      pageBuilder: (BuildContext context, GoRouterState s) => KvPage<void>.of(s, build(s), transition: transition),
    );

/// Экраны раздела внутри оболочки администратора (с панелью вкладок).
final List<RouteBase> adminsAdminShellRoutes = <RouteBase>[
  _route(AdminsPaths.admSystem, 'adm-system', (_) => const AdmSystemScreen(), transition: KvTransition.fade),
  _route(AdminsPaths.admSources, 'adm-sources', (_) => const AdmSourcesScreen(), transition: KvTransition.fade),
  _route(AdminsPaths.admModels, 'adm-models', (_) => const AdmModelsScreen(), transition: KvTransition.fade),
  _route(AdminsPaths.admLog, 'adm-log', (_) => const AdmLogScreen(), transition: KvTransition.fade),
  _route(AdminsPaths.admProfile, 'adm-profile', (_) => const AdmProfileScreen(), transition: KvTransition.fade),
];

/// Экраны раздела внутри оболочки администратора ИБ (с панелью вкладок).
final List<RouteBase> adminsSecShellRoutes = <RouteBase>[
  _route(AdminsPaths.secUsers, 'sec-users', (_) => const SecUsersScreen(), transition: KvTransition.fade),
  _route(AdminsPaths.secRoles, 'sec-roles', (_) => const SecRolesScreen(), transition: KvTransition.fade),
  _route(AdminsPaths.secLog, 'sec-log', (GoRouterState s) => SecLogScreen(open: s.uri.queryParameters['open']), transition: KvTransition.fade),
  _route(AdminsPaths.secPolicy, 'sec-policy', (_) => const SecPolicyScreen(), transition: KvTransition.fade),
  _route(AdminsPaths.secProfile, 'sec-profile', (_) => const SecProfileScreen(), transition: KvTransition.fade),
];

/// Экраны раздела поверх оболочек (без панели вкладок).
final List<RouteBase> adminsRootRoutes = <RouteBase>[
  _route(AdminsPaths.eAdmServer, 'e-adm-server', (_) => const AdmServerScreen()),
  _route(AdminsPaths.eAdmDevices, 'e-adm-devices', (_) => const AdmDevicesScreen()),
  _route('/admin/e-src/:sourceId', 'e-src-vib', (GoRouterState s) => AdmSourceScreen(sourceId: s.pathParameters['sourceId']!)),
  _route('/admin/e-src-edit/:sourceId', 'e-src-vib-edit', (GoRouterState s) => AdmSourceFormScreen(sourceId: s.pathParameters['sourceId'])),
  _route(AdminsPaths.eSrcAdd, 'e-src-add', (_) => const AdmSourceFormScreen()),
  _route(AdminsPaths.eSrcAddOk, 'e-src-add-ok', (_) => const AdmSourceAddedScreen(), transition: KvTransition.fade),
  _route(
    '/admin/e-tags/:unitId',
    'e-tags',
    (GoRouterState s) => AdmTagsScreen(unitId: s.pathParameters['unitId']!, fromSegment: KvNavExtra.of(s)?.fromSegment),
  ),
  _route('/admin/e-model/:modelId', 'e-model-next', (GoRouterState s) => AdmModelScreen(modelId: s.pathParameters['modelId']!)),
  _route(AdminsPaths.eAdmMaint, 'e-adm-maint', (_) => const AdmMaintScreen()),
  _route(AdminsPaths.eUpdateRun, 'e-update-run', (_) => const AdmUpdateRunScreen()),
  _route(AdminsPaths.eAdmScope, 'e-adm-scope', (_) => const RoleScopeScreen(roleId: 'admin', back: AdminsPaths.admProfile)),
  _route(AdminsPaths.eUserSearch, 'e-user-search', (_) => const SecUserSearchScreen()),
  _route(
    '/sec/e-user/:userId',
    'e-user-smirnov',
    (GoRouterState s) => SecUserScreen(userId: s.pathParameters['userId']!, assigned: s.uri.queryParameters['assigned'] == '1'),
  ),
  _route(AdminsPaths.eUserNew, 'e-user-new', (_) => const SecUserNewScreen()),
  _route('/sec/e-user-new-done', 'e-user-new-done', (GoRouterState s) => SecUserNewDoneScreen(userId: s.uri.queryParameters['user']), transition: KvTransition.fade),
  _route(
    '/sec/e-role/:roleId',
    'e-role-master',
    (GoRouterState s) => SecRoleScreen(roleId: s.pathParameters['roleId']!, fresh: s.uri.queryParameters['fresh'] == '1'),
  ),
  _route(AdminsPaths.eRoleNew, 'e-role-new', (_) => const SecRoleNewScreen()),
  _route(AdminsPaths.ePolicyPwd, 'e-policy-pwd', (_) => const SecPolicyPwdScreen()),
  _route(AdminsPaths.eSecScope, 'e-sec-scope', (_) => const RoleScopeScreen(roleId: 'security_admin', back: AdminsPaths.secProfile)),
  _route(AdminsPaths.eSecSessions, 'e-sec-sessions', (_) => const SecSessionsScreen()),
];
