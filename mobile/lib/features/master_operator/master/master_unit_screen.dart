import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../shared/bridges.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_sheet_swap.dart';
import 'master_assign_sheet.dart';
import 'master_finding_sheets.dart';

/// Плитка показания агрегата со спарклайном за сутки.
class MoReadingTile extends ConsumerWidget {
  /// Создаёт плитку показания [reading] агрегата [unitId].
  const MoReadingTile({super.key, required this.unitId, required this.reading, this.status, this.spark = true});

  /// Агрегат.
  final String unitId;

  /// Показание.
  final Reading reading;

  /// Тон вместо тона по уставкам.
  final KvStatus? status;

  /// Показать спарклайн.
  final bool spark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TelemetrySeries? s = spark ? ref.watch(seriesProvider((unitId: unitId, key: reading.key, period: TelemetryPeriod.day))).value : null;
    return KvTile(
      label: reading.short,
      value: KvFormat.num(reading.value, reading.digits),
      unit: reading.unit,
      status: status ?? reading.kvStatus,
      spark: spark ? (s?.chart ?? KvSeriesData(values: [reading.value, reading.value])) : null,
    );
  }
}

/// Агрегат глазами мастера: режим с кнопкой смены, показания плитками или остановленный счёт наработки,
/// находки, ТО и осмотры, назначение осмотра.
///
/// Режим «резерв» или «остановлен» показывает экран «Н-101 остановлен» с запуском; [at] = «0912» - Н-101
/// в 09:12 (сценарий Б), до осмотра, с находкой R08 и срочным назначением.
class MasterUnitScreen extends ConsumerWidget {
  /// Создаёт экран агрегата [unitId].
  const MasterUnitScreen({super.key, required this.unitId, this.at});

  /// Агрегат.
  final String unitId;

  /// Момент истории или null.
  final String? at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Equipment? u = ref.watch(unitProvider(unitId)).value;
    if (u == null) {
      return KvScreen(
        header: KvHeader(title: ' ', onBack: () => context.kvBack(MasterOperatorPaths.masterShift)),
        children: const [KvSkeleton.card(height: 76), KvSkeleton.card(height: 280)],
      );
    }
    final List<HistoryEvent> history = ref.watch(unitHistoryProvider(unitId)).value ?? const <HistoryEvent>[];
    final List<Finding> fresh = ref.watch(findingsProvider((status: 'new', unitId: u.id))).value ?? const <Finding>[];
    final bool stopped = at == null && (u.mode == 'reserve' || u.mode == 'stopped');
    final bool repair = u.mode == 'repair';
    final bool n101 = u.id == 'N-101';
    final String since = history.firstOrNull?.time ?? '09:41';
    Reading? r(String key) => u.readings[key];

