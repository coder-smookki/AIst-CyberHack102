import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../service_common.dart';
import 'report_paper.dart';

/// Предпросмотр отчёта PDF (c-report): первая страница акта осмотра на светлой бумаге, номер страницы,
/// выгрузка в Excel и лист «Поделиться».
class ReportScreen extends ConsumerWidget {
  /// Создаёт экран для осмотра [inspectionId]; без номера - текущий осмотр сотрудника.
  const ReportScreen({super.key, this.inspectionId});

  /// Номер осмотра или null.
  final String? inspectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final String? id = inspectionId ?? ref.watch(currentInspectionIdProvider).value;
    final InspectionSummary? s = id == null ? null : ref.watch(inspectionSummaryProvider(id)).value;
    final int pages = s == null || s.reportPages == 0 ? 1 : s.reportPages;
    return KvScreen(
      header: KvHeader(
        title: 'Отчёт PDF',
        subtitle: s == null
            ? ' '
            : KvFormat.typo('${s.inspectionId} · $pages ${KvFormat.plural(pages, 'страница', 'страницы', 'страниц')} · ${KvFormat.num(s.reportSizeMb, 1)} МБ'),
        status: KvStatus.info,
        onBack: () => context.kvBack(EngineerServicePaths.cSummary),
        onMore: s == null ? null : () => showReportShare(context, s),
      ),
      foot: Row(
        children: [
          Expanded(
            child: KvButton(
              'Excel',
              kind: KvButtonKind.secondary,
              icon: KvIcons.fileXls,
              onPressed: s == null
                  ? null
                  : () async {
                      await ref.read(reportRepositoryProvider).inspectionReport(s.inspectionId, 'xlsx');
                      if (context.mounted) {
                        showKvSnack(context, text: 'Excel сохранён в «Файлы» · 3 листа');
                      }
                    },
            ),
          ),
          const SizedBox(width: KvSpace.s3),
          Expanded(child: KvButton('Поделиться', icon: KvIcons.share, onPressed: s == null ? null : () => showReportShare(context, s))),
        ],
      ),
      children: [
        if (s == null) const KvSkeleton(height: 480, radius: 8) else ReportPaper(summary: s),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(width: 18, height: 6, decoration: BoxDecoration(color: c.brand, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 6),
            Container(width: 6, height: 6, decoration: BoxDecoration(color: c.surface3, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 6),
            Text('Стр. 1 из $pages', style: t.caption.copyWith(height: KvTextStyles.normalHeight(13))),
          ],
        ),
      ],
    );
  }
}

/// Лист «Отчёт INS-2209» (c-report-share): отправить мастеру, сохранить PDF, выгрузить Excel.
Future<void> showReportShare(BuildContext context, InspectionSummary s) {
  final BuildContext screen = context;
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => Consumer(
      builder: (BuildContext sheet, WidgetRef ref, Widget? child) {
        final String master = ref.watch(peopleProvider).value?['master']?.name ?? '';
        final String unit = ref.watch(unitProvider(s.unitId)).value?.code ?? s.unitId;
        final int pages = s.reportPages == 0 ? 1 : s.reportPages;
        Future<void> save(String format) async {
          Navigator.of(sheet).pop();
          await ref.read(reportRepositoryProvider).inspectionReport(s.inspectionId, format);
          if (screen.mounted) {
            showKvSnack(screen, text: format == 'pdf' ? 'PDF сохранён в «Файлы»' : 'Excel сохранён в «Файлы» · 3 листа');
          }
        }

        return KvSheet(
          title: KvFormat.typo('Отчёт ${s.inspectionId}'),
          children: [
            KvList(
              children: [
                KvRow(
                  icon: KvIcons.send,
                  title: 'Отправить мастеру',
                  subtitle: KvFormat.typo('$master · в приложении'),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    showKvToast(
                      screen,
                      kind: KvToastKind.ok,
                      icon: KvIcons.send,
                      title: 'Отчёт отправлен',
                      text: KvFormat.typo('$master получит его в приложении'),
                    );
                  },
                ),
                KvRow(
                  icon: KvIcons.download,
                  title: 'Сохранить PDF в «Файлы»',
                  subtitle: KvFormat.typo('${KvFormat.num(s.reportSizeMb, 1)} МБ · $pages ${KvFormat.plural(pages, 'страница', 'страницы', 'страниц')}'),
                  onTap: () => save('pdf'),
                ),
                KvRow(icon: KvIcons.fileXls, title: 'Экспорт в Excel', subtitle: 'Находки, показания, наработка', onTap: () => save('xlsx')),
              ],
            ),
            Text(KvFormat.typo('Отчёт также хранится на сервере цеха и в истории $unit.'), style: sheet.kvText.caption),
          ],
        );
      },
    ),
  );
}
