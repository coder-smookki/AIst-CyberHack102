import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../shared/bridges.dart';
import '../service_common.dart';

/// Задание мастера (c-task, c-task-ams2): агрегат, причина (правило с показаниями или сообщение оператора),
/// что сделать и кнопка «Начать осмотр»; меню - карточка, история агрегата, звонок мастеру.
class TaskScreen extends ConsumerWidget {
  /// Создаёт экран задания [taskId].
  const TaskScreen({super.key, required this.taskId});

  /// Номер задания: T-318, T-317.
  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final InspectionTask? task = ref.watch(taskProvider(taskId)).value;
    final Equipment? unit = task == null ? null : ref.watch(unitProvider(task.unitId)).value;
    final Map<String, Person> people = ref.watch(peopleProvider).value ?? const <String, Person>{};
    if (task == null || unit == null) {
      return KvScreen(
        header: KvHeader(title: KvFormat.typo('Задание $taskId'), onBack: () => context.kvBack(EngineerServicePaths.cNotif)),
        children: const [KvSkeleton.card(height: 104), KvSkeleton.card(height: 250)],
      );
    }
    final bool byOperator = task.faultReportId != null;
    final String due = task.due.contains(', ') ? task.due.split(', ').last : task.due;
    final Person? master = people.values.where((Person p) => p.name == task.from).firstOrNull ?? people['master'];
    final String assigned = task.assignedAt.isEmpty ? '' : 'Назначено ${task.assignedAt} · ';
    return KvScreen(
      header: KvHeader(
        title: KvFormat.typo('Задание ${task.id}'),
        subtitle: KvFormat.typo('$assignedсрок до $due'),
        status: byOperator ? KvStatus.bad : KvStatus.warn,
        onBack: () => context.kvBack(EngineerServicePaths.cNotif),
        onMore: () => showTaskMenu(context, unit, master),
      ),
      foot: KvButton(
        'Начать осмотр',
        icon: KvIcons.scan,
        onPressed: () => context.kvUp(byOperator && unit.id == 'AMS-2' ? EngineerInspectPaths.fAScanAms2 : EngineerInspectPaths.scanner),
      ),
      children: [
        _UnitCard(unit: unit, stoppedRule: byOperator ? _stopRule(ref, unit) : null),
        if (byOperator) _OperatorReason(task: task, unit: unit) else _RuleReason(task: task, unit: unit),
        KvCard(
          title: 'Что сделать',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KvKeyValues([
                ('Срок', 'сегодня до $due'),
                ('Назначила', '${ServiceFormat.short(task.from)}, ${(master?.roleLabel ?? 'мастер').toLowerCase()}'),
              ]),
              if (task.instructions.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(KvFormat.typo(task.instructions), style: context.kvText.sm.copyWith(height: 1.45, color: context.kv.text)),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Правило аварийной остановки агрегата из его истории: «S05».
  static String? _stopRule(WidgetRef ref, Equipment unit) {
    final List<HistoryEvent> history = ref.watch(unitHistoryProvider(unit.id)).value ?? const <HistoryEvent>[];
    for (final HistoryEvent e in history) {
      final RegExpMatch? m = RegExp(r'S\d{2}').firstMatch(e.text);
      if (e.status == 'bad' && m != null) {
        return m.group(0);
      }
    }
    return null;
  }
}

/// Карточка агрегата задания (.c-unit): обозначение, чип состояния, модель и место; касание - карточка агрегата.
class _UnitCard extends StatelessWidget {
  const _UnitCard({required this.unit, required this.stoppedRule});

  final Equipment unit;
  final String? stoppedRule;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return KvCard(
      onTap: () => context.kvPush(EngineerInspectPaths.card(unit.id)),
      semanticLabel: unit.code,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(unit.code, style: t.h2.copyWith(height: KvTextStyles.normalHeight(17))),
              ),
              const SizedBox(width: KvSpace.s2),
              if (stoppedRule != null)
                KvChip(KvFormat.typo('Остановлен по $stoppedRule'), status: KvStatus.unk)
              else
                KvChip(unit.statusLabel, status: unit.kvStatus),
              const SizedBox(width: KvSpace.s2),
              KvIcon(KvIcons.chevronRight, size: 20, color: c.text3),
            ],
          ),
          const SizedBox(height: 4),
          Text(KvFormat.typo(unit.model), style: t.caption),
          const SizedBox(height: 4),
          Text(KvFormat.typo(unit.location), style: t.caption),
        ],
      ),
    );
  }
}

/// Причина по правилу (T-318): сработавшее правило и две плитки показаний со спарклайнами за неделю.
class _RuleReason extends ConsumerWidget {
  const _RuleReason({required this.task, required this.unit});

