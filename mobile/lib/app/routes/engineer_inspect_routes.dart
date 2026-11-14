import 'package:go_router/go_router.dart';

import '../../features/engineer_inspect/card_charts_screen.dart';
import '../../features/engineer_inspect/card_history_screen.dart';
import '../../features/engineer_inspect/card_now_screen.dart';
import '../../features/engineer_inspect/defect_screen.dart';
import '../../features/engineer_inspect/diagnostics_screen.dart';
import '../../features/engineer_inspect/docs_screen.dart';
import '../../features/engineer_inspect/inspect_catalog.dart';
import '../../features/engineer_inspect/inspect_providers.dart';
import '../../features/engineer_inspect/objects_screen.dart';
import '../../features/engineer_inspect/route_screen.dart';
import '../../features/engineer_inspect/rule_screen.dart';
import '../../features/engineer_inspect/scan_detail_screens.dart';
import '../../features/engineer_inspect/scanner_screen.dart';
import '../../features/engineer_inspect/search_screen.dart';
import '../navigation/kv_page.dart';

/// Пути экранов раздела «Инженер: осмотр». Идентификаторы прототипа - имена маршрутов go_router.
///
/// Экраны одного агрегата принимают его в параметре запроса `unit` (по умолчанию Н-101 из задания мастера),
/// поэтому один маршрут обслуживает все агрегаты станции.
abstract final class EngineerInspectPaths {
  /// Объекты.
  static const String objects = '/engineer/objects';

  /// Объекты · 09:12, до задания: тот же экран объектов, пока задания мастера нет.
  static const String objects0912 = objects;

  /// Объекты · первый день П. Ершова: тот же экран объектов для нового сотрудника.
  static const String fCErshovHome = objects;

  /// Поиск агрегата.
  static const String search = '/engineer/search';

  /// Поиск с готовым запросом [q] (b-search-empty - запрос без результата).
  static String searchFor(String q) => _q(search, {'q': q});

  /// Карточка · Сейчас.
  static String card(String unitId) => '/engineer/objects/card/$unitId';

  /// Карточка · Графики.
  static String cardCharts(String unitId) => '/engineer/objects/card/$unitId/charts';

  /// Карточка · История.
  static String cardHistory(String unitId) => '/engineer/objects/card/$unitId/history';

  /// Паспорт и документы Н-101.
  static const String docs = '/engineer/docs';

  /// Паспорт и документы агрегата.
  static String docsFor(String unitId) => _q(docs, {'unit': unitId});

  /// Паспорт · страница: документ [index] агрегата.
  static String docView(String unitId, int index) => _q('/engineer/b-doc-view', {'unit': unitId, 'doc': '$index'});

  /// Сканер · агрегат распознан (Н-101).
  static const String scanner = '/engineer/scanner';

  /// Сканер агрегата.
  static String scannerFor(String unitId, {String? via}) => _q(scanner, {'unit': unitId, 'via': ?via});

  /// Сканер · поиск шильдика.
  static const String bScanSearch = '/engineer/b-scan-search';

  /// Сканер · плохие условия.
  static const String bScanPoor = '/engineer/b-scan-poor';

  /// Сканер · признак дефекта (течь у вала Н-101).
  static const String bScanDefect = '/engineer/b-scan-defect';

  /// Признак дефекта [label] агрегата крупным планом.
  static String scanDefectFor(String unitId, [String? label]) => _q(bScanDefect, {'unit': unitId, 'label': ?label});

  /// Сканер · чтение манометра (Н-101).
  static const String bScanGauge = '/engineer/b-scan-gauge';

  /// Чтение манометра агрегата.
  static String scanGaugeFor(String unitId) => _q(bScanGauge, {'unit': unitId});

  /// Маршрут осмотра (Н-101).
  static const String bRoute = '/engineer/b-route';

  /// Маршрут осмотра агрегата.
  static String routeFor(String unitId) => _q(bRoute, {'unit': unitId});

  /// Новый дефект по признаку камеры (Н-101).
  static const String bDefect = '/engineer/b-defect';

  /// Новый дефект по признаку [label] агрегата.
  static String defectFor(String unitId, {String? label}) => _q(bDefect, {'unit': unitId, 'label': ?label});

  /// Новый дефект · вручную (Н-101).
  static const String bDefectManual = '/engineer/b-defect-manual';

  /// Новый дефект агрегата вручную.
  static String defectManualFor(String unitId) => _q(bDefectManual, {'unit': unitId});

  /// Диагностика (Н-101).
  static const String diagnostics = '/engineer/objects/diagnostics';

  /// Диагностика агрегата.
  static String diagnosticsFor(String unitId) => _q(diagnostics, {'unit': unitId});

  /// Разбор правила [ruleId] по агрегату (b-rule, b-rule-r04, b-rule-r08, b-rule-s01, b-rule-s04, b-rule-r11).
  static String rule(String ruleId, [String unitId = kInspectDefaultUnit]) => _q('/engineer/rule/$ruleId', {'unit': unitId});

  /// Сканер · АМС-2, признак течи.
  static const String fAScanAms2 = '/engineer/f-a-scan-ams2';

