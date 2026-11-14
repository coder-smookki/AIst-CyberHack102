import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/master_operator/master/master_finding_screen.dart';
import '../../features/master_operator/master/master_findings_screen.dart';
import '../../features/master_operator/master/master_plan_item_screen.dart';
import '../../features/master_operator/master/master_plan_screen.dart';
import '../../features/master_operator/master/master_profile_screen.dart';
import '../../features/master_operator/master/master_report_screen.dart';
import '../../features/master_operator/master/master_shift_screen.dart';
import '../../features/master_operator/master/master_team_screen.dart';
import '../../features/master_operator/master/master_unit_screen.dart';
import '../../features/master_operator/operator/op_assistant_screen.dart';
import '../../features/master_operator/operator/op_camera_screen.dart';
import '../../features/master_operator/operator/op_history_screen.dart';
import '../../features/master_operator/operator/op_objects_screen.dart';
import '../../features/master_operator/operator/op_profile_screen.dart';
import '../../features/master_operator/operator/op_report_screen.dart';
import '../../features/master_operator/operator/op_unit_screen.dart';
import '../../features/master_operator/widgets/mo_common.dart';
import '../navigation/kv_page.dart';

/// Пути экранов раздела «Мастер и оператор». Имена маршрутов go_router - идентификаторы экранов прототипа;
/// экраны одного вида с разными объектами (находки, работы плана, агрегаты, сообщения) открываются по номеру,
/// а состояния истории смены (06:41, 08:12, 07:30, 09:12) - параметром at.
abstract final class MasterOperatorPaths {
  /// Смена.
  static const String masterShift = '/master/shift';

  /// Смена · 06:41 (до остановки АМС-2, сценарий А).
  static const String masterShift0640 = '/master/shift?at=0640';

  /// Смена · 08:12 (АМС-2 на ремонте, до F-1043, сценарий Б).
  static const String masterShift0812 = '/master/shift?at=0812';

  /// Уведомления мастера.
  static const String dMNotif = '/master/shift/d-m-notif';

  /// Команда и охват.
  static const String dMTeam = '/master/shift/d-m-team';

  /// Сообщение оператора по номеру.
  static String report(String id) => '/master/shift/report/$id';

  /// Сообщение оператора S-077.
  static const String dMReport = '/master/shift/report/S-077';

  /// Агрегат для мастера по идентификатору.
  static String unit(String id) => '/master/shift/unit/$id';

  /// Агрегат Н-101 · мастер (в режиме «резерв» - состояние «Н-101 остановлен»).
  static const String dMUnit = '/master/shift/unit/N-101';

  /// Агрегат Н-101 · 09:12 (сценарий Б, до осмотра).
  static const String dMUnit0912 = '/master/shift/unit/N-101?at=0912';

  /// Агрегат АМС-2 · мастер.
  static const String dMUnitAms2 = '/master/shift/unit/AMS-2';

  /// Н-101 остановлен: тот же экран агрегата в режиме «резерв».
  static const String dMUnitStopped = dMUnit;

  /// Находки.
  static const String masterFindings = '/master/findings';

  /// Находки · в работе и закрытые.
  static const String dMFindingsAll = '/master/findings/d-m-findings-all';

  /// Находка по номеру.
  static String finding(String id) => '/master/findings/finding/$id';

  /// Проверка находки F-1043 (отклонённая находка - то же состояние экрана по данным).
  static const String dMFinding = '/master/findings/finding/F-1043';

  /// Находка F-1042 · R08.
  static const String dMFindingR08 = '/master/findings/finding/F-1042';

  /// Находка F-1041 в 07:28, до решения мастера (сценарий А).
  static const String dMFindingAms2 = '/master/findings/finding/F-1041?at=0728';

  /// Находка F-1041.
  static const String dMF1041 = '/master/findings/finding/F-1041';

  /// Находка F-1036.
  static const String dMF1036 = '/master/findings/finding/F-1036';

  /// Находка F-1031.
  static const String dMF1031 = '/master/findings/finding/F-1031';

  /// План ТО.
  static const String masterPlan = '/master/plan';

  /// План ТО · календарь.
  static const String dMPlanCal = '/master/plan/d-m-plan-cal';

  /// Работа плана по номеру.
  static String planItem(String id) => '/master/plan/item/$id';

  /// Работа плана · ТО-2 Н-101.
  static const String dMPlanItem = '/master/plan/item/P-502';

  /// Просроченная поверка манометра.
  static const String dMPlanP499 = '/master/plan/item/P-499';

  /// Работа плана P-501.
  static const String dMPlanP501 = '/master/plan/item/P-501';

  /// Работа плана P-503.
  static const String dMPlanP503 = '/master/plan/item/P-503';

  /// Работа плана P-504.
  static const String dMPlanP504 = '/master/plan/item/P-504';

