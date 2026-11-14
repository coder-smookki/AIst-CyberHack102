import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/navigation/kv_page.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import '../shared/bridges.dart';

/// Пути вкладок карточки агрегата по индексу сегмента: Сейчас, Графики, История.
String cardTabPath(String unitId, int index) => switch (index) {
      1 => EngineerInspectPaths.cardCharts(unitId),
      2 => EngineerInspectPaths.cardHistory(unitId),
      _ => EngineerInspectPaths.card(unitId),
    };

/// Сегмент вкладок карточки: Сейчас / Графики / История; смена пункта - переход seg без движения шапки.
class CardTabs extends StatelessWidget {
  /// Создаёт сегмент для агрегата [unitId] с выбранным пунктом [index].
  const CardTabs({super.key, required this.unitId, required this.index, this.fromSegment});

  /// Агрегат.
  final String unitId;

  /// Выбранный пункт.
  final int index;

  /// Пункт предыдущего экрана, откуда едет плашка.
  final int? fromSegment;

  @override
  Widget build(BuildContext context) {
    return KvSegment(
      items: const ['Сейчас', 'Графики', 'История'],
      index: index,
      animateFrom: fromSegment,
      onBackground: true,
      onChanged: (int i) => context.kvSeg(cardTabPath(unitId, i), fromSegment: index),
    );
  }
}

/// Шапка карточки агрегата: обозначение, статус и модель, «назад» к объектам, меню карточки.
class CardHeader extends StatelessWidget {
  /// Создаёт шапку для агрегата [unit].
  const CardHeader({super.key, required this.unit});

  /// Агрегат.
  final Equipment unit;

  @override
  Widget build(BuildContext context) {
    return KvHeader(
      title: unit.code,
      subtitle: '${unit.statusLabel} · ${unit.modelShort}',
      status: unit.kvStatus,
      onBack: () => context.kvBack(EngineerInspectPaths.objects),
      onMore: () => showCardMenu(context, unit),
    );
  }
}

/// Меню карточки (лист card-menu): маршрут осмотра, дефект вручную, документы, отчёты PDF и Excel.
Future<void> showCardMenu(BuildContext context, Equipment unit) {
  final BuildContext screen = context;
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => Consumer(
      builder: (BuildContext sheet, WidgetRef ref, Widget? child) {
        Future<void> report(String format) async {
          Navigator.of(sheet).pop();
          await ref.read(reportRepositoryProvider).unitReport(unit.id, format);
          if (!screen.mounted) {
            return;
          }
          final DateTime now = ref.read(clockProvider).now();
          final bool pdf = format == 'pdf';
          showKvToast(
            screen,
            kind: KvToastKind.ok,
            icon: pdf ? KvIcons.filePdf : KvIcons.fileXls,
            title: pdf ? 'Отчёт PDF сформирован' : 'Файл Excel сформирован',
            text: KvFormat.typo(pdf
                ? '${unit.code} · ${KvFormat.date(now)} ${KvFormat.time(now)} · сохранён на устройстве'
                : '${unit.code} · показания 15.10-14.11 · сохранён на устройстве'),
          );
        }

        void open(String path) {
          Navigator.of(sheet).pop();
          screen.kvPush(path);
        }

        return KvSheet(
          title: '${unit.code} · ${unit.modelShort}',
          children: [
            KvList(
              children: [
                KvRow(icon: KvIcons.route, title: 'Маршрут осмотра', subtitle: '${unit.nodes.length + 1} узлов по приоритету', onTap: () => open(EngineerInspectPaths.routeFor(unit.id))),
                if (unit.id == 'N-101')
                  KvRow(
                    icon: KvIcons.flag,
                    title: 'Добавить дефект вручную',
                    subtitle: 'Если камера не выделила признак',
                    onTap: () => open(EngineerInspectPaths.defectManualFor(unit.id)),
                  ),
                KvRow(
                  icon: KvIcons.file,
                  title: 'Паспорт и документы',
                  subtitle: '${unit.documents.length} PDF · доступны без сети',
                  onTap: () => open(EngineerInspectPaths.docsFor(unit.id)),
                ),
                KvRow(icon: KvIcons.filePdf, title: 'Отчёт по агрегату · PDF', subtitle: 'История, находки, наработка', onTap: () => report('pdf')),
                KvRow(icon: KvIcons.fileXls, title: 'Показания · Excel', subtitle: 'Датчики за 30 дней', onTap: () => report('xlsx')),
              ],
            ),
          ],
        );
      },
    ),
  );
}

