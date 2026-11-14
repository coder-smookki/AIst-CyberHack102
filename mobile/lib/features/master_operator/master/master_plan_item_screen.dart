import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_common.dart';
import '../widgets/mo_sheet_swap.dart';

/// Короткие названия работ плана для заголовка экрана.
const Map<String, String> _short = {'P-499': 'Поверка', 'P-501': 'Ремонт', 'P-502': 'ТО-2', 'P-503': 'Подшипники', 'P-504': 'ТО', 'P-505': 'Ревизия'};

/// Работа плана ТО: остаток наработки или просрочка, пояснение о сроках, состав и исполнитель, объём работ
/// и действие по статусу: перенос ТО-2, назначение просроченной поверки, утверждение черновика.
class MasterPlanItemScreen extends ConsumerWidget {
  /// Создаёт экран работы [itemId].
  const MasterPlanItemScreen({super.key, required this.itemId});

  /// Номер работы: «P-502».
  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<PlanItem> plan = ref.watch(planProvider).value ?? const <PlanItem>[];
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final PlanItem? p = plan.where((PlanItem x) => x.id == itemId).firstOrNull;
    final String back = itemId == 'P-502' ? MasterOperatorPaths.masterPlan : MasterOperatorPaths.dMPlanCal;
    final Equipment? u = p == null ? null : units.where((Equipment x) => x.id == p.unitId).firstOrNull;
    if (p == null || u == null) {
      return KvScreen(
        header: KvHeader(title: ' ', onBack: () => context.kvBack(back)),
        children: const [KvSkeleton.card(height: 90), KvSkeleton.card(height: 180)],
      );
    }
    final DateTime now = ref.watch(clockProvider).now();
    final bool over = p.status == 'overdue';
    final int lateDays = over ? now.day - int.parse(p.date.substring(0, 2)) : 0;
    final (String, KvStatus) st = over
        ? ('Просрочено на $lateDays дн', KvStatus.bad)
        : p.status == 'planned'
            ? ('Запланировано · ${moDay(p.date)}, ${p.time}', KvStatus.info)
            : ('Черновик · ${moDay(p.date)}', KvStatus.unk);
    final String work = switch (p.id) {
      'P-502' => '${u.maintenance.length > 1 ? u.maintenance[1].work : p.work}; замена торцевого уплотнения по F-1043',
      'P-505' => u.maintenance.length > 2 ? u.maintenance[2].work : p.work,
      'P-501' => u.maintenance.firstOrNull?.work ?? p.work,
      _ => p.work,
    };
    Widget? foot;
    if (p.id == 'P-502') {
      foot = KvButton('Перенести срок', kind: KvButtonKind.secondary, icon: KvIcons.calendar, onPressed: () => _move(context, p, u));
    } else if (over) {
      foot = KvButton(
        'Назначить на сегодня',
        icon: KvIcons.clipboard,
        wait: true,
        onPressed: () async {
          final WorkflowRepository repo = ref.read(workflowRepositoryProvider);
          await repo.movePlanItem(p.id, date: KvFormat.date(now), time: '15:00');
          await repo.assignPlanItem(p.id, 'Елена Титова');
          if (context.mounted) {
            showKvToast(context, kind: KvToastKind.ok, title: 'Поверка назначена', text: KvFormat.typo('Елена Титова · ${KvFormat.dayMonth(now)}, 15:00'));
          }
        },
      );
    } else if (p.status == 'draft') {
      foot = KvButton(
        'Утвердить в плане',
        icon: KvIcons.check,
        wait: true,
        onPressed: () async {
          await ref.read(workflowRepositoryProvider).assignPlanItem(p.id, p.who);
          if (context.mounted) {
            showKvToast(context, kind: KvToastKind.ok, title: 'Работа утверждена', text: KvFormat.typo('${u.code} · ${moDay(p.date)}, ${p.time}'));
          }
        },
      );
    }
    return KvScreen(
      header: KvHeader(
        title: KvFormat.typo('${_short[p.id] ?? p.work.split(' ').first} · ${u.code}'),
        subtitle: KvFormat.typo(st.$1),
        status: st.$2,
        onBack: () => context.kvBack(back),
      ),
      foot: foot,
      children: [
        KvCard(child: _hours(p, u, lateDays)),
        if (over)
          KvNote(tone: KvStatus.bad, icon: KvIcons.alert, text: KvFormat.typo('Срок поверки прошёл. До поверки сверяйте манометр с датчиком давления: сейчас 4,6 и 4,6 бар.'))
        else
          KvNote(
            icon: KvIcons.timer,
            text: KvFormat.typo('Сроки считаются по наработке: пока агрегат остановлен, часы не начисляются. Дата - прогноз по средней наработке 23 ч/сут.'),
          ),
        KvCard(
          child: KvKeyValues([
            ('Работа', KvFormat.typo(p.work)),
            ('Агрегат', KvFormat.typo('${u.code} · ${u.modelShort}')),
            ('Основание', KvFormat.typo(p.basis)),
            ('Исполнитель', p.who),
          ]),
        ),
        KvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Объём работ', style: context.kvText.h2),
              const SizedBox(height: KvSpace.s2),
              Text(KvFormat.typo(work), style: context.kvText.sm.copyWith(color: context.kv.text2)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hours(PlanItem p, Equipment u, int lateDays) {
    return switch (p.id) {
      'P-502' => MoNext(
          value: KvFormat.num(u.nextTo.inHours),
          unit: 'ч',
          title: KvFormat.typo('до ${u.nextTo.code} по наработке'),
          text: KvFormat.typo('${KvFormat.num(u.runHours)} из ${KvFormat.num(u.nextTo.atHours)} ч · интервал 8 000 ч'),
          progress: u.runHours / u.nextTo.atHours,
          progressStatus: KvStatus.warn,
        ),
      'P-503' => MoNext(
          value: KvFormat.num(u.resource.left),
          unit: 'ч',
          tone: KvStatus.info,
          title: 'ресурс подшипников',
          text: KvFormat.typo('${KvFormat.num(u.resource.used)} из ${KvFormat.num(u.resource.total)} ч наработки'),
          progress: 0.96,
          progressStatus: KvStatus.warn,
        ),
      'P-504' => MoNext(
          value: KvFormat.num(u.resource.left),
          unit: 'ч',
          tone: KvStatus.info,
          title: 'до ТО агрегата',
          text: KvFormat.typo('${KvFormat.num(u.resource.used)} из ${KvFormat.num(u.resource.total)} ч наработки'),
          progress: 0.89,
        ),
      'P-505' => MoNext(
          value: KvFormat.num(u.maintenance.length > 2 ? u.maintenance[2].inHours : 0),
          unit: 'ч',
          tone: KvStatus.info,
          title: 'до ревизии',
          text: KvFormat.typo('при 22 000 ч наработки'),
          progress: 0.82,
        ),
      'P-501' => MoNext(value: '0', unit: 'ч', tone: KvStatus.unk, title: 'наработка остановлена', text: KvFormat.typo('${u.code} на ремонте с 06:44')),
      _ when p.status == 'overdue' => MoNext(
          value: '$lateDays',
          unit: 'дн',
          tone: KvStatus.bad,
          title: 'просрочено',
          text: 'срок поверки ${p.date}',
          progress: 1,
          progressStatus: KvStatus.bad,
        ),
      _ => MoNext(value: moDay(p.date), unit: '', tone: KvStatus.info, title: 'по плану', text: KvFormat.typo('${p.time} · ${p.who}')),
    };
  }

  Future<void> _move(BuildContext context, PlanItem p, Equipment u) => showKvSheet<void>(context, builder: (BuildContext sheet) => _MoveSheet(item: p, unit: u));
}

/// Лист переноса ТО-2: новая дата, превышение интервала по наработке и причина; итог - в том же листе.
class _MoveSheet extends ConsumerStatefulWidget {
  const _MoveSheet({required this.item, required this.unit});

  final PlanItem item;
  final Equipment unit;

  @override
  ConsumerState<_MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends ConsumerState<_MoveSheet> {
  static const List<(String, String, String, int)> _dates = [
    ('15.11, 10:00', '15.11.2026', '10:00', 0),
    ('15.11, 14:00', '15.11.2026', '14:00', 4),
    ('16.11, 08:00', '16.11.2026', '08:00', 22),
  ];
  int _on = 1;
  bool _done = false;
  final TextEditingController _reason = TextEditingController(text: 'Совместить с заменой уплотнения по F-1043');

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    await ref.read(workflowRepositoryProvider).movePlanItem(widget.item.id, date: _dates[_on].$2, time: _dates[_on].$3);
    if (mounted) {
      setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Equipment u = widget.unit;
    final String title = '${u.nextTo.code} ${u.code}';
    final int over = _dates[_on].$4;
    final String who = widget.item.who;
    final bool she = who.split(' ').first.endsWith('а');
    return MoSheetSwap(
      child: _done
          ? MoDoneSheet(
              key: const ValueKey<String>('done'),
              icon: KvIcons.calendar,
              tone: KvStatus.info,
              title: 'Срок перенесён',
              text: KvFormat.typo('$who ${she ? 'получила' : 'получил'} новое время ${u.nextTo.code}.'),
              pairs: [(title, _dates[_on].$1), ('Превышение', over == 0 ? 'нет' : '≈ $over ч наработки')],
              actions: [KvButton('Готово', onPressed: () => Navigator.of(context).pop())],
            )
          : KvSheet(
              key: const ValueKey<String>('form'),
              title: KvFormat.typo('Перенести $title'),
              children: [
                const MoLabel('Новая дата'),
                KvFilterChips(items: [for (final (String, String, String, int) d in _dates) KvFilterItem(d.$1)], selected: _on, onSelected: (int i) => setState(() => _on = i)),
                KvNote(
                  tone: KvStatus.warn,
                  icon: KvIcons.timer,
                  text: KvFormat.typo(over == 0
                      ? '${u.nextTo.code} привязано к ${KvFormat.num(u.nextTo.atHours)} ч. В срок ${_dates[_on].$1} интервал не будет превышен.'
                      : '${u.nextTo.code} привязано к ${KvFormat.num(u.nextTo.atHours)} ч. При переносе на ${_dates[_on].$1} интервал будет превышен примерно на $over ч наработки.'),
                ),
                KvField(label: 'Причина', controller: _reason, area: true, fieldKey: const ValueKey<String>('mo-move-reason')),
              ],
              actions: [KvButton('Перенести', wait: true, onPressed: _apply)],
            ),
    );
  }
}
