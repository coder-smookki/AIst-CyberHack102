import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kst_vizor/app/app.dart';
import 'package:kst_vizor/app/router.dart';
import 'package:kst_vizor/app/state/app_state.dart';
import 'package:kst_vizor/core/widgets/kv_overlays.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/repos/mock_auth_repository.dart';
import 'package:kst_vizor/data/providers.dart';

import '../design/design_case.dart';

/// Запущенное приложение раздела для теста: демонстрационный сервер, провайдеры и маршрутизатор.
class AdminsApp {
  /// Создаёт описание запущенного приложения.
  const AdminsApp(this.backend, this.container, this.router);

  /// Демонстрационный сервер.
  final MockBackend backend;

  /// Провайдеры приложения.
  final ProviderContainer container;

  /// Маршрутизатор.
  final GoRouter router;

  /// Текущий путь.
  String get path => router.routerDelegate.currentConfiguration.uri.path;
}

/// Открывает приложение на [route] под учётной записью [email] (телефон 390 × 844, данные без задержки).
Future<AdminsApp> pumpAdminsApp(
  WidgetTester tester,
  String route, {
  String email = 'security@kst.demo',
  void Function(MockBackend b)? setup,
}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(780, 1688);
  tester.view.padding = const FakeViewPadding(top: 108, bottom: 68);
  tester.view.viewPadding = const FakeViewPadding(top: 108, bottom: 68);
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
  await pumpFor(tester, const Duration(milliseconds: 1200));
  return AdminsApp(backend, container, router);
}

/// Касается единственного видимого текста [text] (или совпадения [index]) и ждёт [wait].
Future<void> tapText(WidgetTester tester, String text, {int index = 0, Duration wait = const Duration(milliseconds: 700)}) async {
  final Finder f = find.text(text).at(index);
  await tester.ensureVisible(f);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(f.hitTestable());
  await pumpFor(tester, wait);
}

/// Касается кнопки с подписью для диктора [label].
Future<void> tapLabel(WidgetTester tester, String label) async {
  await tester.tap(find.bySemanticsLabel(label).first);
  await pumpFor(tester, const Duration(milliseconds: 700));
}

/// Ждёт, пока уведомление уйдёт, чтобы не осталось таймеров после теста.
Future<void> settleToasts(WidgetTester tester) async {
  hideKvTransients();
  await pumpFor(tester, const Duration(milliseconds: 3500));
}
