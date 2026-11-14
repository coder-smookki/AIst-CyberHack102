import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/models/admin.dart';
import 'package:kst_vizor/data/models/equipment.dart';
import 'package:kst_vizor/data/models/people.dart';

import 'design_case.dart';

/// Снимки раздела «Инженер: осмотр» (engineer_inspect).
final List<DesignCase> engineerInspectCases = <DesignCase>[
  const DesignCase('objects', route: '/engineer/objects', role: KvRole.engineer),
  const DesignCase('objects-0912', route: '/engineer/objects', role: KvRole.engineer, time: '9:12', setup: _beforeTask),
  const DesignCase('f-c-ershov-home', route: '/engineer/objects', role: KvRole.engineer, email: 'p.ershov@kst-energo.ru', setup: _ershovFirstDay),
  const DesignCase('search', route: '/engineer/search?q=2786', role: KvRole.engineer),
  DesignCase('b-search-empty', route: Uri(path: '/engineer/search', queryParameters: {'q': 'Н-205'}).toString(), role: KvRole.engineer),
  const DesignCase('card', route: '/engineer/objects/card/N-101', role: KvRole.engineer),
  const DesignCase('card-ams1', route: '/engineer/objects/card/AMS-1', role: KvRole.engineer),
  const DesignCase('card-ams2', route: '/engineer/objects/card/AMS-2', role: KvRole.engineer),
  const DesignCase('card-menu', route: '/engineer/objects/card/N-101', role: KvRole.engineer, steps: <DesignStep>[TapLabel('Ещё')]),
  const DesignCase('b-menu-ams1', route: '/engineer/objects/card/AMS-1', role: KvRole.engineer, steps: <DesignStep>[TapLabel('Ещё')]),
  const DesignCase('b-menu-ams2', route: '/engineer/objects/card/AMS-2', role: KvRole.engineer, steps: <DesignStep>[TapLabel('Ещё')]),
  const DesignCase('b-menu-charts', route: '/engineer/objects/card/N-101/charts', role: KvRole.engineer, steps: <DesignStep>[TapLabel('Ещё')]),
  const DesignCase('b-menu-history', route: '/engineer/objects/card/N-101/history', role: KvRole.engineer, steps: <DesignStep>[TapLabel('Ещё')]),
  const DesignCase('card-charts', route: '/engineer/objects/card/N-101/charts', role: KvRole.engineer, steps: <DesignStep>[Wait(Duration(milliseconds: 1300))]),
  const DesignCase('card-history', route: '/engineer/objects/card/N-101/history', role: KvRole.engineer),
  const DesignCase('docs', route: '/engineer/docs', role: KvRole.engineer),
  const DesignCase('b-doc-view', route: '/engineer/b-doc-view', role: KvRole.engineer),
  const DesignCase('scanner', route: '/engineer/scanner', role: KvRole.engineer),
  const DesignCase('b-scan-search', route: '/engineer/b-scan-search', role: KvRole.engineer),
  const DesignCase('b-scan-poor', route: '/engineer/b-scan-poor', role: KvRole.engineer),
  const DesignCase('b-scan-defect', route: '/engineer/b-scan-defect', role: KvRole.engineer),
  const DesignCase('b-scan-dismissed', route: '/engineer/b-scan-defect', role: KvRole.engineer, steps: <DesignStep>[TapText('Не дефект')]),
  const DesignCase('b-scan-gauge', route: '/engineer/b-scan-gauge', role: KvRole.engineer),
  const DesignCase('b-scan-finish', route: '/engineer/scanner', role: KvRole.engineer, steps: <DesignStep>[TapText('Завершить')]),
  const DesignCase('b-route', route: '/engineer/b-route', role: KvRole.engineer),
  const DesignCase('b-defect', route: '/engineer/b-defect', role: KvRole.engineer),
  const DesignCase('b-defect-manual', route: '/engineer/b-defect-manual', role: KvRole.engineer),
  const DesignCase('b-defect-node', route: '/engineer/b-defect', role: KvRole.engineer, steps: <DesignStep>[TapText('Торцевое уплотнение')]),
  const DesignCase(
    'b-scan-added',
    route: '/engineer/b-defect',
    role: KvRole.engineer,
    setup: _beforeF1043,
    steps: <DesignStep>[TapText('Подтвердить'), Wait(Duration(milliseconds: 900))],
  ),
  const DesignCase('diagnostics', route: '/engineer/objects/diagnostics', role: KvRole.engineer),
  const DesignCase('b-diag-rest', route: '/engineer/objects/diagnostics', role: KvRole.engineer, steps: <DesignStep>[Custom(_openRest)]),
  const DesignCase('b-rule', route: '/engineer/rule/R01', role: KvRole.engineer),
  const DesignCase('b-rule-r04', route: '/engineer/rule/R04', role: KvRole.engineer),
  const DesignCase('b-rule-r08', route: '/engineer/rule/R08', role: KvRole.engineer),
  const DesignCase('b-rule-s01', route: '/engineer/rule/S01', role: KvRole.engineer),
  const DesignCase('b-rule-s04', route: '/engineer/rule/S04', role: KvRole.engineer),
  const DesignCase('b-rule-r11', route: '/engineer/rule/R11', role: KvRole.engineer),
  const DesignCase('f-a-scan-ams2', route: '/engineer/f-a-scan-ams2', role: KvRole.engineer, time: '7:04', setup: _ams2Before0705),
  const DesignCase(
    'f-a-saved',
    route: '/engineer/f-a-scan-ams2',
    role: KvRole.engineer,
    time: '7:05',
    setup: _ams2Before0705,
    steps: <DesignStep>[TapText('Зафиксировать'), Wait(Duration(milliseconds: 900))],
  ),
  const DesignCase(
    'f-a-dismissed',
    route: '/engineer/f-a-scan-ams2',
    role: KvRole.engineer,
    time: '7:05',
    setup: _ams2Before0705,
    steps: <DesignStep>[TapText('Не дефект')],
  ),
];