  /// Путь [path] с параметрами запроса; агрегат по умолчанию не пишется.
  static String _q(String path, Map<String, String> params) {
    final Map<String, String> p = {
      for (final MapEntry<String, String> e in params.entries)
        if (!(e.key == 'unit' && e.value == kInspectDefaultUnit)) e.key: e.value,
    };
    return p.isEmpty ? path : Uri(path: path, queryParameters: p).toString();
  }
}

/// Агрегат из параметра запроса `unit`.
String _unit(GoRouterState s) => s.uri.queryParameters['unit'] ?? kInspectDefaultUnit;

/// Экраны раздела внутри оболочки инженера (с панелью вкладок).
final List<RouteBase> engineerInspectEngineerShellRoutes = <RouteBase>[
  GoRoute(
    path: '/engineer/objects',
    name: 'objects',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const ObjectsScreen(), transition: KvTransition.fade),
    routes: <RouteBase>[
      GoRoute(
        path: 'card/:unitId/charts',
        name: 'card-charts',
        pageBuilder: (_, GoRouterState s) =>
            KvPage<void>.of(s, CardChartsScreen(unitId: s.pathParameters['unitId']!, fromSegment: KvNavExtra.of(s)?.fromSegment)),
      ),
      GoRoute(
        path: 'card/:unitId/history',
        name: 'card-history',
        pageBuilder: (_, GoRouterState s) =>
            KvPage<void>.of(s, CardHistoryScreen(unitId: s.pathParameters['unitId']!, fromSegment: KvNavExtra.of(s)?.fromSegment)),
      ),
      GoRoute(
        path: 'card/:unitId',
        name: 'card',
        pageBuilder: (_, GoRouterState s) =>
            KvPage<void>.of(s, CardNowScreen(unitId: s.pathParameters['unitId']!, fromSegment: KvNavExtra.of(s)?.fromSegment)),
      ),
      GoRoute(
        path: 'diagnostics',
        name: 'diagnostics',
        pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, DiagnosticsScreen(unitId: _unit(s))),
      ),
    ],
  ),
];

/// Экраны раздела поверх оболочек (без панели вкладок): поиск, документы, камера, маршрут, формы и разборы правил.
final List<RouteBase> engineerInspectRootRoutes = <RouteBase>[
  GoRoute(
    path: EngineerInspectPaths.search,
    name: 'search',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, SearchScreen(initialQuery: s.uri.queryParameters['q'])),
  ),
  GoRoute(
    path: EngineerInspectPaths.docs,
    name: 'docs',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, DocsScreen(unitId: _unit(s))),
  ),
  GoRoute(
    path: '/engineer/b-doc-view',
    name: 'b-doc-view',
    pageBuilder: (_, GoRouterState s) =>
        KvPage<void>.of(s, DocViewScreen(unitId: _unit(s), index: int.tryParse(s.uri.queryParameters['doc'] ?? '') ?? 0)),
  ),
  GoRoute(
    path: EngineerInspectPaths.scanner,
    name: 'scanner',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(
      s,
      ScannerScreen(unitId: _unit(s), nameplateFirst: s.uri.queryParameters['unit'] == null, via: s.uri.queryParameters['via']),
      transition: KvTransition.up,
    ),
  ),
  GoRoute(
    path: EngineerInspectPaths.bScanSearch,
    name: 'b-scan-search',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const ScanSearchScreen(), transition: KvTransition.up),
  ),
  GoRoute(
    path: EngineerInspectPaths.bScanPoor,
    name: 'b-scan-poor',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const ScanPoorScreen(), transition: KvTransition.up),
  ),
  GoRoute(
    path: EngineerInspectPaths.bScanDefect,
    name: 'b-scan-defect',
    pageBuilder: (_, GoRouterState s) =>
        KvPage<void>.of(s, ScanDefectScreen(unitId: _unit(s), label: s.uri.queryParameters['label'] ?? kDefaultSign)),
  ),
  GoRoute(
    path: EngineerInspectPaths.bScanGauge,
    name: 'b-scan-gauge',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, ScanGaugeScreen(unitId: _unit(s))),
  ),
  GoRoute(
    path: EngineerInspectPaths.bRoute,
    name: 'b-route',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, RouteScreen(unitId: _unit(s))),
  ),
  GoRoute(
    path: EngineerInspectPaths.bDefect,
    name: 'b-defect',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, DefectScreen(unitId: _unit(s), label: s.uri.queryParameters['label'] ?? kDefaultSign)),
  ),
  GoRoute(
    path: EngineerInspectPaths.bDefectManual,
    name: 'b-defect-manual',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, DefectScreen(unitId: _unit(s), manual: true)),
  ),
  GoRoute(
    path: '/engineer/rule/:ruleId',
    name: 'b-rule',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, RuleScreen(ruleId: s.pathParameters['ruleId']!, unitId: _unit(s))),
  ),
  GoRoute(
    path: EngineerInspectPaths.fAScanAms2,
    name: 'f-a-scan-ams2',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const ScanAms2Screen(), transition: KvTransition.up),
  ),
];
