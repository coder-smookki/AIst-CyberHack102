import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_page.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_sheet_swap.dart';

/// Срок осмотра в листе назначения: подпись чипа и срок для задания.
typedef MoDue = ({String chip, String due});

/// Исходные значения листа «Назначить осмотр» (registerAssign прототипа): агрегат, причина, кто и когда.
@immutable
class MoAssignPreset {
  /// Создаёт заготовку.
  const MoAssignPreset({
    required this.unitId,
    required this.unitCode,
    required this.summary,
    required this.reason,
    required this.dues,
    this.sheetTitle = 'Назначить осмотр',
    this.icon = KvIcons.alert,
    this.iconStatus = KvStatus.bad,
    this.who = 0,
    this.subA = 'Свободен · рядом, узел откачки',
    this.subB = 'Свободна · задание в 14:00',
    this.priority = 1,
    this.dueOn = 0,
    this.faultReportId,
    this.doneTitle = 'Осмотр назначен',
    this.showPriority = true,
    this.toShift = false,
  });

  /// Агрегат.
  final String unitId;

  /// Обозначение агрегата.
  final String unitCode;

  /// Первая строка сводки: «АМС-2 · по сообщению S-077».
  final String summary;

  /// Причина осмотра.
  final String reason;

  /// Варианты срока.
  final List<MoDue> dues;

  /// Заголовок листа.
  final String sheetTitle;

  /// Значок сводки.
  final KvIcons icon;

  /// Тон значка сводки.
  final KvStatus? iconStatus;

  /// Инженер по умолчанию: 0 - Алексей Смирнов, 1 - Елена Титова.
  final int who;

  /// Подпись Алексея Смирнова.
  final String subA;

  /// Подпись Елены Титовой.
  final String subB;

  /// Приоритет по умолчанию: 0 - плановый, 1 - срочно, 2 - авария.
  final int priority;

  /// Срок по умолчанию.
  final int dueOn;

  /// Сообщение оператора, по которому назначается осмотр.
  final String? faultReportId;

  /// Заголовок результата.
  final String doneTitle;

  /// Показать приоритет в итоге.
  final bool showPriority;

  /// Кнопка итога «К смене» вместо «Готово».
  final bool toShift;

  /// Осмотр по сообщению оператора S-077 (06:51, сценарий А).
  static const MoAssignPreset report = MoAssignPreset(
    unitId: 'AMS-2',
    unitCode: 'АМС-2',
    summary: 'АМС-2 · по сообщению S-077',
    reason: 'Течь под агрегатом, повышенный шум',
    who: 0,
    priority: 2,
    dues: [(chip: 'Через 15 мин', due: '14.11, до 07:06'), (chip: 'До 07:00', due: '14.11, до 07:00'), (chip: 'До конца смены', due: '14.11, до 08:00')],
    dueOn: 1,
    faultReportId: 'S-077',
    toShift: true,
  );

  /// Контроль Н-101 после ТО-2.
  static const MoAssignPreset n101 = MoAssignPreset(
    unitId: 'N-101',
    unitCode: 'Н-101',
    summary: 'Н-101 · контроль после ТО-2 15.11',
    reason: 'Вибрация 1X 3,1 мм/с, подшипник 78 °C',
    icon: KvIcons.activity,
    iconStatus: KvStatus.warn,
    who: 1,
    priority: 0,
    dues: [(chip: '15.11, 14:00', due: '15.11, 14:00'), (chip: '16.11, 10:00', due: '16.11, 10:00'), (chip: 'До конца недели', due: '15.11, до 20:00')],
  );

  /// Срочный осмотр Н-101 по правилу R08 (09:12, сценарий Б).
  static const MoAssignPreset r08 = MoAssignPreset(
    unitId: 'N-101',
    unitCode: 'Н-101',
    sheetTitle: 'Н-101 · по правилу R08',
    summary: 'Н-101 · сработало R08 в 08:12',
    reason: 'Вибрация 1X 3,1 мм/с, подшипник 78 °C',
    icon: KvIcons.activity,
    iconStatus: KvStatus.warn,
    who: 0,
    priority: 1,
    subA: 'Свободен · зал 2, рядом с Н-101',
    dues: [(chip: 'Сегодня до 10:00', due: '14.11, до 10:00'), (chip: 'До 12:00', due: '14.11, до 12:00'), (chip: 'До конца смены', due: '14.11, до 20:00')],
  );

