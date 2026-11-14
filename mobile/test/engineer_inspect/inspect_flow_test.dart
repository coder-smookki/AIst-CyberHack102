import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kst_vizor/app/app.dart';
import 'package:kst_vizor/app/router.dart';
import 'package:kst_vizor/app/state/app_state.dart';
import 'package:kst_vizor/core/kv.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/repos/mock_auth_repository.dart';
import 'package:kst_vizor/data/providers.dart';

import '../design/harness.dart';

/// Запущенное приложение инженера на демонстрационном сервере без задержек.
class _App {
  _App(this.container, this.backend, this.router);

  final ProviderContainer container;
  final MockBackend backend;
  final GoRouter router;
}

/// Открывает приложение под инженером на пути [route] в окне 390 × 844.
Future<_App> _open(WidgetTester tester, String route) async {
  await loadKvFonts();
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.padding = const FakeViewPadding(top: 108, bottom: 68);
  addTearDown(tester.view.reset);
  addTearDown(hideKvTransients);
  final FixedClock clock = FixedClock(StoryClock.storyNow);
  final MockBackend backend = MockBackend(clock: clock, latency: MockLatency.none);
  final ProviderContainer container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      mockBackendProvider.overrideWithValue(backend),
      settingsStoreProvider.overrideWithValue(MemorySettingsStore({'theme_mode': 'light', 'onboarding_seen': true})),
    ],
    retry: (int count, Object error) => null,
  );
  addTearDown(container.dispose);
  container.read(sessionProvider.notifier).restore(MockAuthRepository(backend).demoSession('engineer@kst.demo'));
  final GoRouter router = container.read(routerProvider);
  router.go(route);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const KvApp()));
  await _settle(tester);
  return _App(container, backend, router);
}

