import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/navigation/kv_page.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import '../shared/bridges.dart';
import 'diagnostics_screen.dart';
import 'inspect_catalog.dart';
import 'inspect_providers.dart';
import 'scanner_screen.dart';
import 'widgets/inspect_camera.dart';

/// Разбор правила (b-rule, b-rule-r04, b-rule-r08, b-rule-s01, b-rule-s04, b-rule-r11): вывод и уровень, условия
/// с отметками выполнено / не выполнено / нет данных, кадр и показание-основание, рекомендация и действие.
class RuleScreen extends ConsumerWidget {
  /// Создаёт разбор правила [ruleId] по агрегату [unitId].
  const RuleScreen({super.key, required this.ruleId, this.unitId = kInspectDefaultUnit});

  /// Правило: «R01».
  final String ruleId;

  /// Агрегат.
  final String unitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final Equipment? unit = ref.watch(unitProvider(unitId)).value;
    final RuleDef? rule = (ref.watch(rulesProvider).value ?? const <RuleDef>[]).where((RuleDef r) => r.id == ruleId).firstOrNull;
    final DiagnosisResult? fired = (ref.watch(diagnosisProvider(unitId)).value ?? const <DiagnosisResult>[]).where((DiagnosisResult d) => d.ruleId == ruleId).firstOrNull;
    final RuleCheck? check = ref.watch(ruleCheckProvider((unitId: unitId, ruleId: ruleId))).value;
    final Map<int, String> levels = ref.watch(severityLabelsProvider).value ?? const <int, String>{};
    final KvSeverity sev = fired == null ? KvSeverity.check : KvSeverity.of(fired, rule);
    final bool bad = fired?.status == 'bad';
    final String code = unit?.code ?? unitId;
    final bool fix = fired?.result == 'match' && check?.frameLabel != null;
    Widget foot;
    if (fix) {
      final String label = check!.frameLabel!;
      foot = KvButton('Зафиксировать дефект', icon: KvIcons.flag, onPressed: () => context.kvPush(EngineerInspectPaths.defectFor(unitId, label: label)));
    } else {
      foot = KvButton(
        'Добавить в осмотр',
        icon: KvIcons.plus,
        kind: KvButtonKind.tonal,
        onPressed: () async {
          final Inspection? ins = await ref.read(inspectionRepositoryProvider).activeInspection(unitId);
          if (!context.mounted) {
            return;
          }
          showKvSnack(
            context,
            text: KvFormat.typo('Добавлено в осмотр ${ins?.id ?? code} · $ruleId'),
            actionLabel: 'Маршрут',
            onAction: () => context.kvPush(EngineerInspectPaths.routeFor(unitId)),
          );
        },
      );
    }
    return KvScreen(
      header: KvHeader(
        title: 'Правило $ruleId',
        subtitle: '${sev.label} · $code',
        status: sev.status,
        onBack: () => context.kvBack(EngineerInspectPaths.diagnosticsFor(unitId)),
      ),
      foot: foot,
      children: [
        if (rule == null || check == null) ...[
          const KvSkeleton.card(height: 140),
          const KvSkeleton.card(height: 260),
        ] else ...[
          KvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(rule.title, style: t.h2),
                const SizedBox(height: KvSpace.s3),
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: bad ? c.badBg : c.warnBg, borderRadius: BorderRadius.circular(16)),
                      child: KvIcon(bad ? KvIcons.alert : KvIcons.alertCircle, color: bad ? c.bad : c.warn),
                    ),
                    const SizedBox(width: KvSpace.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(check.verdict, style: t.bodyM),
                          Text(KvFormat.typo(check.count), style: t.caption),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: KvSpace.s3),
                Text('Уровень правила · ${levels[rule.severity] ?? ''}', style: t.caption),
              ],
            ),
          ),
          KvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Условия правила', style: t.label),
                for (int i = 0; i < check.conditions.length; i++) _Condition(condition: check.conditions[i], rule: rule, first: i == 0),
              ],
            ),
          ),
          if (check.frameLabel != null || check.chartKey != null)
            _Evidence(check: check, unitId: unitId)
          else if (unit != null)
            _RunCard(unit: unit),
          KvNote(
            tone: bad ? KvStatus.bad : KvStatus.warn,
            icon: KvIcons.wrench,
            child: Text.rich(
              TextSpan(children: [const TextSpan(text: 'Рекомендация.', style: TextStyle(fontWeight: FontWeight.w600)), TextSpan(text: ' ${rule.recommendation}')]),
            ),
          ),
          const KvNote(
            icon: KvIcons.hand,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'Система показывает признаки и основания. '),
                  TextSpan(text: 'Решение принимает инженер.', style: TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Условие правила (.b-cond): кружок состояния, источник с отметкой, условие и что видно сейчас.
class _Condition extends StatelessWidget {
  const _Condition({required this.condition, required this.rule, required this.first});

  final RuleCondition condition;
  final RuleDef rule;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final RuleCondition k = condition;
    final (Color bg, Color fg, KvIcons icon) = switch (k.state) {
      'met' => (c.btnPrimary, c.onBrand, KvIcons.check),
      'missing' => (c.warnBg, c.warn, KvIcons.alertCircle),
      'soon' => (c.warnBg, c.warn, KvIcons.timer),
      _ => (c.surface2, c.text3, KvIcons.minus),
    };
    final String mark = switch (k.state) {
      'not' => ' · не выполнено',
      'missing' => '',
      'soon' => ' · скоро',
      _ => ' · выполнено',
    };
    final String what = k.what.isNotEmpty ? k.what : (k.source == 'camera' ? rule.camera : rule.sensor);
    final TextStyle keyStyle = t.label.copyWith(height: KvTextStyles.normalHeight(12));
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: first ? null : BoxDecoration(border: Border(top: BorderSide(color: c.divider))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: KvIcon(icon, size: 16, color: fg),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    KvIcon(evidenceIcon(k.source), size: 14, color: c.text2),
                    const SizedBox(width: 6),
                    Flexible(child: Text('${k.label}$mark', style: keyStyle)),
                  ],
                ),
                Text(KvFormat.typo(what), style: t.sm.copyWith(fontWeight: FontWeight.w500, height: 1.35)),
                const SizedBox(height: 4),
                Text(KvFormat.typo(k.value), style: t.caption.copyWith(color: k.state == 'missing' ? c.warnText : c.text2)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Основания разбора (.b-evgrid): кадр признака и плитка показания, или график показания за 7 дней.
class _Evidence extends ConsumerWidget {
  const _Evidence({required this.check, required this.unitId});

  final RuleCheck check;
  final String unitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final TelemetrySeries? s = check.chartKey == null
        ? null
        : ref.watch(seriesProvider((unitId: unitId, key: check.chartKey!, period: TelemetryPeriod.week))).value;
    if (check.frameLabel == null) {
      if (s == null) {
        return const KvSkeleton.card(height: 170);
      }
      return KvCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${s.label} · 7 дн', style: context.kvText.label),
            KvAreaChart(data: s.chart, height: 110, showBubble: true),
          ],
        ),
      );
    }
    final Detection? det = (ref.watch(detectionsProvider(unitId)).value ?? const <Detection>[]).where((Detection d) => d.label == check.frameLabel).firstOrNull;
    final KvCamView? view = det == null
        ? null
        : KvCamView(k: 2.6, cx: det.x / 100 + det.w / 200, cy: det.y / 100 + det.h / 200, elementAspect: 1);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double col = (box.maxWidth - KvSpace.s3) / 2;
        return SizedBox(
          height: col,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: col,
                child: view == null
                    ? const KvSkeleton.card()
                    : CamFrame(view: view, aspectRatio: 1, boxes: [arBoxOf(view, detRect(det!), kind: KvArKind.defect)], tag: check.frameTime),
              ),
              const SizedBox(width: KvSpace.s3),
              SizedBox(
                width: col,
                child: s == null
                    ? const KvSkeleton.card()
                    : KvTile(
                        label: s.label,
                        value: KvFormat.num(s.last, s.digits),
                        unit: s.unit,
                        status: KvStatus.ofValue(s.last, s.warn, s.alarm),
                        spark: s.chart,
                        sparkHeight: 48,
                        stretch: true,
                        onTap: () => context.go(
                          EngineerInspectPaths.cardCharts(unitId),
                          extra: const KvNavExtra(transition: KvTransition.push),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Наработка до межремонтного интервала (правило по моточасам без кадра и графика).
class _RunCard extends StatelessWidget {
  const _RunCard({required this.unit});

  final Equipment unit;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    final double at = unit.nextTo.atHours;
    return KvCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Text('Наработка, моточасы', style: t.label)),
              const SizedBox(width: KvSpace.s3),
              Text(KvFormat.typo('${KvFormat.num(unit.runHours)} из ${KvFormat.num(at)} ч'), style: t.sm),
            ],
          ),
          const SizedBox(height: KvSpace.s3),
          KvProgress(value: at == 0 ? 0 : (unit.runHours / at).clamp(0, 1), status: KvStatus.warn),
        ],
      ),
    );
  }
}

/// Признак кадра для врезки разбора правила: класс признака по подписи рамки.
DefectClass? defectClassOf(RuleCheck check) => check.frameLabel == null ? null : kDefectClasses[check.frameLabel];
