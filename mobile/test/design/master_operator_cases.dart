import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/providers.dart';

import 'design_case.dart';

/// Касание виджета по части текста (подписи с неразрывными пробелами и дефисами).
class TapContains extends DesignStep {
  /// Создаёт шаг.
  const TapContains(this.text, {this.index = 0});

  /// Часть текста.
  final String text;

  /// Какое совпадение по счёту.
  final int index;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) =>
      tapFinder(
        tester,
        find.textContaining(text).at(index),
        'часть текста «$text»',
      );
}

/// Касание текста после прокрутки экрана до него (ленивый список строит только видимые блоки);
/// после касания экран под листом возвращается к началу, как на доске прототипа.
class TapScrolled extends DesignStep {
  /// Создаёт шаг.
  const TapScrolled(this.text);

  /// Текст.
  final String text;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) async {
    await tester.scrollUntilVisible(
      find.text(text),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await pumpFor(tester, const Duration(milliseconds: 300));
    await tapFinder(tester, find.text(text), 'текст «$text»');
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await pumpFor(tester, const Duration(milliseconds: 100));
  }
}

/// Push-уведомление цехового сервера в ленту роли во время показа экрана.
class PushNote extends DesignStep {
  /// Создаёт шаг.
  const PushNote(
    this.roleKey, {
    required this.kind,
    required this.title,
    required this.text,
    this.target,
  });

  /// Лента роли.
  final String roleKey;

  /// Тон.
  final String kind;

  /// Заголовок.
  final String title;

  /// Текст.
  final String text;

  /// Экран по касанию.
  final String? target;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) async {
    final MockBackend backend = container.read(mockBackendProvider);
    backend.pushNotification(
      roleKey,
      kind: kind,
      title: title,
      text: text,
      target: target,
    );
    backend.notify(KvDomain.notifications);
    await pumpFor(tester, const Duration(milliseconds: 900));
  }
}

/// Прокрутка экрана до карточки доказательств находки.
class ScrollToEvidence extends DesignStep {
  /// Создаёт шаг.
  const ScrollToEvidence();

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) async {
    final Finder f = find.byKey(const ValueKey<String>('mo-evidence'));
    expect(f, findsOneWidget, reason: 'Нет карточки доказательств');
    await Scrollable.ensureVisible(tester.element(f));
    await pumpFor(tester, const Duration(milliseconds: 300));
  }
}

/// Сообщение S-077 в 06:51: только что отправлено, мастер ещё не назначил осмотр.
void _s077New(MockBackend b) {
  final int i = b.db.faultReports.indexWhere(
    (FaultReport r) => r.id == 'S-077',
  );
  final FaultReport r = b.db.faultReports[i];
  b.db.faultReports[i] = r.copyWith(
    status: 'new',
    statusLabel: 'Новое',
    timeline: r.timeline.take(1).toList(),
  );
}

/// F-1043 отклонена мастером в 09:45 как ложное срабатывание.
void _f1043Rejected(MockBackend b) {
  final int i = b.db.findings.indexWhere((Finding f) => f.id == 'F-1043');
  b.db.findings[i] = b.db.findings[i].copyWith(
    status: 'rejected',
    rejectReason: 'Ложное срабатывание',
    closedNote: 'Капель нет, пятно - конденсат на корпусе.',
    closedBy: 'Марина Орлова',
    rejectedAt: '09:45',
  );
}

/// Н-101 переведён мастером в резерв в 09:41 по находке F-1043.
void _n101Reserve(MockBackend b) {
  final Equipment u = b.unitOf('N-101');
  b.putUnit(u.copyWith(mode: 'reserve', modeLabel: 'В резерве'));
  b.pushHistory(
    'N-101',
    status: 'info',
    title: 'Режим: в резерве',
    text: 'По находке F-1043',
    who: 'Марина Орлова',
  );
}

/// Push мастеру от оператора в 06:41 (сценарий А).
const PushNote _pushReport = PushNote(
  'master',
  kind: 'bad',
  title: 'Оператор сообщил о неисправности',
  text: 'АМС-2 · течь под агрегатом, повышенный шум · 06:40',
  target: '/master/shift/report/S-077',
);