  /// Работа плана P-505.
  static const String dMPlanP505 = '/master/plan/item/P-505';

  /// Профиль мастера.
  static const String masterProfile = '/master/profile';

  /// Отчёты смены.
  static const String dMReports = '/master/profile/d-m-reports';

  /// Сменный отчёт 13.11.
  static const String dMReport1311 = '/master/d-m-report-1311';

  /// Агрегаты оператора.
  static const String opObjects = '/operator/objects';

  /// Агрегаты · 07:30 (до решения мастера, сценарий А).
  static const String opObjects0730 = '/operator/objects?at=0730';

  /// Агрегат для оператора по идентификатору.
  static String opUnit(String id) => '/operator/objects/unit/$id';

  /// Агрегат Н-101 · просмотр.
  static const String dOpUnit = '/operator/objects/unit/N-101';

  /// Агрегат АМС-1 · просмотр.
  static const String dOpUnitAms1 = '/operator/objects/unit/AMS-1';

  /// Агрегат на ремонте по идентификатору.
  static String opRepair(String id) => '/operator/objects/repair/$id';

  /// АМС-2 на ремонте.
  static const String dOpRepair = '/operator/objects/repair/AMS-2';

  /// Уведомления оператора.
  static const String dOpNotif = '/operator/objects/d-op-notif';

  /// Сообщение о неисправности: черновик сценария по АМС-2.
  static const String opReport = '/operator/op-report';

  /// Сообщение о неисправности · 06:40: тот же черновик в 06:40.
  static const String opReport0640 = opReport;

  /// Пустое сообщение о неисправности по агрегату.
  static String opReportFor(String unitId) => '/operator/op-report?unit=$unitId';

  /// Сообщение · Н-101.
  static const String dOpReportN101 = '/operator/op-report?unit=N-101';

  /// Кадр к сообщению.
  static const String dOpCamera = '/operator/d-op-camera';

  /// Сообщение отправлено по номеру.
  static String reportSent(String id) => '/operator/d-op-report-sent?id=$id';

  /// Сообщение S-077 отправлено.
  static const String dOpReportSent = '/operator/d-op-report-sent?id=S-077';

  /// История сообщений.
  static const String opHistory = '/operator/history';

  /// События смены.
  static const String dOpEvents = '/operator/history/d-op-events';

  /// Статус сообщения по номеру.
  static String reportStatus(String id) => '/operator/history/report/$id';

  /// Статус сообщения S-077.
  static const String dOpReportStatus = '/operator/history/report/S-077';

  /// Статус сообщения S-071.
  static const String dOpReportS071 = '/operator/history/report/S-071';

  /// Ассистент оператора.
  static const String opAssistant = '/operator/assistant';

  /// Ассистент · ответ про ремонт АМС-2.
  static const String dOpAssistantAns = '/operator/assistant?q=repair';

  /// Профиль оператора.
  static const String opProfile = '/operator/profile';
}

/// Страница экрана мастера: экран слушает push-уведомления ленты мастера.
Page<void> _master(GoRouterState s, Widget child, {KvTransition transition = KvTransition.push}) =>
    KvPage<void>.of(s, MoPushListener(roleKey: 'master', child: child), transition: transition);

/// Страница экрана оператора: экран слушает push-уведомления ленты оператора.
Page<void> _operator(GoRouterState s, Widget child, {KvTransition transition = KvTransition.push}) =>
    KvPage<void>.of(s, MoPushListener(roleKey: 'operator', child: child), transition: transition);

