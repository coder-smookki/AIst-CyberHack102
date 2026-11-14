import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../app/routes/engineer_service_routes.dart';
import '../../app/routes/entry_routes.dart';
import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import '../shared/bridges.dart';
import 'widgets/inspect_blocks.dart';

/// Объекты (домашний экран инженера, эталон раздела): поиск, счётчики состояния, задание мастера и карточки агрегатов.
class ObjectsScreen extends ConsumerWidget {
  /// Создаёт экран.
  const ObjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Site? site = ref.watch(siteProvider).value;
    final AsyncValue<List<Equipment>> units = ref.watch(unitsProvider);
    final AppUser? me = ref.watch(sessionProvider.select((AuthSession? s) => s?.user));
    final AsyncValue<List<InspectionTask>> taskValue = ref.watch(tasksProvider(me?.name));
    final List<InspectionTask> tasks = taskValue.value ?? const <InspectionTask>[];
    final List<Inspection>? inspections = ref.watch(inspectionsProvider(null)).value;
    final List<PlanItem> plan = ref.watch(planProvider).value ?? const <PlanItem>[];
    final InspectionTask? task = tasks.where((InspectionTask t) => t.status != 'done' && t.status != 'cancelled').firstOrNull;
    final List<Equipment> list = units.value ?? const <Equipment>[];
    final bool firstDay = taskValue.hasValue && tasks.isEmpty && inspections != null && !inspections.any((Inspection i) => i.who == me?.name);
    final String who = firstDay && me != null ? me.short : (site?.shiftShort ?? '');

    return KvScreen(
      header: KvRootHeader(title: 'Объекты', subtitle: site == null ? ' ' : KvFormat.typo('${site.name} · $who')),
      children: [
        KvSearchPill('Номер, модель, серийный номер', onTap: () => context.kvPush(EngineerInspectPaths.search)),
        if (units.hasValue) _Counters(units: list) else const KvSkeleton(height: 100, radius: KvRadius.card),
        if (task != null)
          _TaskBanner(
            task: task,
            unit: list.where((Equipment u) => u.id == task.unitId).firstOrNull,
            onTap: () => context.kvPush(task.unitId == 'AMS-2' ? EngineerServicePaths.cTaskAms2 : EngineerServicePaths.cTask),
          )
        else if (firstDay) ...[
          const KvNote(
            icon: KvIcons.clipboard,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'Заданий пока нет', style: TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: '\nМастер назначит осмотр в приложении, уведомление придёт на телефон.'),
                ],
              ),
            ),
          ),
          TintedAction(
            icon: KvIcons.sparkle,
            title: 'Первый день в КСТ Визор',
            subtitle: 'Знакомство за 1 минуту: сканер, маршрут, находки',
            onTap: () => context.kvPush(EntryPaths.aOnb1),
          ),
        ] else if (taskValue.hasValue && units.hasValue)
          _NoTaskNote(units: list),
        if (!units.hasValue) ...[const KvSkeleton.card(height: 150), const KvSkeleton.card(height: 150)],
        for (final Equipment u in list)
          _UnitCard(
            unit: u,
            repairPlan: plan.where((PlanItem p) => p.unitId == u.id && p.status == 'planned').firstOrNull,
            onTap: () => context.kvPush(EngineerInspectPaths.card(u.id)),
          ),
      ],
    );
  }
}

/// Плашка без задания мастера: последнее сработавшее правило по агрегату с отклонением ведёт в его диагностику.
class _NoTaskNote extends ConsumerWidget {
  const _NoTaskNote({required this.units});

  final List<Equipment> units;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ({Equipment unit, DiagnosisResult rule})? fired;
    for (final Equipment u in units.where((Equipment u) => u.status == 'warn' || u.status == 'bad')) {
      final DiagnosisResult? d = (ref.watch(diagnosisProvider(u.id)).value ?? const <DiagnosisResult>[])
          .where((DiagnosisResult d) => d.firedAt.isNotEmpty)
          .firstOrNull;
      if (d != null) {
        fired = (unit: u, rule: d);
        break;
      }
    }
    final ({Equipment unit, DiagnosisResult rule})? f = fired;
    return KvNote(
      icon: KvIcons.clipboard,
      text: KvFormat.typo(
        f == null ? 'Заданий от мастера пока нет.' : 'Заданий от мастера пока нет. ${f.unit.code}: сработало правило ${f.rule.ruleId} в ${f.rule.firedAt}.',
      ),
      onTap: f == null ? null : () => context.kvPush(EngineerInspectPaths.diagnosticsFor(f.unit.id)),
    );
  }
}

class _Counters extends StatelessWidget {
  const _Counters({required this.units});

  final List<Equipment> units;

