import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/app/app.dart';
import 'package:kst_vizor/app/router.dart';
import 'package:kst_vizor/app/routes/entry_routes.dart';
import 'package:kst_vizor/app/state/app_state.dart';
import 'package:kst_vizor/core/kv.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/repos/mock_auth_repository.dart';
import 'package:kst_vizor/data/providers.dart';
import 'package:kst_vizor/features/shared/guide_screen.dart';

/// Кадры по 50 мс в течение [ms] миллисекунд.
Future<void> _settle(WidgetTester tester, [int ms = 1200]) async {
  for (int i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Открывает приложение на экране [route]; [email] - войти заранее этой учётной записью.
Future<ProviderContainer> _open(WidgetTester tester, String route, {String? email}) async {
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
      settingsStoreProvider.overrideWithValue(MemorySettingsStore({'theme_mode': 'light', 'onboarding_seen': true})),
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
  return container;
}

/// Прокручивает инструкцию до конца, собирая все тексты, и проверяет каждый раздел и пункт роли [role].
Future<void> _expectAllSections(WidgetTester tester, KvRole? role) async {
  final Set<String> seen = <String>{};
  final ScrollableState list = tester.state<ScrollableState>(find.byType(Scrollable).first);
  for (int i = 0; i < 80; i++) {
    seen.addAll(tester.widgetList<Text>(find.byType(Text)).map((Text t) => t.data ?? ''));
    if (list.position.pixels >= list.position.maxScrollExtent) {
      break;
    }
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 100));
  }
  for (final GuideSection s in guideSections(role)) {
    expect(seen, contains(s.title));
    for (final GuideItem item in s.items) {
      expect(seen, contains(KvFormat.typo(item.title)), reason: '${s.title}: ${item.title}');
      expect(seen, contains(KvFormat.typo(item.text)), reason: '${s.title}: ${item.title}');
    }
  }
  expect(tester.takeException(), isNull);
}

void main() {
  test('раздел своей роли первым, все разделы на месте', () {
    final int all = kGuideCommon.length + kGuideRoles.length;
    expect(guideSections(null).length, all);
    for (final KvRole role in KvRole.values) {
      final List<GuideSection> s = guideSections(role);
      expect(s.length, all);
      if (role != KvRole.engineer) {
        expect(s.first.roles, contains(role), reason: role.name);
      } else {
        expect(s.first.title, 'Начало работы');
      }
    }
  });

  testWidgets('со входа: ссылка «Как пользоваться» открывает общий порядок работы', (WidgetTester tester) async {
    final ProviderContainer c = await _open(tester, EntryPaths.login);
    await tester.tap(find.text('Как пользоваться'));
    await _settle(tester);
    expect(c.read(routerProvider).state.uri.path, EntryPaths.guide);
    expect(find.text('Порядок работы в приложении'), findsOneWidget);
    await _expectAllSections(tester, null);
  });

  for (final (KvRole role, String email) in <(KvRole, String)>[
    (KvRole.engineer, 'engineer@kst.demo'),
    (KvRole.master, 'm.orlova@kst-energo.ru'),
    (KvRole.operator, 'o.kuznetsova@kst-energo.ru'),
    (KvRole.admin, 'i.vlasov@kst-energo.ru'),
    (KvRole.sec, 'd.zakharov@kst-energo.ru'),
  ]) {
    testWidgets('из профиля роли ${role.name}: строка «Как пользоваться» и все разделы', (WidgetTester tester) async {
      final ProviderContainer c = await _open(tester, '/${role.name}/profile', email: email);
      expect(c.read(sessionProvider)?.user.role, role);
      await tester.scrollUntilVisible(find.text('Как пользоваться'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Как пользоваться'));
      await _settle(tester);
      expect(c.read(routerProvider).state.uri.path, EntryPaths.guide);
      await _expectAllSections(tester, role);
    });
  }
}