    final Widget modeCard = KvCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Row(
        children: [
          KvRowIcon(
            icon: stopped ? KvIcons.pause : (repair ? KvIcons.wrench : KvIcons.power),
            status: stopped ? KvStatus.unk : (repair ? KvStatus.info : KvStatus.ok),
          ),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Режим: ${stopped ? (u.mode == 'stopped' ? 'остановлен' : 'резерв') : (repair ? 'На ремонте' : 'В работе')}',
                  style: context.kvText.bodyM,
                ),
                Text(
                  KvFormat.typo(stopped
                      ? 'С $since · наработка не начисляется'
                      : repair
                          ? 'С 06:44 · ремонт 15.11, 08:00'
                          : 'Наработка ${KvFormat.num(u.runHours)} ч · начисляется'),
                  style: context.kvText.caption,
                ),
              ],
            ),
          ),
          if (stopped) ...[
            const SizedBox(width: KvSpace.s3),
            KvButton('Запустить', kind: KvButtonKind.tonal, small: true, onPressed: () => _run(context, ref, u)),
          ] else if (!repair) ...[
            const SizedBox(width: KvSpace.s3),
            KvButton('Сменить', kind: KvButtonKind.tonal, small: true, onPressed: () => _mode(context, u)),
          ],
        ],
      ),
    );

    final List<Widget> body = [modeCard];
    if (stopped) {
      body.addAll([
        KvCard(
          child: MoNext(
            value: KvFormat.num(u.nextTo.inHours),
            unit: 'ч',
            tone: KvStatus.unk,
            title: KvFormat.typo('до ${u.nextTo.code} - счёт остановлен'),
            text: KvFormat.typo('${KvFormat.num(u.runHours)} ч наработки зафиксировано в $since'),
            progress: u.nextTo.atHours == 0 ? 0 : (u.runHours / u.nextTo.atHours).clamp(0.0, 1.0),
          ),
        ),
        KvNote(icon: KvIcons.info, text: KvFormat.typo('Показания не обновляются, пока ${u.code} остановлен. Оператор и инженер видят режим «Остановлен».')),
      ]);
    } else {
      final List<String> keys = ['vib1x', 'tBearing', 'tWinding', repair ? 'current' : 'pressOut'];
      KvStatus? tone(String key) => repair && (key == 'pressOut' || key == 'current') ? KvStatus.unk : null;
      body.add(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MoGridRow(children: [for (final String k in keys.take(2)) if (r(k) != null) MoReadingTile(unitId: u.id, reading: r(k)!, status: tone(k))]),
          const SizedBox(height: KvSpace.s3),
          MoGridRow(children: [for (final String k in keys.skip(2)) if (r(k) != null) MoReadingTile(unitId: u.id, reading: r(k)!, status: tone(k))]),
        ],
      ));
    }
    if (at == '0912') {
      body.add(KvList(
        children: [
          KvRow(
            icon: KvIcons.alertCircle,
            iconStatus: KvStatus.warn,
            title: KvFormat.typo('Находка F-1042 · R08'),
            subtitle: KvFormat.typo('Создана правилом в 08:12 · ждёт подтверждения'),
            onTap: () => context.kvPush(MasterOperatorPaths.finding('F-1042')),
          ),
          KvRow(
            icon: KvIcons.calendar,
            title: KvFormat.typo('ТО-2 через 10 ч'),
            subtitle: KvFormat.typo('Прогноз 15.11, 10:00 · Е. Титова'),
            onTap: () => context.kvPush(MasterOperatorPaths.planItem('P-502')),
          ),
          KvRow(icon: KvIcons.history, iconStatus: KvStatus.unk, title: 'Сегодня осмотров не было', subtitle: KvFormat.typo('Последний 13.11, 16:40 · А. Смирнов'), chevron: false),
        ],
      ));
    } else if (n101) {
      body.add(KvList(
        children: [
          KvRow(
            icon: KvIcons.alertCircle,
            iconStatus: KvStatus.warn,
            title: 'Находки',
            subtitle: fresh.isEmpty
                ? 'Новых нет'
                : '${fresh.length} ${KvFormat.plural(fresh.length, 'ждёт', 'ждут', 'ждут')} подтверждения · ${[for (final Finding f in fresh) f.ruleId].join(', ')}',
            onTap: () => moGoTab(context, MasterOperatorPaths.masterFindings),
          ),
          KvRow(
            icon: KvIcons.calendar,
            title: KvFormat.typo('${u.nextTo.code} через ${KvFormat.num(u.nextTo.inHours)} ч'),
            subtitle: KvFormat.typo('Прогноз 15.11, 10:00 · Е. Титова'),
            onTap: () => context.kvPush(MasterOperatorPaths.planItem('P-502')),
          ),
          KvRow(
            icon: KvIcons.scan,
            title: 'Осмотр сегодня',
            subtitle: KvFormat.typo('09:20-09:34 · А. Смирнов · INS-2209'),
            onTap: () => context.kvPush(MasterOperatorPaths.dMTeam),
          ),
        ],
      ));
    } else if (repair) {
      body.add(KvList(
        children: [
          KvRow(
            icon: KvIcons.alertCircle,
            iconStatus: KvStatus.bad,
            title: KvFormat.typo('Находка F-1041'),
            subtitle: 'Течь уплотнения · запланировано ТО',
            onTap: () => context.kvPush(MasterOperatorPaths.finding('F-1041')),
          ),
          KvRow(
            icon: KvIcons.calendar,
            title: 'Ремонт уплотнения',
            subtitle: KvFormat.typo('15.11, 08:00 · А. Смирнов'),
            onTap: () => context.kvPush(MasterOperatorPaths.planItem('P-501')),
          ),
        ],
      ));
    }

    return KvScreen(
      header: KvHeader(
        title: u.code,
        subtitle: '${stopped ? 'Остановлен' : u.statusLabel} · ${u.modelShort}',
        status: stopped ? KvStatus.unk : u.kvStatus,
        onBack: () => context.kvBack(MasterOperatorPaths.masterShift),
      ),
      foot: n101 && !stopped
          ? KvButton('Назначить осмотр', icon: KvIcons.clipboard, onPressed: () => showMoAssignSheet(context, at == '0912' ? MoAssignPreset.r08 : MoAssignPreset.n101))
          : null,
      children: body,
    );
  }

  Future<void> _mode(BuildContext context, Equipment u) => showKvSheet<void>(context, builder: (BuildContext sheet) => _ModeSheet(unit: u));

  Future<void> _run(BuildContext context, WidgetRef ref, Equipment u) {
    return showKvDialog<void>(
      context,
      builder: (BuildContext dialog) => KvDialog(
        icon: KvIcons.power,
        tone: KvStatus.ok,
        title: KvFormat.typo('Запустить ${u.code}?'),
        text: KvFormat.typo('Наработка снова начнёт начисляться. Убедитесь, что работы по F-1043 не требуют остановки.'),
        actions: [
          KvButton('Отмена', kind: KvButtonKind.secondary, onPressed: () => Navigator.of(dialog).pop()),
          KvButton(
            'Запустить',
            wait: true,
            onPressed: () async {
              await ref.read(equipmentRepositoryProvider).setMode(u.id, 'running', reason: 'Запуск после резерва');
              if (dialog.mounted) {
                Navigator.of(dialog).pop();
              }
            },
          ),
        ],
      ),
    );
  }
}

