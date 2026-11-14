import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/navigation/kv_page.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_common.dart';

/// Переключатель «Агрегаты / Календарь» плана ТО: смена пункта - переход seg, шапка и панель стоят.
class _PlanTabs extends StatelessWidget {
  const _PlanTabs({required this.index, this.from});

  final int index;
  final int? from;

  @override
  Widget build(BuildContext context) {
    return KvSegment(
      items: const ['Агрегаты', 'Календарь'],
      index: index,
      animateFrom: from,
      onBackground: true,
      onChanged: (int i) => context.kvSeg(i == 0 ? MasterOperatorPaths.masterPlan : MasterOperatorPaths.dMPlanCal, fromSegment: index),
    );
  }
}

/// Тон срока работы по остатку часов: просрочено, скоро (до 48 ч), в норме.
KvStatus _toneOf(double left) => left <= 0 ? KvStatus.bad : (left <= 48 ? KvStatus.warn : KvStatus.ok);

/// План ТО по наработке: ближайшая работа и карточки агрегатов со сроками ТО, ресурсом и ремонтом.
class MasterPlanScreen extends ConsumerWidget {
  /// Создаёт экран.
  const MasterPlanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int? from = KvNavExtra.of(GoRouterState.of(context))?.fromSegment;
    final DateTime now = ref.watch(clockProvider).now();
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final List<PlanItem> plan = ref.watch(planProvider).value ?? const <PlanItem>[];
    final Equipment? n101 = units.where((Equipment u) => u.id == 'N-101').firstOrNull;
    final PlanItem? to2 = plan.where((PlanItem p) => p.id == 'P-502').firstOrNull;
    return KvScreen(
      header: KvRootHeader(title: 'План ТО', subtitle: 'По наработке · ${KvFormat.dayMonth(now)}, ${KvFormat.time(now)}'),
      stagger: from != null ? KvStagger.seg : KvStagger.appear,
      staggerSkip: from != null ? 1 : 0,
      children: [
        _PlanTabs(index: 0, from: from),
        if (n101 != null)
          KvCard(
            onTap: () => context.kvPush(MasterOperatorPaths.planItem('P-502')),
            child: MoNext(
              value: KvFormat.num(n101.nextTo.inHours),
              unit: 'ч',
              title: KvFormat.typo('${n101.nextTo.code} ${n101.code} с объёмом ТО-1'),
              text: KvFormat.typo(
                'при ${KvFormat.num(n101.nextTo.atHours)} ч · прогноз ${moDay(to2?.date ?? n101.nextTo.date)}, ${to2?.time ?? '10:00'} · ${moShortName(to2?.who ?? 'Елена Титова')}',
              ),
              progress: n101.runHours / n101.nextTo.atHours,
              progressStatus: KvStatus.warn,
            ),
          ),
        for (final Equipment u in units) _UnitPlanCard(unit: u),
      ],
    );
  }
}

class _UnitPlanCard extends StatelessWidget {
  const _UnitPlanCard({required this.unit});

  final Equipment unit;

