import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/core/format/kv_format.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/models/admin.dart';
import 'package:kst_vizor/data/models/people.dart';

import 'design_case.dart';

/// Касание текста [text] (после типографской обработки, если [typo]); цель, закрытая кнопкой внизу или
/// оставшаяся за краем экрана, сначала прокручивается в видимую часть.
class TapSeen extends DesignStep {
  /// Создаёт шаг.
  const TapSeen(this.text, {this.index = 0, this.typo = false});

  /// Текст.
  final String text;

  /// Какое совпадение по счёту.
  final int index;

  /// Сравнивать с текстом после KvFormat.typo.
  final bool typo;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) async {
    final String t = typo ? KvFormat.typo(text) : text;
    Finder target() => find.text(t).at(index);
    for (int i = 0; i < 24 && (find.text(t).evaluate().length <= index || target().hitTestable().evaluate().isEmpty); i++) {
      final Size size = tester.view.physicalSize / tester.view.devicePixelRatio;
      await tester.dragFrom(Offset(24, size.height * 0.55), const Offset(0, -160));
      await pumpFor(tester, const Duration(milliseconds: 400));
    }
    await tapFinder(tester, target().hitTestable(), 'текст «$t»');
  }
}

/// Блокирует учётную запись [id] в данных до открытия экрана, как это делает администратор ИБ в 09:41.
void _block(MockBackend b, String id, {String reason = ''}) {
  final int i = b.db.users.indexWhere((AdminUser u) => u.id == id);
  b.db.users[i] = b.db.users[i].copyWith(status: 'blocked', blockReason: reason, blockedAt: '14.11.2026, 09:41', activeSessions: 0);
  b.db.sessions.removeWhere((UserSession s) => s.userId == id);
}

/// Снимает блокировку учётной записи [id].
void _unblock(MockBackend b, String id) {
  final int i = b.db.users.indexWhere((AdminUser u) => u.id == id);
  b.db.users[i] = b.db.users[i].copyWith(status: 'active');
}

/// Своя роль «Старший инженер» уже создана (как на доске прототипа), сотрудникам не назначена.
void _senior(MockBackend b) {
  if (!b.db.roles.any((Role r) => r.id == 'senior')) {
    b.db.roles.add(b.db.seniorRoleTemplate!);
  }
}

/// Роль «Старший инженер» назначена Елене Титовой.
void _seniorTitova(MockBackend b) {
  _senior(b);
  final int i = b.db.users.indexWhere((AdminUser u) => u.id == 'u-106');
  b.db.users[i] = b.db.users[i].copyWith(roleCode: 'senior', roleLabel: 'Старший инженер');
  for (int k = 0; k < b.db.roles.length; k++) {
    final Role r = b.db.roles[k];
    b.db.roles[k] = r.copyWith(users: b.db.users.where((AdminUser u) => u.roleCode == r.id).length);
  }
}

/// Сначала своя роль, затем изменение [then].
void _withSenior(MockBackend b, VoidCallback then) {
  _senior(b);
  then();
}

void _blockSmirnov(MockBackend b) => _withSenior(b, () => _block(b, 'u-101'));
void _blockBelov(MockBackend b) => _withSenior(b, () => _block(b, 'u-109', reason: 'Перевод в другое подразделение'));
void _blockTitova(MockBackend b) => _withSenior(b, () => _block(b, 'u-106'));
void _blockErshov(MockBackend b) => _withSenior(b, () => _block(b, 'u-110'));
void _blockOrlova(MockBackend b) => _withSenior(b, () => _block(b, 'u-102'));
void _blockKuznetsova(MockBackend b) => _withSenior(b, () => _block(b, 'u-103'));
void _blockVlasov(MockBackend b) => _withSenior(b, () => _block(b, 'u-104'));
void _blockGusev(MockBackend b) => _withSenior(b, () => _block(b, 'u-107'));
void _blockLebedeva(MockBackend b) => _withSenior(b, () => _block(b, 'u-108'));
void _unblockPanov(MockBackend b) => _withSenior(b, () => _unblock(b, 'u-111'));

