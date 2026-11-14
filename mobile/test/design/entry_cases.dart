import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/providers.dart';
import 'package:kst_vizor/features/entry/entry_state.dart';

import 'design_case.dart';

/// Почта инженера смены из истории: с ней прототип показывает заполненный вход.
const String _engineerEmail = 'a.smirnov@kst-energo.ru';

/// Почта Сергея Белова, которого администратор ИБ блокирует в сценарии Д.
const String _belovEmail = 's.belov@kst-energo.ru';

/// Блокирует учётную запись Сергея Белова до открытия экрана, как в сценарии Д (14.11.2026, 09:41).
void _blockBelov(MockBackend backend) {
  final int i = backend.db.users.indexWhere((AdminUser u) => u.id == 'u-109');
  backend.db.users[i] = backend.db.users[i].copyWith(
    status: 'blocked',
    blockReason: 'Перевод в другое подразделение',
    blockedAt: '14.11.2026, 09:41',
    activeSessions: 0,
  );
}

/// Касание кольца сканера в листе биометрии с короткой паузой: подтверждённое состояние снимается
/// до автоматического перехода к объектам (1,7 с).
Future<void> _touchScanner(WidgetTester tester) async {
  final Finder ring = find.bySemanticsLabel('Приложить палец');
  expect(ring, findsOneWidget, reason: 'Нет кольца сканера');
  await tester.tap(ring, warnIfMissed: false);
  await pumpFor(tester, const Duration(milliseconds: 200));
}

/// Шаги до открытого листа биометрии на экране входа.
const List<DesignStep> _openBio = <DesignStep>[TapText('Войти по биометрии')];

/// Снимает фокус с полей ввода.
Future<void> _unfocus(WidgetTester tester, ProviderContainer container) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await pumpFor(tester, const Duration(milliseconds: 400));
}

/// Снимки раздела «Вход и первый запуск» (entry): по одному на каждый экран и наложение прототипа.
final List<DesignCase> entryCases = <DesignCase>[
  for (int n = 1; n <= 3; n++) DesignCase('a-onb-$n', route: '/a-onb-$n'),
  const DesignCase('login', route: '/login'),
  const DesignCase('a-login-loading', route: '/a-login-loading'),
  const DesignCase(
    'a-login-error',
    route: '/login',
    steps: <DesignStep>[EnterText('login-email', _engineerEmail), EnterText('login-password', 'wrongpass1'), TapText('Войти')],
  ),
  const DesignCase('login-bio', route: '/login', steps: _openBio),
  DesignCase(
    'a-bio-ok',
    route: '/login',
    steps: <DesignStep>[..._openBio, Custom((WidgetTester tester, ProviderContainer container) => _touchScanner(tester))],
  ),
  DesignCase(
    'a-bio-fail',
    route: '/login',
    steps: <DesignStep>[
      ..._openBio,
      Custom((WidgetTester tester, ProviderContainer container) async {
        (container.read(bioScannerProvider) as DemoBioScanner).failNext = 1;
        await _touchScanner(tester);
        await pumpFor(tester, const Duration(milliseconds: 500));
      }),
    ],
  ),
  const DesignCase('a-offline', route: '/a-offline'),
  const DesignCase('a-offline-info', route: '/a-offline', steps: <DesignStep>[TapLabel('Ещё')]),
  const DesignCase('a-offline-confirm', route: '/a-offline', steps: <DesignStep>[TapText('Работать без связи')]),
  const DesignCase('a-blocked', route: '/a-blocked?email=$_belovEmail', setup: _blockBelov),
  const DesignCase(
    'a-blocked-contact',
    route: '/a-blocked?email=$_belovEmail',
    setup: _blockBelov,
    steps: <DesignStep>[TapText('Связаться с администратором ИБ')],
  ),
  const DesignCase(
    'a-new-pass',
    route: '/a-new-pass',
    role: KvRole.engineer,
    email: 'newbie@kst.demo',
    steps: <DesignStep>[EnterText('new-pass-2', 'Ershov-Nas26'), EnterText('new-pass-1', 'Ershov-Nas26')],
  ),
  const DesignCase(
    'a-new-pass-weak',
    route: '/a-new-pass-weak',
    role: KvRole.engineer,
    email: 'newbie@kst.demo',
    steps: <DesignStep>[EnterText('new-pass-1', 'ershov1'), Custom(_unfocus)],
  ),
  const DesignCase('a-pass-ok', route: '/a-pass-ok', role: KvRole.engineer, email: 'newbie@kst.demo'),
  const DesignCase('a-temp-login', route: '/a-temp-login'),
  const DesignCase('a-blocked-login', route: '/a-blocked-login'),
  for (final String role in <String>['master', 'operator', 'admin', 'sec']) DesignCase('a-login-$role', route: '/a-login-$role'),
  DesignCase(
    'f-e-kicked',
    route: '/engineer/objects',
    role: KvRole.engineer,
    steps: <DesignStep>[
      Custom((WidgetTester tester, ProviderContainer container) async {
        unawaited(container.read(securityRepositoryProvider).block('u-101', reason: 'Проверка доступа'));
        await pumpFor(tester, const Duration(milliseconds: 900));
      }),
    ],
  ),
];