  @override
  Widget build(BuildContext context) {
    final int ok = units.where((Equipment u) => u.status == 'ok').length;
    final int warn = units.where((Equipment u) => u.status == 'warn' || u.status == 'bad').length;
    final int repair = units.where((Equipment u) => u.inRepair).length;
    return Row(
      children: [
        Expanded(child: KvKpi(value: '$ok', label: 'Норма', status: KvStatus.ok)),
        const SizedBox(width: KvSpace.s2),
        Expanded(child: KvKpi(value: '$warn', label: 'Внимание', status: KvStatus.warn)),
        const SizedBox(width: KvSpace.s2),
        Expanded(child: KvKpi(value: '$repair', label: 'На ремонте', status: KvStatus.info)),
      ],
    );
  }
}

/// Плашка задания мастера (.task-banner).
class _TaskBanner extends StatelessWidget {
  const _TaskBanner({required this.task, required this.unit, required this.onTap});

  final InspectionTask task;
  final Equipment? unit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final String due = task.due.contains(', ') ? task.due.split(', ').last : task.due;
    final String rule = RegExp(r'[RSV]\d{2}').firstMatch('${task.title} ${task.reason}')?.group(0) ?? '';
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    return KvPressable(
      onTap: onTap,
      borderRadius: radius,
      pressedScale: 0.985,
      semanticLabel: 'Задание мастера',
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: c.tint2, borderRadius: radius),
        child: Row(
          children: [
            KvRowIcon(icon: KvIcons.clipboard, background: c.surface),
            const SizedBox(width: KvSpace.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    KvFormat.typo('Осмотр ${unit?.code ?? task.unitId} до $due'),
                    style: t.sm.copyWith(fontWeight: FontWeight.w600, color: c.brand, height: KvTextStyles.normalHeight(14)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    KvFormat.typo('Задание мастера · ${task.from}${rule.isEmpty ? '' : ' · $rule'}'),
                    style: t.caption.copyWith(height: KvTextStyles.normalHeight(13)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: KvSpace.s3),
            KvIcon(KvIcons.chevronRight, size: 20, color: c.brand),
          ],
        ),
      ),
    );
  }
}

/// Карточка агрегата в списке (.unit-card).
class _UnitCard extends StatelessWidget {
  const _UnitCard({required this.unit, required this.repairPlan, required this.onTap});

  final Equipment unit;
  final PlanItem? repairPlan;
  final VoidCallback onTap;

  String get _line {
    final Equipment u = unit;
    if (u.inRepair) {
      final String when = repairPlan == null ? u.nextTo.date : '${repairPlan!.date.substring(0, 5)}, ${repairPlan!.time}';
      return 'На ремонте · ${u.nextTo.code.toLowerCase()} $when';
    }
    if (u.status == 'warn' || u.status == 'bad') {
      final String part = u.resource.label.contains('подшипник') ? 'подшипники' : 'ресурс';
      return 'До ${u.nextTo.code} ${KvFormat.num(u.nextTo.inHours)} ч · $part ${KvFormat.num(u.resource.used)} из ${KvFormat.num(u.resource.total)} ч';
    }
    if (u.resource.total <= 0) {
      return u.runHours > 0 ? 'Наработка ${KvFormat.num(u.runHours)} ч · ресурс не задан' : 'Ресурс не задан';
    }
    return 'Наработка ${KvFormat.num(u.runHours)} из ${KvFormat.num(u.resource.total)} ч';
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool narrow = MediaQuery.sizeOf(context).width <= 370;
    final KvStatus bar = switch (unit.status) {
      'bad' => KvStatus.bad,
      'warn' => KvStatus.warn,
      _ => KvStatus.info,
    };
    return KvCard(
      onTap: onTap,
      semanticLabel: unit.code,
      padding: const EdgeInsets.fromLTRB(16, 16, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(unit.code, style: t.h2.copyWith(height: KvTextStyles.normalHeight(17)))),
              const SizedBox(width: KvSpace.s2),
              KvChip(unit.statusLabel, status: unit.kvStatus),
              const SizedBox(width: KvSpace.s2),
              KvIcon(KvIcons.chevronRight, size: 20, color: c.text3),
            ],
          ),
          const SizedBox(height: 6),
          Text('${unit.model} · ${unit.kindShort}', maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption),
          const SizedBox(height: 6 + 2),
          Text(KvFormat.typo(unit.summary), style: (narrow ? t.sm : t.body).copyWith(fontWeight: FontWeight.w500, height: 1.35)),
          const SizedBox(height: 6 + 6),
          KvProgress(value: unit.resource.fraction, status: bar),
          const SizedBox(height: 6),
          Text(KvFormat.typo(_line), style: t.label),
        ],
      ),
    );
  }
}
