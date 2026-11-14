import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../shared/bridges.dart';
import '../service_common.dart';

/// История (history, c-history-*): осмотры и события по всем агрегатам по дням, фильтр по агрегату со сводкой
/// агрегата сверху. Касание события открывает связанный экран.
class HistoryScreen extends ConsumerWidget {
  /// Создаёт ленту; [unitId] - отбор по агрегату, [base] - путь вкладки «История» роли.
  const HistoryScreen({super.key, this.unitId, this.base = EngineerServicePaths.history});

  /// Агрегат фильтра или null - все.
  final String? unitId;

  /// Путь ленты без фильтра: /engineer/history или /senior/history.
  final String base;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<HistoryEvent>> feed = ref.watch(activityProvider);
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final Equipment? unit = unitId == null ? null : units.where((Equipment u) => u.id == unitId).firstOrNull;
    final DateTime now = ref.watch(clockProvider).now();
    final List<HistoryEvent> events = (feed.value ?? const <HistoryEvent>[]).where((HistoryEvent e) => unitId == null || e.unitId == unitId).toList();
    final List<String> days = [];
    for (final HistoryEvent e in events) {
      if (!days.contains(e.date)) {
        days.add(e.date);
      }
    }
    final List<String> filterIds = ['N-101', 'AMS-1', 'AMS-2'].where((String id) => units.isEmpty || units.any((Equipment u) => u.id == id)).toList();
    final int selected = unitId == null ? 0 : filterIds.indexOf(unitId!) + 1;
    return KvScreen(
      header: KvRootHeader(
        title: 'История',
        subtitle: unitId == null ? 'Осмотры и события по всем объектам' : KvFormat.typo('Осмотры и события · ${unit?.code ?? unitId}'),
      ),
      children: [
        KvFilterChips(
          items: [
            const KvFilterItem('Все'),
            for (final String id in filterIds) KvFilterItem(KvFormat.typo(units.where((Equipment u) => u.id == id).firstOrNull?.code ?? id)),
          ],
          selected: selected,
          onSelected: (int i) {
            if (i == selected) {
              return;
            }
            context.kvFade(i == 0 ? base : EngineerServicePaths.historyUnit(filterIds[i - 1], base: base));
          },
        ),
        if (unit != null) _UnitSummary(unit: unit),
        if (!feed.hasValue) ...[const KvSkeleton(width: 140), const KvSkeleton.card(height: 260)],
        for (final String day in days) ...[
          KvSectionLabel(ServiceFormat.day(day, now)),
          KvList(
            noIcons: true,
            children: [
              for (final HistoryEvent e in events.where((HistoryEvent e) => e.date == day)) _EventRow(event: e),
            ],
          ),
        ],
      ],
    );
  }
}

/// Сводка агрегата над лентой (.c-unit-sum): значок состояния, обозначение, чип, наработка и последний осмотр.
class _UnitSummary extends StatelessWidget {
  const _UnitSummary({required this.unit});

  final Equipment unit;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    final bool ok = unit.status == 'ok';
    final String last = unit.lastInspection.date.length >= 5 ? unit.lastInspection.date.substring(0, 5) : unit.lastInspection.date;
    return KvCard(
      onTap: () => context.kvPush(EngineerInspectPaths.card(unit.id)),
      semanticLabel: unit.code,
      child: Row(
        children: [
          KvRowIcon(icon: ok ? KvIcons.checkCircle : KvIcons.alert, status: ok ? null : unit.kvStatus),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(unit.code, style: t.h2)),
                    const SizedBox(width: KvSpace.s3),
                    KvChip(unit.inRepair ? unit.modeLabel : unit.statusLabel, status: unit.kvStatus),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  KvFormat.typo('Наработка ${KvFormat.num(unit.runHours)} ч · осмотр $last'),
                  style: t.caption.copyWith(height: KvTextStyles.normalHeight(13)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Событие ленты (.c-hist .row): заголовок, кто и когда, чип итога; касание - связанный экран.
class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final HistoryEvent event;

  @override
  Widget build(BuildContext context) {
    final String sub = [ServiceFormat.short(event.who), event.time, if (event.text.isNotEmpty) event.text].join(' · ');
    return KvRow(
      minHeight: 64,
      title: KvFormat.typo(event.title),
      subtitle: KvFormat.typo(sub),
      trailing: event.label.isEmpty ? null : KvChip(event.label, status: KvStatus.parse(event.status)),
      chevron: false,
      onTap: event.target == null ? null : () => context.kvPush(event.target!),
    );
  }
}