/// Push мастеру о срабатывании R08 в 08:12 (сценарий Б).
const PushNote _pushR08 = PushNote(
  'master',
  kind: 'warn',
  title: 'Н-101: сработало правило R08',
  text:
      'Вибрация 1X 3,1 мм/с, уставка 2,8 · подшипник 78 °C, уставка 75 °C · 08:12',
  target: '/master/shift/unit/N-101?at=0912',
);

/// Push оператору о ремонте АМС-2 в 07:30 (сценарий А).
const PushNote _pushRepair = PushNote(
  'operator',
  kind: 'info',
  title: 'АМС-2 на ремонте',
  text:
      'Мастер запланировал ремонт уплотнения 15.11, 08:00 · по вашему сообщению S-077',
  target: '/operator/objects/repair/AMS-2',
);

const String _f1043 = '/master/findings/finding/F-1043';
const String _f1042 = '/master/findings/finding/F-1042';
const String _f1041at = '/master/findings/finding/F-1041?at=0728';
const List<String> _reasons = [
  'Ложное срабатывание',
  'Уже устранено',
  'Дубликат',
];

/// Отклонение находки: диалог без причины и три состояния с выбранной причиной.
List<DesignCase> _rejects(String id, String route, {String time = '9:41'}) => [
  DesignCase(
    id,
    route: route,
    role: KvRole.master,
    time: time,
    steps: const <DesignStep>[TapText('Отклонить')],
  ),
  for (int i = 0; i < _reasons.length; i++)
    DesignCase(
      '$id-$i',
      route: route,
      role: KvRole.master,
      time: time,
      steps: <DesignStep>[const TapText('Отклонить'), TapText(_reasons[i])],
    ),
];

