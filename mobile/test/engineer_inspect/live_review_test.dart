import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:kst_vizor/app/app.dart';
import 'package:kst_vizor/app/router.dart';
import 'package:kst_vizor/app/state/app_state.dart';
import 'package:kst_vizor/core/kv.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/repos/mock_equipment_repository.dart';
import 'package:kst_vizor/data/mock/repos/mock_inspection_repository.dart';
import 'package:kst_vizor/data/providers.dart';
import 'package:kst_vizor/features/engineer_inspect/live/live_camera.dart';
import 'package:kst_vizor/features/engineer_inspect/live/live_detection.dart';

import '../design/harness.dart';

/// Осмотры демонстрационного сервера со счётчиком записанных находок.
class _CountingInspections extends MockInspectionRepository {
  _CountingInspections(super.backend);

  int added = 0;

  @override
  Future<Finding> addFinding(
    String inspectionId, {
    required String node,
    required String title,
    required String ruleId,
    required int severity,
    String? comment,
    List<String> evidence = const <String>[],
  }) {
    added++;
    return super.addFinding(inspectionId, node: node, title: title, ruleId: ruleId, severity: severity, comment: comment, evidence: evidence);
  }
}

/// Признак «подтёк» на маленьком стоп-кадре.
LiveDetection _leak() => LiveDetection(
      unitId: 'N-101',
      jpeg: img.encodeJpg(img.Image(width: 64, height: 48)),
      frameSize: const Size(64, 48),
      box: const LiveBox(cls: 'leak', conf: 0.81, rect: Rect.fromLTRB(10, 10, 40, 30), status: 'defect', node: 'seal'),
      at: DateTime(2026, 11, 14, 9, 31),
    );

/// Приложение с экранами решения по признаку и заглушкой сканера.
Future<({ProviderContainer container, _CountingInspections repo})> _open(WidgetTester tester, String start) async {
  await loadKvFonts();
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  addTearDown(tester.view.reset);
  addTearDown(hideKvTransients);
  final MockBackend backend = MockBackend(latency: MockLatency.none);
  final _CountingInspections repo = _CountingInspections(backend);
  final GoRouter router = GoRouter(
    navigatorKey: kvRootNavigatorKey,
    initialLocation: start,
    routes: [
      GoRoute(path: '/engineer/scanner', name: 'scanner', builder: (_, _) => const Center(child: Text('сканер'))),
      GoRoute(path: '/review', builder: (BuildContext context, _) => Consumer(builder: (_, WidgetRef ref, _) => LiveScanDefectScreen(d: ref.watch(liveReviewProvider).shown!))),
      GoRoute(path: '/form', builder: (BuildContext context, _) => Consumer(builder: (_, WidgetRef ref, _) => LiveDefectFormScreen(d: ref.watch(liveReviewProvider).shown!))),
    ],
  );
  final ProviderContainer container = ProviderContainer(
    overrides: [
      mockBackendProvider.overrideWithValue(backend),
      serverModeProvider.overrideWithValue(false),
      inspectionRepositoryProvider.overrideWithValue(repo),
      equipmentRepositoryProvider.overrideWithValue(MockEquipmentRepository(backend)),
      routerProvider.overrideWithValue(router),
      settingsStoreProvider.overrideWithValue(MemorySettingsStore({'theme_mode': 'light', 'onboarding_seen': true})),
    ],
    retry: (int count, Object error) => null,
  );
  addTearDown(container.dispose);
  container.read(liveReviewProvider.notifier).open(_leak());
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const KvApp()));
  for (int i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return (container: container, repo: repo);
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text).last);
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  test('решения по признакам: «не дефект» скрывает признак до конца осмотра, новый осмотр сбрасывает', () {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    final LiveReviewController review = c.read(liveReviewProvider.notifier);
    review.open(_leak());
    expect(c.read(liveReviewProvider).pending, isNotNull);
    review.dismiss(_leak());
    expect(c.read(liveReviewProvider).pending, isNull);
    expect(review.isDismissed('N-101', 'leak', 'seal'), isTrue);
    expect(review.isDismissed('N-101', 'leak', 'flanges'), isFalse);
    expect(review.isDismissed('N-101', 'corrosion', 'seal'), isFalse);
    review.done();
    expect(review.isDismissed('N-101', 'leak', 'seal'), isTrue);
    review.reset();
    expect(review.isDismissed('N-101', 'leak', 'seal'), isFalse);
  });

  testWidgets('«Не дефект» ничего не записывает в осмотр и возвращает на сканер', (WidgetTester tester) async {
    final ({ProviderContainer container, _CountingInspections repo}) app = await _open(tester, '/review');
    expect(find.text('Подтёк'), findsOneWidget);
    expect(find.text('Подтвердить'), findsNothing);
    await _tapText(tester, 'Не дефект');
    expect(app.repo.added, 0);
    expect(app.container.read(liveReviewProvider.notifier).isDismissed('N-101', 'leak', 'seal'), isTrue);
    expect(find.text('сканер'), findsOneWidget);
  });

  testWidgets('«Это дефект» на кадре признака записывает одну находку и возвращает на сканер', (WidgetTester tester) async {
    final ({ProviderContainer container, _CountingInspections repo}) app = await _open(tester, '/review');
    await _tapText(tester, 'Это дефект');
    expect(app.repo.added, 1);
    expect(app.container.read(liveReviewProvider).pending, isNull);
    expect(find.text('сканер'), findsOneWidget);
  });

  testWidgets('«Подтвердить» в форме дефекта записывает одну находку', (WidgetTester tester) async {
    final ({ProviderContainer container, _CountingInspections repo}) app = await _open(tester, '/form');
    expect(find.text('Новый дефект'), findsOneWidget);
    await _tapText(tester, 'Подтвердить');
    expect(app.repo.added, 1);
    expect(app.container.read(liveReviewProvider).pending, isNull);
    expect(find.text('сканер'), findsOneWidget);
  });
}
