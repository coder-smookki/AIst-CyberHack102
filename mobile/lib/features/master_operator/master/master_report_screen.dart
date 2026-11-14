import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_common.dart';
import '../widgets/mo_frame.dart';
import 'master_assign_sheet.dart';

/// Подробности сообщения оператора, которые сервер передаёт вложениями: кадр, событие правила,
/// инженер смены и последний осмотр агрегата.
@immutable
class _ReportExtras {
  const _ReportExtras({this.frame, this.ruleNote, this.engineer, this.lastInspection});

  final String? frame;
  final String? ruleNote;
  final String? engineer;
  final String? lastInspection;
}

const Map<String, _ReportExtras> _extras = {
  'S-077': _ReportExtras(
    frame: 'Кадр оператора · 06:39',
    ruleNote: '06:44 сработало правило S05: обмотка 112 °C, уставка 110 °C. АМС-2 остановлен автоматически.',
    engineer: 'Алексей Смирнов · свободен',
    lastInspection: '12.11 · отклонений не выявлено',
  ),
};

/// Сообщение оператора для мастера: текст и признаки, кадр с камеры, событие правила, инженер смены
/// и назначение осмотра; меню «ещё» - карточка агрегата, звонок оператору, PDF.
class MasterReportScreen extends ConsumerWidget {
  /// Создаёт экран сообщения [reportId].
  const MasterReportScreen({super.key, required this.reportId});

  /// Номер сообщения: «S-077».
  final String reportId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<FaultReport> reports = ref.watch(faultReportsProvider(null)).value ?? const <FaultReport>[];
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    final FaultReport? r = reports.where((FaultReport x) => x.id == reportId).firstOrNull;
    if (r == null) {
      return KvScreen(
        header: KvHeader(title: 'Сообщение $reportId', onBack: () => context.kvBack(MasterOperatorPaths.masterShift)),
        children: const [KvSkeleton.card(height: 140), KvSkeleton.card(height: 180)],
      );
    }
    final Equipment? unit = units.where((Equipment u) => u.id == r.unitId).firstOrNull;
    final String code = unit?.code ?? r.unitId;
    final _ReportExtras? x = _extras[r.id];
    final bool fresh = r.status == 'new';
    final List<String> signs = moReportSigns(r);
    final KvStatus status = switch (r.status) {
      'new' => KvStatus.bad,
      'closed' => KvStatus.ok,
      'assigned' => KvStatus.warn,
      _ => KvStatus.info,
    };
    return KvScreen(
      header: KvHeader(
        title: 'Сообщение ${r.id}',
        subtitle: KvFormat.typo('${fresh ? 'Новое' : r.statusLabel} · $code · ${r.time}'),
        status: status,
        onBack: () => context.kvBack(MasterOperatorPaths.masterShift),
        onMore: () => _menu(context, r, code),
      ),
      foot: fresh
          ? KvButton('Назначить осмотр', icon: KvIcons.clipboard, onPressed: () => showMoAssignSheet(context, MoAssignPreset.report))
          : null,
      children: [
        KvCard(
          child: MoQuote(
            avatar: r.author,
            who: '${r.author} · оператор · ${r.time}',
            text: r.text,
            large: true,
            chips: [for (final String s in signs) KvChip(s, status: moSignTone(s), dot: false)],
          ),
        ),
        if (x?.frame != null) MoFrame(crop: MoFrameCrop.ams2, boxes: const [moPuddleBox], chip: x!.frame),
        if (x?.ruleNote != null) KvNote(tone: KvStatus.bad, icon: KvIcons.temp, text: KvFormat.typo(x!.ruleNote!)),
        if (x?.engineer != null)
          KvList(
            children: [
              KvRow(icon: KvIcons.user, title: 'Инженер смены', subtitle: x!.engineer, chevron: false),
              KvRow(
                icon: KvIcons.history,
                title: KvFormat.typo('Последний осмотр $code'),
                subtitle: KvFormat.typo(x.lastInspection ?? ''),
                chevron: false,
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _menu(BuildContext context, FaultReport r, String code) {
    final BuildContext screen = context;
    return showKvSheet<void>(
      context,
      builder: (BuildContext sheet) {
        void close(VoidCallback then) {
          Navigator.of(sheet).pop();
          then();
        }

        return KvSheet(
          title: KvFormat.typo('${r.id} · $code'),
          children: [
            KvList(
              children: [
                KvRow(
                  icon: KvIcons.grid,
                  title: KvFormat.typo('Карточка $code'),
                  subtitle: 'Показания и режим',
                  onTap: () => close(() => screen.kvPush(MasterOperatorPaths.unit(r.unitId))),
                ),
                KvRow(
                  icon: KvIcons.phone,
                  title: 'Связаться с оператором',
                  subtitle: '${r.author} · пульт',
                  onTap: () => close(
                    () => showKvToast(
                      screen,
                      kind: KvToastKind.info,
                      icon: KvIcons.phone,
                      title: 'Вызов оператору',
                      text: KvFormat.typo('${r.author} · +7 912 405-20-31'),
                    ),
                  ),
                ),
                KvRow(
                  icon: KvIcons.filePdf,
                  title: 'Сообщение в PDF',
                  subtitle: 'Для журнала смены',
                  onTap: () => close(
                    () => showKvToast(
                      screen,
                      kind: KvToastKind.ok,
                      icon: KvIcons.download,
                      title: 'PDF сформирован',
                      text: KvFormat.typo('${r.id} · 0,4 МБ · Загрузки'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
