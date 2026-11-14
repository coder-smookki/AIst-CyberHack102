import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/repos/mock_equipment_repository.dart';
import 'package:kst_vizor/data/mock/repos/mock_inspection_repository.dart';
import 'package:kst_vizor/data/providers.dart';
import 'package:kst_vizor/features/engineer_inspect/inspect_providers.dart';

/// Осмотры сервера: новые сверху, у двух агрегатов по нескольку осмотров.
class _History extends MockInspectionRepository {
  _History(super.backend);

  @override
  Future<List<Inspection>> inspections({String? unitId}) async => [
        for (final String u in const ['AMS-1', 'N-101', 'AMS-1', 'NOPE-9', 'AMS-2', 'N-101'])
          Inspection(id: '1', unitId: u, date: '15.11', time: '09:00', duration: '', who: 'Алексей Смирнов', status: 'done', defects: 0, checks: 0),
      ];
}

ProviderContainer _container({required bool server}) {
  final MockBackend backend = MockBackend(latency: MockLatency.none);
  final ProviderContainer c = ProviderContainer(
    overrides: [
      mockBackendProvider.overrideWithValue(backend),
      serverModeProvider.overrideWithValue(server),
      inspectionRepositoryProvider.overrideWithValue(_History(backend)),
      equipmentRepositoryProvider.overrideWithValue(MockEquipmentRepository(backend)),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> _drain() async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('на сервере недавние берутся из настоящих осмотров, без зашитых агрегатов', () async {
    final ProviderContainer c = _container(server: true);
    final ProviderSubscription<List<RecentSearch>> sub = c.listen(recentSearchesProvider, (_, _) {});
    addTearDown(sub.close);
    expect(c.read(recentSearchesProvider), isEmpty);
    await _drain();
    final List<RecentSearch> recent = c.read(recentSearchesProvider);
    expect(recent.map((RecentSearch r) => r.unitId), ['AMS-1', 'N-101', 'AMS-2']);
    expect(recent.any((RecentSearch r) => r.query == 'Н-205'), isFalse);
  });

  test('поиск, сделанный до загрузки истории, история не затирает', () async {
    final ProviderContainer c = _container(server: true);
    final ProviderSubscription<List<RecentSearch>> sub = c.listen(recentSearchesProvider, (_, _) {});
    addTearDown(sub.close);
    c.read(recentSearchesProvider.notifier).remember('ТР-1', 'TR-1');
    await _drain();
    expect(c.read(recentSearchesProvider).map((RecentSearch r) => r.unitId), ['TR-1']);
  });

  test('в демонстрационном режиме нет несуществующего агрегата Н-205', () {
    final ProviderContainer c = _container(server: false);
    expect(c.read(recentSearchesProvider).any((RecentSearch r) => r.query == 'Н-205'), isFalse);
    expect(c.read(recentSearchesProvider).every((RecentSearch r) => r.unitId != null), isTrue);
  });
}
