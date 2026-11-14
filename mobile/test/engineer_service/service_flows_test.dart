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
import 'package:kst_vizor/data/mock/seed/seed_engineer_service.dart';
import 'package:kst_vizor/data/providers.dart';
import 'package:kst_vizor/features/engineer_service/flows/service_flows.dart';

import '../design/harness.dart';

/// Запущенное приложение на демонстрационном сервере без задержек.
class _App {
  _App(this.container, this.backend, this.router);

  final ProviderContainer container;
  final MockBackend backend;
  final GoRouter router;

  /// Путь верхнего экрана, в том числе открытого поверх (push).
  String get location => router.routerDelegate.currentConfiguration.last.matchedLocation;
}

/// Открывает приложение под учётной записью [email] на пути [route] в окне 390 × 844; [setup] готовит данные.
Future<_App> _open(WidgetTester tester, String route, {String email = 'engineer@kst.demo', void Function(MockBackend b)? setup}) async {
  await loadKvFonts();
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.padding = const FakeViewPadding(top: 108, bottom: 68);
  addTearDown(tester.view.reset);
  addTearDown(hideKvTransients);
  final FixedClock clock = FixedClock(StoryClock.storyNow);
  final MockBackend backend = MockBackend(clock: clock, latency: MockLatency.none);
  setup?.call(backend);
  final ProviderContainer container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      mockBackendProvider.overrideWithValue(backend),
      settingsStoreProvider.overrideWithValue(MemorySettingsStore({'theme_mode': 'light', 'onboarding_seen': true})),
    ],
    retry: (int count, Object error) => null,
  );
  addTearDown(container.dispose);
  container.read(sessionProvider.notifier).restore(MockAuthRepository(backend).demoSession(email));
  final GoRouter router = container.read(routerProvider);
  router.go(route);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const KvApp()));
  await _settle(tester);
  return _App(container, backend, router);
}