  final InspectionTask task;
  final Equipment unit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvTextStyles t = context.kvText;
    final String ruleId = RegExp(r'[RSV]\d{2}').firstMatch('${task.title} ${task.reason}')?.group(0) ?? '';
    final List<RuleDef> rules = ref.watch(rulesProvider).value ?? const <RuleDef>[];
    final List<DiagnosisResult> diagnosis = ref.watch(diagnosisProvider(unit.id)).value ?? const <DiagnosisResult>[];
    final RuleDef? rule = rules.where((RuleDef r) => r.id == ruleId).firstOrNull;
    final String fired = diagnosis.where((DiagnosisResult d) => d.ruleId == ruleId).firstOrNull?.firedAt ?? '';
    final Map<String, Reading> readings = ref.watch(readingsProvider(unit.id)).value ?? unit.readings;
    return KvCard(
      title: 'Причина',
      trailing: Text(fired.isEmpty ? 'Датчики' : 'Датчики · $fired', style: t.label.copyWith(height: KvTextStyles.normalHeight(12))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const KvRowIcon(icon: KvIcons.activity, status: KvStatus.warn),
              const SizedBox(width: KvSpace.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      KvFormat.typo('Сработало правило $ruleId'),
                      style: t.body.copyWith(fontWeight: FontWeight.w500, height: 1.35, color: context.kv.text),
                    ),
                    const SizedBox(height: 2),
                    Text(KvFormat.typo(rule?.title ?? task.reason), style: t.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: KvSpace.s3),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _ReadingTile(unit: unit, reading: readings['vib1x']),
                ),
                const SizedBox(width: KvSpace.s3),
                Expanded(
                  child: _ReadingTile(unit: unit, reading: readings['tBearing']),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Плитка показания со спарклайном за неделю; касание - графики агрегата.
class _ReadingTile extends ConsumerWidget {
  const _ReadingTile({required this.unit, required this.reading});

  final Equipment unit;
  final Reading? reading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Reading? r = reading;
    if (r == null) {
      return const SizedBox.shrink();
    }
    final TelemetrySeries? s = ref.watch(seriesProvider((unitId: unit.id, key: r.key, period: TelemetryPeriod.week))).value;
    return KvTile(
      label: r.short,
      value: KvFormat.num(r.value, r.digits),
      unit: r.unit,
      status: r.kvStatus,
      spark: s?.chart,
      onTap: () => context.kvPush(EngineerInspectPaths.cardCharts(unit.id)),
    );
  }
}

/// Причина по сообщению оператора (T-317): цитата сообщения и плашка аварийной остановки агрегата.
class _OperatorReason extends ConsumerWidget {
  const _OperatorReason({required this.task, required this.unit});

  final InspectionTask task;
  final Equipment unit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final FaultReport? fr = (ref.watch(faultReportsProvider(null)).value ?? const <FaultReport>[])
        .where((FaultReport f) => f.id == task.faultReportId)
        .firstOrNull;
    final Reading? winding = unit.readings['tWinding'];
    final String stopped = unit.stoppedAt == null ? '' : unit.stoppedAt!.split(' ').last;
    final String? rule = TaskScreen._stopRule(ref, unit);
    return KvCard(
      title: 'Причина',
      trailing: Text(fr == null ? 'Оператор' : 'Оператор · ${fr.time}', style: t.label.copyWith(height: KvTextStyles.normalHeight(12))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              KvAvatar(fr?.author ?? '?'),
              const SizedBox(width: KvSpace.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      KvFormat.typo('«${fr?.text ?? task.reason}»'),
                      style: t.body.copyWith(fontWeight: FontWeight.w500, height: 1.4, color: c.text),
                    ),
                    const SizedBox(height: 2),
                    Text(KvFormat.typo('${fr?.author ?? ''} · сообщение ${fr?.id ?? ''}'), style: t.caption),
                  ],
                ),
              ),
            ],
          ),
          if (rule != null && winding != null) ...[
            const SizedBox(height: KvSpace.s3),
            KvNote(
              tone: KvStatus.bad,
              icon: KvIcons.temp,
              text: KvFormat.typo(
                '$rule в $stopped: обмотка ${KvFormat.num(winding.value, winding.digits)} °C, уставка ${KvFormat.num(winding.alarm, winding.digits)} °C. Агрегат остановлен.',
              ),
              onTap: () => context.kvPush(EngineerInspectPaths.card(unit.id)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Меню задания (листы c-task-menu, c-task-ams2-menu): карточка и история агрегата, звонок мастеру.
Future<void> showTaskMenu(BuildContext context, Equipment unit, Person? master) {
  final BuildContext screen = context;
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => KvSheet(
      title: KvFormat.typo('Задание · ${unit.code}'),
      children: [
        KvList(
          children: [
            KvRow(
              icon: KvIcons.grid,
              title: KvFormat.typo('Карточка ${unit.code}'),
              subtitle: unit.modelShort,
              onTap: () {
                Navigator.of(sheet).pop();
                screen.kvPush(EngineerInspectPaths.card(unit.id));
              },
            ),
            KvRow(
              icon: KvIcons.clock,
              title: KvFormat.typo('История ${unit.code}'),
              subtitle: 'Осмотры и события',
              onTap: () {
                Navigator.of(sheet).pop();
                screen.kvPush(EngineerServicePaths.historyUnit(unit.id));
              },
            ),
            if (master != null)
              KvRow(
                icon: KvIcons.phone,
                title: 'Связаться с мастером',
                subtitle: KvFormat.typo('${master.name} · ${master.phone}'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  showKvToast(
                    screen,
                    kind: KvToastKind.info,
                    icon: KvIcons.phone,
                    title: master.name,
                    text: KvFormat.typo('Вызов ${master.phone}'),
                  );
                },
              ),
          ],
        ),
      ],
    ),
  );
}
