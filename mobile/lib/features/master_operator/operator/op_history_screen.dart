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
import 'op_blocks.dart';
import 'op_objects_screen.dart';

/// Переключатель «Сообщения / События» истории оператора: смена пункта - переход seg.
class _HistoryTabs extends StatelessWidget {
  const _HistoryTabs({required this.index, this.from});

  final int index;
  final int? from;

  @override
  Widget build(BuildContext context) {
    return KvSegment(
      items: const ['Сообщения', 'События'],
      index: index,
      animateFrom: from,
      onBackground: true,
      onChanged: (int i) => context.kvSeg(i == 0 ? MasterOperatorPaths.opHistory : MasterOperatorPaths.dOpEvents, fromSegment: index),
    );
  }
}

/// Работа плана, запланированная по агрегату [unitId], или null.
PlanItem? opPlannedWork(List<PlanItem> plan, String unitId) =>
    plan.where((PlanItem p) => p.unitId == unitId && p.status == 'planned').firstOrNull;

/// Подпись этапа сообщения в истории: закрыто, ремонт по плану или текущий шаг.
String opStageOf(FaultReport r, PlanItem? work) {
  final int step = r.timeline.isEmpty ? 1 : r.timeline.length.clamp(1, 4);
  return switch (r.status) {
    'closed' => 'Проверено инженером · сообщение закрыто',
    'repair' when work != null => 'Ремонт ${moDay(work.date)}, ${work.time} · этап $step из 5',
    _ => '${r.timeline.isEmpty ? r.statusLabel : r.timeline.last.title} · этап $step из 5',
  };
}

/// История сообщений оператора о неисправностях: карточки со статусом и этапами.
class OpHistoryScreen extends ConsumerWidget {
  /// Создаёт экран.
  const OpHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int? from = KvNavExtra.of(GoRouterState.of(context))?.fromSegment;
    final List<FaultReport> reports = ref.watch(faultReportsProvider(null)).value ?? const <FaultReport>[];
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final List<PlanItem> plan = ref.watch(planProvider).value ?? const <PlanItem>[];
    String code(String id) => units.where((Equipment u) => u.id == id).firstOrNull?.code ?? id;
    return KvScreen(
      header: const KvRootHeader(title: 'История', subtitle: 'Сообщения о неисправностях'),
      stagger: from != null ? KvStagger.seg : KvStagger.appear,
      staggerSkip: from != null ? 1 : 0,
      children: [
        _HistoryTabs(index: 0, from: from),
        if (reports.isEmpty)
          const KvEmpty(icon: KvIcons.megaphone, title: 'Сообщений пока нет', text: 'Заметили течь, шум или запах - сообщите мастеру.'),
        for (final FaultReport r in reports)
          OpReportCard(
            report: r,
            code: code(r.unitId),
            stage: opStageOf(r, opPlannedWork(plan, r.unitId)),
            onTap: () => context.kvPush(MasterOperatorPaths.reportStatus(r.id)),
          ),
      ],
    );
  }
}