/// Кадры по 50 мс в течение [ms]: переходы, задержка нажатия, ожидание кнопок.
Future<void> _settle(WidgetTester tester, [int ms = 1500]) async {
  for (int i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Касание видимого виджета [f]; если он ниже экрана - сначала прокрутка экрана к нему.
Future<void> _tapFinder(WidgetTester tester, Finder f, {int ms = 1500}) async {
  if (f.hitTestable().evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      f,
      200,
      scrollable: find.descendant(of: find.byType(KvScreen).last, matching: find.byType(Scrollable)).first,
    );
    await _settle(tester, 300);
  }
  await tester.tap(f.hitTestable().first);
  await _settle(tester, ms);
}

/// Касание текста [text].
Future<void> _tap(WidgetTester tester, String text, {int ms = 1500}) => _tapFinder(tester, find.text(text), ms: ms);

/// Касание видимого значка [icon] (кнопки шапки и листов).
Future<void> _tapIcon(WidgetTester tester, KvIcons icon, {int ms = 900}) async {
  await tester.tap(find.byWidgetPredicate((Widget w) => w is KvIcon && w.icon == icon).hitTestable().last);
  await _settle(tester, ms);
}

/// Касание кнопки «Ещё» в шапке.
Future<void> _more(WidgetTester tester) => _tapIcon(tester, KvIcons.more);

void main() {
  testWidgets('итог осмотра: PDF в «Файлы», меню и «Завершить и сохранить» ведут к отчёту', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/c-summary');
    await _tap(tester, 'PDF', ms: 700);
    expect(find.text('PDF сохранён в «Файлы»'), findsOneWidget);

    await _more(tester);
    expect(find.text('Предпросмотр отчёта'), findsOneWidget);
    await _tap(tester, 'Предпросмотр отчёта');
    expect(app.location, '/engineer/c-report');

    app.router.go('/engineer/c-summary');
    await _settle(tester);
    await _tap(tester, 'Завершить и сохранить', ms: 2200);
    expect(app.location, '/engineer/c-saved');
    expect(find.text('Осмотр сохранён'), findsOneWidget);
    await _tap(tester, 'Открыть отчёт');
    expect(app.location, '/engineer/c-report');
  });

  testWidgets('отчёт: «Поделиться» - отправка мастеру с уведомлением', (WidgetTester tester) async {
    await _open(tester, '/engineer/c-report');
    await _tap(tester, 'Поделиться', ms: 900);
    expect(find.text('Отправить мастеру'), findsOneWidget);
    await _tap(tester, 'Отправить мастеру', ms: 700);
    expect(find.text('Отчёт отправлен'), findsOneWidget);
  });

  testWidgets('история: фильтр по агрегату показывает сводку и только его события', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/history');
    expect(find.textContaining('остановка, S05'), findsOneWidget);
    await _tap(tester, KvFormat.typo('АМС-1'));
    expect(app.location, '/engineer/history/c-history/AMS-1');
    expect(find.textContaining('остановка, S05'), findsNothing);
    expect(find.textContaining('Осмотры и события ·'), findsOneWidget);
  });

  testWidgets('ассистент: подсказка «Ближайшие ТО» и вопрос с клавиатуры', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/assistant');
    await _tap(tester, 'Ближайшие ТО');
    expect(find.text('Ближайшие работы по наработке:'), findsOneWidget);

    await _tap(tester, 'Вопрос об оборудовании');
    expect(app.location, '/engineer/c-assist-input');
    await tester.enterText(find.byKey(const ValueKey<String>('assistant-question')), 'Когда меняли муфту АМС-1?');
    await _settle(tester, 300);
    await _tapIcon(tester, KvIcons.send, ms: 2000);
    expect(app.location, '/engineer/assistant');
    expect(find.text('Записей не нашёл'), findsOneWidget);
    await _tap(tester, 'Спросить мастера', ms: 700);
    expect(find.text('Вопрос отправлен мастеру'), findsOneWidget);
  });

  testWidgets('уведомления: отметить все прочитанными, переход к заданию и меню задания', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/c-notif');
    expect(find.text('3 новых'), findsOneWidget);
    await _more(tester);
    await _tap(tester, 'Отметить все прочитанными', ms: 900);
    expect(find.text('Готово'), findsOneWidget);
    expect(find.text('Нет новых'), findsOneWidget);
    hideKvTransients();

    await _tapFinder(tester, find.textContaining('Новое задание'));
    expect(app.location, '/engineer/task/T-318');
    expect(find.text('Начать осмотр'), findsOneWidget);
    await _more(tester);
    await _tap(tester, 'Связаться с мастером', ms: 700);
    expect(find.text('Марина Орлова'), findsOneWidget);
  });

  testWidgets('профиль: проверка связи с сервером цеха и выход из учётной записи', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/profile');
    await _tap(tester, 'Сервер цеха', ms: 900);
    await _tap(tester, 'Проверить связь', ms: 1600);
    expect(find.text('Связь в норме'), findsOneWidget);
    hideKvTransients();
    await _tapIcon(tester, KvIcons.close);

    await _tap(tester, 'Выйти из учётной записи', ms: 900);
    expect(find.text('Выйти из учётной записи?'), findsOneWidget);
    await _tap(tester, 'Выйти', ms: 2000);
    expect(app.container.read(sessionProvider), isNull);
    expect(app.location, '/login');
  });

  testWidgets('настройки: тема переключается, чувствительность меняет пояснение, кэш очищается, «О приложении»', (
    WidgetTester tester,
  ) async {
    final _App app = await _open(tester, '/engineer/c-settings');
    await _tap(tester, 'Тёмная', ms: 800);
    expect(app.container.read(deviceSettingsProvider).themeMode, ThemeMode.dark);

    await _tap(tester, 'Баланс', ms: 600);
    expect(find.text('Баланс: средняя чувствительность для плановых обходов.'), findsOneWidget);

    await _tap(tester, 'Очистить кэш снимков', ms: 900);
    expect(find.text('Очистить кэш снимков?'), findsOneWidget);
    await _tap(tester, 'Очистить');
    expect(find.text('Кэш очищен'), findsOneWidget);
    expect(find.text(KvFormat.typo('0 МБ')), findsOneWidget);
    hideKvTransients();

    await _tap(tester, 'О приложении', ms: 900);
    expect(find.text('КСТ Визор'), findsOneWidget);
  });

  testWidgets('очередь отправки: «Повторить отправку» передаёт всё на сервер цеха', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/c-queue');
    expect(find.text(KvFormat.typo('Ждут отправки · 3')), findsOneWidget);
    await _tap(tester, 'Повторить отправку', ms: 2000);
    expect(app.location, '/engineer/c-queue-ok');
    expect(find.text(KvFormat.typo('Отправлено сегодня · 4')), findsOneWidget);
  });

  testWidgets('роль изменена: «Открыть разделы» обновляет сеанс, старший инженер видит раздел «Находки»', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/objects', email: 'e.titova@kst-energo.ru');
    seedSeniorRoleScenario(app.backend.db);
    showRoleChangedDialog(
      find.byType(KvScreen).evaluate().last,
      roleName: 'Старший инженер',
      added: const <String>['confirm', 'reports_all'],
    ).ignore();
    await _settle(tester, 700);
    await _tap(tester, 'Открыть разделы');
    expect(app.container.read(sessionProvider)?.user.role, KvRole.senior);
    expect(app.location, '/senior/objects');

    await _tap(tester, 'Новый раздел · Находки');
    expect(app.location, '/senior/findings');
    await _tap(tester, 'Деградация уплотнения вала');
    expect(app.location, '/senior/findings/finding/F-1043');
  });

  testWidgets('уведомление о задании открывает диагностику по правилам', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/objects');
    final InspectionTask task = (await app.container.read(workflowRepositoryProvider).tasks()).firstWhere(
      (InspectionTask t) => t.id == 'T-318',
    );
    final Equipment unit = await app.container.read(unitProvider('N-101').future);
    showTaskPush(find.byType(KvScreen).evaluate().last, task: task, unit: unit);
    await _settle(tester, 600);
    await _tapFinder(tester, find.byType(KvToast));
    expect(app.location, '/engineer/objects/diagnostics');
  });
}
