import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/navigation/kv_page.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../app/routes/engineer_service_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'inspect_catalog.dart';
import 'inspect_providers.dart';

/// Паспорт и документы (docs): паспортные данные агрегата, документы PDF с закладками и пометка о работе без сети.
class DocsScreen extends ConsumerWidget {
  /// Создаёт экран документов агрегата [unitId].
  const DocsScreen({super.key, this.unitId = kInspectDefaultUnit});

  /// Агрегат.
  final String unitId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Equipment? unit = ref.watch(unitProvider(unitId)).value;
    return KvScreen(
      header: KvHeader(
        title: 'Паспорт и документы',
        subtitle: unit == null ? ' ' : '${unit.code} · ${unit.modelShort}',
        onBack: () => context.kvBack(EngineerInspectPaths.card(unitId)),
      ),
      children: [
        if (unit == null) ...[
          const KvSkeleton.card(height: 360),
          const KvSkeleton.card(height: 200),
        ] else ...[
          KvCard(
            child: KvKeyValues([
              ('Модель', unit.modelFull),
              ('Серийный номер', unit.serial),
              ('Изготовитель', unit.manufacturer),
              ('Ввод в работу', unit.commissioned),
              ('Место', unit.location),
              ...unit.specs.take(4),
            ]),
          ),
          KvSectionLabel('Документы · ${unit.documents.length} PDF'),
          KvList(
            children: [
              for (int i = 0; i < unit.documents.length; i++)
                KvRow(
                  icon: KvIcons.filePdf,
                  title: unit.documents[i].name,
                  subtitle: KvFormat.typo(
                    [
                      unit.documents[i].type,
                      unit.documents[i].size,
                      ?kDocumentBookmarks[unit.documents[i].name],
                    ].join(' · '),
                  ),
                  onTap: () => context.kvPush(EngineerInspectPaths.docView(unitId, i)),
                ),
            ],
          ),
          const KvNote(icon: KvIcons.wifiOff, text: 'Документы загружены с цехового сервера и открываются без сети.'),
        ],
      ],
    );
  }
}

/// Страница документа (b-doc-view): страница с найденным по правилу абзацем и схемой узла, листание страниц,
/// добавление страницы в осмотр и вопрос ассистенту.
class DocViewScreen extends ConsumerWidget {
  /// Создаёт просмотр документа [index] агрегата [unitId].
  const DocViewScreen({super.key, this.unitId = kInspectDefaultUnit, this.index = 0});

  /// Агрегат.
  final String unitId;

  /// Номер документа в списке агрегата.
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Equipment? unit = ref.watch(unitProvider(unitId)).value;
    final Inspection? ins = ref.watch(activeInspectionProvider(unitId)).value;
    final EquipmentDocument? doc = unit == null || index >= unit.documents.length ? null : unit.documents[index];
    final DocPage? page = doc == null
        ? null
        : kDocPages[doc.name] ??
            DocPage(title: doc.name, page: 1, pages: 1, section: unit!.modelFull, heading: doc.name, ruleId: '', text: '', prev: '', next: '');
    void pageToast(int n, String section) =>
        showKvToast(context, kind: KvToastKind.info, icon: KvIcons.file, title: 'Страница $n', text: KvFormat.typo(section));
    return KvScreen(
      header: KvHeader(
        title: page?.title ?? ' ',
        subtitle: page == null ? ' ' : KvFormat.typo('${doc!.type} · с. ${page.page} из ${page.pages}'),
        onBack: () => context.kvBack(EngineerInspectPaths.docsFor(unitId)),
        onMore: page == null
            ? null
            : () => showKvToast(
                  context,
                  kind: KvToastKind.ok,
                  icon: KvIcons.clipboard,
                  title: 'Страница добавлена в осмотр',
                  text: KvFormat.typo('${ins?.id ?? unit?.code ?? unitId} · ${_short(doc!.name)}, с. ${page.page}'),
                ),
      ),
      foot: KvButton(
        'Спросить ассистента',
        kind: KvButtonKind.tonal,
        icon: KvIcons.chat,
        onPressed: () => context.go(EngineerServicePaths.assistant, extra: const KvNavExtra(transition: KvTransition.fade)),
      ),
      children: [
        if (page == null)
          const KvSkeleton.card(height: 500)
        else ...[
          _Page(page: page),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              KvButton(
                'с. ${page.page - 1}',
                kind: KvButtonKind.secondary,
                small: true,
                icon: KvIcons.chevronLeft,
                onPressed: page.prev.isEmpty ? null : () => pageToast(page.page - 1, page.prev),
              ),
              const SizedBox(width: KvSpace.s3),
              Text(
                '${page.page} / ${page.pages}',
                style: context.kvText.caption.copyWith(height: KvTextStyles.normalHeight(13)),
              ),
              const SizedBox(width: KvSpace.s3),
              KvButton(
                'с. ${page.page + 1}',
                kind: KvButtonKind.secondary,
                small: true,
                iconRight: KvIcons.chevronRight,
                onPressed: page.next.isEmpty ? null : () => pageToast(page.page + 1, page.next),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Короткое название документа для уведомления: «паспорт» из «Паспорт насоса IL 65/160».
  static String _short(String name) => name.split(' ').first.toLowerCase();
}

/// Страница документа (.b-page): колонтитул, заголовок раздела, строки текста, схема узла и найденный абзац.
class _Page extends StatelessWidget {
  const _Page({required this.page});

  final DocPage page;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final List<Widget> blocks = [
      Text(page.section, style: t.micro),
      Text(page.heading, style: t.sm.copyWith(fontWeight: FontWeight.w600, height: KvTextStyles.normalHeight(14))),
      ..._lines(c, const [1, 0.92, 0.96, 0.6]),
      if (page.ruleId.isNotEmpty) ...[
        const AspectRatio(aspectRatio: 300 / 120, child: _Drawing()),
        _Found(page: page),
      ],
      ..._lines(c, const [1, 0.88, 0.94, 0.72, 0.4]),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(KvSpace.s5, KvSpace.s5, KvSpace.s5, KvSpace.s6),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(KvRadius.card), boxShadow: c.shadow1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < blocks.length; i++) ...[if (i > 0) const SizedBox(height: 10), blocks[i]],
        ],
      ),
    );
  }

