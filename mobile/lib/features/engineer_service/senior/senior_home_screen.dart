import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../shared/bridges.dart';
import '../service_common.dart';

/// Объекты старшего инженера (f-d-senior-home): как у инженера, но вместо задания по правилу - плашка нового
/// раздела «Находки» и плановый обход из задания мастера; в подписи - имя сотрудника вместо смены.
class SeniorHomeScreen extends ConsumerWidget {
  /// Создаёт экран.
  const SeniorHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Site? site = ref.watch(siteProvider).value;
    final AsyncValue<List<Equipment>> units = ref.watch(unitsProvider);
    final String? me = ref.watch(sessionProvider.select((AuthSession? s) => s?.user.name));
    final List<InspectionTask> tasks = ref.watch(tasksProvider(me)).value ?? const <InspectionTask>[];
    final List<PlanItem> plan = ref.watch(planProvider).value ?? const <PlanItem>[];
    final int pending = ref.watch(findingsProvider((status: 'new', unitId: null))).value?.length ?? 0;
    final InspectionTask? task = tasks.where((InspectionTask t) => t.status != 'done' && t.status != 'cancelled').firstOrNull;
    final List<Equipment> list = units.value ?? const <Equipment>[];
    final Equipment? taskUnit = task == null ? null : list.where((Equipment u) => u.id == task.unitId).firstOrNull;
    return KvScreen(
      header: KvRootHeader(
        title: 'Объекты',
        subtitle: site == null ? ' ' : KvFormat.typo('${site.name} · ${me == null ? site.shiftShort : ServiceFormat.short(me)}'),
      ),
      children: [
        KvSearchPill('Номер, модель, серийный номер', onTap: () => context.kvPush(EngineerInspectPaths.search)),
        if (units.hasValue) _Counters(units: list) else const KvSkeleton(height: 100, radius: KvRadius.card),
        if (pending > 0)
          SeniorBanner(
            icon: KvIcons.alertCircle,
            title: 'Новый раздел · Находки',
            subtitle: '$pending ${KvFormat.plural(pending, 'находка ждёт', 'находки ждут', 'находок ждут')} подтверждения',
            onTap: () => context.kvFade(EngineerServicePaths.fDSeniorFindings),
          ),
        if (task != null)
          SeniorBanner(
            icon: KvIcons.clipboard,
            title: KvFormat.typo('Обход ${taskUnit?.code ?? task.unitId} в ${task.due.split(', ').last}'),
            subtitle: KvFormat.typo('Задание мастера · ${task.from}'),
            onTap: () => context.kvPush(EngineerServicePaths.seniorCard(task.unitId)),
          ),
        if (!units.hasValue) ...[const KvSkeleton.card(height: 150), const KvSkeleton.card(height: 150)],
        for (final Equipment u in list)
          _UnitCard(
            unit: u,
            repairPlan: plan.where((PlanItem p) => p.unitId == u.id && p.status == 'planned').firstOrNull,
            onTap: () => context.kvPush(EngineerServicePaths.seniorCard(u.id)),
          ),
      ],
    );
  }
}

/// Счётчики состояния агрегатов: норма, внимание, на ремонте.
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
        Expanded(
          child: KvKpi(value: '$ok', label: 'Норма', status: KvStatus.ok),
        ),
        const SizedBox(width: KvSpace.s2),
        Expanded(
          child: KvKpi(value: '$warn', label: 'Внимание', status: KvStatus.warn),
        ),
        const SizedBox(width: KvSpace.s2),
        Expanded(
          child: KvKpi(value: '$repair', label: 'На ремонте', status: KvStatus.info),
        ),
      ],
    );
  }
}

/// Синяя плашка-переход (.task-banner): значок на белом квадрате, заголовок, подпись и шеврон.
class SeniorBanner extends StatelessWidget {
  /// Создаёт плашку.
  const SeniorBanner({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap});

  /// Значок.
  final KvIcons icon;

  /// Заголовок.
  final String title;

  /// Подпись.
  final String subtitle;

  /// Касание.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    return KvPressable(
      onTap: onTap,
      borderRadius: radius,
      pressedScale: 0.985,
      semanticLabel: title,
      child: Container(
        constraints: const BoxConstraints(minHeight: 60),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: c.tint2, borderRadius: radius),
        child: Row(
          children: [
            KvRowIcon(icon: icon, background: c.surface),
            const SizedBox(width: KvSpace.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: t.sm.copyWith(fontWeight: FontWeight.w600, color: c.brand, height: KvTextStyles.normalHeight(14)),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13))),
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

/// Карточка агрегата в списке (.unit-card): обозначение, состояние, модель, сводка, ресурс и срок ТО.
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
              Expanded(
                child: Text(unit.code, style: t.h2.copyWith(height: KvTextStyles.normalHeight(17))),
              ),
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