/// Снимки раздела «Мастер и оператор» (master_operator): по одному на каждый экран и наложение прототипа.
final List<DesignCase> masterOperatorCases = <DesignCase>[
  const DesignCase('master-shift', route: '/master/shift', role: KvRole.master),
  const DesignCase(
    'master-shift-0640',
    route: '/master/shift?at=0640',
    role: KvRole.master,
    time: '6:41',
  ),
  const DesignCase(
    'master-shift-0812',
    route: '/master/shift?at=0812',
    role: KvRole.master,
    time: '8:12',
  ),
  const DesignCase(
    'd-m-push',
    route: '/master/shift?at=0640',
    role: KvRole.master,
    time: '6:41',
    setup: _s077New,
    steps: <DesignStep>[_pushReport],
  ),
  const DesignCase(
    'f-b-master-push',
    route: '/master/shift?at=0812',
    role: KvRole.master,
    time: '8:12',
    steps: <DesignStep>[_pushR08],
  ),
  const DesignCase(
    'd-m-notif',
    route: '/master/shift/d-m-notif',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-team',
    route: '/master/shift/d-m-team',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-assign-team',
    route: '/master/shift/d-m-team',
    role: KvRole.master,
    steps: <DesignStep>[TapText('Елена Титова')],
  ),
  const DesignCase(
    'd-m-assigned-team',
    route: '/master/shift/d-m-team',
    role: KvRole.master,
    steps: <DesignStep>[
      TapText('Елена Титова'),
      TapText('Назначить'),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'd-m-report',
    route: '/master/shift/report/S-077',
    role: KvRole.master,
    time: '6:51',
    setup: _s077New,
  ),
  const DesignCase(
    'd-m-report-menu',
    route: '/master/shift/report/S-077',
    role: KvRole.master,
    time: '6:51',
    setup: _s077New,
    steps: <DesignStep>[TapLabel('Ещё')],
  ),
  const DesignCase(
    'master-assign',
    route: '/master/shift/report/S-077',
    role: KvRole.master,
    time: '6:51',
    setup: _s077New,
    steps: <DesignStep>[TapText('Назначить осмотр')],
  ),
  const DesignCase(
    'd-m-assigned',
    route: '/master/shift/report/S-077',
    role: KvRole.master,
    time: '6:52',
    setup: _s077New,
    steps: <DesignStep>[
      TapText('Назначить осмотр'),
      TapText('Назначить'),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'd-m-unit',
    route: '/master/shift/unit/N-101',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-unit-0912',
    route: '/master/shift/unit/N-101?at=0912',
    role: KvRole.master,
    time: '9:12',
  ),
  const DesignCase(
    'd-m-unit-ams2',
    route: '/master/shift/unit/AMS-2',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-unit-stopped',
    route: '/master/shift/unit/N-101',
    role: KvRole.master,
    setup: _n101Reserve,
  ),
  const DesignCase(
    'd-m-assign-n101',
    route: '/master/shift/unit/N-101',
    role: KvRole.master,
    steps: <DesignStep>[TapText('Назначить осмотр')],
  ),
  const DesignCase(
    'd-m-assigned-n101',
    route: '/master/shift/unit/N-101',
    role: KvRole.master,
    steps: <DesignStep>[
      TapText('Назначить осмотр'),
      TapText('Назначить'),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'f-b-assign',
    route: '/master/shift/unit/N-101?at=0912',
    role: KvRole.master,
    time: '9:12',
    steps: <DesignStep>[TapText('Назначить осмотр')],
  ),
  const DesignCase(
    'f-b-assigned',
    route: '/master/shift/unit/N-101?at=0912',
    role: KvRole.master,
    time: '9:12',
    steps: <DesignStep>[
      TapText('Назначить осмотр'),
      TapText('Назначить'),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'd-m-mode',
    route: '/master/shift/unit/N-101',
    role: KvRole.master,
    steps: <DesignStep>[TapText('Сменить')],
  ),
  const DesignCase(
    'd-m-mode-done',
    route: '/master/shift/unit/N-101',
    role: KvRole.master,
    steps: <DesignStep>[
      TapText('Сменить'),
      TapContains('Остановить Н'),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'd-m-mode-run',
    route: '/master/shift/unit/N-101',
    role: KvRole.master,
    setup: _n101Reserve,
    steps: <DesignStep>[TapText('Запустить')],
  ),
  const DesignCase(
    'master-findings',
    route: '/master/findings',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-findings-all',
    route: '/master/findings/d-m-findings-all',
    role: KvRole.master,
  ),
  const DesignCase('d-m-finding', route: _f1043, role: KvRole.master),
  const DesignCase(
    'd-m-finding-scroll',
    route: _f1043,
    role: KvRole.master,
    steps: <DesignStep>[ScrollToEvidence()],
  ),
  const DesignCase('d-m-finding-r08', route: _f1042, role: KvRole.master),
  const DesignCase(
    'd-m-finding-ams2',
    route: _f1041at,
    role: KvRole.master,
    time: '7:28',
  ),
  const DesignCase(
    'd-m-finding-rejected',
    route: _f1043,
    role: KvRole.master,
    setup: _f1043Rejected,
  ),
  const DesignCase(
    'd-m-f-1041',
    route: '/master/findings/finding/F-1041',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-f-1036',
    route: '/master/findings/finding/F-1036',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-f-1031',
    route: '/master/findings/finding/F-1031',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-confirm',
    route: _f1043,
    role: KvRole.master,
    steps: <DesignStep>[TapText('Подтвердить')],
  ),
  const DesignCase(
    'd-m-confirm-keep',
    route: _f1043,
    role: KvRole.master,
    steps: <DesignStep>[
      TapText('Подтвердить'),
      TapText('Оставить в работе до ТО-2'),
    ],
  ),
  const DesignCase(
    'd-m-confirmed-keep',
    route: _f1043,
    role: KvRole.master,
    steps: <DesignStep>[
      TapText('Подтвердить'),
      TapText('Оставить в работе до ТО-2'),
      TapText('Подтвердить', index: 1),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'd-m-confirmed',
    route: _f1043,
    role: KvRole.master,
    steps: <DesignStep>[
      TapText('Подтвердить'),
      TapText('Подтвердить', index: 1),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'd-m-confirm-r08',
    route: _f1042,
    role: KvRole.master,
    steps: <DesignStep>[TapText('Подтвердить')],
  ),
  const DesignCase(
    'd-m-confirmed-r08',
    route: _f1042,
    role: KvRole.master,
    steps: <DesignStep>[
      TapText('Подтвердить'),
      TapText('Подтвердить', index: 1),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'd-m-confirm-ams2',
    route: _f1041at,
    role: KvRole.master,
    time: '7:28',
    steps: <DesignStep>[TapText('Подтвердить')],
  ),
  const DesignCase(
    'd-m-confirmed-ams2',
    route: _f1041at,
    role: KvRole.master,
    time: '7:30',
    steps: <DesignStep>[
      TapText('Подтвердить'),
      TapText('Подтвердить', index: 1),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  ..._rejects('d-m-reject', _f1043),
  ..._rejects('d-m-reject-r08', _f1042),
  ..._rejects('d-m-reject-ams2', _f1041at, time: '7:28'),
  const DesignCase(
    'd-m-schedule',
    route: _f1043,
    role: KvRole.master,
    steps: <DesignStep>[TapScrolled('Назначить на ТО')],
  ),
  const DesignCase(
    'd-m-scheduled',
    route: _f1043,
    role: KvRole.master,
    steps: <DesignStep>[
      TapScrolled('Назначить на ТО'),
      TapText('Добавить в план'),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'd-m-comment',
    route: _f1043,
    role: KvRole.master,
    steps: <DesignStep>[TapScrolled('Комментарий мастера')],
  ),
  const DesignCase(
    'd-m-comment-saved',
    route: _f1043,
    role: KvRole.master,
    steps: <DesignStep>[
      TapScrolled('Комментарий мастера'),
      TapText('Сохранить'),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'd-m-finding-menu',
    route: _f1043,
    role: KvRole.master,
    steps: <DesignStep>[TapLabel('Ещё')],
  ),
  const DesignCase('master-plan', route: '/master/plan', role: KvRole.master),
  const DesignCase(
    'd-m-plan-cal',
    route: '/master/plan/d-m-plan-cal',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-plan-item',
    route: '/master/plan/item/P-502',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-plan-p499',
    route: '/master/plan/item/P-499',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-plan-p501',
    route: '/master/plan/item/P-501',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-plan-p503',
    route: '/master/plan/item/P-503',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-plan-p504',
    route: '/master/plan/item/P-504',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-plan-p505',
    route: '/master/plan/item/P-505',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-plan-move',
    route: '/master/plan/item/P-502',
    role: KvRole.master,
    steps: <DesignStep>[TapText('Перенести срок')],
  ),
  const DesignCase(
    'd-m-plan-moved',
    route: '/master/plan/item/P-502',
    role: KvRole.master,
    steps: <DesignStep>[
      TapText('Перенести срок'),
      TapText('Перенести'),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'master-profile',
    route: '/master/profile',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-reports',
    route: '/master/profile/d-m-reports',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-report-1311',
    route: '/master/d-m-report-1311',
    role: KvRole.master,
  ),
  const DesignCase(
    'd-m-report-1311-share',
    route: '/master/d-m-report-1311',
    role: KvRole.master,
    steps: <DesignStep>[TapText('Поделиться')],
  ),
  const DesignCase(
    'd-m-report-1311-xls',
    route: '/master/d-m-report-1311',
    role: KvRole.master,
    steps: <DesignStep>[TapText('Excel')],
  ),
  const DesignCase(
    'd-m-xls-share',
    route: '/master/profile/d-m-reports',
    role: KvRole.master,
    steps: <DesignStep>[TapText('Отчёт за октябрь')],
  ),
  const DesignCase(
    'd-m-settings',
    route: '/master/profile',
    role: KvRole.master,
    steps: <DesignStep>[TapText('Настройки')],
  ),
  const DesignCase(
    'd-m-logout',
    route: '/master/profile',
    role: KvRole.master,
    steps: <DesignStep>[TapText('Выйти из учётной записи')],
  ),
  const DesignCase(
    'op-objects',
    route: '/operator/objects',
    role: KvRole.operator,
  ),
  const DesignCase(
    'op-objects-0730',
    route: '/operator/objects?at=0730',
    role: KvRole.operator,
    time: '7:30',
  ),
  const DesignCase(
    'd-op-push',
    route: '/operator/objects?at=0730',
    role: KvRole.operator,
    time: '7:30',
    steps: <DesignStep>[_pushRepair],
  ),
  const DesignCase(
    'd-op-unit',
    route: '/operator/objects/unit/N-101',
    role: KvRole.operator,
    steps: <DesignStep>[Wait(Duration(milliseconds: 1300))],
  ),
  const DesignCase(
    'd-op-unit-ams1',
    route: '/operator/objects/unit/AMS-1',
    role: KvRole.operator,
    steps: <DesignStep>[Wait(Duration(milliseconds: 1300))],
  ),
  const DesignCase(
    'd-op-unit-menu',
    route: '/operator/objects/unit/N-101',
    role: KvRole.operator,
    steps: <DesignStep>[TapLabel('Ещё')],
  ),
  const DesignCase(
    'd-op-locked',
    route: '/operator/objects/unit/N-101',
    role: KvRole.operator,
    steps: <DesignStep>[TapLabel('Ещё'), TapText('Осмотр агрегата')],
  ),
  const DesignCase(
    'd-op-repair',
    route: '/operator/objects/repair/AMS-2',
    role: KvRole.operator,
  ),
  const DesignCase(
    'd-op-notif',
    route: '/operator/objects/d-op-notif',
    role: KvRole.operator,
  ),
  const DesignCase(
    'op-report',
    route: '/operator/op-report',
    role: KvRole.operator,
  ),
  const DesignCase(
    'op-report-0640',
    route: '/operator/op-report',
    role: KvRole.operator,
    time: '6:40',
  ),
  const DesignCase(
    'd-op-report-n101',
    route: '/operator/op-report?unit=N-101',
    role: KvRole.operator,
  ),
  const DesignCase(
    'd-op-report-need',
    route: '/operator/op-report?unit=N-101',
    role: KvRole.operator,
    steps: <DesignStep>[
      TapText('Отправить мастеру'),
      Wait(Duration(milliseconds: 900)),
    ],
  ),
  const DesignCase(
    'd-op-pick-unit',
    route: '/operator/op-report',
    role: KvRole.operator,
    steps: <DesignStep>[TapContains('АМС-2')],
  ),
  const DesignCase(
    'd-op-camera',
    route: '/operator/d-op-camera',
    role: KvRole.operator,
  ),
  const DesignCase(
    'd-op-report-sent',
    route: '/operator/d-op-report-sent?id=S-077&photo=1',
    role: KvRole.operator,
  ),
  const DesignCase(
    'op-history',
    route: '/operator/history',
    role: KvRole.operator,
  ),
  const DesignCase(
    'd-op-events',
    route: '/operator/history/d-op-events',
    role: KvRole.operator,
  ),
  const DesignCase(
    'd-op-report-status',
    route: '/operator/history/report/S-077',
    role: KvRole.operator,
  ),
  const DesignCase(
    'd-op-report-s071',
    route: '/operator/history/report/S-071',
    role: KvRole.operator,
  ),
  const DesignCase(
    'op-assistant',
    route: '/operator/assistant',
    role: KvRole.operator,
  ),
  const DesignCase(
    'd-op-assistant-ans',
    route: '/operator/assistant?q=repair',
    role: KvRole.operator,
  ),
  const DesignCase(
    'op-profile',
    route: '/operator/profile',
    role: KvRole.operator,
  ),
  const DesignCase(
    'd-op-access',
    route: '/operator/profile',
    role: KvRole.operator,
    steps: <DesignStep>[TapText('Мои права')],
  ),
  const DesignCase(
    'd-op-settings',
    route: '/operator/profile',
    role: KvRole.operator,
    steps: <DesignStep>[TapText('Настройки')],
  ),
  const DesignCase(
    'd-op-logout',
    route: '/operator/profile',
    role: KvRole.operator,
    steps: <DesignStep>[TapText('Выйти из учётной записи')],
  ),
];
