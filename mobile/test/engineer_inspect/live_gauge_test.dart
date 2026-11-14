import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:kst_vizor/app/app.dart';
import 'package:kst_vizor/app/router.dart';
import 'package:kst_vizor/app/state/app_state.dart';
import 'package:kst_vizor/core/kv.dart';
import 'package:kst_vizor/data/api/api_gauge.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/repos/mock_equipment_repository.dart';
import 'package:kst_vizor/data/mock/repos/mock_inspection_repository.dart';
import 'package:kst_vizor/data/providers.dart';
import 'package:kst_vizor/features/engineer_inspect/live/frame_encoder.dart';
import 'package:kst_vizor/features/engineer_inspect/live/live_camera.dart';
import 'package:kst_vizor/features/engineer_inspect/live/live_detection.dart';
import 'package:kst_vizor/features/engineer_inspect/live/live_gauge.dart';

import '../design/harness.dart';

/// Осмотры с серверным номером и счётчиками записей.
class _Inspections extends MockInspectionRepository {
  _Inspections(super.backend);

  final List<String> recorded = [];
  final List<String> marks = [];

  @override
  Future<Inspection?> activeInspection(String unitId) async =>
      Inspection(id: '42', unitId: unitId, date: '15.11', time: '09:30', duration: '', who: 'Инженер', status: 'draft', defects: 0, checks: 0);

  @override
  Future<List<RouteStep>> markRouteStep(String unitId, String nodeId, {required String result, String note = ''}) async {
    marks.add('$nodeId:$result');
    return const <RouteStep>[];
  }

  @override
  Future<Finding> addFinding(
    String inspectionId, {
    required String node,
    required String title,
    required String ruleId,
    required int severity,
    String? comment,
    List<String> evidence = const <String>[],
  }) async {
    recorded.add('$inspectionId:$node:$ruleId');
    return Finding(
      id: 'F-1',
      unitId: 'N-101',
      node: node,
      title: title,
      ruleId: ruleId,
      severity: severity,
      status: 'new',
      source: 'engineer',
      date: '15.11',
      time: '09:31',
      author: 'Инженер',
      comment: comment,
    );
  }
}

/// Манометр на стоп-кадре 200 x 160.
LiveDetection _gauge() => LiveDetection(
      unitId: 'N-101',
      jpeg: img.encodeJpg(img.Image(width: 200, height: 160)),
      frameSize: const Size(200, 160),
      box: const LiveBox(cls: 'gauge', conf: 0.9, rect: Rect.fromLTRB(60, 40, 140, 120), status: 'ok', node: 'gauge'),
      at: DateTime(2026, 11, 15, 9, 31),
    );

