import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../shared/bridges.dart';
import '../service_common.dart';

/// Итог осмотра (c-summary): полнота обхода, находки с группой тяжести, выгрузка PDF и Excel, передача находок
/// мастеру и кнопка «Завершить и сохранить».
class SummaryScreen extends ConsumerWidget {
  /// Создаёт экран итога осмотра [inspectionId]; без номера - текущий осмотр сотрудника.
  const SummaryScreen({super.key, this.inspectionId});

  /// Номер осмотра или null.
  final String? inspectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? id = inspectionId ?? ref.watch(currentInspectionIdProvider).value;
    final InspectionSummary? s = id == null ? null : ref.watch(inspectionSummaryProvider(id)).value;
    final Equipment? unit = s == null ? null : ref.watch(unitProvider(s.unitId)).value;
    final Person? master = ref.watch(peopleProvider).value?['master'];
    if (s == null) {
      return KvScreen(
        header: KvHeader(title: 'Итог осмотра', onBack: () => context.kvBack(EngineerInspectPaths.diagnostics)),
        children: const [
          KvSkeleton(height: 100, radius: KvRadius.card),
          KvSkeleton.card(height: 230),
        ],
      );
    }
    final String code = unit?.code ?? s.unitId;
    return KvScreen(
      header: KvHeader(
        title: 'Итог осмотра',
        subtitle: KvFormat.typo('$code · ${s.date}, ${s.start} · ${s.duration}'),
        status: unit?.kvStatus ?? KvStatus.warn,
        onBack: () => context.kvBack(EngineerInspectPaths.diagnostics),
        onMore: () => showSummaryMenu(context, s),
      ),
      foot: KvButton(
        'Завершить и сохранить',
        icon: KvIcons.check,
        wait: true,
        onPressed: () async {
          await ref.read(inspectionRepositoryProvider).finish(s.inspectionId);
          if (context.mounted) {
            context.kvFade(EngineerServicePaths.cSaved);
          }
        },
      ),
      children: [
        _Kpis(summary: s),
        if (s.verdict != null) InspectionVerdictBlock(verdict: s.verdict),
        KvSectionLabel(
          KvFormat.typo(
            'Находки · ${s.findings.length} · ${s.cameraDefects} ${KvFormat.plural(s.cameraDefects, 'дефект', 'дефекта', 'дефектов')} на камере',
          ),
        ),
        KvList(noIcons: true, children: [for (final SummaryFinding f in s.findings) _FindingRow(finding: f)]),
        _Exports(summary: s),
        _Handoff(master: master?.name ?? ''),
      ],
    );
  }
}

/// Три счётчика итога: узлы, находки, сработавшие правила (подписи переносятся на две строки).
class _Kpis extends StatelessWidget {
  const _Kpis({required this.summary});

  final InspectionSummary summary;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: KvKpi(
              value: '${summary.nodesChecked}/${summary.nodesTotal}',
              label: 'Узлов осмотрено',
              status: KvStatus.info,
              labelMaxLines: 2,
            ),
          ),
          const SizedBox(width: KvSpace.s2),
          Expanded(
            child: KvKpi(value: '${summary.findings.length}', label: 'Находки', status: KvStatus.bad, labelMaxLines: 2),
          ),
          const SizedBox(width: KvSpace.s2),
          Expanded(
            child: KvKpi(value: '${summary.rulesFired}', label: 'Правил сработало', status: KvStatus.warn, labelMaxLines: 2),
          ),
        ],
      ),
    );
  }
}

/// Строка находки: название, правило и источники, чип группы тяжести; касание - диагностика по правилам.
class _FindingRow extends StatelessWidget {
  const _FindingRow({required this.finding});

  final SummaryFinding finding;

  @override
  Widget build(BuildContext context) {
    final (String label, KvStatus tone) = ServiceFormat.severity(finding.severity);
    final String rules = [finding.ruleId, ...finding.relatedRules].join(', ');
    return KvRow(
      title: finding.title,
      subtitle: KvFormat.typo('$rules · ${finding.sources}'),
      trailing: KvChip(label, status: tone),
      chevron: false,
      onTap: () => context.kvPush(EngineerInspectPaths.diagnostics),
    );
  }
}

/// Выгрузка отчёта: PDF и Excel в «Файлы» с уведомлением снизу и переходом к предпросмотру.
class _Exports extends ConsumerWidget {
  const _Exports({required this.summary});

  final InspectionSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Future<void> export(String format) async {
      await ref.read(reportRepositoryProvider).inspectionReport(summary.inspectionId, format);
      if (!context.mounted) {
        return;
      }
      showKvSnack(
        context,
        text: format == 'pdf' ? 'PDF сохранён в «Файлы»' : 'Excel сохранён в «Файлы»',
        actionLabel: 'Открыть',
        onAction: () => context.kvPush(EngineerServicePaths.cReport),
      );
    }

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: KvActionCard(icon: KvIcons.filePdf, title: 'PDF', subtitle: 'В «Файлы»', onTap: () => export('pdf')),
          ),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: KvActionCard(icon: KvIcons.fileXls, title: 'Excel', subtitle: 'В «Файлы»', onTap: () => export('xlsx')),
          ),
        ],
      ),
    );
  }
}

/// Плашка «Находки уйдут мастеру» (.c-handoff).
class _Handoff extends StatelessWidget {
  const _Handoff({required this.master});

  final String master;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: c.tint2, borderRadius: BorderRadius.circular(KvRadius.card)),
      child: Row(
        children: [
          KvAvatar(master.isEmpty ? 'М' : master),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Находки уйдут мастеру',
                  style: t.sm.copyWith(fontWeight: FontWeight.w600, color: c.text, height: KvTextStyles.normalHeight(14)),
                ),
                const SizedBox(height: 2),
                Text(
                  KvFormat.typo('$master подтвердит или снимет их. Решение по осмотру за инженером.'),
                  style: t.caption.copyWith(height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Меню итога (лист c-summary-menu): предпросмотр отчёта, продолжить осмотр, диагностика по правилам.
Future<void> showSummaryMenu(BuildContext context, InspectionSummary s) {
  final BuildContext screen = context;
  void open(BuildContext sheet, VoidCallback go) {
    Navigator.of(sheet).pop();
    go();
  }

  final String rules = s.findings.map((SummaryFinding f) => f.ruleId).join(', ');
  final int pages = s.reportPages == 0 ? 1 : s.reportPages;
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => KvSheet(
      title: KvFormat.typo('Осмотр ${s.inspectionId}'),
      children: [
        KvList(
          children: [
            KvRow(
              icon: KvIcons.file,
              title: 'Предпросмотр отчёта',
              subtitle: 'PDF, $pages ${KvFormat.plural(pages, 'страница', 'страницы', 'страниц')}',
              onTap: () => open(sheet, () => screen.kvPush(EngineerServicePaths.cReport)),
            ),
            KvRow(
              icon: KvIcons.scan,
              title: 'Продолжить осмотр',
              subtitle: 'Вернуться к камере',
              onTap: () => open(sheet, () => screen.kvUp(EngineerInspectPaths.scanner)),
            ),
            KvRow(
              icon: KvIcons.activity,
              title: 'Диагностика по правилам',
              subtitle: KvFormat.typo('$rules и уставки'),
              onTap: () => open(sheet, () => screen.kvPush(EngineerInspectPaths.diagnostics)),
            ),
          ],
        ),
      ],
    ),
  );
}