/// Лист смены режима агрегата: в работе или остановлен, причина; остановка фиксирует наработку.
class _ModeSheet extends ConsumerStatefulWidget {
  const _ModeSheet({required this.unit});

  final Equipment unit;

  @override
  ConsumerState<_ModeSheet> createState() => _ModeSheetState();
}

class _ModeSheetState extends ConsumerState<_ModeSheet> {
  static const List<String> _reasons = ['По находке F-1043', 'Перевод в резерв', 'Ремонт', 'Другое'];
  int _mode = 1;
  int _reason = 0;
  String? _at;

  Future<void> _apply() async {
    final String mode = switch (_reason) {
      2 => 'repair',
      3 => 'stopped',
      _ => 'reserve',
    };
    await ref.read(equipmentRepositoryProvider).setMode(widget.unit.id, mode, reason: _reasons[_reason]);
    if (mounted) {
      setState(() => _at = KvFormat.time(ref.read(clockProvider).now()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final Equipment u = widget.unit;
    if (_at != null) {
      return MoSheetSwap(
        child: MoDoneSheet(
          key: const ValueKey<String>('done'),
          icon: KvIcons.pause,
          tone: KvStatus.unk,
          title: KvFormat.typo('${u.code} остановлен'),
          text: KvFormat.typo('$_at · ${_reasons[_reason][0].toLowerCase()}${_reasons[_reason].substring(1)}. Оператор и инженер смены получили уведомление.'),
          pairs: [('Наработка', '${KvFormat.num(u.runHours)} ч · зафиксирована'), ('До ${u.nextTo.code}', '${KvFormat.num(u.nextTo.inHours)} ч · счёт на паузе')],
          actions: [KvButton('Готово', onPressed: () => Navigator.of(context).pop())],
        ),
      );
    }
    return MoSheetSwap(
      child: KvSheet(
        key: const ValueKey<String>('form'),
        title: KvFormat.typo('Режим ${u.code}'),
        children: [
          KvList(
            children: [
              MoRadioRow(icon: KvIcons.power, iconStatus: KvStatus.ok, title: 'В работе', subtitle: 'Наработка начисляется', on: _mode == 0, onTap: () => setState(() => _mode = 0)),
              MoRadioRow(icon: KvIcons.pause, title: 'Остановлен', subtitle: 'Резерв или ремонт', on: _mode == 1, onTap: () => setState(() => _mode = 1)),
            ],
          ),
          if (_mode == 1) ...[
            const MoLabel('Причина'),
            KvFilterChips(items: [for (final String r in _reasons) KvFilterItem(KvFormat.typo(r))], selected: _reason, onSelected: (int i) => setState(() => _reason = i)),
            KvNote(
              tone: KvStatus.warn,
              icon: KvIcons.timer,
              text: KvFormat.typo('Пока ${u.code} остановлен, наработка не начисляется: сроки ТО-2 и ресурс подшипников сдвинутся.'),
            ),
          ],
        ],
        actions: [
          if (_mode == 1)
            KvButton(KvFormat.typo('Остановить ${u.code}'), kind: KvButtonKind.danger, icon: KvIcons.pause, wait: true, onPressed: _apply)
          else
            KvButton('Оставить в работе', kind: KvButtonKind.secondary, onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}
