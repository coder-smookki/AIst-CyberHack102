import 'dart:async';

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
import 'package:kst_vizor/features/entry/entry_state.dart';

/// Запущенное приложение на демонстрационном сервере без задержек.
class _App {
  _App(this.container, this.backend);

  final ProviderContainer container;
  final MockBackend backend;

  GoRouter get router => container.read(routerProvider);

  /// Текущий путь приложения.
  String get path => router.state.uri.path;

  /// Сеанс приложения.
  AuthSession? get session => container.read(sessionProvider);
}

/// Открывает приложение на маршруте [route]; [email] - войти заранее этой учётной записью,
/// [firstLaunch] - знакомство ещё не показано.
Future<_App> _open(WidgetTester tester, String route, {String? email, bool firstLaunch = false}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  addTearDown(tester.view.reset);
  addTearDown(hideKvTransients);
  final FixedClock clock = FixedClock(StoryClock.storyNow);
  final MockBackend backend = MockBackend(clock: clock, latency: MockLatency.none);
  final ProviderContainer container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      mockBackendProvider.overrideWithValue(backend),
      settingsStoreProvider.overrideWithValue(MemorySettingsStore({'theme_mode': 'light', 'onboarding_seen': !firstLaunch})),
    ],
    retry: (int count, Object error) => null,
  );
  addTearDown(container.dispose);
  if (email != null) {
    container.read(sessionProvider.notifier).restore(MockAuthRepository(backend).demoSession(email));
  }
  container.read(routerProvider).go(route);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const KvApp()));
  await _settle(tester);
  return _App(container, backend);
}

