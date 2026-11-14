import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/navigation/kv_page.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import '../shared/bridges.dart';
import 'card_now_screen.dart';
import 'inspect_catalog.dart';

/// Периоды графика по пунктам сегмента: 1 ч, 24 ч, 7 дн, 30 дн.
const List<TelemetryPeriod> _periods = [TelemetryPeriod.hour, TelemetryPeriod.day, TelemetryPeriod.week, TelemetryPeriod.month];

/// Подписи периодов.
const List<String> _periodLabels = ['1 ч', '24 ч', '7 дн', '30 дн'];

/// Карточка агрегата, вкладка «Графики» (card-charts): основной график показания с периодом, пиком и уставками,
/// две плитки других показаний (касание меняет их местами с основным графиком) и пояснение со ссылкой на диагностику.
class CardChartsScreen extends ConsumerStatefulWidget {
  /// Создаёт вкладку для агрегата [unitId].
  const CardChartsScreen({super.key, required this.unitId, this.fromSegment});

  /// Агрегат.
  final String unitId;

  /// Пункт сегмента предыдущего экрана карточки.
  final int? fromSegment;

  @override
  ConsumerState<CardChartsScreen> createState() => _CardChartsScreenState();
}

class _CardChartsScreenState extends ConsumerState<CardChartsScreen> {
  String _main = 'vib1x';
  List<String> _side = const ['tBearing', 'pressOut'];
  int _period = 2;

  void _swap(int i) {
    setState(() {
      final String was = _main;
      _main = _side[i];
      _side = [for (int k = 0; k < _side.length; k++) k == i ? was : _side[k]];
    });
  }

  @override
  Widget build(BuildContext context) {
    final String unitId = widget.unitId;
    final Equipment? unit = ref.watch(unitProvider(unitId)).value;
    final bool segSwap = KvNavExtra.of(GoRouterState.of(context))?.transition == KvTransition.seg;
    final String? note = kChartNotes[_main];
    return KvScreen(
      header: unit == null ? KvHeader(title: unitId, onBack: () => context.kvBack(EngineerInspectPaths.objects)) : CardHeader(unit: unit),
      stagger: segSwap ? KvStagger.seg : KvStagger.appear,
      staggerSkip: segSwap ? 1 : 0,
      children: [
        CardTabs(unitId: unitId, index: 1, fromSegment: widget.fromSegment),
        _MainChart(unitId: unitId, keyName: _main, period: _period, onPeriod: (int i) => setState(() => _period = i)),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < _side.length; i++) ...[
                if (i > 0) const SizedBox(width: KvSpace.s3),
                Expanded(child: _SwapTile(unitId: unitId, keyName: _side[i], onTap: () => _swap(i))),
              ],
            ],
          ),
        ),
        if (note != null)
          AnimatedSwitcher(
            duration: context.kvReduceMotion ? Duration.zero : KvMotion.std,
            child: KvNote(
              key: ValueKey<String>(_main),
              text: KvFormat.typo(note),
              onTap: () => context.kvPush(EngineerInspectPaths.diagnosticsFor(unitId)),
            ),
          ),
      ],
    );
  }
}

/// Основной график (.b-mc): подпись и последнее значение, чип пика, сегмент периода и график по уставкам.
class _MainChart extends ConsumerWidget {
  const _MainChart({required this.unitId, required this.keyName, required this.period, required this.onPeriod});

  final String unitId;
  final String keyName;
  final int period;
  final ValueChanged<int> onPeriod;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TelemetrySeries? s = ref.watch(seriesProvider((unitId: unitId, key: keyName, period: _periods[period]))).value;
    final String id = '$keyName-$period';
    return KvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (s == null)
            const KvSkeleton(height: 74)
          else
            _Head(key: ValueKey<String>('head-$id'), series: s),
          const SizedBox(height: KvSpace.s3),
          KvSegment(items: _periodLabels, index: period, onChanged: onPeriod),
          const SizedBox(height: KvSpace.s3 + 10),
          if (s == null)
            const KvSkeleton(height: 220)
          else
            KvAreaChart(key: ValueKey<String>('chart-$id'), data: s.chart, height: 160, showBubble: true, legend: true),
        ],
      ),
    );
  }
}

/// Шапка основного графика (.b-mc-head): подпись, значение с единицей и чип пика с датой.
class _Head extends StatelessWidget {
  const _Head({super.key, required this.series});

  final TelemetrySeries series;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    final TelemetrySeries s = series;
    final KvStatus peak = KvStatus.ofValue(s.peakValue, s.warn, s.alarm);
    final String chip = '${peak == KvStatus.ok ? 'макс' : 'пик'} ${KvFormat.num(s.peakValue, s.digits)} · ${s.peakLabel}';
    final Widget head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.label, style: t.label),
              const SizedBox(height: 6),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: KvFormat.num(s.last, s.digits), style: t.numXl),
                    const WidgetSpan(alignment: PlaceholderAlignment.baseline, baseline: TextBaseline.alphabetic, child: SizedBox(width: 6)),
                    TextSpan(text: s.unit, style: t.unit.copyWith(fontSize: 15)),
                  ],
                ),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
              ),
            ],
          ),
        ),
        const SizedBox(width: KvSpace.s2),
        KvChip(chip, status: peak == KvStatus.ok ? KvStatus.info : peak, dot: false),
      ],
    );
    if (context.kvReduceMotion) {
      return head;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: KvMotion.ease,
      child: head,
      builder: (BuildContext context, double v, Widget? child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 6 * (1 - v)), child: child)),
    );
  }
}

/// Плитка показания под графиком: касание выводит показание на основной график.
class _SwapTile extends ConsumerWidget {
  const _SwapTile({required this.unitId, required this.keyName, required this.onTap});

  final String unitId;
  final String keyName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Reading? r = (ref.watch(readingsProvider(unitId)).value ?? ref.watch(unitProvider(unitId)).value?.readings)?[keyName];
    final TelemetrySeries? s = ref.watch(seriesProvider((unitId: unitId, key: keyName, period: TelemetryPeriod.day))).value;
    if (r == null) {
      return const KvSkeleton.card(height: 116);
    }
    return KvTile(
      key: ValueKey<String>(keyName),
      label: r.short,
      value: KvFormat.num(r.value, r.digits),
      unit: r.unit,
      status: r.kvStatus,
      spark: s?.chart,
      onTap: onTap,
    );
  }
}
