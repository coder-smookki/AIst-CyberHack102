import 'package:go_router/go_router.dart';

import '../../features/engineer_inspect/card_now_screen.dart';
import '../../features/engineer_service/assistant/assistant_screen.dart';
import '../../features/engineer_service/history/history_screen.dart';
import '../../features/engineer_service/notifications/notifications_screen.dart';
import '../../features/engineer_service/notifications/task_screen.dart';
import '../../features/engineer_service/profile/profile_screen.dart';
import '../../features/engineer_service/queue/queue_screen.dart';
import '../../features/engineer_service/report/report_screen.dart';
import '../../features/engineer_service/senior/senior_findings_screen.dart';
import '../../features/engineer_service/senior/senior_home_screen.dart';
import '../../features/engineer_service/senior/senior_profile_screen.dart';
import '../../features/engineer_service/settings/settings_screen.dart';
import '../../features/engineer_service/summary/saved_screen.dart';
import '../../features/engineer_service/summary/summary_screen.dart';
import '../../features/master_operator/master/master_finding_screen.dart';
import '../navigation/kv_page.dart';

/// Пути экранов раздела «Инженер: итоги и сервис». Идентификаторы прототипа - имена маршрутов go_router.
abstract final class EngineerServicePaths {
  /// Итог осмотра.
  static const String cSummary = '/engineer/c-summary';

  /// Осмотр сохранён.
  static const String cSaved = '/engineer/c-saved';

  /// Предпросмотр отчёта.
  static const String cReport = '/engineer/c-report';

  /// История.
  static const String history = '/engineer/history';

  /// История агрегата [unitId] внутри ленты [base] (/engineer/history или /senior/profile/history).
  static String historyUnit(String unitId, {String base = history}) => '$base/c-history/$unitId';

  /// История · Н-101.
  static const String cHistoryN101 = '/engineer/history/c-history/N-101';

  /// История · АМС-1.
  static const String cHistoryAms1 = '/engineer/history/c-history/AMS-1';

  /// История · АМС-2.
  static const String cHistoryAms2 = '/engineer/history/c-history/AMS-2';

  /// Ассистент.
  static const String assistant = '/engineer/assistant';

  /// Ассистент · ввод вопроса.
  static const String cAssistInput = '/engineer/c-assist-input';

  /// Ввод вопроса с готовым текстом [question]; после ответа - возврат во вкладку [base].
  static String assistantInput({String base = assistant, String question = ''}) => Uri(
    path: cAssistInput,
    queryParameters: <String, String>{if (question.isNotEmpty) 'q': question, if (base != assistant) 'from': base},
  ).toString();

  /// Уведомления.
  static const String cNotif = '/engineer/c-notif';

  /// Задание [taskId].
  static String task(String taskId) => '/engineer/task/$taskId';

  /// Задание по правилу R08.
  static const String cTask = '/engineer/task/T-318';

  /// Задание по сообщению оператора.
  static const String cTaskAms2 = '/engineer/task/T-317';

  /// Профиль.
  static const String profile = '/engineer/profile';

  /// Настройки.
  static const String cSettings = '/engineer/c-settings';

  /// Настройки · прокрутка.
  static const String cSettingsEnd = '/engineer/c-settings-end';

  /// Очередь отправки · нет связи.
  static const String cQueue = '/engineer/c-queue';

  /// Очередь отправки · всё передано.
  static const String cQueueOk = '/engineer/c-queue-ok';

  /// Объекты · старший инженер.
  static const String fDSeniorHome = '/senior/objects';

  /// Карточка агрегата [unitId], открытая старшим инженером (панель вкладок старшего инженера остаётся).
  static String seniorCard(String unitId) => '/senior/objects/card/$unitId';

  /// Находки · старший инженер.
  static const String fDSeniorFindings = '/senior/findings';

  /// Находка [findingId], открытая старшим инженером.
  static String seniorFinding(String findingId) => '/senior/findings/finding/$findingId';

  /// Ассистент старшего инженера.
  static const String seniorAssistant = '/senior/assistant';

  /// Профиль · старший инженер.
  static const String fDSeniorProfile = '/senior/profile';

  /// История осмотров из профиля старшего инженера.
  static const String seniorHistory = '/senior/profile/history';
}

