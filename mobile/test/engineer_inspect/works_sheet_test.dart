import 'package:flutter/widgets.dart';
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
import 'package:kst_vizor/data/repositories/inspection_repository.dart';
import 'package:kst_vizor/features/engineer_inspect/works_sheet.dart';

import '../design/harness.dart';

/// Осмотры со списком записанных работ.
class _Works extends MockInspectionRepository {
  _Works(super.backend);

  final List<String> works = [];

  @override
  Future<List<RouteStep>> route(String unitId) async => const [
        RouteStep(n: 1, nodeId: 'seal', name: 'Торцевое уплотнение', why: 'finding', reason: 'Прошлое замечание'),
        RouteStep(n: 2, nodeId: 'motor_bearings', name: 'Подшипники двигателя', why: 'resource', reason: 'Ресурс 96 %'),
        RouteStep(n: 3, nodeId: 'equipment', name: 'Агрегат', why: 'routine', reason: 'Плановый осмотр'),
      ];

  @override
  Future<List<MaintenanceKind>> maintenanceKinds(String unitId) async => const [(code: 'TO-1', name: 'ТО-1')];

  @override
  Future<void> addWork(String inspectionId, String unitId, {required WorkKind kind, String? node, String? comment, String? maintenanceCode}) async {
    works.add('${kind.server}|${node ?? '-'}|${maintenanceCode ?? '-'}|${comment ?? ''}');
  }
}

Future<_Works> _open(WidgetTester tester) async {
  await loadKvFonts();
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(720, 1560);
  addTearDown(tester.view.reset);
  addTearDown(hideKvTransients);
  final MockBackend backend = MockBackend(latency: MockLatency.none);
  final _Works repo = _Works(backend);
  final GoRouter router = GoRouter(
    navigatorKey: kvRootNavigatorKey,
    initialLocation: '/host',
    routes: [
      GoRoute(
        path: '/host',
        builder: (BuildContext context, _) => Center(child: KvButton('Работы', onPressed: () => showWorksSheet(context, 'N-101'))),
      ),
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
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const KvApp()));
  await _settle(tester);
  await _tap(tester, 'Работы');
  return repo;
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  await _settle(tester);
}

void main() {
  testWidgets('замена без узла не сохраняется; с узлом уходит одна запись только по «Сохранить»', (WidgetTester tester) async {
    final _Works repo = await _open(tester);
    expect(find.text('Агрегат целиком'), findsOneWidget);
    expect(find.text('Агрегат'), findsNothing);
    await _tap(tester, 'Заменил');
    expect(find.text('Агрегат целиком'), findsNothing);
    expect(find.text('Для замены выберите узел'), findsOneWidget);
    await _tap(tester, 'Сохранить');
    expect(repo.works, isEmpty);
    await _tap(tester, 'Подшипники двигателя');
    expect(repo.works, isEmpty);
    await tester.enterText(find.byType(EditableText), 'SKF 6309');
    await _settle(tester);
    await _tap(tester, 'Сохранить');
    expect(repo.works, ['replacement|motor_bearings|-|SKF 6309']);
    expect(find.text('Работа записана'), findsOneWidget);
  });

  testWidgets('обслуживание по регламенту и заметка, которая требует текста', (WidgetTester tester) async {
    final _Works repo = await _open(tester);
    await _tap(tester, 'ТО-1');
    await _tap(tester, 'Сохранить');
    expect(repo.works, ['maintenance|-|TO-1|']);
    await _tap(tester, 'Работы');
    await _tap(tester, 'Заметка');
    expect(find.text('Напишите текст заметки'), findsOneWidget);
    await _tap(tester, 'Торцевое уплотнение');
    await tester.enterText(find.byType(EditableText), 'Капли под валом');
    await _settle(tester);
    await _tap(tester, 'Сохранить');
    expect(repo.works.last, 'note|seal|-|Капли под валом');
  });
}