/// 09:12: правило R08 уже сработало, задания T-318 ещё нет.
void _beforeTask(MockBackend b) => b.db.tasks.removeWhere((t) => t.id == 'T-318');

/// Первый день П. Ершова: пароль уже сменён, заданий и осмотров нет.
void _ershovFirstDay(MockBackend b) {
  final int i = b.db.users.indexWhere((AdminUser u) => u.email == 'p.ershov@kst-energo.ru');
  b.db.users[i] = b.db.users[i].copyWith(status: 'active');
}

/// До подтверждения дефекта в осмотре INS-2209: находки F-1043 ещё нет.
void _beforeF1043(MockBackend b) {
  b.db.findings.removeWhere((f) => f.id == 'F-1043');
  b.db.counters['F-'] = 1042;
}

/// 07:04, АМС-2 остановлен по S05, течь у вала ещё не зафиксирована (F-1041 появится после «Зафиксировать»).
void _ams2Before0705(MockBackend b) {
  b.db.findings.removeWhere((f) => f.id == 'F-1041');
  b.db.counters['F-'] = 1040;
  final int i = b.db.units.indexWhere((Equipment u) => u.id == 'AMS-2');
  b.db.units[i] = b.db.units[i].copyWith(mode: 'stopped', modeLabel: 'Остановлен');
}

/// Открывает лист несработавших правил: строка внизу ленивого списка, после касания список возвращается наверх,
/// как основа листа в прототипе.
Future<void> _openRest(WidgetTester tester, ProviderContainer container) async {
  final Finder row = find.text('Остальные 12 правил');
  final ScrollableState list = tester.state<ScrollableState>(find.byType(Scrollable).first);
  await tester.scrollUntilVisible(row, 400, scrollable: find.byType(Scrollable).first);
  await tapFinder(tester, row, 'строка «Остальные 12 правил»');
  list.position.jumpTo(0);
  await pumpFor(tester, const Duration(milliseconds: 300));
}