/// Вариант карточки сотрудника на доске прототипа: состояние, роль, сеансы, своя запись, подготовка данных.
class _UserVariant {
  const _UserVariant(
    this.id,
    this.userId, {
    this.state = 'active',
    this.role = 'Инженер',
    this.sessions = false,
    this.self = false,
    this.setup,
    this.assigned = false,
  });

  final String id;
  final String userId;
  final String state;
  final String role;
  final bool sessions;
  final bool self;
  final void Function(MockBackend b)? setup;
  final bool assigned;
}

const List<_UserVariant> _users = [
  _UserVariant('e-user-smirnov', 'u-101', sessions: true),
  _UserVariant('e-user-smirnov-blocked', 'u-101', state: 'blocked', setup: _blockSmirnov),
  _UserVariant('e-user-belov', 'u-109', sessions: true),
  _UserVariant('e-user-belov-blocked', 'u-109', state: 'blocked', setup: _blockBelov),
  _UserVariant('e-user-titova', 'u-106'),
  _UserVariant('e-user-titova-senior', 'u-106', role: 'Старший инженер', setup: _seniorTitova, assigned: true),
  _UserVariant('e-user-titova-blocked', 'u-106', state: 'blocked', setup: _blockTitova),
  _UserVariant('e-user-ershov', 'u-110', state: 'temp'),
  _UserVariant('e-user-ershov-blocked', 'u-110', state: 'blocked', setup: _blockErshov),
  _UserVariant('e-user-panov', 'u-111', state: 'blocked', role: 'Оператор'),
  _UserVariant('e-user-panov-active', 'u-111', role: 'Оператор', setup: _unblockPanov),
  _UserVariant('e-user-orlova', 'u-102', role: 'Мастер', sessions: true),
  _UserVariant('e-user-orlova-blocked', 'u-102', state: 'blocked', setup: _blockOrlova),
  _UserVariant('e-user-kuznetsova', 'u-103', role: 'Оператор', sessions: true),
  _UserVariant('e-user-kuznetsova-blocked', 'u-103', state: 'blocked', setup: _blockKuznetsova),
  _UserVariant('e-user-vlasov', 'u-104', role: 'Админ'),
  _UserVariant('e-user-vlasov-blocked', 'u-104', state: 'blocked', setup: _blockVlasov),
  _UserVariant('e-user-zakharov', 'u-105', role: 'Админ ИБ', self: true),
  _UserVariant('e-user-gusev', 'u-107', role: 'Мастер'),
  _UserVariant('e-user-gusev-blocked', 'u-107', state: 'blocked', setup: _blockGusev),
  _UserVariant('e-user-lebedeva', 'u-108', role: 'Оператор'),
  _UserVariant('e-user-lebedeva-blocked', 'u-108', state: 'blocked', setup: _blockLebedeva),
];

/// Пауза до появления уведомления после кнопки с ожиданием.
const Wait _done = Wait(Duration(milliseconds: 100));