Future<({_Inspections repo, List<String?> sent})> _open(WidgetTester tester, Map<String, dynamic> reply) async {
  await loadKvFonts();
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  addTearDown(tester.view.reset);
  addTearDown(hideKvTransients);
  final MockBackend backend = MockBackend(latency: MockLatency.none);
  final _Inspections repo = _Inspections(backend);
  final List<String?> sent = [];
  final GoRouter router = GoRouter(
    navigatorKey: kvRootNavigatorKey,
    initialLocation: '/gauge',
    routes: [
      GoRoute(path: '/engineer/scanner', name: 'scanner', builder: (_, _) => const Center(child: Text('сканер'))),
      GoRoute(path: '/gauge', builder: (_, _) => LiveScanGaugeScreen(unitId: 'N-101', d: _gauge())),
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
      gaugeScaleProvider.overrideWith((Ref ref, String unitId) async => const GaugeScale(min: 0, max: 10, unit: 'бар', ratedMax: 16)),
      gaugeReaderProvider.overrideWithValue((String unitId, Uint8List crop, {String? inspectionId}) async {
        sent.add(inspectionId);
        return GaugeReading.fromJson(reply);
      }),
    ],
    retry: (int count, Object error) => null,
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const KvApp()));
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
  for (int i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return (repo: repo, sent: sent);
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).last);
  await tester.tap(find.text(text).last);
  for (int i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  test('отказ сервера не даёт числа, даже если в ответе есть value', () {
    final GaugeReading r = GaugeReading.fromJson(const {
      'ok': false,
      'value': 4.2,
      'unit': 'бар',
      'reason': 'Манометр не прочитан: циферблат не найден',
      'difference_percent': 3.0,
      'exceeds': false,
      'inspection_id': 42,
    });
    expect(r.ok, isFalse);
    expect(r.value, isNull);
    expect(r.differencePercent, isNull);
    expect(r.exceeds, isNull);
    expect(r.recorded, isFalse);
    expect(r.reason, contains('циферблат не найден'));
  });

  test('надёжное показание: число, сверка с датчиком и учёт в осмотре', () {
    final GaugeReading r = GaugeReading.fromJson(const {
      'ok': true,
      'value': 6.1,
      'unit': 'бар',
      'sensor_value': 4.9,
      'difference_percent': 19.7,
      'limit_percent': 15.0,
      'exceeds': true,
      'inspection_id': 42,
      'finding': {'rule_id': 'R05', 'title': 'Расхождение манометра и датчика'},
    });
    expect(r.value, 6.1);
    expect(r.exceeds, isTrue);
    expect(r.recorded, isTrue);
    expect(r.ruleTitle, 'R05 · Расхождение манометра и датчика');
  });

  test('шкала из карточки: край шкалы и паспортный предел', () {
    final GaugeScale s = GaugeScale.fromJson(const {'min': 0, 'max': 10, 'unit': 'бар'}, const {'max_pressure_bar': 16});
    expect(s.ratedMax, 16);
    expect(s.atEdge(0.1), isTrue);
    expect(s.atEdge(9.9), isTrue);
    expect(s.atEdge(4.2), isFalse);
  });

  test('вырезка манометра: рамка с полями, у края кадра поля обрезаются', () {
    final Uint8List frame = img.encodeJpg(img.Image(width: 200, height: 160));
    final img.Image mid = img.decodeJpg(cropJpeg(frame, 60, 40, 80, 80)!)!;
    expect(mid.width, 112);
    expect(mid.height, 112);
    final img.Image edge = img.decodeJpg(cropJpeg(frame, 0, 0, 50, 40)!)!;
    expect(edge.width, 60);
    expect(edge.height, 50);
    expect(cropJpeg(frame, 10, 10, 0, 20), isNull);
    expect(cropJpeg(Uint8List.fromList([1, 2, 3]), 0, 0, 10, 10), isNull);
  });

  testWidgets('отказ сервера: честная причина, никакого числа и кнопки сохранения', (WidgetTester tester) async {
    final app = await _open(tester, {'ok': false, 'value': null, 'unit': 'бар', 'reason': 'Стрелка манометра не определена уверенно', 'inspection_id': 42});
    expect(app.sent, ['42']);
    expect(find.text('Показание не прочитано'), findsOneWidget);
    expect(find.textContaining('не определена уверенно'), findsOneWidget);
    expect(find.text('Сохранить показание'), findsNothing);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('показание в норме сохраняется только по кнопке и отмечает узел проверенным', (WidgetTester tester) async {
    final app = await _open(tester, {
      'ok': true,
      'value': 4.2,
      'unit': 'бар',
      'sensor_value': 4.1,
      'difference_percent': 2.4,
      'limit_percent': 15.0,
      'exceeds': false,
      'inspection_id': 42,
    });
    expect(find.text('4,2'), findsOneWidget);
    expect(find.textContaining('В пределах шкалы прибора 0-10'), findsOneWidget);
    expect(app.repo.marks, isEmpty);
    await _tapText(tester, 'Сохранить показание');
    expect(app.repo.marks, ['gauge:ok']);
    expect(app.repo.recorded, isEmpty);
  });

  testWidgets('расхождение больше 15 % записывается находкой по R05', (WidgetTester tester) async {
    final app = await _open(tester, {
      'ok': true,
      'value': 9.95,
      'unit': 'бар',
      'sensor_value': 4.9,
      'difference_percent': 50.8,
      'limit_percent': 15.0,
      'exceeds': true,
      'inspection_id': 42,
    });
    expect(find.textContaining('у края шкалы'), findsOneWidget);
    await _tapText(tester, 'Сохранить показание');
    expect(app.repo.recorded, ['42:gauge:R05']);
    expect(app.repo.marks, isEmpty);
  });
}