/// События агрегатов за сегодня на шкале времени: сообщения, остановки, находки и ремонты.
class OpEventsScreen extends ConsumerWidget {
  /// Создаёт экран.
  const OpEventsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int? from = KvNavExtra.of(GoRouterState.of(context))?.fromSegment;
    final DateTime now = ref.watch(clockProvider).now();
    final String today = KvFormat.date(now);
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final List<(String, String, HistoryEvent)> events = [
      for (final Equipment u in units)
        for (final HistoryEvent h in ref.watch(unitHistoryProvider(u.id)).value ?? const <HistoryEvent>[])
          if (h.date == today) (h.time, u.code, h),
    ]..sort(((String, String, HistoryEvent) a, (String, String, HistoryEvent) b) => b.$1.compareTo(a.$1));
    return KvScreen(
      header: KvRootHeader(title: 'История', subtitle: 'События агрегатов · ${KvFormat.dayMonth(now)}'),
      stagger: from != null ? KvStagger.seg : KvStagger.appear,
      staggerSkip: from != null ? 1 : 0,
      children: [
        _HistoryTabs(index: 1, from: from),
        if (events.isNotEmpty)
          KvCard(
            child: KvTimeline(
              items: [
                for (final (String, String, HistoryEvent) e in events)
                  KvTimelineItem(
                    time: KvFormat.typo('${e.$1} · ${e.$2}'),
                    title: KvFormat.typo(e.$3.title),
                    text: KvFormat.typo(e.$3.text),
                    status: KvStatus.parse(e.$3.status),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Статус сообщения оператора: текст и признаки, ход работ по шагам и переход к агрегату.
class OpReportStatusScreen extends ConsumerWidget {
  /// Создаёт экран сообщения [reportId].
  const OpReportStatusScreen({super.key, required this.reportId});

  /// Номер сообщения.
  final String reportId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<FaultReport> reports = ref.watch(faultReportsProvider(null)).value ?? const <FaultReport>[];
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final List<PlanItem> plan = ref.watch(planProvider).value ?? const <PlanItem>[];
    final FaultReport? r = reports.where((FaultReport x) => x.id == reportId).firstOrNull;
    if (r == null) {
      return KvScreen(
        header: KvHeader(title: reportId, onBack: () => context.kvBack(MasterOperatorPaths.opHistory)),
        children: const [KvSkeleton.card(height: 140), KvSkeleton.card(height: 300)],
      );
    }
    final Equipment? u = units.where((Equipment x) => x.id == r.unitId).firstOrNull;
    final String code = u?.code ?? r.unitId;
    final bool closed = r.status == 'closed';
    final PlanItem? work = r.status == 'repair' ? opPlannedWork(plan, r.unitId) : null;
    final List<String> signs = [
      for (final String s in r.kind.split(', '))
        if (s.isNotEmpty) s,
    ];
    final List<HistoryEvent> history = u == null
        ? const <HistoryEvent>[]
        : ref.watch(unitHistoryProvider(u.id)).value ?? const <HistoryEvent>[];
    final String? stop = history.where((HistoryEvent h) => h.title == 'Аварийная остановка').firstOrNull?.time;
    final List<KvTimelineItem> steps = [
      for (final FaultStep s in r.timeline)
        KvTimelineItem(time: s.time, title: KvFormat.typo(s.title), text: KvFormat.typo(s.who), status: moStepTone(s.title)),
      if (work != null)
        KvTimelineItem(
          time: KvFormat.typo('${moDay(work.date)}, ${work.time}'),
          title: work.work.replaceFirst('торцевого ', ''),
          text: 'Запланирован · ${work.who}',
        ),
    ];
    return KvScreen(
      header: KvHeader(
        title: r.id,
        subtitle: KvFormat.typo('${r.statusLabel} · $code'),
        status: closed ? KvStatus.ok : KvStatus.info,
        onBack: () => context.kvBack(MasterOperatorPaths.opHistory),
      ),
      children: [
        KvCard(
          child: MoQuote(
            avatar: r.author,
            who: '${r.author} · ${moDay(r.date)}, ${r.time}',
            text: r.text.isEmpty ? r.kind : r.text,
            large: true,
            chips: [
              for (final String s in signs) KvChip(s, status: closed ? null : KvStatus.bad, dot: false),
              if (!closed && r.id == 'S-077') const KvChip('Кадр приложен', dot: false),
            ],
          ),
        ),
        KvCard(
          title: 'Ход работ',
          child: KvTimeline(items: steps),
        ),
        if (!closed && u != null)
          KvList(
            children: [
              KvRow(
                icon: u.mode == 'repair' ? KvIcons.wrench : KvIcons.grid,
                title: KvFormat.typo('Открыть $code'),
                subtitle: KvFormat.typo(
                  u.mode == 'repair' && stop != null ? '${u.statusLabel} · показания на $stop' : '${u.statusLabel} · показания и режим',
                ),
                onTap: () => context.kvPush(opUnitPath(u)),
              ),
            ],
          ),
      ],
    );
  }
}