/// Карточка сотрудника и все её наложения: меню, роль, сброс пароля, сеанс, блокировка, разблокировка.
List<DesignCase> _userCases(_UserVariant v) {
  final String route = '/sec/e-user/${v.userId}${v.assigned ? '?assigned=1' : ''}';
  final void Function(MockBackend b) setup = v.setup ?? _senior;
  DesignCase c(String suffix, [List<DesignStep> steps = const <DesignStep>[]]) =>
      DesignCase('${v.id}$suffix', route: route, role: KvRole.sec, setup: setup, steps: steps);
  if (v.state == 'blocked') {
    return [
      c(''),
      c('-menu', const [TapLabel('Ещё')]),
      c('-unblock', const [TapSeen('Разблокировать')]),
    ];
  }
  final bool temp = v.state == 'temp';
  final List<DesignStep> role = [TapSeen(v.role), if (v.id == 'e-user-titova') const TapSeen('Старший инженер')];
  final List<DesignStep> reset = [TapSeen(temp ? 'Временный пароль' : 'Пароль')];
  final List<DesignStep> block = [
    const TapSeen('Заблокировать учётную запись'),
    if (v.userId == 'u-109') const EnterText('block-reason', 'Перевод в другое подразделение'),
  ];
  return [
    c(''),
    c('-menu', const [TapLabel('Ещё')]),
    if (v.self) ...[
      DesignCase.skip('${v.id}-role', reason: 'своя роль не меняется: в прототипе к листу нет перехода (строка роли без касания)'),
      DesignCase.skip('${v.id}-role-ok', reason: 'своя роль не меняется: в прототипе к уведомлению нет перехода'),
    ] else ...[
      c('-role', role),
      c('-role-ok', [TapSeen(v.role), const TapSeen('Назначить роль'), _done]),
    ],
    c('-reset', reset),
    c('-reset-done', [...reset, TapSeen(temp ? 'Выдать' : 'Сбросить'), _done]),
    if (v.sessions && !v.self) ...[
      c('-sess', const [TapSeen('Завершить')]),
      c('-sess-ok', const [TapSeen('Завершить'), TapSeen('Завершить', index: 1), _done]),
    ],
    if (!v.self) c('-block', block),
  ];
}

/// Подписи показаний агрегатов на экране привязки тегов.
const Map<String, String> _readingLabels = {
  'vib1x': 'Вибрация 1X',
  'vib2x': 'Вибрация 2X',
  'vibHf': 'ВЧ шум вибрации',
  'tBearing': 'Температура подшипника',
  'tWinding': 'Температура обмоток',
  'pressOut': 'Давление нагнетания',
  'pressIn': 'Давление на входе',
  'current': 'Ток двигателя',
  'unbalance': 'Небаланс токов',
  'flow': 'Расход',
};

/// Привязка тегов агрегата и её наложения: меню, новый тег, лист каждого тега, уведомление о сохранении.
List<DesignCase> _tagCases(String id, String slug, String unitId, List<String> keys) {
  final String route = '/admin/e-tags/$unitId';
  return [
    DesignCase(id, route: route, role: KvRole.admin),
    DesignCase('$id-saved', route: route, role: KvRole.admin, steps: const [TapSeen('Вибрация 1X'), TapSeen('Сохранить привязку'), _done]),
    DesignCase('$id-menu', route: route, role: KvRole.admin, steps: const [TapLabel('Ещё')]),
    DesignCase('$id-new', route: route, role: KvRole.admin, steps: const [TapSeen('Добавить тег')]),
    for (final String k in keys) DesignCase('e-tag-$slug-$k', route: route, role: KvRole.admin, steps: [TapSeen(_readingLabels[k]!)]),
  ];
}

/// Источник данных и его наложения: меню, отключение, уведомление; форма параметров.
List<DesignCase> _sourceCases(String slug) {
  final String route = '/admin/e-src/src-$slug';
  return [
    DesignCase('e-src-$slug', route: route, role: KvRole.admin),
    DesignCase('e-src-$slug-menu', route: route, role: KvRole.admin, steps: const [TapLabel('Ещё')]),
    DesignCase('e-src-$slug-off', route: route, role: KvRole.admin, steps: const [TapLabel('Ещё'), TapSeen('Отключить источник')]),
    DesignCase(
      'e-src-$slug-off-ok',
      route: route,
      role: KvRole.admin,
      steps: const [TapLabel('Ещё'), TapSeen('Отключить источник'), TapSeen('Отключить'), _done],
    ),
    DesignCase('e-src-$slug-edit', route: '/admin/e-src-edit/src-$slug', role: KvRole.admin),
  ];
}