  /// Внеплановый обход АМС-1 из команды смены.
  static const MoAssignPreset team = MoAssignPreset(
    unitId: 'AMS-1',
    unitCode: 'АМС-1',
    sheetTitle: 'Задание инженеру',
    summary: 'АМС-1 · внеплановый обход',
    reason: 'Проверить уплотнение по аналогии с АМС-2',
    icon: KvIcons.clipboard,
    who: 1,
    priority: 0,
    dues: [(chip: 'До 12:00', due: '14.11, до 12:00'), (chip: 'До 14:00', due: '14.11, до 14:00'), (chip: 'До конца смены', due: '14.11, до 20:00')],
    doneTitle: 'Задание отправлено',
    showPriority: false,
  );
}

/// Открывает лист назначения осмотра по заготовке [preset]; «Назначить» создаёт задание на сервере
/// и показывает итог в том же листе.
Future<void> showMoAssignSheet(BuildContext context, MoAssignPreset preset) {
  final BuildContext screen = context;
  return showKvSheet<void>(context, builder: (BuildContext sheet) => _AssignSheet(preset: preset, screen: screen));
}

class _AssignSheet extends ConsumerStatefulWidget {
  const _AssignSheet({required this.preset, required this.screen});

  final MoAssignPreset preset;
  final BuildContext screen;

  @override
  ConsumerState<_AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends ConsumerState<_AssignSheet> {
  static const List<String> _engineers = ['Алексей Смирнов', 'Елена Титова'];
  static const List<String> _priorities = ['Плановый', 'Срочно', 'Авария'];
  static const List<String> _priorityCodes = ['normal', 'high', 'urgent'];

  late int _who = widget.preset.who;
  late int _priority = widget.preset.priority;
  late int _due = widget.preset.dueOn;
  InspectionTask? _task;

  Future<void> _assign() async {
    final MoAssignPreset p = widget.preset;
    final InspectionTask task = await ref.read(workflowRepositoryProvider).assignInspection(
          unitId: p.unitId,
          assignee: _engineers[_who],
          reason: p.reason,
          due: p.dues[_due].due,
          priority: _priorityCodes[_priority],
          faultReportId: p.faultReportId,
        );
    if (mounted) {
      setState(() => _task = task);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MoSheetSwap(child: _task == null ? _form(context) : _done(context, _task!));
  }

  Widget _form(BuildContext context) {
    final MoAssignPreset p = widget.preset;
    return KvSheet(
      key: const ValueKey<String>('form'),
      title: p.sheetTitle,
      children: [
        KvRow(icon: p.icon, iconStatus: p.iconStatus, title: KvFormat.typo(p.summary), subtitle: KvFormat.typo(p.reason), chevron: false),
        const MoLabel('Инженер'),
        KvList(
          children: [
            MoRadioRow(avatar: _engineers[0], title: _engineers[0], subtitle: p.subA, on: _who == 0, onTap: () => setState(() => _who = 0)),
            MoRadioRow(avatar: _engineers[1], title: _engineers[1], subtitle: p.subB, on: _who == 1, onTap: () => setState(() => _who = 1)),
          ],
        ),
        const MoLabel('Приоритет'),
        KvSegment(items: _priorities, index: _priority, onChanged: (int i) => setState(() => _priority = i)),
        const MoLabel('Срок'),
        KvFilterChips(
          items: [for (final MoDue d in p.dues) KvFilterItem(KvFormat.typo(d.chip))],
          selected: _due,
          onSelected: (int i) => setState(() => _due = i),
        ),
      ],
      actions: [KvButton('Назначить', icon: KvIcons.send, wait: true, onPressed: _assign)],
    );
  }

  Widget _done(BuildContext context, InspectionTask task) {
    final MoAssignPreset p = widget.preset;
    final String name = _engineers[_who];
    final bool she = name.split(' ').first.endsWith('а');
    final String text = '$name ${she ? 'получила' : 'получил'} задание ${task.id} на телефон.${p.faultReportId != null ? ' Оператор видит, что сообщение принято.' : ''}';
    return MoDoneSheet(
      key: const ValueKey<String>('done'),
      title: p.doneTitle,
      text: text,
      pairs: [
        ('Агрегат', p.unitCode),
        ('Срок', p.dues[_due].due),
        if (p.showPriority) ('Приоритет', _priorities[_priority]),
      ],
      actions: [
        KvButton(
          p.toShift ? 'К смене' : 'Готово',
          onPressed: () {
            Navigator.of(context).pop();
            if (p.toShift && widget.screen.mounted) {
              widget.screen.go(MasterOperatorPaths.masterShift, extra: const KvNavExtra(transition: KvTransition.fade));
            }
          },
        ),
      ],
    );
  }
}
