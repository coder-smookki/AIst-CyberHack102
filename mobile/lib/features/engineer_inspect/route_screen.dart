import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'inspect_providers.dart';

/// Причина места узла в маршруте: значок, цвет и подпись легенды.
enum RouteWhy {
  /// Датчики и правила.
  sensor(KvIcons.activity, 'датчики и правила'),

  /// Прошлая находка.
  finding(KvIcons.flag, 'прошлая находка'),

  /// Ресурс на исходе.
  resource(KvIcons.timer, 'ресурс'),

  /// Регламент.
  routine(KvIcons.calendar, 'регламент');

  const RouteWhy(this.icon, this.legend);

  /// Значок 14.
  final KvIcons icon;

  /// Подпись в легенде.
  final String legend;

  /// Причина словами для блока «Сначала проверьте»: «Прошлая находка», «Датчики», «Ресурс», «План».
  String get title => switch (this) {
        RouteWhy.sensor => 'Датчики',
        RouteWhy.finding => 'Прошлая находка',
        RouteWhy.resource => 'Ресурс',
        RouteWhy.routine => 'План',
      };

  /// Причина по коду сервера.
  static RouteWhy of(String code) => RouteWhy.values.where((RouteWhy w) => w.name == code).firstOrNull ?? RouteWhy.routine;

  /// Цвет подписи (.b-why.sensor и т. д.).
  Color color(KvColors c) => switch (this) {
        RouteWhy.sensor => c.warnText,
        RouteWhy.finding => c.bad,
        RouteWhy.resource => c.brand,
        RouteWhy.routine => c.text3,
      };
}

/// Маршрут осмотра (b-route): следующий узел крупно, оставшиеся и осмотренные узлы с причиной приоритета
/// и итогом, легенда причин и «Продолжить осмотр».
class RouteScreen extends ConsumerWidget {
  /// Создаёт маршрут агрегата [unitId].
  const RouteScreen({super.key, this.unitId = kInspectDefaultUnit});

  /// Агрегат.
  final String unitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Equipment? unit = ref.watch(unitProvider(unitId)).value;
    final AsyncValue<List<RouteStep>> value = ref.watch(routeProvider(unitId));
    final List<RouteStep> route = value.value ?? const <RouteStep>[];
    final RouteStep? next = route.next;
    final List<RouteStep> left = route.where((RouteStep s) => s.result == null).toList();
    final List<RouteStep> done = route.where((RouteStep s) => s.result != null && s.result != 'next').toList();
    final String scanner = EngineerInspectPaths.scannerFor(unitId);
    return KvScreen(
      header: KvHeader(
        title: 'Маршрут осмотра',
        subtitle: KvFormat.typo('${unit?.code ?? unitId} · осмотрено ${done.length} из ${route.length}'),
        status: KvStatus.info,
        onBack: () => context.kvBack(scanner),
      ),
      foot: KvButton('Продолжить осмотр', icon: KvIcons.scan, onPressed: () => context.kvBack(scanner)),
      children: [
        if (!value.hasValue) ...[const KvSkeleton.card(height: 130), const KvSkeleton.card(height: 200)],
        if (next != null) _NextCard(step: next, index: route.indexOf(next) + 1, total: route.length, unitId: unitId),
        if (left.isNotEmpty) ...[
          KvSectionLabel('Осталось · ${left.length}'),
          KvList(dividerIndent: 60, children: [for (final RouteStep s in left) _StepRow(step: s)]),
        ],
        if (done.isNotEmpty) ...[
          KvSectionLabel('Осмотрено · ${done.length}'),
          KvList(dividerIndent: 60, children: [for (final RouteStep s in done) _StepRow(step: s)]),
        ],
        if (value.hasValue) const _Legend(),
      ],
    );
  }
}

/// Подпись причины (.b-why): значок 14 и текст 12 цвета причины.
class RouteWhyLabel extends StatelessWidget {
  /// Создаёт подпись причины [why] с текстом [text].
  const RouteWhyLabel({super.key, required this.why, required this.text, this.height});

  /// Причина.
  final RouteWhy why;

  /// Текст подписи.
  final String text;

  /// Межстрочный множитель: в строках списка 1,35, в легенде 1,33, в карточке «Далее» - normal.
  final double? height;

  @override
  Widget build(BuildContext context) {
    final Color color = why.color(context.kv);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        KvIcon(why.icon, size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(KvFormat.typo(text), style: context.kvText.label.copyWith(color: color, height: height ?? KvTextStyles.normalHeight(12))),
        ),
      ],
    );
  }
}

/// Карточка следующего узла (.b-nextcard): рамка цвета бренда, оценка времени и переход к осмотру узла.
class _NextCard extends StatelessWidget {
  const _NextCard({required this.step, required this.index, required this.total, required this.unitId});

  final RouteStep step;
  final int index;
  final int total;
  final String unitId;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool gauge = step.nodeId == 'gauge';
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    return KvPressable(
      onTap: () => gauge ? context.kvUp(EngineerInspectPaths.scanGaugeFor(unitId)) : context.kvUp(EngineerInspectPaths.scannerFor(unitId)),
      borderRadius: radius,
      pressedScale: 0.985,
      semanticLabel: step.name,
      child: Container(
        padding: const EdgeInsets.all(KvSpace.s4),
        decoration: BoxDecoration(color: c.surface, borderRadius: radius, border: Border.all(color: c.brand, width: 1.5), boxShadow: c.shadow2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: Text('Далее · узел $index из $total', style: t.label.copyWith(color: c.brand))),
                const SizedBox(width: KvSpace.s3),
                const KvChip('~2 мин', status: KvStatus.info, dot: false),
              ],
            ),
            const SizedBox(height: KvSpace.s3),
            Row(
              children: [
                KvRowIcon(icon: gauge ? KvIcons.gauge : KvIcons.box),
                const SizedBox(width: KvSpace.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(step.name, style: t.bodyM),
                      RouteWhyLabel(why: RouteWhy.of(step.why), text: step.reason),
                    ],
                  ),
                ),
                const SizedBox(width: KvSpace.s2),
                KvIcon(KvIcons.chevronRight, size: 20, color: c.text3),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка узла маршрута (.b-route .row): номер или итог в круге, название, причина и итог осмотра.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});

  final RouteStep step;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final String? r = step.result;
    final (Color bg, Color fg) = switch (r) {
      'ok' => (c.okBg, c.ok),
      'warn' => (c.warnBg, c.warn),
      'bad' => (c.badBg, c.bad),
      'next' => (c.btnPrimary, c.onBrand),
      _ => (c.surface2, c.text2),
    };
    final bool checked = r != null && r != 'next';
    return KvRow(
      title: step.name,
      minHeight: 64,
      leading: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: checked
            ? KvIcon(r == 'ok' ? KvIcons.check : KvIcons.alert, size: 16, color: fg)
            : Text('${step.n}', style: t.caption.copyWith(fontWeight: FontWeight.w600, color: fg, height: 1)),
      ),
      subtitleWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          RouteWhyLabel(why: RouteWhy.of(step.why), text: step.reason, height: 1.35),
          if (step.note.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(KvFormat.typo('Итог: ${step.note}'), style: t.caption.copyWith(height: 1.35)),
          ],
        ],
      ),
    );
  }
}

/// Легенда причин (.b-legend): четыре подписи с номером приоритета.
class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (int i = 0; i < RouteWhy.values.length; i++) RouteWhyLabel(why: RouteWhy.values[i], text: '${i + 1}. ${RouteWhy.values[i].legend}', height: 1.33),
      ],
    );
  }
}
