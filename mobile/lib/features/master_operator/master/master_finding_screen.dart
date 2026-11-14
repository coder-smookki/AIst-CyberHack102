import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../../shared/bridges.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_frame.dart';
import 'master_finding_sheets.dart';
import 'master_findings_screen.dart';

/// Кадры осмотров, приложенные к находкам: подпись кадра по номеру находки.
const Map<String, String> _frames = {'F-1043': 'Кадр 09:31 · INS-2209', 'F-1041': 'Кадр 07:03 · INS-2207'};

/// Источник основания: значок и подпись.
(KvIcons, String) _source(String src) => switch (src) {
      'camera' => (KvIcons.camera, 'Камера, живое видео'),
      'data' => (KvIcons.database, 'Учёт наработки'),
      'user' => (KvIcons.megaphone, 'Оператор смены'),
      _ => (KvIcons.activity, 'Датчики, сервер ввода-вывода'),
    };

/// Проверка находки мастером: кадр или график, тяжесть и правило, доказательства, комментарий автора,
/// рекомендация правила, решение и действия «Отклонить» / «Подтвердить».
///
/// [at] = «0728» - находка F-1041 в 07:28, до решения мастера (сценарий А): экран показывает её новой,
/// решения в этом моменте истории данные не меняют.
class MasterFindingScreen extends ConsumerWidget {
  /// Создаёт экран находки [findingId].
  const MasterFindingScreen({super.key, required this.findingId, this.at});

  /// Номер находки.
  final String findingId;

  /// Момент истории или null.
  final String? at;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Finding? f = ref.watch(findingProvider(findingId)).value;
    final List<Equipment> units = ref.watch(unitsProvider).value ?? const <Equipment>[];
    if (f == null) {
      return KvScreen(
        header: KvHeader(title: findingId, onBack: () => context.kvBack(MasterOperatorPaths.masterFindings)),
        children: const [KvSkeleton.card(height: 200), KvSkeleton.card(height: 160)],
      );
    }
    final Equipment? unit = units.where((Equipment u) => u.id == f.unitId).firstOrNull;
    final String code = unit?.code ?? f.unitId;
    final bool story = at != null;
    final bool rejected = f.status == 'rejected';
    final bool isNew = !rejected && (f.status == 'new' || story);
    final bool full = isNew && !story && f.author != 'Система';
    final (String, KvStatus) st = moFindingStatus(isNew ? 'new' : f.status);
    final List<DiagnosisResult> diag = ref.watch(diagnosisProvider(f.unitId)).value ?? const <DiagnosisResult>[];
    final List<RuleDef> rules = ref.watch(rulesProvider).value ?? const <RuleDef>[];
    final RuleDef? rule = rules.where((RuleDef r) => r.id == f.ruleId).firstOrNull;
    final DiagnosisResult? match = f.id == 'F-1041' ? null : diag.where((DiagnosisResult d) => d.ruleId == f.ruleId).firstOrNull;
    final List<(String, String)> evidence = match != null
        ? [for (final Evidence e in match.evidence) (e.source, e.text)]
        : [
            for (final String e in f.evidence)
              (moEvidenceSource(e), () {
                final String s = e.replaceFirst(RegExp('^Камера: '), '');
                return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
              }()),
          ];
    final MoDecision decision = MoDecision.of(f, code);
    final String back = isNew ? MasterOperatorPaths.masterFindings : MasterOperatorPaths.dMFindingsAll;

    final List<Widget> body = [
      if (rejected) _rejectedNote(context, f, code),
      ?_media(context, ref, f, unit),
      _title(context, f, code, rule),
      _evidence(context, evidence),
      KvCard(
        child: MoQuote(
          avatar: f.author == 'Система' ? 'КВ' : f.author,
          who: f.author == 'Система' ? 'Правило ${f.ruleId}' : '${f.author} · инженер',
          text: f.comment ?? (f.author == 'Система' ? 'Создана правилом ${f.ruleId} по данным датчиков.' : f.source),
        ),
      ),
      KvNote(
        child: Text.rich(
          TextSpan(children: [TextSpan(text: 'Рекомендация ${f.ruleId}.', style: const TextStyle(fontWeight: FontWeight.w600)), TextSpan(text: ' ${KvFormat.typo(f.recommendation)}')]),
        ),
      ),
      if (!isNew && (f.status == 'planned' || f.status == 'confirmed') && f.confirmedBy != null)
        KvCard(
          child: KvKeyValues([
            (moVerb(f.confirmedBy!, 'Подтвердила', 'Подтвердил'), KvFormat.typo('${f.confirmedBy} · ${f.confirmedAt ?? ''}')),
            if (f.planned != null) ('Работы', KvFormat.typo(f.planned!)),
          ]),
        ),
      if (f.status == 'closed') KvNote(tone: KvStatus.ok, icon: KvIcons.checkCircle, text: KvFormat.typo('${f.closedNote ?? 'Замечание снято'} · ${f.closedBy ?? ''}')),
      if (full)
        KvList(
          children: [
            KvRow(
              icon: KvIcons.calendar,
              title: 'Назначить на ТО',
              subtitle: KvFormat.typo(f.unitId == 'AMS-2' ? 'Отдельный ремонт' : 'Включить в ТО-2 · 15.11, 10:00'),
              onTap: () => showMoScheduleSheet(context, f, code),
            ),
            KvRow(icon: KvIcons.edit, title: 'Комментарий мастера', subtitle: 'Виден инженеру и в отчёте', onTap: () => showMoCommentSheet(context, f)),
          ],
        ),
    ];