/// Экраны раздела внутри оболочки мастера (с панелью вкладок).
final List<RouteBase> masterOperatorMasterShellRoutes = <RouteBase>[
  GoRoute(
    path: '/master/shift',
    name: 'master-shift',
    pageBuilder: (BuildContext c, GoRouterState s) => _master(s, MasterShiftScreen(at: s.uri.queryParameters['at']), transition: KvTransition.fade),
    routes: <RouteBase>[
      GoRoute(path: 'd-m-notif', name: 'd-m-notif', pageBuilder: (BuildContext c, GoRouterState s) => _master(s, const MasterNotifScreen())),
      GoRoute(path: 'd-m-team', name: 'd-m-team', pageBuilder: (BuildContext c, GoRouterState s) => _master(s, const MasterTeamScreen())),
      GoRoute(
        path: 'report/:id',
        name: 'd-m-report',
        pageBuilder: (BuildContext c, GoRouterState s) => _master(s, MasterReportScreen(reportId: s.pathParameters['id']!)),
      ),
      GoRoute(
        path: 'unit/:id',
        name: 'd-m-unit',
        pageBuilder: (BuildContext c, GoRouterState s) => _master(s, MasterUnitScreen(unitId: s.pathParameters['id']!, at: s.uri.queryParameters['at'])),
      ),
    ],
  ),
  GoRoute(
    path: '/master/findings',
    name: 'master-findings',
    pageBuilder: (BuildContext c, GoRouterState s) => _master(s, const MasterFindingsScreen(), transition: KvTransition.fade),
    routes: <RouteBase>[
      GoRoute(
        path: 'd-m-findings-all',
        name: 'd-m-findings-all',
        pageBuilder: (BuildContext c, GoRouterState s) => _master(s, const MasterFindingsAllScreen(), transition: KvTransition.fade),
      ),
      GoRoute(
        path: 'finding/:id',
        name: 'd-m-finding',
        pageBuilder: (BuildContext c, GoRouterState s) =>
            _master(s, MasterFindingScreen(findingId: s.pathParameters['id']!, at: s.uri.queryParameters['at'])),
      ),
    ],
  ),
  GoRoute(
    path: '/master/plan',
    name: 'master-plan',
    pageBuilder: (BuildContext c, GoRouterState s) => _master(s, const MasterPlanScreen(), transition: KvTransition.fade),
    routes: <RouteBase>[
      GoRoute(path: 'd-m-plan-cal', name: 'd-m-plan-cal', pageBuilder: (BuildContext c, GoRouterState s) => _master(s, const MasterPlanCalScreen(), transition: KvTransition.fade)),
      GoRoute(
        path: 'item/:id',
        name: 'd-m-plan-item',
        pageBuilder: (BuildContext c, GoRouterState s) => _master(s, MasterPlanItemScreen(itemId: s.pathParameters['id']!)),
      ),
    ],
  ),
  GoRoute(
    path: '/master/profile',
    name: 'master-profile',
    pageBuilder: (BuildContext c, GoRouterState s) => _master(s, const MasterProfileScreen(), transition: KvTransition.fade),
    routes: <RouteBase>[
      GoRoute(path: 'd-m-reports', name: 'd-m-reports', pageBuilder: (BuildContext c, GoRouterState s) => _master(s, const MasterReportsScreen())),
    ],
  ),
];

/// Экраны раздела внутри оболочки оператора (с панелью вкладок).
final List<RouteBase> masterOperatorOperatorShellRoutes = <RouteBase>[
  GoRoute(
    path: '/operator/objects',
    name: 'op-objects',
    pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, OpObjectsScreen(at: s.uri.queryParameters['at']), transition: KvTransition.fade),
    routes: <RouteBase>[
      GoRoute(path: 'unit/:id', name: 'd-op-unit', pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, OpUnitScreen(unitId: s.pathParameters['id']!))),
      GoRoute(path: 'repair/:id', name: 'd-op-repair', pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, OpRepairScreen(unitId: s.pathParameters['id']!))),
      GoRoute(path: 'd-op-notif', name: 'd-op-notif', pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, const OpNotifScreen())),
    ],
  ),
  GoRoute(
    path: '/operator/history',
    name: 'op-history',
    pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, const OpHistoryScreen(), transition: KvTransition.fade),
    routes: <RouteBase>[
      GoRoute(path: 'd-op-events', name: 'd-op-events', pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, const OpEventsScreen(), transition: KvTransition.fade)),
      GoRoute(
        path: 'report/:id',
        name: 'd-op-report-status',
        pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, OpReportStatusScreen(reportId: s.pathParameters['id']!)),
      ),
    ],
  ),
  GoRoute(
    path: '/operator/assistant',
    name: 'op-assistant',
    pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, OpAssistantScreen(question: s.uri.queryParameters['q']), transition: KvTransition.fade),
  ),
  GoRoute(
    path: '/operator/profile',
    name: 'op-profile',
    pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, const OpProfileScreen(), transition: KvTransition.fade),
  ),
];

/// Экраны раздела поверх оболочек (без панели вкладок): отчёт смены, сообщение оператора, камера.
final List<RouteBase> masterOperatorRootRoutes = <RouteBase>[
  GoRoute(path: '/master/d-m-report-1311', name: 'd-m-report-1311', pageBuilder: (BuildContext c, GoRouterState s) => _master(s, const MasterShiftReportScreen())),
  GoRoute(
    path: '/operator/op-report',
    name: 'op-report',
    pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, OpReportScreen(unitId: s.uri.queryParameters['unit']), transition: KvTransition.up),
  ),
  GoRoute(path: '/operator/d-op-camera', name: 'd-op-camera', pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, const OpCameraScreen(), transition: KvTransition.up)),
  GoRoute(
    path: '/operator/d-op-report-sent',
    name: 'd-op-report-sent',
    pageBuilder: (BuildContext c, GoRouterState s) => _operator(s, OpReportSentScreen(reportId: s.uri.queryParameters['id'] ?? 'S-077'), transition: KvTransition.fade),
  ),
];