/// Кадры с шагом 50 мс в течение [ms] миллисекунд: анимации и бесконечные индикаторы не дают ждать pumpAndSettle.
Future<void> _settle(WidgetTester tester, [int ms = 1200]) async {
  for (int i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Касание единственного виджета [finder] и ожидание отклика.
Future<void> _tap(WidgetTester tester, Finder finder, [int ms = 1200]) async {
  expect(finder, findsOneWidget);
  await tester.tap(finder, warnIfMissed: false);
  await _settle(tester, ms);
}

/// Ввод почты и пароля на экране входа и нажатие «Войти».
Future<void> _login(WidgetTester tester, String email, String password) async {
  await tester.enterText(find.byKey(const ValueKey<String>('login-email')), email);
  await tester.enterText(find.byKey(const ValueKey<String>('login-password')), password);
  await _tap(tester, find.text('Войти'), 1500);
}

void main() {
  testWidgets('первый запуск: знакомство из трёх шагов, «Пропустить» ведёт ко входу и запоминается', (WidgetTester tester) async {
    final _App app = await _open(tester, '/', firstLaunch: true);
    expect(app.path, '/a-onb-1');
    expect(find.text('Наведите камеру на шильдик'), findsOneWidget);
    await _tap(tester, find.text('Далее'));
    expect(app.path, '/a-onb-2');
    expect(find.text('Обойдите агрегат'), findsOneWidget);
    await _tap(tester, find.text('Далее'));
    expect(app.path, '/a-onb-3');
    expect(find.text('Показывается только при первом запуске'), findsOneWidget);
    await _tap(tester, find.text('Начать работу'));
    expect(app.path, '/login');
    expect(app.container.read(deviceSettingsProvider).onboardingSeen, isTrue);
  });

  testWidgets('«Пропустить» на первом шаге открывает вход', (WidgetTester tester) async {
    final _App app = await _open(tester, '/a-onb-1', firstLaunch: true);
    await _tap(tester, find.text('Пропустить'));
    expect(app.path, '/login');
    expect(app.container.read(deviceSettingsProvider).onboardingSeen, isTrue);
  });

  testWidgets('неверный пароль: уведомление сверху с числом оставшихся попыток', (WidgetTester tester) async {
    final _App app = await _open(tester, '/login');
    await _login(tester, 'a.smirnov@kst-energo.ru', 'wrongpass1');
    expect(find.text('Не удалось войти'), findsOneWidget);
    expect(find.text('Неверная почта или пароль. Осталось попыток: 9.'), findsOneWidget);
    expect(app.session, isNull);
    await _settle(tester, 3000);
  });

  testWidgets('«Забыли пароль?» показывает контакт администратора ИБ', (WidgetTester tester) async {
    await _open(tester, '/login');
    await _tap(tester, find.text('Забыли пароль?'));
    expect(find.text('Пароль восстанавливает администратор ИБ'), findsOneWidget);
    expect(find.text('Дмитрий Захаров · d.zakharov@kst-energo.ru'), findsOneWidget);
    await _settle(tester, 3000);
  });

  testWidgets('вход инженера открывает объекты смены', (WidgetTester tester) async {
    final _App app = await _open(tester, '/login');
    await _login(tester, 'engineer@kst.demo', 'demo12345');
    expect(app.session?.user.role, KvRole.engineer);
    expect(app.path, '/engineer/objects');
  });

  testWidgets('скрытый вход мастера заполнен и ведёт на смену', (WidgetTester tester) async {
    final _App app = await _open(tester, '/a-login-master');
    expect(find.text('m.orlova@kst-energo.ru'), findsOneWidget);
    await _tap(tester, find.text('Войти'), 1500);
    expect(app.session?.user.role, KvRole.master);
    expect(app.path, '/master/shift');
  });

  testWidgets('биометрия: касание сканера подтверждает личность и открывает объекты', (WidgetTester tester) async {
    final _App app = await _open(tester, '/login');
    await _tap(tester, find.text('Войти по биометрии'));
    expect(find.text('Вход по биометрии'), findsOneWidget);
    await _tap(tester, find.bySemanticsLabel('Приложить палец'), 300);
    expect(find.text('Личность подтверждена'), findsOneWidget);
    expect(find.text('Алексей Смирнов, инженер-диагност. Открываем объекты смены.'), findsOneWidget);
    await _settle(tester, 2500);
    expect(app.session?.user.role, KvRole.engineer);
    expect(app.path, '/engineer/objects');
  });

  testWidgets('биометрия: отпечаток не распознан, «Повторить» и «Войти с паролем»', (WidgetTester tester) async {
    final _App app = await _open(tester, '/login');
    (app.container.read(bioScannerProvider) as DemoBioScanner).failNext = 1;
    await _tap(tester, find.text('Войти по биометрии'));
    await _tap(tester, find.bySemanticsLabel('Приложить палец'));
    expect(find.text('Отпечаток не распознан'), findsOneWidget);
    expect(find.text('Приложите палец ещё раз или войдите с паролем. Осталось 2 попытки.'), findsOneWidget);
    await _tap(tester, find.text('Повторить'));
    expect(find.text('Вход по биометрии'), findsOneWidget);
    await _tap(tester, find.text('Войти с паролем'));
    expect(find.text('Вход по биометрии'), findsNothing);
    expect(app.path, '/login');
    expect(app.session, isNull);
  });

  testWidgets('сервер недоступен: параметры подключения, копирование и работа без связи', (WidgetTester tester) async {
    final _App app = await _open(tester, '/login');
    await _login(tester, 'offline@kst.demo', 'demo12345');
    expect(app.path, '/a-offline');
    expect(find.text('Цеховой сервер не отвечает'), findsOneWidget);
    await _tap(tester, find.bySemanticsLabel('Ещё'));
    expect(find.text('Очередь отправки'), findsOneWidget);
    await _tap(tester, find.text('Скопировать для администратора'));
    expect(find.text('Данные скопированы'), findsOneWidget);
    await _settle(tester, 3000);
    await _tap(tester, find.bySemanticsLabel('Закрыть').last);
    expect(find.text('Очередь отправки'), findsNothing);
    await _tap(tester, find.text('Работать без связи'));
    expect(find.text('Работать без связи?'), findsOneWidget);
    await _tap(tester, find.text('Продолжить'), 1500);
    expect(app.session?.user.role, KvRole.engineer);
    expect(app.path, '/engineer/objects');
  });

  testWidgets('сервер недоступен: «Повторить подключение» повторяет вход', (WidgetTester tester) async {
    final _App app = await _open(tester, '/login');
    await _login(tester, 'offline@kst.demo', 'demo12345');
    expect(app.path, '/a-offline');
    await _tap(tester, find.text('Повторить подключение'), 1500);
    expect(app.path, '/a-login-loading');
    expect(find.textContaining('Проверяем учётную запись на'), findsOneWidget);
    await _settle(tester, 2500);
    expect(app.session?.user.role, KvRole.engineer);
    expect(app.path, '/engineer/objects');
  });

  testWidgets('заблокированная запись: экран блокировки, контакты администратора ИБ и звонок', (WidgetTester tester) async {
    final _App app = await _open(tester, '/a-blocked-login');
    expect(find.text('s.belov@kst-energo.ru'), findsOneWidget);
    await _tap(tester, find.text('Войти'), 1500);
    expect(app.path, '/a-blocked');
    expect(find.text('Учётная запись заблокирована'), findsOneWidget);
    expect(find.text('Перевод в другое подразделение'), findsOneWidget);
    await _tap(tester, find.text('Связаться с администратором ИБ'));
    expect(find.text('Рабочие дни, 09:00-18:00'), findsOneWidget);
    await _tap(tester, find.text('Позвонить'));
    expect(find.text('Вызов'), findsOneWidget);
    await _settle(tester, 3000);
    await _tap(tester, find.text('Скопировать адрес'));
    expect(find.text('Адрес скопирован'), findsOneWidget);
    await _settle(tester, 3000);
    await _tap(tester, find.byWidgetPredicate((Widget w) => w is KvIcon && w.icon == KvIcons.close).last);
    expect(find.text('Рабочие дни, 09:00-18:00'), findsNothing);
    await _tap(tester, find.text('Вернуться ко входу'));
    expect(app.path, '/login');
  });

  testWidgets('первый вход: пароль не по политике отклоняется, надёжный сохраняется', (WidgetTester tester) async {
    final _App app = await _open(tester, '/a-temp-login');
    expect(find.text('Биометрия - после первого входа с паролем'), findsOneWidget);
    await _tap(tester, find.text('Войти'), 1500);
    expect(app.path, '/a-new-pass');
    expect(app.session?.mustChangePassword, isTrue);
    await tester.enterText(find.byKey(const ValueKey<String>('new-pass-1')), 'ershov1');
    await _settle(tester, 300);
    expect(find.text('Слабый'), findsOneWidget);
    expect(find.text('Не короче 10 символов · сейчас 7'), findsOneWidget);
    await _tap(tester, find.text('Сохранить и войти'));
    expect(find.text('Пароль не подходит'), findsOneWidget);
    expect(find.text('Нужно не меньше 10 символов, буквы и цифры'), findsOneWidget);
    await _settle(tester, 3000);
    await tester.enterText(find.byKey(const ValueKey<String>('new-pass-1')), 'Ershov-Nasos-26');
    await tester.enterText(find.byKey(const ValueKey<String>('new-pass-2')), 'Ershov-Nasos-26');
    await _settle(tester, 300);
    expect(find.text('Надёжный'), findsOneWidget);
    await _tap(tester, find.text('Сохранить и войти'), 1500);
    expect(app.path, '/a-pass-ok');
    expect(find.text('Пароль сохранён'), findsOneWidget);
    expect(app.session?.mustChangePassword, isFalse);
    await _tap(tester, find.byType(KvToggle), 400);
    await _tap(tester, find.text('Перейти к объектам'), 1500);
    expect(app.path.startsWith('/engineer/'), isTrue);
  });

  testWidgets('блокировка во время работы: «Сеанс завершён» и переход ко входу', (WidgetTester tester) async {
    final _App app = await _open(tester, '/engineer/objects', email: 'engineer@kst.demo');
    unawaited(app.container.read(securityRepositoryProvider).block('u-101', reason: 'Проверка доступа'));
    await _settle(tester);
    expect(find.text('Сеанс завершён'), findsOneWidget);
    await _tap(tester, find.text('Ко входу'), 1500);
    expect(app.session, isNull);
    expect(app.path, '/a-blocked-login');
    expect(find.text('a.smirnov@kst-energo.ru'), findsOneWidget);
  });
}
