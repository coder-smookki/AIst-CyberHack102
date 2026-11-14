import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state/app_state.dart';
import '../../data/providers.dart';
import '../../data/repositories/inspection_repository.dart';

/// Агрегат по умолчанию для экранов осмотра, открытых без параметра: насос из задания мастера.
const String kInspectDefaultUnit = 'N-101';

/// Маршрут осмотра агрегата: узлы по приоритету с итогами текущего обхода.
final routeProvider = FutureProvider.autoDispose.family<List<RouteStep>, String>((Ref ref, String unitId) {
  ref.watch(revisionProvider(KvDomain.inspections));
  return ref.watch(inspectionRepositoryProvider).route(unitId);
});

/// Разбор правила по агрегату: условия, основания и вывод.
final ruleCheckProvider = FutureProvider.autoDispose.family<RuleCheck, ({String unitId, String ruleId})>((Ref ref, ({String unitId, String ruleId}) a) {
  ref.watch(revisionProvider(KvDomain.inspections));
  return ref.watch(inspectionRepositoryProvider).ruleCheck(a.unitId, a.ruleId);
});

/// Рамки распознавания на текущем кадре камеры у агрегата.
final detectionsProvider = FutureProvider.autoDispose.family<List<Detection>, String>((Ref ref, String unitId) {
  ref.watch(revisionProvider(KvDomain.inspections));
  return ref.watch(inspectionRepositoryProvider).detections(unitId);
});

/// Идущий осмотр агрегата или null.
final activeInspectionProvider = FutureProvider.autoDispose.family<Inspection?, String>((Ref ref, String unitId) {
  ref.watch(revisionProvider(KvDomain.inspections));
  return ref.watch(inspectionRepositoryProvider).activeInspection(unitId);
});

/// Подписи уровней правил 1-3: «наблюдение и проверка» … «критично: остановка или запрет эксплуатации».
final FutureProvider<Map<int, String>> severityLabelsProvider = FutureProvider<Map<int, String>>(
  (Ref ref) => ref.watch(inspectionRepositoryProvider).severityLabels(),
);

/// Несработавшие правила агрегата с разбором: сначала правила без данных, затем остальные по порядку справочника.
final restRulesProvider = FutureProvider.autoDispose.family<List<({RuleDef rule, RuleCheck check})>, String>((Ref ref, String unitId) async {
  ref.watch(revisionProvider(KvDomain.inspections));
  final InspectionRepository repo = ref.watch(inspectionRepositoryProvider);
  final List<RuleDef> rules = await repo.rules();
  final Set<String> fired = (await repo.diagnosis(unitId)).map((DiagnosisResult d) => d.ruleId).toSet();
  final List<RuleDef> rest = rules.where((RuleDef r) => !fired.contains(r.id)).toList();
  final List<RuleCheck> checks = await Future.wait([for (final RuleDef r in rest) repo.ruleCheck(unitId, r.id)]);
  final List<({RuleDef rule, RuleCheck check})> all = [for (int i = 0; i < rest.length; i++) (rule: rest[i], check: checks[i])];
  return [
    ...all.where((({RuleDef rule, RuleCheck check}) e) => e.check.missing != null),
    ...all.where((({RuleDef rule, RuleCheck check}) e) => e.check.missing == null),
  ];
});

/// Поиск агрегата по номеру, модели или серийному номеру.
final unitSearchProvider = FutureProvider.autoDispose.family<List<Equipment>, String>((Ref ref, String query) {
  ref.watch(revisionProvider(KvDomain.equipment));
  return ref.watch(equipmentRepositoryProvider).search(query);
});

/// Недавний запрос поиска: агрегат или строка без результата.
typedef RecentSearch = ({String query, String? unitId});

/// Недавние запросы поиска на этом телефоне, новые сверху (не больше трёх). На цеховом сервере список
/// начинается с агрегатов из настоящих осмотров сотрудника, в демонстрационном режиме - с агрегатов демо-данных.
class RecentSearches extends Notifier<List<RecentSearch>> {
  bool _touched = false;

  @override
  List<RecentSearch> build() {
    _touched = false;
    if (!ref.watch(serverModeProvider)) {
      return const [(query: 'АМС-2', unitId: 'AMS-2'), (query: 'АМС-1', unitId: 'AMS-1')];
    }
    final String? me = ref.watch(sessionProvider.select((AuthSession? s) => s?.user.name));
    Future<void>.microtask(() => _fromHistory(me));
    return const <RecentSearch>[];
  }

  /// Агрегаты последних осмотров сотрудника [me] (без имени - все осмотры, которые отдал сервер), новые сверху.
  Future<void> _fromHistory(String? me) async {
    try {
      final List<Inspection> all = await ref.read(inspectionRepositoryProvider).inspections();
      final List<Equipment> units = await ref.read(equipmentRepositoryProvider).units();
      final Map<String, Equipment> byId = {for (final Equipment u in units) u.id: u};
      final List<RecentSearch> found = [];
      for (final Inspection i in all) {
        final Equipment? u = byId[i.unitId];
        if (u == null || (me != null && me.isNotEmpty && i.who.isNotEmpty && i.who != me) || found.any((RecentSearch r) => r.unitId == u.id)) {
          continue;
        }
        found.add((query: u.code, unitId: u.id));
        if (found.length == 3) {
          break;
        }
      }
      if (ref.mounted && !_touched) {
        state = found;
      }
    } on Object {
      return;
    }
  }

  /// Запомнить запрос [query]; [unitId] - найденный агрегат или null.
  void remember(String query, String? unitId) {
    final String q = query.trim();
    if (q.isEmpty) {
      return;
    }
    _touched = true;
    state = [
      (query: q, unitId: unitId),
      ...state.where((RecentSearch r) => r.query.toLowerCase() != q.toLowerCase() && (unitId == null || r.unitId != unitId)),
    ].take(3).toList(growable: false);
  }
}

/// Недавние запросы поиска.
final NotifierProvider<RecentSearches, List<RecentSearch>> recentSearchesProvider =
    NotifierProvider<RecentSearches, List<RecentSearch>>(RecentSearches.new);

/// Сведения разбора правила для экранов.
extension RuleCheckView on RuleCheck {
  /// Первое условие без данных или null.
  RuleCondition? get missing => conditions.where((RuleCondition c) => c.state == 'missing').firstOrNull;
}

/// Сведения маршрута осмотра для экранов.
extension RouteView on List<RouteStep> {
  /// Осмотренные узлы.
  int get checked => where((RouteStep s) => s.result != null && s.result != 'next').length;

  /// Следующий узел или null.
  RouteStep? get next => where((RouteStep s) => s.result == 'next').firstOrNull ?? where((RouteStep s) => s.result == null).firstOrNull;
}
