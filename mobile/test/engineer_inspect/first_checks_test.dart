import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kst_vizor/app/app.dart';
import 'package:kst_vizor/app/router.dart';
import 'package:kst_vizor/app/state/app_state.dart';
import 'package:kst_vizor/core/kv.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/repos/mock_equipment_repository.dart';
import 'package:kst_vizor/data/mock/repos/mock_inspection_repository.dart';
import 'package:kst_vizor/data/providers.dart';
import 'package:kst_vizor/features/engineer_inspect/card_now_screen.dart';
import 'package:kst_vizor/features/engineer_inspect/scanner_screen.dart';

import '../design/harness.dart';

/// Маршрут осмотра с осмотренным первым узлом.
class _Route extends MockInspectionRepository {
  _Route(super.backend);

  @override
  Future<List<RouteStep>> route(String unitId) async => const [
        RouteStep(n: 1, nodeId: 'coupling', name: 'Муфта', why: 'routine', reason: '', result: 'ok'),
        RouteStep(n: 2, nodeId: 'seal', name: 'Торцевое уплотнение', why: 'finding', reason: 'течь 12.11 не закрыта', result: 'next'),
        RouteStep(n: 3, nodeId: 'motor_bearings', name: 'Подшипники двигателя', why: 'sensor', reason: 'вибрация 1x выше 2,8 мм/с'),
        RouteStep(n: 4, nodeId: 'casing', name: 'Корпус насоса', why: 'resource', reason: 'ресурс 92 %'),
        RouteStep(n: 5, nodeId: 'flanges', name: 'Фланцы', why: 'routine', reason: 'плановый осмотр'),
      ];
}

void main() {
  testWidgets('«Сначала проверьте»: три неосмотренных узла с причиной словами и сканер с подсказкой', (WidgetTester tester) async {
    await loadKvFonts();
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(780, 1688);
    addTearDown(tester.view.reset);
    addTearDown(hideKvTransients);
    final MockBackend backend = MockBackend(latency: MockLatency.none);
    final GoRouter router = GoRouter(
      navigatorKey: kvRootNavigatorKey,
      initialLocation: '/host',
      routes: [
        GoRoute(path: '/host', builder: (_, _) => const Scaffold(body: SingleChildScrollView(child: FirstChecks(unitId: 'N-101')))),
        GoRoute(
          path: '/engineer/scanner',
          name: 'scanner',
          builder: (_, GoRouterState s) => ScannerScreen(unitId: s.uri.queryParameters['unit'] ?? 'N-101', aim: s.uri.queryParameters['aim']),
        ),
      ],
    );
    final ProviderContainer container = ProviderContainer(
      overrides: [
        mockBackendProvider.overrideWithValue(backend),
        serverModeProvider.overrideWithValue(false),
        inspectionRepositoryProvider.overrideWithValue(_Route(backend)),
        equipmentRepositoryProvider.overrideWithValue(MockEquipmentRepository(backend)),
        routerProvider.overrideWithValue(router),
        settingsStoreProvider.overrideWithValue(MemorySettingsStore({'theme_mode': 'light', 'onboarding_seen': true})),
      ],
      retry: (int count, Object error) => null,
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const KvApp()));
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Сначала проверьте'), findsOneWidget);
    expect(find.text('Муфта'), findsNothing);
    expect(find.text('Фланцы'), findsNothing);
    expect(find.textContaining('Прошлая находка: течь 12.11'), findsOneWidget);
    expect(find.textContaining('Датчики: вибрация 1x'), findsOneWidget);
    expect(find.textContaining('Ресурс: ресурс 92'), findsOneWidget);
    await tester.tap(find.textContaining('Проверить: Торцевое уплотнение'));
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Наведите камеру на: Торцевое уплотнение'), findsOneWidget);
  });
}