    Widget? foot;
    if (isNew) {
      foot = Row(
        children: [
          Expanded(
            child: KvButton('Отклонить', kind: KvButtonKind.dangerSoft, onPressed: () => showMoRejectDialog(context, f, story: story, stay: decision.rejectStays && !story)),
          ),
          const SizedBox(width: KvSpace.s3),
          Expanded(child: KvButton('Подтвердить', icon: KvIcons.check, onPressed: () => showMoConfirmSheet(context, f, code, story: story))),
        ],
      );
    } else if (rejected) {
      foot = KvButton(
        'Вернуть на подтверждение',
        kind: KvButtonKind.secondary,
        icon: KvIcons.refresh,
        onPressed: () => ref.read(inspectionRepositoryProvider).reopenFinding(f.id),
      );
    }

    return KvScreen(
      header: KvHeader(
        title: f.id,
        subtitle: KvFormat.typo('${st.$1} · $code'),
        status: st.$2,
        onBack: () => context.kvBack(back),
        onMore: full ? () => showMoFindingMenu(context, f, code) : null,
      ),
      foot: foot,
      children: body,
    );
  }

  Widget _rejectedNote(BuildContext context, Finding f, String code) {
    final String who = f.closedBy ?? 'Мастер';
    final String note = f.closedNote ?? '';
    final String noteText = note.isEmpty ? '' : ' Проверено на месте: ${note[0].toLowerCase()}${note.substring(1)}';
    final String reason = (f.rejectReason ?? '').toLowerCase();
    return KvNote(
      icon: KvIcons.ban,
      text: KvFormat.typo(
        '${moVerb(who, 'Отклонила', 'Отклонил')} $who · ${f.rejectedAt ?? ''}. Причина: $reason.$noteText Инженер уведомлён, запись осталась в истории $code.',
      ),
    );
  }

  Widget? _media(BuildContext context, WidgetRef ref, Finding f, Equipment? unit) {
    if (f.unitId == 'N-101' && f.ruleId == 'R01') {
      return MoFrame(crop: MoFrameCrop.n101, boxes: const [moLeakBox], chip: _frames[f.id]);
    }
    if (f.unitId == 'AMS-2') {
      return MoFrame(crop: MoFrameCrop.ams2, boxes: const [moPuddleBox], chip: _frames[f.id] ?? _frames['F-1041']);
    }
    if (f.unitId == 'N-101') {
      final TelemetrySeries? s = ref.watch(seriesProvider((unitId: 'N-101', key: 'vib1x', period: TelemetryPeriod.week))).value;
      final Reading? v = unit?.readings['vib1x'];
      return KvCard(
        title: 'Вибрация 1X · 7 дн',
        trailing: v == null ? null : KvChip(KvFormat.withUnit(v.value, v.unit, 1), status: v.kvStatus),
        child: s == null ? const SizedBox(height: 120 + 8 + 16) : KvAreaChart(data: s.chart, height: 120),
      );
    }
    return null;
  }

  Widget _title(BuildContext context, Finding f, String code, RuleDef? rule) {
    final KvTextStyles t = context.kvText;
    final (String, KvStatus) sev = moSeverity(f.severity);
    String src = '';
    if (rule != null) {
      final bool cam = !rule.camera.startsWith('Не требу');
      final bool sen = !rule.sensor.startsWith('Не требу');
      src = cam && sen
          ? 'камера + датчики'
          : cam
              ? 'камера'
              : 'датчики';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(spacing: KvSpace.s2, runSpacing: KvSpace.s2, children: [KvChip(sev.$1, status: sev.$2), KvChip(src.isEmpty ? f.ruleId : '${f.ruleId} · $src', dot: false)]),
          const SizedBox(height: 6),
          Text(f.title, style: t.hdr),
          const SizedBox(height: 6),
          Text(KvFormat.typo('$code · ${f.node} · ${f.date.substring(0, 5)}, ${f.time}'), style: t.caption),
        ],
      ),
    );
  }

  Widget _evidence(BuildContext context, List<(String, String)> ev) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return KvCard(
      key: const ValueKey<String>('mo-evidence'),
      style: KvCardStyle.flush,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Expanded(child: Text('Доказательства', style: t.h2)),
                Text('${ev.length}', style: t.caption.copyWith(height: KvTextStyles.normalHeight(13))),
              ],
            ),
          ),
          for (int i = 0; i < ev.length; i++)
            Container(
              foregroundDecoration: i == 0 ? null : _DividerDecoration(c.divider),
              child: KvRow(icon: _source(ev[i].$1).$1, title: KvFormat.typo(ev[i].$2), subtitle: _source(ev[i].$1).$2, chevron: false),
            ),
        ],
      ),
    );
  }
}

/// Разделитель строки внутри карточки: линия 1 px сверху от левого края 68 (как у .list).
class _DividerDecoration extends Decoration {
  const _DividerDecoration(this.color);

  final Color color;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _DividerPainter(color);
}

class _DividerPainter extends BoxPainter {
  _DividerPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final Size size = configuration.size ?? Size.zero;
    canvas.drawRect(Rect.fromLTWH(offset.dx + 68, offset.dy, size.width - 68, 1), Paint()..color = color);
  }
}
