import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/core/kv.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/seed/seed_engineer_service.dart';
import 'package:kst_vizor/data/providers.dart';
import 'package:kst_vizor/features/engineer_service/flows/service_flows.dart';
import 'package:kst_vizor/features/engineer_service/settings/settings_screen.dart';

import 'design_case.dart';

/// Снимки раздела «Инженер: итоги и сервис» (engineer_service): по одному на каждый экран и наложение прототипа.
final List<DesignCase> engineerServiceCases = <DesignCase>[
  const DesignCase('c-summary', route: '/engineer/c-summary', role: KvRole.engineer),
  const DesignCase('c-summary-menu', route: '/engineer/c-summary', role: KvRole.engineer, steps: <DesignStep>[TapLabel('Ещё')]),
  const DesignCase('c-summary-saved', route: '/engineer/c-summary', role: KvRole.engineer, steps: <DesignStep>[TapText('PDF')]),
  const DesignCase('c-saved', route: '/engineer/c-saved', role: KvRole.engineer),
  const DesignCase('c-report', route: '/engineer/c-report', role: KvRole.engineer),
  const DesignCase('c-report-share', route: '/engineer/c-report', role: KvRole.engineer, steps: <DesignStep>[TapLabel('Ещё')]),
  const DesignCase('history', route: '/engineer/history', role: KvRole.engineer),
  const DesignCase('c-history-n101', route: '/engineer/history/c-history/N-101', role: KvRole.engineer),
  const DesignCase('c-history-ams1', route: '/engineer/history/c-history/AMS-1', role: KvRole.engineer),
  const DesignCase('c-history-ams2', route: '/engineer/history/c-history/AMS-2', role: KvRole.engineer),
  const DesignCase('assistant', route: '/engineer/assistant', role: KvRole.engineer),
  DesignCase(
    'c-assist-input',
    route: Uri(path: '/engineer/c-assist-input', queryParameters: {'q': 'Когда меняли муфту АМС-1?'}).toString(),
    role: KvRole.engineer,
    steps: const <DesignStep>[Custom(_keyboard)],
  ),
  DesignCase(
    'c-assist-nf',
    route: Uri(path: '/engineer/c-assist-input', queryParameters: {'q': 'Когда меняли муфту АМС-1?'}).toString(),
    role: KvRole.engineer,
    setup: _newDialog,
    steps: const <DesignStep>[TapLabel('Отправить'), Wait(Duration(milliseconds: 1200))],
  ),
  const DesignCase(
    'c-assist-to',
    route: '/engineer/assistant',
    role: KvRole.engineer,
    setup: _newDialog,
    steps: <DesignStep>[TapText('Ближайшие ТО'), Wait(Duration(milliseconds: 600))],
  ),
  const DesignCase('c-notif', route: '/engineer/c-notif', role: KvRole.engineer),
  const DesignCase('c-notif-menu', route: '/engineer/c-notif', role: KvRole.engineer, steps: <DesignStep>[TapLabel('Ещё')]),
  const DesignCase('c-task', route: '/engineer/task/T-318', role: KvRole.engineer),
  const DesignCase('c-task-ams2', route: '/engineer/task/T-317', role: KvRole.engineer, time: '6:53'),
  const DesignCase('c-task-menu', route: '/engineer/task/T-318', role: KvRole.engineer, steps: <DesignStep>[TapLabel('Ещё')]),
  const DesignCase(
    'c-task-ams2-menu',
    route: '/engineer/task/T-317',
    role: KvRole.engineer,
    time: '6:53',
    steps: <DesignStep>[TapLabel('Ещё')],
  ),
  const DesignCase('profile', route: '/engineer/profile', role: KvRole.engineer),
  const DesignCase('c-server', route: '/engineer/profile', role: KvRole.engineer, steps: <DesignStep>[TapText('Сервер цеха')]),
  const DesignCase('c-logout', route: '/engineer/profile', role: KvRole.engineer, steps: <DesignStep>[Custom(_tapLogout)]),
  const DesignCase('c-settings', route: '/engineer/c-settings', role: KvRole.engineer),
  const DesignCase('c-settings-end', route: '/engineer/c-settings-end', role: KvRole.engineer),
  const DesignCase('c-cache', route: '/engineer/c-settings', role: KvRole.engineer, steps: <DesignStep>[TapText('Очистить кэш снимков')]),
  const DesignCase('c-about', route: '/engineer/c-settings', role: KvRole.engineer, steps: <DesignStep>[Custom(_about)]),
  const DesignCase('c-queue', route: '/engineer/c-queue', role: KvRole.engineer),
  const DesignCase('c-queue-ok', route: '/engineer/c-queue-ok', role: KvRole.engineer),
  const DesignCase(
    'f-b-eng-push',
    route: '/engineer/objects',
    role: KvRole.engineer,
    time: '9:12',
    setup: _beforeTask,
    steps: <DesignStep>[Custom(_push)],
  ),
  const DesignCase(
    'f-d-role-changed',
    route: '/engineer/objects',
    role: KvRole.engineer,
    email: 'e.titova@kst-energo.ru',
    steps: <DesignStep>[Custom(_roleChanged)],
  ),
  const DesignCase('f-d-senior-home', route: '/senior/objects', role: KvRole.senior, setup: _senior),
  const DesignCase('f-d-senior-findings', route: '/senior/findings', role: KvRole.senior, setup: _senior),
  const DesignCase('f-d-senior-profile', route: '/senior/profile', role: KvRole.senior, setup: _senior),
  const DesignCase('f-d-logout', route: '/senior/profile', role: KvRole.senior, setup: _senior, steps: <DesignStep>[Custom(_tapLogout)]),
];