/// Лента истории по пути [path] (полный путь ленты - [base]) и отбор по агрегату внутри неё. Корень вкладки
/// появляется наплывом, лента из профиля старшего инженера въезжает справа.
GoRoute _history(String path, {required String base, required String name}) => GoRoute(
  path: path,
  name: name,
  pageBuilder: (_, GoRouterState s) => KvPage<void>.of(
    s,
    HistoryScreen(base: base),
    transition: base == EngineerServicePaths.history ? KvTransition.fade : KvTransition.push,
  ),
  routes: <RouteBase>[
    GoRoute(
      path: 'c-history/:unitId',
      name: base == EngineerServicePaths.history ? 'c-history-n101' : 'senior-c-history',
      pageBuilder: (_, GoRouterState s) => KvPage<void>.of(
        s,
        HistoryScreen(base: base, unitId: s.pathParameters['unitId']),
        transition: KvTransition.fade,
      ),
    ),
  ],
);

/// Экраны раздела внутри оболочки инженера (с панелью вкладок).
final List<RouteBase> engineerServiceEngineerShellRoutes = <RouteBase>[
  _history(EngineerServicePaths.history, base: EngineerServicePaths.history, name: 'history'),
  GoRoute(
    path: EngineerServicePaths.assistant,
    name: 'assistant',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const AssistantScreen(), transition: KvTransition.fade),
  ),
  GoRoute(
    path: EngineerServicePaths.profile,
    name: 'profile',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const ProfileScreen(), transition: KvTransition.fade),
  ),
];

/// Экраны раздела внутри оболочки старшего инженера (с панелью вкладок).
final List<RouteBase> engineerServiceSeniorShellRoutes = <RouteBase>[
  GoRoute(
    path: EngineerServicePaths.seniorAssistant,
    name: 'senior-assistant',
    pageBuilder: (_, GoRouterState s) =>
        KvPage<void>.of(s, const AssistantScreen(base: EngineerServicePaths.seniorAssistant), transition: KvTransition.fade),
  ),
  GoRoute(
    path: EngineerServicePaths.fDSeniorHome,
    name: 'f-d-senior-home',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const SeniorHomeScreen(), transition: KvTransition.fade),
    routes: <RouteBase>[
      GoRoute(
        path: 'card/:unitId',
        name: 'senior-card',
        pageBuilder: (_, GoRouterState s) =>
            KvPage<void>.of(s, CardNowScreen(unitId: s.pathParameters['unitId']!, fromSegment: KvNavExtra.of(s)?.fromSegment)),
      ),
    ],
  ),
  GoRoute(
    path: EngineerServicePaths.fDSeniorFindings,
    name: 'f-d-senior-findings',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const SeniorFindingsScreen(), transition: KvTransition.fade),
    routes: <RouteBase>[
      GoRoute(
        path: 'finding/:id',
        name: 'senior-finding',
        pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, MasterFindingScreen(findingId: s.pathParameters['id']!)),
      ),
    ],
  ),
  GoRoute(
    path: EngineerServicePaths.fDSeniorProfile,
    name: 'f-d-senior-profile',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const SeniorProfileScreen(), transition: KvTransition.fade),
    routes: <RouteBase>[_history('history', base: EngineerServicePaths.seniorHistory, name: 'senior-history')],
  ),
];

/// Экраны раздела поверх оболочек (без панели вкладок).
final List<RouteBase> engineerServiceRootRoutes = <RouteBase>[
  GoRoute(
    path: EngineerServicePaths.cSummary,
    name: 'c-summary',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const SummaryScreen()),
  ),
  GoRoute(
    path: EngineerServicePaths.cSaved,
    name: 'c-saved',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const SavedScreen(), transition: KvTransition.fade),
  ),
  GoRoute(
    path: EngineerServicePaths.cReport,
    name: 'c-report',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const ReportScreen()),
  ),
  GoRoute(
    path: EngineerServicePaths.cAssistInput,
    name: 'c-assist-input',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(
      s,
      AssistantInputScreen(
        question: s.uri.queryParameters['q'] ?? '',
        base: s.uri.queryParameters['from'] ?? EngineerServicePaths.assistant,
      ),
      transition: KvTransition.fade,
    ),
  ),
  GoRoute(
    path: EngineerServicePaths.cNotif,
    name: 'c-notif',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const NotificationsScreen()),
  ),
  GoRoute(
    path: '/engineer/task/:taskId',
    name: 'c-task',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, TaskScreen(taskId: s.pathParameters['taskId']!)),
  ),
  GoRoute(
    path: EngineerServicePaths.cSettings,
    name: 'c-settings',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const SettingsScreen()),
  ),
  GoRoute(
    path: EngineerServicePaths.cSettingsEnd,
    name: 'c-settings-end',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const SettingsScreen(atEnd: true)),
  ),
  GoRoute(
    path: EngineerServicePaths.cQueue,
    name: 'c-queue',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const QueueScreen(online: false)),
  ),
  GoRoute(
    path: EngineerServicePaths.cQueueOk,
    name: 'c-queue-ok',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const QueueScreen(online: true), transition: KvTransition.fade),
  ),
];