/// Роль и её наложения: меню, сохранение прав (системные), удаление (своя роль).
List<DesignCase> _roleCases(String id, String roleId, {bool fresh = false}) {
  final String route = '/sec/e-role/$roleId${fresh ? '?fresh=1' : ''}';
  final bool system = roleId != 'senior';
  return [
    DesignCase(id, route: route, role: KvRole.sec, setup: _senior),
    if (system)
      DesignCase('$id-saved', route: route, role: KvRole.sec, setup: _senior, steps: const [TapSeen('Сохранить изменения'), _done])
    else
      DesignCase.skip(
        '$id-saved',
        reason: 'у своей роли в прототипе нет кнопки сохранения: внизу «Назначить сотруднику», уведомление недостижимо',
      ),
    DesignCase('$id-menu', route: route, role: KvRole.sec, setup: _senior, steps: const [TapLabel('Ещё')]),
    if (!system)
      DesignCase('$id-delete', route: route, role: KvRole.sec, setup: _senior, steps: const [TapLabel('Ещё'), TapSeen('Удалить роль')]),
  ];
}

/// Записи системного журнала: id прототипа и текст строки.
const List<(String, String)> _alog = [
  ('e-alog-ins', 'Сохранён осмотр INS-2209 · Н-101'),
  ('e-alog-plate', 'Н-101 опознан по шильдику'),
  ('e-alog-vib', 'Шлюз вибродатчиков Н-101: задержка ответа 2,4 с'),
  ('e-alog-r08', 'Сработало R08 для Н-101, уведомлены 2 пользователя'),
  ('e-alog-mode', 'АМС-2 переведён в режим «На ремонте»'),
  ('e-alog-s05', 'S05 тревога: АМС-2 обмотка 112 °C'),
  ('e-alog-bk', 'Резервная копия 1,8 ГБ создана'),
  ('e-alog-bk0', 'Запуск резервного копирования по расписанию'),
  ('e-alog-rep', 'Суточный отчёт сформирован'),
];

/// Записи журнала безопасности: id прототипа, заголовок строки и номер совпадения.
const List<(String, String, int)> _slog = [
  ('e-slog-fail', '3 неудачных входа', 0),
  ('e-slog-z', 'Вход по биометрии', 0),
  ('e-slog-new', 'Создана учётная запись', 0),
  ('e-slog-s', 'Вход по биометрии', 1),
  ('e-slog-o', 'Вход по паролю', 0),
  ('e-slog-k', 'Вход по паролю', 1),
  ('e-slog-block', 'Блокировка входа', 0),
];

/// Резервные копии: дата и время строки.
const List<String> _backups = ['14.11.2026, 03:00', '13.11.2026, 03:00', '12.11.2026, 15:20'];

/// Модели распознавания: id прототипа и код модели.
const List<(String, String)> _models = [
  ('e-model-det', 'm-det'),
  ('e-model-gauge', 'm-gauge'),
  ('e-model-plate', 'm-plate'),
  ('e-model-next', 'm-det-next'),
];