/// Задание T-318 до назначения мастером в 09:12.
InspectionTask? _t318;

/// 09:12, до задания: T-318 мастер ещё не назначил.
void _beforeTask(MockBackend b) {
  _t318 = b.db.tasks.firstWhere((InspectionTask t) => t.id == 'T-318');
  b.db.tasks.removeWhere((InspectionTask t) => t.id == 'T-318');
}

/// Новый разговор с ассистентом: прошлых вопросов нет.
void _newDialog(MockBackend b) => b.db.assistantDialog.clear();

/// Роль «Старший инженер» уже назначена Елене Титовой.
void _senior(MockBackend b) => seedSeniorRoleScenario(b.db);

/// Контекст открытого экрана для листов, диалогов и уведомлений.
BuildContext _root() => find.byType(KvScreen).evaluate().last;

/// Экранная клавиатура высотой как в прототипе (.c-kb): поле вопроса поднимается над ней.
Future<void> _keyboard(WidgetTester tester, ProviderContainer container) async {
  tester.view.viewInsets = const FakeViewPadding(bottom: 237 * 2);
  await pumpFor(tester, const Duration(milliseconds: 300));
}

/// Касание кнопки ниже первого экрана: сначала прокрутка к ней.
Future<void> _tapBelow(WidgetTester tester, String text) async {
  final Finder f = find.text(text);
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.descendant(of: find.byType(KvScreen).last, matching: find.byType(Scrollable)).first,
  );
  await pumpFor(tester, const Duration(milliseconds: 100));
  await tapFinder(tester, f, 'текст «$text»');
}

Future<void> _tapLogout(WidgetTester tester, ProviderContainer container) => _tapBelow(tester, 'Выйти из учётной записи');

/// В 09:12 мастер назначает T-318: на телефоне инженера появляется уведомление.
Future<void> _push(WidgetTester tester, ProviderContainer container) async {
  final Equipment unit = await container.read(unitProvider('N-101').future);
  showTaskPush(_root(), task: _t318!, unit: unit);
  await pumpFor(tester, const Duration(milliseconds: 600));
}

/// Администратор ИБ назначил Елене Титовой роль «Старший инженер»: на её телефоне - диалог о новых разделах.
Future<void> _roleChanged(WidgetTester tester, ProviderContainer container) async {
  seedSeniorRoleScenario(container.read(mockBackendProvider).db);
  showRoleChangedDialog(_root(), roleName: 'Старший инженер', added: const <String>['confirm', 'reports_all']).ignore();
  await pumpFor(tester, const Duration(milliseconds: 700));
}

/// Лист «О приложении» поверх настроек без прокрутки, как на доске прототипа (касание строки проверяет тест раздела).
Future<void> _about(WidgetTester tester, ProviderContainer container) async {
  showAboutSheet(_root()).ignore();
  await pumpFor(tester, const Duration(milliseconds: 700));
}
