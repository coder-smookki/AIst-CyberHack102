import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import '../shared/bridges.dart';
import 'inspect_providers.dart';
import 'widgets/inspect_camera.dart';

/// Значок источника основания: камера, датчики, данные, отметка инженера.
KvIcons evidenceIcon(String source) => switch (source) {
      'camera' => KvIcons.camera,
      'sensor' => KvIcons.activity,
      'data' || 'resource' => KvIcons.database,
      _ => KvIcons.user,
    };

/// Первое предложение рекомендации со строчной буквы: «перевести насос в резерв.».
String recommendationLead(String text) {
  final int dot = text.indexOf('.');
  final String first = dot > 0 ? text.substring(0, dot + 1) : text;
  return first.isEmpty ? first : '${first[0].toLowerCase()}${first.substring(1)}';
}

/// Диагностика по правилам (diagnostics): сработавшие правила по шкале «Критично / Планово / Проверить»
/// с основаниями и рекомендацией, фильтр по уровню и строка несработавших правил.
class DiagnosticsScreen extends ConsumerStatefulWidget {
  /// Создаёт диагностику агрегата [unitId].
  const DiagnosticsScreen({super.key, this.unitId = kInspectDefaultUnit});

  /// Агрегат.
  final String unitId;

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  int _filter = 0;

  @override
  Widget build(BuildContext context) {
    final String unitId = widget.unitId;
    final Equipment? unit = ref.watch(unitProvider(unitId)).value;
    final AsyncValue<List<DiagnosisResult>> value = ref.watch(diagnosisProvider(unitId));
    final List<RuleDef> rules = ref.watch(rulesProvider).value ?? const <RuleDef>[];
    final List<({RuleDef rule, RuleCheck check})> rest = ref.watch(restRulesProvider(unitId)).value ?? const <({RuleDef rule, RuleCheck check})>[];
    RuleDef? ruleOf(String id) => rules.where((RuleDef r) => r.id == id).firstOrNull;
    final List<(DiagnosisResult, KvSeverity)> items = [
      for (final DiagnosisResult d in value.value ?? const <DiagnosisResult>[]) (d, KvSeverity.of(d, ruleOf(d.ruleId))),
    ]..sort(((DiagnosisResult, KvSeverity) a, (DiagnosisResult, KvSeverity) b) => a.$2.index.compareTo(b.$2.index));
    int count(KvSeverity s) => items.where(((DiagnosisResult, KvSeverity) e) => e.$2 == s).length;
    final KvSeverity? want = _filter == 0 ? null : KvSeverity.values[_filter - 1];
    final int missing = rest.where((({RuleDef rule, RuleCheck check}) e) => e.check.missing != null).length;
    final KvStatus status = count(KvSeverity.critical) > 0
        ? KvStatus.bad
        : items.isEmpty
            ? KvStatus.ok
            : KvStatus.warn;
    final String code = unit?.code ?? unitId;
    return KvScreen(
      header: KvHeader(
        title: 'Диагностика',
        subtitle: KvFormat.typo(
          '$code · ${rules.length} ${KvFormat.plural(rules.length, 'правило', 'правила', 'правил')}, сработало ${items.length}',
        ),
        status: status,
        onBack: () => context.kvBack(EngineerInspectPaths.card(unitId)),
        onMore: () {
          final DateTime now = ref.read(clockProvider).now();
          showKvToast(
            context,
            kind: KvToastKind.ok,
            icon: KvIcons.filePdf,
            title: 'Диагностика выгружена в PDF',
            text: KvFormat.typo('$code · ${KvFormat.date(now)} ${KvFormat.time(now)} · сохранено на устройстве'),
          );
        },
      ),
      children: [
        KvFilterChips(
          items: [
            KvFilterItem('Все', count: '${items.length}'),
            for (final KvSeverity s in KvSeverity.values) KvFilterItem(s.label, count: '${count(s)}'),
          ],
          selected: _filter,
          onSelected: (int i) => setState(() => _filter = i),
        ),
        if (!value.hasValue) ...[const KvSkeleton.card(height: 230), const KvSkeleton.card(height: 230)],
        for (final (DiagnosisResult d, KvSeverity s) in items)
          if (want == null || s == want)
            _Appear(
              key: ValueKey<String>('diag-${d.ruleId}-$_filter'),
              animate: _filter != 0,
              child: _DiagCard(result: d, severity: s, rule: ruleOf(d.ruleId), unitId: unitId),
            ),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.checkCircle,
              iconStatus: KvStatus.ok,
              title: 'Остальные ${rest.length} ${KvFormat.plural(rest.length, 'правило', 'правила', 'правил')}',
              subtitle: 'Признаков не выявлено${missing == 0 ? '' : ' · по $missing нет данных'}',
              onTap: () => _showRest(context, rest),
            ),
          ],
        ),
      ],
    );
  }

  /// Лист несработавших правил (b-diag-rest): пояснение и правила, сначала без данных.
  void _showRest(BuildContext context, List<({RuleDef rule, RuleCheck check})> rest) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) {
        final KvColors c = sheet.kv;
        final KvTextStyles t = sheet.kvText;
        return KvSheet(
          title: 'Не сработали · ${rest.length} ${KvFormat.plural(rest.length, 'правило', 'правила', 'правил')}',
          children: [
            const KvNote(
              icon: KvIcons.info,
              text: '«Признаков не выявлено» значит, что условия правила не выполнены. Это не подтверждает отсутствие дефекта.',
            ),
            KvList(
              noIcons: true,
              children: [
                for (final ({RuleDef rule, RuleCheck check}) e in rest)
                  KvRow(
                    title: '${e.rule.id} · ${e.rule.title}',
                    titleWidget: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: e.rule.id, style: TextStyle(color: c.brand)),
                          TextSpan(text: ' · ${e.rule.title}'),
                        ],
                      ),
                      style: t.bodyM.copyWith(height: 1.3),
                    ),
                    subtitleWidget: e.check.missing == null
                        ? null
                        : Text('Нет данных: ${e.check.missing!.value}', style: t.caption.copyWith(height: 1.35, color: c.warnText)),
                    subtitle: e.check.missing == null ? 'Признаков не выявлено' : null,
                    onTap: e.check.missing == null || e.rule.id != 'R05'
                        ? null
                        : () {
                            Navigator.of(sheet).pop();
                            screen.kvUp(EngineerInspectPaths.scanGaugeFor(widget.unitId));
                          },
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Появление карточки при смене фильтра: подъём на 10 px и проявление за 300 мс.
class _Appear extends StatelessWidget {
  const _Appear({super.key, required this.child, required this.animate});

  final Widget child;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    if (!animate || context.kvReduceMotion) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: KvMotion.ease,
      child: child,
      builder: (BuildContext context, double v, Widget? c) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 10 * (1 - v)), child: c)),
    );
  }
}