/// Карточка агрегата, вкладка «Сейчас» (эталон раздела): ресурс и ближайшее ТО, диагностика, четыре плитки
/// показаний со спарклайнами за сутки и кнопка «Начать осмотр».
class CardNowScreen extends ConsumerWidget {
  /// Создаёт экран для агрегата [unitId].
  const CardNowScreen({super.key, required this.unitId, this.fromSegment});

  /// Агрегат: 'N-101', 'AMS-1', 'AMS-2'.
  final String unitId;

  /// Пункт сегмента предыдущего экрана карточки.
  final int? fromSegment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<Equipment> unitValue = ref.watch(unitProvider(unitId));
    final Equipment? unit = unitValue.value;
    if (unit == null) {
      return KvScreen(
        header: KvHeader(title: unitId, onBack: () => context.kvBack(EngineerInspectPaths.objects)),
        children: [
          CardTabs(unitId: unitId, index: 0, fromSegment: fromSegment),
          if (unitValue.hasError)
            KvAsync<Equipment>(value: unitValue, builder: (_, _) => const SizedBox.shrink(), onRetry: () => ref.invalidate(unitProvider(unitId)))
          else ...[
            const KvSkeleton.card(height: 170),
            const KvSkeleton.card(height: 72),
          ],
        ],
      );
    }
    final List<DiagnosisResult> diagnosis = ref.watch(diagnosisProvider(unit.id)).value ?? const <DiagnosisResult>[];
    final List<RuleDef> rules = ref.watch(rulesProvider).value ?? const <RuleDef>[];
    final List<Finding> findings = ref.watch(findingsProvider((status: null, unitId: unit.id))).value ?? const <Finding>[];
    final List<HistoryEvent> history = ref.watch(unitHistoryProvider(unit.id)).value ?? const <HistoryEvent>[];
    final bool segSwap = KvNavExtra.of(GoRouterState.of(context))?.transition == KvTransition.seg;

    return KvScreen(
      header: CardHeader(unit: unit),
      stagger: segSwap ? KvStagger.seg : KvStagger.appear,
      staggerSkip: segSwap ? 1 : 0,
      foot: KvButton(
        unit.inRepair ? 'Осмотр перед ремонтом' : 'Начать осмотр',
        icon: KvIcons.scan,
        onPressed: () => context.kvUp(EngineerInspectPaths.scannerFor(unit.id)),
      ),
      children: [
        CardTabs(unitId: unit.id, index: 0, fromSegment: fromSegment),
        _ResourceCard(unit: unit, history: history),
        _DiagnosisRow(unit: unit, diagnosis: diagnosis, rules: rules, findings: findings, history: history),
        _ReadingTiles(unit: unit),
      ],
    );
  }
}

/// Карточка ресурса (.res-card): остаток часов крупно, норма, полоса и ближайшее ТО.
class _ResourceCard extends StatelessWidget {
  const _ResourceCard({required this.unit, required this.history});