  /// Серые строки текста страницы (.b-line) шириной [widths] от строки.
  static List<Widget> _lines(KvColors c, List<double> widths) => [
        for (final double w in widths)
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: w,
            child: Container(height: 7, decoration: BoxDecoration(color: c.surface3, borderRadius: BorderRadius.circular(4))),
          ),
      ];
}

/// Абзац, найденный по правилу (.b-page-hl): синяя полоса слева, подпись правила и текст.
class _Found extends StatelessWidget {
  const _Found({required this.page});

  final DocPage page;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return ClipRRect(
      borderRadius: BorderRadius.circular(KvRadius.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(color: c.tint2, border: Border(left: BorderSide(color: c.brand, width: 3))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(11, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Найдено по правилу ${page.ruleId}', style: t.label.copyWith(color: c.brand, height: KvTextStyles.normalHeight(12))),
              const SizedBox(height: 6),
              Text(KvFormat.typo(page.text), style: t.caption.copyWith(color: c.text, height: 1.45)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Схема узла на странице паспорта: двигатель, вал, насос, уплотнение (поз. 12) в пунктирном круге и выноска.
class _Drawing extends StatelessWidget {
  const _Drawing();

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return CustomPaint(painter: _DrawingPainter(line: c.text2, accent: c.brand, font: context.kvText.base));
  }
}

class _DrawingPainter extends CustomPainter {
  _DrawingPainter({required this.line, required this.accent, required this.font});

  final Color line;
  final Color accent;
  final TextStyle font;

  @override
  void paint(Canvas canvas, Size size) {
    final double k = size.width / 300;
    canvas.save();
    canvas.scale(k);
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = line;
    canvas.drawRRect(RRect.fromLTRBR(20, 40, 90, 80, const Radius.circular(6)), p);
    canvas.drawRRect(RRect.fromLTRBR(90, 52, 210, 68, const Radius.circular(3)), p);
    canvas.drawRRect(RRect.fromLTRBR(210, 30, 280, 90, const Radius.circular(10)), p);
    p.color = accent;
    canvas.drawLine(const Offset(150, 52), const Offset(150, 68), p);
    canvas.drawLine(const Offset(160, 52), const Offset(160, 68), p);
    canvas.drawPath(
      Path()
        ..moveTo(155, 42)
        ..lineTo(155, 18)
        ..lineTo(195, 18),
      p,
    );
    const double r = 18;
    const double circumference = 2 * 3.141592653589793 * r;
    const int dashes = 14;
    const double step = circumference / dashes;
    for (int i = 0; i < dashes; i++) {
      canvas.drawArc(Rect.fromCircle(center: const Offset(155, 60), radius: r), i * step / r, 4 / r, false, p);
    }
    final TextPainter tp = TextPainter(
      text: TextSpan(text: 'поз. 12', style: font.copyWith(fontSize: 11, height: 1, color: accent, fontWeight: FontWeight.w400)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(198, 22 - tp.computeDistanceToActualBaseline(TextBaseline.alphabetic)));
    tp.dispose();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DrawingPainter old) => old.line != line || old.accent != accent;
}

