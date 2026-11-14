import 'package:go_router/go_router.dart';

import '../../features/engineer_inspect/card_now_screen.dart';
import '../../features/engineer_inspect/objects_screen.dart';
import '../navigation/kv_page.dart';
import '../navigation/placeholder.dart';

/// Пути экранов раздела «Инженер: осмотр». Идентификаторы прототипа - имена маршрутов go_router.
abstract final class EngineerInspectPaths {
  /// Объекты.
  static const String objects = '/engineer/objects';
  /// Объекты · 09:12, до задания.
  static const String objects0912 = '/engineer/objects/objects-0912';
  /// Объекты · первый день П. Ершова.
  static const String fCErshovHome = '/engineer/objects/f-c-ershov-home';
  /// Поиск агрегата.
  static const String search = '/engineer/search';
  /// Поиск · нет результатов.
  static const String bSearchEmpty = '/engineer/b-search-empty';
  /// Карточка · Сейчас.
  static String card(String unitId) => '/engineer/objects/card/$unitId';
  /// Карточка · Графики.
  static String cardCharts(String unitId) => '/engineer/objects/card/$unitId/charts';
  /// Карточка · История.
  static String cardHistory(String unitId) => '/engineer/objects/card/$unitId/history';
  /// Паспорт и документы.
  static const String docs = '/engineer/docs';
  /// Паспорт · страница.
  static const String bDocView = '/engineer/b-doc-view';
  /// Сканер · агрегат распознан.
  static const String scanner = '/engineer/scanner';
  /// Сканер · поиск шильдика.
  static const String bScanSearch = '/engineer/b-scan-search';
  /// Сканер · плохие условия.
  static const String bScanPoor = '/engineer/b-scan-poor';
  /// Сканер · признак дефекта.
  static const String bScanDefect = '/engineer/b-scan-defect';
  /// Сканер · чтение манометра.
  static const String bScanGauge = '/engineer/b-scan-gauge';
  /// Маршрут осмотра.
  static const String bRoute = '/engineer/b-route';
  /// Новый дефект.
  static const String bDefect = '/engineer/b-defect';
  /// Новый дефект · вручную.
  static const String bDefectManual = '/engineer/b-defect-manual';
  /// Диагностика.
  static const String diagnostics = '/engineer/objects/diagnostics';
  /// Правило R01 · все условия.
  static const String bRule = '/engineer/b-rule';
  /// Правило R04 · не хватает данных.
  static const String bRuleR04 = '/engineer/b-rule-r04';
  /// Правило R08.
  static const String bRuleR08 = '/engineer/b-rule-r08';
  /// Правило S01.
  static const String bRuleS01 = '/engineer/b-rule-s01';
  /// Правило S04.
  static const String bRuleS04 = '/engineer/b-rule-s04';
  /// Правило R11.
  static const String bRuleR11 = '/engineer/b-rule-r11';
  /// Сканер · АМС-2, признак течи.
  static const String fAScanAms2 = '/engineer/f-a-scan-ams2';
}

/// Экраны раздела внутри оболочки инженера (с панелью вкладок).
final List<RouteBase> engineerInspectEngineerShellRoutes = <RouteBase>[
  GoRoute(
    path: '/engineer/objects',
    name: 'objects',
    pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, const ObjectsScreen(), transition: KvTransition.fade),
    routes: <RouteBase>[
      kvPlaceholderRoute('card/:unitId/charts', id: 'card-charts', title: 'Карточка · Графики'),
      kvPlaceholderRoute('card/:unitId/history', id: 'card-history', title: 'Карточка · История'),
      kvPlaceholderRoute('objects-0912', id: 'objects-0912', title: 'Объекты · 09:12, до задания'),
      kvPlaceholderRoute('f-c-ershov-home', id: 'f-c-ershov-home', title: 'Объекты · первый день П. Ершова'),
      GoRoute(
        path: 'card/:unitId',
        name: 'card',
        pageBuilder: (_, GoRouterState s) => KvPage<void>.of(s, CardNowScreen(unitId: s.pathParameters['unitId']!, fromSegment: KvNavExtra.of(s)?.fromSegment)),
      ),
      kvPlaceholderRoute('diagnostics', id: 'diagnostics', title: 'Диагностика'),
    ],
  ),
];

/// Экраны раздела поверх оболочек (без панели вкладок): формы, камера, вход.
final List<RouteBase> engineerInspectRootRoutes = <RouteBase>[
  kvPlaceholderRoute('/engineer/search', id: 'search', title: 'Поиск агрегата'),
  kvPlaceholderRoute('/engineer/b-search-empty', id: 'b-search-empty', title: 'Поиск · нет результатов'),
  kvPlaceholderRoute('/engineer/docs', id: 'docs', title: 'Паспорт и документы'),
  kvPlaceholderRoute('/engineer/b-doc-view', id: 'b-doc-view', title: 'Паспорт · страница'),
  kvPlaceholderRoute('/engineer/scanner', id: 'scanner', title: 'Сканер · агрегат распознан', transition: KvTransition.up),
  kvPlaceholderRoute('/engineer/b-scan-search', id: 'b-scan-search', title: 'Сканер · поиск шильдика', transition: KvTransition.up),
  kvPlaceholderRoute('/engineer/b-scan-poor', id: 'b-scan-poor', title: 'Сканер · плохие условия', transition: KvTransition.up),
  kvPlaceholderRoute('/engineer/b-scan-defect', id: 'b-scan-defect', title: 'Сканер · признак дефекта', transition: KvTransition.up),
  kvPlaceholderRoute('/engineer/b-scan-gauge', id: 'b-scan-gauge', title: 'Сканер · чтение манометра', transition: KvTransition.up),
  kvPlaceholderRoute('/engineer/b-route', id: 'b-route', title: 'Маршрут осмотра'),
  kvPlaceholderRoute('/engineer/b-defect', id: 'b-defect', title: 'Новый дефект'),
  kvPlaceholderRoute('/engineer/b-defect-manual', id: 'b-defect-manual', title: 'Новый дефект · вручную'),
  kvPlaceholderRoute('/engineer/b-rule', id: 'b-rule', title: 'Правило R01 · все условия'),
  kvPlaceholderRoute('/engineer/b-rule-r04', id: 'b-rule-r04', title: 'Правило R04 · не хватает данных'),
  kvPlaceholderRoute('/engineer/b-rule-r08', id: 'b-rule-r08', title: 'Правило R08'),
  kvPlaceholderRoute('/engineer/b-rule-s01', id: 'b-rule-s01', title: 'Правило S01'),
  kvPlaceholderRoute('/engineer/b-rule-s04', id: 'b-rule-s04', title: 'Правило S04'),
  kvPlaceholderRoute('/engineer/b-rule-r11', id: 'b-rule-r11', title: 'Правило R11'),
  kvPlaceholderRoute('/engineer/f-a-scan-ams2', id: 'f-a-scan-ams2', title: 'Сканер · АМС-2, признак течи', transition: KvTransition.up),
];