/// Кадры по 50 мс в течение [ms]: анимации переходов, задержка нажатия и ожидание кнопок.
Future<void> _settle(WidgetTester tester, [int ms = 1500]) async {
  for (int i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Касание виджета с текстом [text]; если он под краем списка - сначала прокрутка к нему.
Future<void> _tap(WidgetTester tester, String text, {int ms = 1200}) async {
  if (find.text(text).hitTestable().evaluate().isEmpty && find.text(text).evaluate().isNotEmpty) {
    await tester.ensureVisible(find.text(text).first);
    await _settle(tester, 300);
  }
  final Finder f = find.text(text).hitTestable();
  expect(f, findsWidgets, reason: 'нет цели «$text»');
  await tester.tap(f.first);
  await _settle(tester, ms);
}

/// Путь текущего экрана.
String _location(_App app) => app.router.state.uri.toString();

void main() {
  testWidgets('карточка агрегата из списка объектов и вкладка «Графики»', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/objects');
    await tester.tap(find.text('Н-101').hitTestable().first);
    await _settle(tester);
    expect(_location(app), '/engineer/objects/card/N-101');
    expect(find.text('Начать осмотр'), findsOneWidget);
    await _tap(tester, 'Графики');
    expect(_location(app), '/engineer/objects/card/N-101/charts');
    expect(find.text('пик 4,8 · 10.11'), findsOneWidget);
  });

  testWidgets('плитка под графиком меняется местами с основным показанием, период переключается', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/objects/card/N-101/charts');
    final TelemetrySeries bearing = await app.container.read(telemetryRepositoryProvider).series('N-101', 'tBearing', TelemetryPeriod.week);
    await tester.tap(find.text('Подшипник').hitTestable());
    await _settle(tester);
    expect(find.text(bearing.label), findsOneWidget);
    expect(find.textContaining('Температура подшипника выше уставки'), findsOneWidget);
    await _tap(tester, '30 дн');
    final TelemetrySeries month = await app.container.read(telemetryRepositoryProvider).series('N-101', 'tBearing', TelemetryPeriod.month);
    expect(find.textContaining(month.peakLabel), findsWidgets);
  });

  testWidgets('поиск по серийному номеру открывает карточку, неизвестный номер - пустой результат', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/search?q=2786');
    expect(find.text('Найдено: 1 · по серийному номеру'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey<String>('search-query')), 'Н-205');
    await _settle(tester);
    expect(find.text('Агрегат не найден'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey<String>('search-query')), '2786');
    await _settle(tester);
    await tester.tap(find.text('Н-101').hitTestable().first);
    await _settle(tester);
    expect(_location(app), '/engineer/objects/card/N-101');
  });

  testWidgets('сканер: «Завершить» спрашивает подтверждение, «Продолжить» закрывает диалог', (WidgetTester tester) async {
    await _open(tester, '/engineer/scanner');
    expect(find.text('Н-101 · Wilo IL 65/160'), findsOneWidget);
    await _tap(tester, 'Завершить');
    expect(find.text('Завершить осмотр?'), findsOneWidget);
    await _tap(tester, 'Продолжить');
    expect(find.text('Завершить осмотр?'), findsNothing);
  });

  testWidgets('признак «не дефект» возвращает на живое видео с уведомлением', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/b-scan-defect');
    await _tap(tester, 'Не дефект');
    expect(find.text('Отмечено: не дефект'), findsOneWidget);
    expect(_location(app), startsWith('/engineer/scanner'));
  });

  testWidgets('подтверждение дефекта создаёт находку для мастера', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/b-defect');
    final int before = app.backend.db.findings.length;
    await _tap(tester, 'Подтвердить', ms: 2000);
    expect(app.backend.db.findings.length, before + 1);
    final String id = app.backend.db.findings.first.id;
    expect(find.text('Дефект зафиксирован · $id'), findsOneWidget);
    expect(app.backend.db.findings.first.ruleId, 'R01');
  });

  testWidgets('выбор узла в форме дефекта', (WidgetTester tester) async {
    await _open(tester, '/engineer/b-defect');
    await _tap(tester, 'Торцевое уплотнение');
    expect(find.text('Узел агрегата'), findsOneWidget);
    final String other = find.descendant(of: find.byType(KvSheet), matching: find.byType(KvRow)).evaluate().map((Element e) => (e.widget as KvRow).title).firstWhere((String t) => t != 'Торцевое уплотнение');
    await _tap(tester, other, ms: 600);
    await _tap(tester, 'Готово');
    expect(find.text(other), findsOneWidget);
  });

  testWidgets('диагностика: отбор «Критично» и лист несработавших правил', (WidgetTester tester) async {
    await _open(tester, '/engineer/objects/diagnostics');
    expect(find.text('R08'), findsOneWidget);
    await tester.tap(find.textContaining('Критично').first);
    await _settle(tester);
    expect(find.text('R01'), findsOneWidget);
    expect(find.text('R08'), findsNothing);
    await tester.tap(find.textContaining('Все').first);
    await _settle(tester);
    await tester.scrollUntilVisible(find.text('Остальные 12 правил'), 300, scrollable: find.byType(Scrollable).first);
    await _tap(tester, 'Остальные 12 правил');
    expect(find.text('Не сработали · 12 правил'), findsOneWidget);
  });

  testWidgets('разбор правила R04: «Добавить в осмотр» показывает снэкбар с переходом к маршруту', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/rule/R04');
    await _tap(tester, 'Добавить в осмотр');
    expect(find.textContaining('Добавлено в осмотр'), findsOneWidget);
    await _tap(tester, 'Маршрут');
    expect(_location(app), startsWith('/engineer/b-route'));
  });

  testWidgets('показание манометра сохраняется в маршрут осмотра', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/b-scan-gauge');
    await _tap(tester, 'Сохранить показание', ms: 2000);
    expect(find.text('Показание сохранено'), findsOneWidget);
    final List<RouteStep> route = await app.container.read(inspectionRepositoryProvider).route('N-101');
    expect(route.firstWhere((RouteStep s) => s.nodeId == 'gauge').result, 'ok');
  });

  testWidgets('меню карточки открывает документы, страница паспорта листается', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/objects/card/N-101');
    await tester.tap(find.byWidgetPredicate((Widget w) => w is KvIcon && w.icon == KvIcons.more));
    await _settle(tester);
    await _tap(tester, 'Паспорт и документы');
    expect(_location(app), '/engineer/docs');
    await _tap(tester, 'Паспорт насоса IL 65/160');
    expect(find.text('6.3 Замена торцевого уплотнения'), findsOneWidget);
    await _tap(tester, 'с. 33');
    expect(find.text('Страница 33'), findsOneWidget);
  });

  testWidgets('маршрут: карточка следующего узла ведёт к чтению манометра', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/b-route');
    await _tap(tester, 'Манометр на нагнетании');
    expect(_location(app), startsWith('/engineer/b-scan-gauge'));
  });

  testWidgets('без задания мастера плашка ведёт в диагностику сработавшего правила', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/objects');
    app.backend.db.tasks.removeWhere((InspectionTask t) => t.id == 'T-318');
    app.container.invalidate(tasksProvider);
    await _settle(tester);
    final Finder note = find.textContaining('Заданий от мастера пока нет.');
    expect(note, findsOneWidget);
    expect(find.textContaining('R08'), findsWidgets);
    await tester.tap(note);
    await _settle(tester);
    expect(_location(app), startsWith('/engineer/objects/diagnostics'));
  });
}