/// Снимки раздела «Админ и Админ ИБ» (admins): по одному на каждый экран и наложение прототипа.
final List<DesignCase> adminsCases = <DesignCase>[
  const DesignCase('adm-system', route: '/admin/system', role: KvRole.admin),
  const DesignCase('e-adm-server', route: '/admin/e-adm-server', role: KvRole.admin),
  const DesignCase('e-adm-server-menu', route: '/admin/e-adm-server', role: KvRole.admin, steps: [TapLabel('Ещё')]),
  const DesignCase('e-adm-restart', route: '/admin/e-adm-server', role: KvRole.admin, steps: [TapSeen('Перезапустить службы')]),
  const DesignCase(
    'e-adm-restart-ok',
    route: '/admin/e-adm-server',
    role: KvRole.admin,
    steps: [TapSeen('Перезапустить службы'), TapSeen('Перезапустить'), _done],
  ),
  const DesignCase('e-adm-devices', route: '/admin/e-adm-devices', role: KvRole.admin),
  const DesignCase('e-adm-devices-menu', route: '/admin/e-adm-devices', role: KvRole.admin, steps: [TapLabel('Ещё')]),
  const DesignCase('adm-sources', route: '/admin/sources', role: KvRole.admin),
  for (final String s in ['vib', 'opc', 'plc']) ..._sourceCases(s),
  const DesignCase('e-src-add', route: '/admin/e-src-add', role: KvRole.admin),
  const DesignCase('e-src-add-ok', route: '/admin/e-src-add-ok', role: KvRole.admin),
  ..._tagCases('e-tags', 'n101', 'N-101', [
    'vib1x',
    'vib2x',
    'vibHf',
    'tBearing',
    'tWinding',
    'pressOut',
    'pressIn',
    'current',
    'unbalance',
    'flow',
  ]),
  ..._tagCases('e-tags-ams1', 'ams1', 'AMS-1', ['vib1x', 'vib2x', 'vibHf', 'tBearing', 'tWinding', 'pressOut', 'current']),
  ..._tagCases('e-tags-ams2', 'ams2', 'AMS-2', ['vib1x', 'vib2x', 'vibHf', 'tBearing', 'tWinding', 'pressOut', 'current']),
  const DesignCase('adm-models', route: '/admin/models', role: KvRole.admin),
  for (final (String id, String m) in _models) ...[
    DesignCase(id, route: '/admin/e-model/$m', role: KvRole.admin),
    DesignCase('$id-menu', route: '/admin/e-model/$m', role: KvRole.admin, steps: const [TapLabel('Ещё')]),
  ],
  const DesignCase('e-model-next-act', route: '/admin/e-model/m-det-next', role: KvRole.admin, steps: [TapSeen('Активировать версию 3.3')]),
  const DesignCase(
    'e-model-next-on',
    route: '/admin/e-model/m-det-next',
    role: KvRole.admin,
    steps: [TapSeen('Активировать версию 3.3'), TapSeen('Активировать'), _done],
  ),
  const DesignCase('adm-log', route: '/admin/log', role: KvRole.admin),
  for (final (String id, String text) in _alog) DesignCase(id, route: '/admin/log', role: KvRole.admin, steps: [TapSeen(text, typo: true)]),
  const DesignCase('e-adm-maint', route: '/admin/e-adm-maint', role: KvRole.admin),
  const DesignCase('e-adm-maint-menu', route: '/admin/e-adm-maint', role: KvRole.admin, steps: [TapLabel('Ещё')]),
  for (int i = 0; i < _backups.length; i++) ...[
    DesignCase('e-backup-$i', route: '/admin/e-adm-maint', role: KvRole.admin, steps: [TapSeen(_backups[i])]),
    DesignCase(
      'e-backup-$i-restore',
      route: '/admin/e-adm-maint',
      role: KvRole.admin,
      steps: [TapSeen(_backups[i]), const TapSeen('Восстановить из копии')],
    ),
    DesignCase(
      'e-backup-$i-plan',
      route: '/admin/e-adm-maint',
      role: KvRole.admin,
      steps: [TapSeen(_backups[i]), const TapSeen('Восстановить из копии'), const TapSeen('Запланировать'), _done],
    ),
  ],
  const DesignCase('e-update-confirm', route: '/admin/e-adm-maint', role: KvRole.admin, steps: [TapSeen('Установить 1.5.0')]),
  const DesignCase('e-update-run', route: '/admin/e-update-run', role: KvRole.admin),
  const DesignCase('e-update-menu', route: '/admin/e-update-run', role: KvRole.admin, steps: [TapLabel('Ещё')]),
  const DesignCase('adm-profile', route: '/admin/profile', role: KvRole.admin),
  const DesignCase('e-adm-logout', route: '/admin/profile', role: KvRole.admin, steps: [TapSeen('Выйти из учётной записи')]),
  const DesignCase('e-adm-scope', route: '/admin/e-adm-scope', role: KvRole.admin),
  const DesignCase('sec-users', route: '/sec/users', role: KvRole.sec, setup: _senior),
  const DesignCase(
    'e-users-filter',
    route: '/sec/users',
    role: KvRole.sec,
    setup: _senior,
    steps: [TapLabel('Фильтр'), TapSeen('Инженер')],
  ),
  const DesignCase('e-user-search', route: '/sec/e-user-search', role: KvRole.sec, setup: _senior, steps: [EnterText('user-search', 'ер')]),
  for (final _UserVariant v in _users) ..._userCases(v),
  const DesignCase(
    'e-user-new',
    route: '/sec/e-user-new',
    role: KvRole.sec,
    setup: _senior,
    steps: [EnterText('user-name', 'Павел Ершов'), EnterText('user-email', 'p.ershov@kst-energo.ru')],
  ),
  const DesignCase('e-user-new-role', route: '/sec/e-user-new', role: KvRole.sec, setup: _senior, steps: [TapSeen('Инженер')]),
  const DesignCase('e-user-new-done', route: '/sec/e-user-new-done?user=u-110', role: KvRole.sec, setup: _senior),
  const DesignCase('sec-roles', route: '/sec/roles', role: KvRole.sec, setup: _senior),
  ..._roleCases('e-role-engineer', 'engineer'),
  ..._roleCases('e-role-master', 'master'),
  ..._roleCases('e-role-operator', 'operator'),
  ..._roleCases('e-role-admin', 'admin'),
  ..._roleCases('e-role-sec', 'security_admin'),
  ..._roleCases('e-role-senior', 'senior'),
  ..._roleCases('e-role-senior-new', 'senior', fresh: true),
  const DesignCase('e-role-new', route: '/sec/e-role-new', role: KvRole.sec),
  const DesignCase('e-role-new-copy', route: '/sec/e-role-new', role: KvRole.sec, steps: [TapSeen('Скопировать из «Инженер»')]),
  const DesignCase('sec-log', route: '/sec/log', role: KvRole.sec, setup: _senior),
  for (final (String id, String title, int index) in _slog)
    DesignCase(
      id,
      route: '/sec/log',
      role: KvRole.sec,
      setup: _senior,
      steps: [TapSeen(title, index: index)],
    ),
  const DesignCase('e-slog-export', route: '/sec/log', role: KvRole.sec, setup: _senior, steps: [TapSeen('Выгрузить журнал')]),
  const DesignCase('sec-policy', route: '/sec/policy', role: KvRole.sec, setup: _senior),
  const DesignCase('e-policy-pwd', route: '/sec/e-policy-pwd', role: KvRole.sec, setup: _senior),
  const DesignCase('e-policy-lock', route: '/sec/policy', role: KvRole.sec, setup: _senior, steps: [TapSeen('Блокировка входа')]),
  const DesignCase('e-policy-session', route: '/sec/policy', role: KvRole.sec, setup: _senior, steps: [TapSeen('Сеанс')]),
  const DesignCase(
    'e-policy-saved',
    route: '/sec/policy',
    role: KvRole.sec,
    setup: _senior,
    steps: [TapSeen('Блокировка входа'), TapSeen('Сохранить'), _done],
  ),
  const DesignCase('sec-profile', route: '/sec/profile', role: KvRole.sec, setup: _senior),
  const DesignCase('e-sec-logout', route: '/sec/profile', role: KvRole.sec, setup: _senior, steps: [TapSeen('Выйти из учётной записи')]),
  const DesignCase('e-sec-scope', route: '/sec/e-sec-scope', role: KvRole.sec, setup: _senior),
  const DesignCase('e-sec-sessions', route: '/sec/e-sec-sessions', role: KvRole.sec, setup: _senior),
  for (final (int i, String slug) in const [(0, 'smirnov'), (1, 'orlova'), (2, 'belov'), (3, 'kuznetsova')])
    DesignCase(
      'e-sess-$slug',
      route: '/sec/e-sec-sessions',
      role: KvRole.sec,
      setup: _senior,
      steps: [TapSeen('Завершить', index: i)],
    ),
  const DesignCase(
    'e-sess-all',
    route: '/sec/e-sec-sessions',
    role: KvRole.sec,
    setup: _senior,
    steps: [TapSeen('Завершить все, кроме моего')],
  ),
  const DesignCase(
    'e-sess-done',
    route: '/sec/e-sec-sessions',
    role: KvRole.sec,
    setup: _senior,
    steps: [TapSeen('Завершить'), TapSeen('Завершить', index: 4), _done],
  ),
];