  final Equipment unit;
  final List<HistoryEvent> history;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool narrow = MediaQuery.sizeOf(context).width <= 370;
    final Resource r = unit.resource;
    final TextStyle info = t.caption.copyWith(height: 1.35);
    final TextStyle toStyle = t.caption.copyWith(height: KvTextStyles.normalHeight(13));
    final TextStyle strong = toStyle.copyWith(color: c.warnText, fontWeight: FontWeight.w600);
    final Widget to = unit.inRepair
        ? Text.rich(
            TextSpan(children: [
              TextSpan(text: KvFormat.typo('Остановлен ${unit.stoppedAt?.split(' ').last ?? ''} · ')),
              TextSpan(text: KvFormat.typo('ремонт ${unit.nextTo.date.substring(0, 5)}, 08:00'), style: strong),
            ]),
            style: toStyle,
          )
        : Text.rich(
            TextSpan(children: [
              TextSpan(text: KvFormat.typo('${unit.nextTo.code} через ')),
              TextSpan(text: KvFormat.withUnit(unit.nextTo.inHours, 'ч'), style: strong),
              TextSpan(text: ' · ${unit.nextTo.date}'),
            ]),
            style: toStyle,
          );
    return KvCard(
      padding: const EdgeInsets.fromLTRB(KvSpace.s4, KvSpace.s4, KvSpace.s4, KvSpace.s4 - 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(KvFormat.num(r.left), style: t.numXl.copyWith(color: c.brand, fontSize: narrow ? 38 : 44)),
                  const SizedBox(width: 6),
                  Text('ч', style: t.unit.copyWith(color: c.brand, fontSize: 22, fontWeight: FontWeight.w300)),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.label, style: t.sm.copyWith(fontWeight: FontWeight.w500, height: 1.35)),
                    Text(KvFormat.typo('${KvFormat.num(r.used)} из ${KvFormat.num(r.total)} ч наработки'), style: info),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          KvProgress(value: r.fraction, status: KvStatus.parse(r.status)),
          const SizedBox(height: 10),
          Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.only(top: 10),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.divider))),
            child: Row(
              children: [
                KvIcon(unit.inRepair ? KvIcons.wrench : KvIcons.calendar, size: 18, color: c.warn),
                const SizedBox(width: KvSpace.s2),
                Expanded(child: to),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка диагностики под карточкой ресурса: число критичных правил и состав.
class _DiagnosisRow extends StatelessWidget {
  const _DiagnosisRow({required this.unit, required this.diagnosis, required this.rules, required this.findings, required this.history});

  final Equipment unit;
  final List<DiagnosisResult> diagnosis;
  final List<RuleDef> rules;
  final List<Finding> findings;
  final List<HistoryEvent> history;

  @override
  Widget build(BuildContext context) {
    String title = 'Диагностика';
    String subtitle;
    KvStatus? status;
    if (diagnosis.isNotEmpty) {
      final Map<KvSeverity, int> n = {for (final KvSeverity s in KvSeverity.values) s: 0};
      for (final DiagnosisResult d in diagnosis) {
        final KvSeverity s = KvSeverity.of(d, rules.where((RuleDef r) => r.id == d.ruleId).firstOrNull);
        n[s] = n[s]! + 1;
      }
      final int crit = n[KvSeverity.critical]!;
      title = crit > 0 ? 'Диагностика: $crit критично' : 'Диагностика';
      status = crit > 0 ? KvStatus.bad : KvStatus.warn;
      final int count = diagnosis.length;
      subtitle = [
        '$count ${KvFormat.plural(count, 'правило', 'правила', 'правил')}',
        if (n[KvSeverity.planned]! > 0) '${n[KvSeverity.planned]} планово',
        if (n[KvSeverity.check]! > 0) '${n[KvSeverity.check]} проверить',
      ].join(' · ');
    } else {
      final Finding? critical = findings.where((Finding f) => f.severity >= 3 && f.status != 'closed' && f.status != 'rejected').firstOrNull;
      if (critical != null) {
        title = 'Диагностика: 1 критично';
        status = KvStatus.bad;
        final HistoryEvent? stop = history.where((HistoryEvent e) => e.title == 'Аварийная остановка').firstOrNull;
        final String? rule = stop == null ? null : RegExp(r'[RS]\d{2}').firstMatch(stop.text)?.group(0);
        subtitle = '${critical.ruleId} · ${critical.id}${stop == null ? '' : ', остановка по ${rule ?? ''} в ${stop.time}'}';
      } else {
        subtitle = 'Признаков по ${rules.isEmpty ? 18 : rules.length} правилам не выявлено';
      }
    }
    return KvList(
      children: [
        KvRow(
          icon: KvIcons.activity,
          iconStatus: status,
          title: title,
          subtitle: KvFormat.typo(subtitle),
          onTap: () => context.kvPush(EngineerInspectPaths.diagnosticsFor(unit.id)),
        ),
      ],
    );
  }
}

/// Четыре плитки показаний со спарклайнами за сутки; касание открывает графики.
class _ReadingTiles extends ConsumerWidget {
  const _ReadingTiles({required this.unit});

  final Equipment unit;

  static const List<String> _keys = ['vib1x', 'tBearing', 'tWinding', 'pressOut'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Map<String, Reading> readings = ref.watch(readingsProvider(unit.id)).value ?? unit.readings;
    final List<Widget> tiles = [
      for (final String key in _keys)
        if (readings[key] != null) _tile(context, ref, readings[key]!),
    ];
    return Column(
      children: [
        for (int i = 0; i < tiles.length; i += 2) ...[
          if (i > 0) const SizedBox(height: KvSpace.s3),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: tiles[i]),
                const SizedBox(width: KvSpace.s3),
                Expanded(child: i + 1 < tiles.length ? tiles[i + 1] : const SizedBox.shrink()),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _tile(BuildContext context, WidgetRef ref, Reading r) {
    final TelemetrySeries? s = ref.watch(seriesProvider((unitId: unit.id, key: r.key, period: TelemetryPeriod.day))).value;
    final bool idle = unit.inRepair && (r.key == 'pressOut' || r.key == 'current');
    return KvTile(
      label: r.short,
      value: KvFormat.num(r.value, r.digits),
      unit: r.unit,
      status: idle ? KvStatus.unk : r.kvStatus,
      spark: s?.chart,
      onTap: () => context.replace(EngineerInspectPaths.cardCharts(unit.id), extra: const KvNavExtra(transition: KvTransition.fade, fromSegment: 0)),
    );
  }
}
