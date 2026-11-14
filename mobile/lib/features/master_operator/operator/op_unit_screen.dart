import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../shared/bridges.dart';
import '../master/master_finding_sheets.dart';
import '../master/master_unit_screen.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_common.dart';

/// Агрегат глазами оператора, только просмотр: живые показания, график вибрации за период, плитки
/// показаний и сообщение о неисправности; меню «ещё» - сообщения по агрегату, осмотр, ассистент.
class OpUnitScreen extends ConsumerStatefulWidget {
  /// Создаёт экран агрегата [unitId].
  const OpUnitScreen({super.key, required this.unitId});

  /// Агрегат.
  final String unitId;

  @override
  ConsumerState<OpUnitScreen> createState() => _OpUnitScreenState();
}

class _OpUnitScreenState extends ConsumerState<OpUnitScreen> {
  static const List<String> _periods = ['1 ч', '24 ч', '7 дн', '30 дн'];
  int _period = 1;

  @override
  Widget build(BuildContext context) {
    final Equipment? u = ref.watch(unitProvider(widget.unitId)).value;
    if (u == null) {
      return KvScreen(
        header: KvHeader(title: ' ', onBack: () => context.kvBack(MasterOperatorPaths.opObjects)),
        children: const [KvSkeleton.card(height: 300), KvSkeleton.card(height: 240)],
      );
    }
    final TelemetryPeriod period = TelemetryPeriod.values[_period];
    final TelemetrySeries? s = ref.watch(seriesProvider((unitId: u.id, key: 'vib1x', period: period))).value;
    final Reading? v = u.readings['vib1x'];
    final String time = KvFormat.time(ref.watch(clockProvider).now());
    final bool running = u.mode == 'running';
    Widget tile(String key) => u.readings[key] == null ? const SizedBox.shrink() : MoReadingTile(unitId: u.id, reading: u.readings[key]!);
    return KvScreen(
      header: KvHeader(
        title: u.code,
        subtitle: KvFormat.typo('${u.statusLabel} · ${u.modelShort}'),
        status: u.kvStatus,
        onBack: () => context.kvBack(MasterOperatorPaths.opObjects),
        onMore: u.id == 'N-101' ? () => _menu(context, u) : null,
      ),
      foot: KvButton(
        'Сообщить о неисправности',
        icon: KvIcons.megaphone,
        onPressed: () => context.kvUp(MasterOperatorPaths.opReportFor(u.id)),
      ),
      children: [
        MoLiveLine('${running ? 'В работе' : u.modeLabel} · только просмотр · $time'),
        KvCard(
          title: 'Вибрация 1X',
          trailing: v == null ? null : KvChip(KvFormat.withUnit(v.value, v.unit, v.digits), status: v.kvStatus),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              KvSegment(items: _periods, index: _period, onChanged: (int i) => setState(() => _period = i)),
              const SizedBox(height: KvSpace.s3),
              RepaintBoundary(
                child: s == null
                    ? const SizedBox(height: 128 + 46)
                    : KvAreaChart(key: ValueKey<TelemetryPeriod>(period), data: s.chart, height: 128, showBubble: true, legend: true),
              ),
            ],
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MoGridRow(children: [tile('tBearing'), tile('tWinding')]),
            const SizedBox(height: KvSpace.s3),
            MoGridRow(children: [tile('pressOut'), tile('current')]),
          ],
        ),
        const KvNote(
          icon: KvIcons.info,
          text: 'Осмотр и диагностику выполняют инженер и мастер. Заметили течь, шум или запах - сообщите мастеру.',
        ),
      ],
    );
  }

  Future<void> _menu(BuildContext context, Equipment u) {
    final BuildContext screen = context;
    final List<FaultReport> reports = ref.read(faultReportsProvider(null)).value ?? const <FaultReport>[];
    final FaultReport? last = reports.where((FaultReport r) => r.unitId == u.id).firstOrNull;
    return showKvSheet<void>(
      context,
      builder: (BuildContext sheet) {
        void close(VoidCallback then) {
          Navigator.of(sheet).pop();
          then();
        }

        return KvSheet(
          title: u.code,
          children: [
            KvList(
              children: [
                KvRow(
                  icon: KvIcons.megaphone,
                  title: 'Сообщить о неисправности',
                  subtitle: 'Мастер получит сразу',
                  onTap: () => close(() => screen.kvUp(MasterOperatorPaths.opReportFor(u.id))),
                ),
                KvRow(
                  icon: KvIcons.history,
                  title: KvFormat.typo('Сообщения по ${u.code}'),
                  subtitle: last == null ? 'Сообщений нет' : KvFormat.typo('${last.id} · ${last.statusLabel.toLowerCase()}'),
                  onTap: last == null ? null : () => close(() => screen.kvPush(MasterOperatorPaths.reportStatus(last.id))),
                ),
                KvRow(
                  icon: KvIcons.lock,
                  iconStatus: KvStatus.unk,
                  title: 'Осмотр агрегата',
                  subtitle: 'Доступно инженеру и мастеру',
                  onTap: () => close(
                    () => showKvToast(
                      screen,
                      kind: KvToastKind.info,
                      icon: KvIcons.lock,
                      title: 'Осмотр недоступен',
                      text: 'Доступно инженеру и мастеру. Вы можете сообщить о неисправности.',
                    ),
                  ),
                ),
                KvRow(
                  icon: KvIcons.chat,
                  title: 'Спросить ассистента',
                  subtitle: 'Почему статус «${u.statusLabel}»',
                  onTap: () => close(() => moGoTab(screen, MasterOperatorPaths.opAssistant)),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Агрегат на ремонте для оператора: запрет запуска, кто и по чему запланировал ремонт, показания на момент
/// остановки и ход работ по сообщению оператора.
class OpRepairScreen extends ConsumerWidget {
  /// Создаёт экран агрегата [unitId].
  const OpRepairScreen({super.key, required this.unitId});

  /// Агрегат.
  final String unitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Equipment? u = ref.watch(unitProvider(unitId)).value;
    if (u == null) {
      return KvScreen(
        header: KvHeader(title: ' ', onBack: () => context.kvBack(MasterOperatorPaths.opObjects)),
        children: const [KvSkeleton.card(height: 230), KvSkeleton.card(height: 150)],
      );
    }
    final List<Finding> findings = ref.watch(findingsProvider((status: null, unitId: u.id))).value ?? const <Finding>[];
    final List<PlanItem> plan = ref.watch(planProvider).value ?? const <PlanItem>[];
    final List<FaultReport> reports = ref.watch(faultReportsProvider(null)).value ?? const <FaultReport>[];
    final List<HistoryEvent> history = ref.watch(unitHistoryProvider(u.id)).value ?? const <HistoryEvent>[];
    final Finding? f = findings.where((Finding x) => x.status == 'planned' || x.status == 'confirmed').firstOrNull;
    final PlanItem? work = plan.where((PlanItem p) => p.unitId == u.id && p.status == 'planned').firstOrNull;
    final FaultReport? report = reports.where((FaultReport r) => r.unitId == u.id && r.status != 'closed').firstOrNull;
    final String stop = history.where((HistoryEvent h) => h.title == 'Аварийная остановка').firstOrNull?.time ?? '06:44';
    final String when = work == null ? '' : '${moDay(work.date)}, ${work.time}';
    Widget tile(String key, {KvStatus? status}) => u.readings[key] == null
        ? const SizedBox.shrink()
        : MoReadingTile(unitId: u.id, reading: u.readings[key]!, status: status, spark: false);
    return KvScreen(
      header: KvHeader(
        title: u.code,
        subtitle: KvFormat.typo('${u.statusLabel} · ${u.modelShort}'),
        status: u.kvStatus,
        onBack: () => context.kvBack(MasterOperatorPaths.opObjects),
      ),
      children: [
        KvCard(
          padding: EdgeInsets.zero,
          child: MoResult(
            status: true,
            icon: KvIcons.wrench,
            iconSize: 34,
            tone: KvStatus.info,
            title: u.statusLabel,
            text:
                '${work?.work.replaceFirst('торцевого ', '') ?? 'Ремонт'}${when.isEmpty ? '' : ' $when'}. Не запускайте агрегат до окончания работ.',
          ),
        ),
        KvCard(
          child: KvKeyValues([
            if (f != null && f.confirmedBy != null)
              (moVerb(f.confirmedBy!, 'Запланировала', 'Запланировал'), KvFormat.typo('${f.confirmedBy} · ${f.confirmedAt ?? ''}')),
            if (work != null) ('Исполнитель', work.who),
            if (f != null) ('Основание', KvFormat.typo('${f.id}${report == null ? '' : ' · ваше ${report.id}'}')),
          ]),
        ),
        MoLabel('Показания на момент остановки $stop'),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MoGridRow(children: [tile('tWinding'), tile('tBearing')]),
            const SizedBox(height: KvSpace.s3),
            MoGridRow(
              children: [
                tile('vib1x'),
                tile('pressOut', status: KvStatus.unk),
              ],
            ),
          ],
        ),
        if (report != null)
          KvList(
            children: [
              KvRow(
                icon: KvIcons.history,
                title: KvFormat.typo('Ход работ по ${report.id}'),
                subtitle: KvFormat.typo(
                  '${report.timeline.length} ${KvFormat.plural(report.timeline.length, 'этап', 'этапа', 'этапов')} · последний ${report.timeline.isEmpty ? report.time : report.timeline.last.time}',
                ),
                onTap: () => context.kvPush(MasterOperatorPaths.reportStatus(report.id)),
              ),
            ],
          ),
      ],
    );
  }
}