/// Карточка сработавшего правила (.b-diag): код и источники, уровень, заголовок, основания и рекомендация.
class _DiagCard extends StatelessWidget {
  const _DiagCard({required this.result, required this.severity, required this.rule, required this.unitId});

  final DiagnosisResult result;
  final KvSeverity severity;
  final RuleDef? rule;
  final String unitId;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final List<String> sources = result.evidence.map((Evidence e) => e.source).toSet().toList();
    return KvCard(
      onTap: () => context.kvPush(EngineerInspectPaths.rule(result.ruleId, unitId)),
      semanticLabel: result.ruleId,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(result.ruleId, style: t.label.copyWith(fontWeight: FontWeight.w600, color: c.brand)),
              const SizedBox(width: 6),
              for (int i = 0; i < sources.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                KvIcon(evidenceIcon(sources[i]), size: 14, color: c.text3),
              ],
              const Spacer(),
              KvChip(severity.label, status: severity.status),
            ],
          ),
          const SizedBox(height: 10),
          Text(result.title, style: t.h2),
          const SizedBox(height: 10),
          EvidenceBox(label: 'Основания', lines: [for (final Evidence e in result.evidence) EvidenceLine(evidenceIcon(e.source), e.text)]),
          if (rule != null) ...[
            const SizedBox(height: 10),
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Рекомендуется:', style: TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: ' ${recommendationLead(rule!.recommendation)}'),
                ],
              ),
              style: t.sm,
            ),
          ],
        ],
      ),
    );
  }
}