  @override
  Widget build(BuildContext context) {
    final Equipment u = unit;
    final List<Widget> rows = [];
    if (u.inRepair) {
      final MaintenanceItem? m = u.maintenance.firstOrNull;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: MoRepairNote(
            icon: KvIcons.wrench,
            title: '${m?.code ?? 'Ремонт'} · 15.11, 08:00',
            text: 'Агрегат остановлен, наработка не начисляется',
          ),
        ),
      );
      rows.add(
        MoMtRow(
          name: 'ТО по наработке',
          every: 'каждые ${KvFormat.num(11000)} ч',
          left: 11000 - u.runHours,
          fraction: u.runHours / 11000,
          tone: KvStatus.unk,
          last: true,
        ),
      );
    } else if (u.id == 'N-101') {
      for (final MaintenanceItem m in u.maintenance) {
        final double left = (m.nextAt ?? 0) - u.runHours;
        rows.add(
          MoMtRow(
            name: m.code,
            every: 'каждые ${KvFormat.num(m.interval)} ч',
            left: left,
            fraction: (u.runHours - (m.lastAt ?? 0)) / (m.interval ?? 1),
            tone: _toneOf(left),
            first: rows.isEmpty,
          ),
        );
      }
      rows.add(
        MoMtRow(
          name: 'Подшипники',
          every: 'ресурс ${KvFormat.num(u.resource.total)} ч',
          left: u.resource.left,
          fraction: u.resource.fraction,
          tone: KvStatus.ok,
          first: rows.isEmpty,
          last: true,
        ),
      );
    } else {
      final MaintenanceItem? m = u.maintenance.firstOrNull;
      final double interval = m?.interval ?? u.resource.total;
      rows.add(
        MoMtRow(
          name: m?.code ?? 'ТО по наработке',
          every: 'каждые ${KvFormat.num(interval)} ч',
          left: interval - u.runHours,
          fraction: u.runHours / interval,
          tone: _toneOf(interval - u.runHours),
          first: true,
          last: true,
        ),
      );
    }
    return KvCard(
      title: u.code,
      trailing: Text(
        KvFormat.typo('${KvFormat.num(u.runHours)} ч наработки'),
        style: context.kvText.caption.copyWith(height: KvTextStyles.normalHeight(13)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

/// План ТО · календарь: месяц с днями работ и хронология работ плана со статусами.
class MasterPlanCalScreen extends ConsumerWidget {
  /// Создаёт экран.
  const MasterPlanCalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvTextStyles t = context.kvText;
    final int? from = KvNavExtra.of(GoRouterState.of(context))?.fromSegment;
    final DateTime now = ref.watch(clockProvider).now();
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final List<PlanItem> plan = ref.watch(planProvider).value ?? const <PlanItem>[];
    String code(String id) => units.where((Equipment u) => u.id == id).firstOrNull?.code ?? id;
    KvStatus tone(PlanItem p) => p.status == 'overdue' || p.unitId == 'AMS-2'
        ? KvStatus.bad
        : p.status == 'planned'
        ? KvStatus.warn
        : KvStatus.info;
    final int overdue = plan.where((PlanItem p) => p.status == 'overdue').length;
    final List<PlanItem> ordered = [...plan]..sort((PlanItem a, PlanItem b) => _key(a).compareTo(_key(b)));
    final Map<int, List<PlanItem>> byDay = {};
    for (final PlanItem p in plan) {
      final List<String> d = p.date.split('.');
      if (d.length == 3 && d[1] == '11' && d[2] == '2026') {
        byDay.putIfAbsent(int.parse(d[0]), () => <PlanItem>[]).add(p);
      }
    }
    return KvScreen(
      header: const KvRootHeader(title: 'План ТО', subtitle: 'Ноябрь - декабрь 2026'),
      stagger: from != null ? KvStagger.seg : KvStagger.appear,
      staggerSkip: from != null ? 1 : 0,
      children: [
        _PlanTabs(index: 1, from: from),
        KvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Ноябрь 2026', style: t.h2)),
                  if (overdue > 0) KvStatusDot('просрочено $overdue', status: KvStatus.bad),
                ],
              ),
              const SizedBox(height: KvSpace.s3),
              _Calendar(today: now.month == 11 && now.year == 2026 ? now.day : 0, byDay: byDay, tone: tone),
            ],
          ),
        ),
        KvCard(
          child: KvTimeline(
            items: [
              for (final PlanItem p in ordered)
                KvTimelineItem(
                  time: KvFormat.typo(
                    '${moDay(p.date)}, ${p.time}${p.status == 'overdue'
                        ? ' · просрочено ${now.day - int.parse(p.date.substring(0, 2))} дн'
                        : p.status == 'draft'
                        ? ' · черновик'
                        : ''}',
                  ),
                  title: KvFormat.typo('${code(p.unitId)} · ${p.work}'),
                  text: p.who == 'не назначен' ? 'Исполнитель не назначен' : p.who,
                  status: tone(p),
                  onTap: () => context.kvPush(MasterOperatorPaths.planItem(p.id)),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static String _key(PlanItem p) {
    final List<String> d = p.date.split('.');
    return d.length == 3 ? '${d[2]}${d[1]}${d[0]}${p.time}' : p.date;
  }
}

class _Calendar extends StatelessWidget {
  const _Calendar({required this.today, required this.byDay, required this.tone});

  final int today;
  final Map<int, List<PlanItem>> byDay;
  final KvStatus Function(PlanItem) tone;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final int offset = DateTime(2026, 11).weekday - 1;
    const List<String> heads = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
    final List<Widget> cells = [
      for (final String h in heads)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            h,
            textAlign: TextAlign.center,
            style: t.micro.copyWith(fontWeight: FontWeight.w400, height: KvTextStyles.normalHeight(11)),
          ),
        ),
      for (int i = 0; i < offset; i++) const SizedBox(height: 38),
      for (int d = 1; d <= 30; d++) _day(context, c, t, d),
    ];
    final List<Widget> rows = [];
    for (int i = 0; i < cells.length; i += 7) {
      final List<Widget> week = cells.sublist(i, i + 7 > cells.length ? cells.length : i + 7);
      rows.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 2),
          child: Row(children: [for (int k = 0; k < 7; k++) Expanded(child: k < week.length ? week[k] : const SizedBox.shrink())]),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: rows);
  }

  Widget _day(BuildContext context, KvColors c, KvTextStyles t, int d) {
    final List<PlanItem> items = byDay[d] ?? const <PlanItem>[];
    final bool over = items.any((PlanItem p) => p.status == 'overdue');
    final bool isToday = d == today;
    final (Color? bg, Color fg, bool bold) = isToday
        ? (c.btnPrimary, c.onBrand, true)
        : over
        ? (c.badBg, c.bad, true)
        : items.isNotEmpty
        ? (c.tint, c.brand, true)
        : (null, d < today ? c.text3 : c.text, false);
    return SizedBox(
      height: 38,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: bg == null ? null : BoxDecoration(color: bg, shape: BoxShape.circle),
            child: Text(
              '$d',
              style: t.sm.copyWith(color: fg, fontWeight: bold ? FontWeight.w600 : FontWeight.w400, height: KvTextStyles.normalHeight(14)),
            ),
          ),
          if (items.isNotEmpty && !isToday)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int i = 0; i < items.length; i++) ...[if (i > 0) const SizedBox(width: 3), KvDot(status: tone(items[i]), size: 5)],
                ],
              ),
            ),
        ],
      ),
    );
  }
}
