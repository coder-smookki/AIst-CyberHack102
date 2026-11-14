import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../service_common.dart';

/// Рамки распознавания на кадре camera.jpg для миниатюр отчёта.
final detectionsProvider = FutureProvider.autoDispose.family<List<Detection>, String>(
  (Ref ref, String unitId) => ref.watch(inspectionRepositoryProvider).detections(unitId),
);

/// Первая страница акта осмотра (.c-paper): всегда светлая бумага формата A4 (1 : 1,414) с шапкой, ресурсом,
/// находками с кадрами камеры, подписью инженера и колонтитулом.
class ReportPaper extends ConsumerWidget {
  /// Создаёт страницу для итога [summary].
  const ReportPaper({super.key, required this.summary});

  /// Итог осмотра.
  final InspectionSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Theme(
      data: KvTheme.light,
      child: Builder(builder: (BuildContext context) => _Paper(summary: summary)),
    );
  }
}

class _Paper extends ConsumerWidget {
  const _Paper({required this.summary});

  final InspectionSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final bool narrow = MediaQuery.sizeOf(context).width <= 370;
    final Equipment? u = ref.watch(unitProvider(summary.unitId)).value;
    final Site? site = ref.watch(siteProvider).value;
    final Map<String, Person> people = ref.watch(peopleProvider).value ?? const <String, Person>{};
    final List<Detection> detections = ref.watch(detectionsProvider(summary.unitId)).value ?? const <Detection>[];
    final List<Inspection> inspections = ref.watch(inspectionsProvider(summary.unitId)).value ?? const <Inspection>[];
    final String who = inspections.where((Inspection i) => i.id == summary.inspectionId).firstOrNull?.who ?? people['engineer']?.name ?? '';
    final String whoTitle = people.values.where((Person p) => p.name == who).firstOrNull?.title ?? 'Инженер';
    final List<SummaryFinding> page = summary.findings;
    final int pages = summary.reportPages == 0 ? 1 : summary.reportPages;
    final double gap = narrow ? 8 : 9;
    final TextStyle base = TextStyle(fontFamily: KvTextStyles.kvFontFamily, fontSize: 10, height: 1.35, color: c.text);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: box.maxWidth * 1.414),
        child: IntrinsicHeight(
          child: Container(
            padding: narrow ? const EdgeInsets.fromLTRB(12, 14, 12, 10) : const EdgeInsets.fromLTRB(14, 16, 14, 12),
            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(8), boxShadow: c.shadow2),
            child: DefaultTextStyle(
              style: base,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Top(summary: summary),
                  SizedBox(height: gap),
                  _Facts(summary: summary),
                  SizedBox(height: gap),
                  if (u != null) _Unit(unit: u, site: site),
                  SizedBox(height: gap),
                  if (u != null) _Resource(unit: u, narrow: narrow),
                  SizedBox(height: gap),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'НАХОДКИ',
                      style: base.copyWith(fontWeight: FontWeight.w600, color: c.text2, letterSpacing: 0.2),
                    ),
                  ),
                  if (page.isEmpty) ...[
                    SizedBox(height: gap),
                    Text('Находок нет: дефекты на камере не подтверждены, правила не сработали.', style: base.copyWith(color: c.text2)),
                  ],
                  for (int i = 0; i < page.length; i++) ...[
                    SizedBox(height: gap),
                    _Finding(
                      finding: page[i],
                      detection: detections.where((Detection d) => d.label == page[i].frame).firstOrNull,
                      first: i == 0,
                      narrow: narrow,
                    ),
                  ],
                  SizedBox(height: gap),
                  const Spacer(),
                  _Sign(who: who, title: whoTitle, date: summary.date),
                  SizedBox(height: gap),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('КСТ Визор · ${site?.server ?? ''}', style: base.copyWith(fontSize: 8, color: c.text3)),
                      const SizedBox(width: 8),
                      Text('стр. 1 из $pages', style: base.copyWith(fontSize: 8, color: c.text3)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Шапка акта: логотип и номер акта с датой и временем осмотра.
class _Top extends StatelessWidget {
  const _Top({required this.summary});

  final InspectionSummary summary;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final TextStyle base = DefaultTextStyle.of(context).style;
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const KvLogo(height: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  KvFormat.typo('Акт осмотра ${summary.inspectionId}'),
                  textAlign: TextAlign.right,
                  style: base.copyWith(fontSize: 11, fontWeight: FontWeight.w600),
                ),
                Text(
                  '${summary.date} · ${summary.start}-${summary.end}',
                  textAlign: TextAlign.right,
                  style: base.copyWith(fontSize: 9, color: c.text2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Агрегат: обозначение и модель, заводской номер, место и наработка.
class _Unit extends StatelessWidget {
  const _Unit({required this.unit, required this.site});

  final Equipment unit;
  final Site? site;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final TextStyle base = DefaultTextStyle.of(context).style;
    final String hall = unit.location.contains(', ') ? unit.location.split(', ').last : unit.location;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(KvFormat.typo('${unit.code} · ${unit.model}'), style: base.copyWith(fontSize: 14, fontWeight: FontWeight.w600, height: 1.25)),
        const SizedBox(height: 2),
        Text(
          KvFormat.typo('Зав. № ${unit.serial} · ${site?.name ?? ''}, $hall · наработка ${KvFormat.num(unit.runHours)} ч'),
          style: base.copyWith(fontSize: 9, color: c.text2),
        ),
      ],
    );
  }
}

/// Три плашки ресурса: подшипники, ТО-2, ревизия.
class _Resource extends StatelessWidget {
  const _Resource({required this.unit, required this.narrow});

  final Equipment unit;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Resource r = unit.resource;
    final MaintenanceItem? to2 = unit.maintenance.where((MaintenanceItem m) => m.code == 'ТО-2').firstOrNull;
    final MaintenanceItem? rev = unit.maintenance.where((MaintenanceItem m) => m.code == 'Ревизия').firstOrNull;
    final List<Widget> cells = [
      _ResCell(
        label: 'Подшипники',
        value: '${KvFormat.num(r.left)} ч',
        color: c.warnText,
        fill: r.fraction,
        bar: c.warn,
        note: '${KvFormat.num(r.used)} из ${KvFormat.num(r.total)}',
        narrow: narrow,
      ),
      if (to2 != null)
        _ResCell(
          label: to2.code,
          value: '${KvFormat.num(to2.inHours)} ч',
          color: c.warnText,
          fill: 0.999,
          bar: c.warn,
          note: 'на ${KvFormat.num(to2.nextAt)} ч',
          narrow: narrow,
        ),
      if (rev != null)
        _ResCell(
          label: rev.code,
          value: '${KvFormat.num(rev.inHours)} ч',
          color: c.brand,
          fill: (rev.interval ?? 0) == 0 ? 0 : (unit.runHours - (rev.lastAt ?? 0)) / rev.interval!,
          bar: c.brand,
          note: 'на ${KvFormat.num(rev.nextAt)} ч',
          narrow: narrow,
        ),
    ];
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(child: i < cells.length ? cells[i] : const SizedBox.shrink()),
          ],
        ],
      ),
    );
  }
}

/// Плашка ресурса (.c-p-res > div): подпись, остаток часов, полоска 3 px и пояснение.
class _ResCell extends StatelessWidget {
  const _ResCell({
    required this.label,
    required this.value,
    required this.color,
    required this.fill,
    required this.bar,
    required this.note,
    required this.narrow,
  });

  final String label;
  final String value;
  final Color color;
  final double fill;
  final Color bar;
  final String note;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final TextStyle base = DefaultTextStyle.of(context).style;
    final TextStyle small = base.copyWith(fontSize: 8.5, color: c.text2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: small),
          const SizedBox(height: 3),
          Text(
            KvFormat.typo(value),
            maxLines: 1,
            softWrap: false,
            style: base.copyWith(
              fontSize: narrow ? 13 : 15,
              fontWeight: FontWeight.w300,
              height: 1,
              color: color,
              leadingDistribution: TextLeadingDistribution.even,
            ),
          ),
          const SizedBox(height: 3),
          Container(
            height: 3,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: c.surface3, borderRadius: BorderRadius.circular(3)),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fill.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(3)),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(KvFormat.typo(note), maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: small),
        ],
      ),
    );
  }
}

/// Находка в акте (.c-p-find): кадр камеры с рамкой дефекта, правило и название, чип, основания и рекомендация.
class _Finding extends StatelessWidget {
  const _Finding({required this.finding, required this.detection, required this.first, required this.narrow});

  final SummaryFinding finding;
  final Detection? detection;
  final bool first;
  final bool narrow;

  static KvIcons _icon(Evidence e) {
    final String t = e.text.toLowerCase();
    if (e.source == 'camera' || t.startsWith('камера')) {
      return KvIcons.camera;
    }
    if (t.contains('вибрац')) {
      return KvIcons.activity;
    }
    if (t.contains('°c') || t.contains('подшипник') || t.contains('обмотк')) {
      return KvIcons.temp;
    }
    return KvIcons.flash;
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final TextStyle base = DefaultTextStyle.of(context).style;
    final (String label, KvStatus tone) = ServiceFormat.severity(finding.severity);
    final (Color chipBg, Color chipFg) = switch (tone) {
      KvStatus.bad => (c.badBg, c.bad),
      KvStatus.warn => (c.warnBg, c.warnText),
      _ => (c.infoBg, c.brand),
    };
    final double thumb = narrow ? 48 : 56;
    final Widget body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Thumb(detection: detection, size: thumb),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      KvFormat.typo('${finding.ruleId} · ${finding.title}'),
                      style: base.copyWith(fontSize: 10.5, fontWeight: FontWeight.w600, height: 1.25),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: chipBg, borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      style: base.copyWith(fontSize: 8.5, fontWeight: FontWeight.w600, height: 1.25, color: chipFg),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (int i = 0; i < finding.evidence.length; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: KvIcon(_icon(finding.evidence[i]), size: 11, color: c.text3),
                      ),
                      const SizedBox(width: 5),
                      Expanded(child: Text(KvFormat.typo(finding.evidence[i].text), style: base.copyWith(fontSize: 9))),
                    ],
                  ),
                ),
              if (finding.recommendation.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(KvFormat.typo(finding.recommendation), style: base.copyWith(fontSize: 9, color: c.text2)),
              ],
            ],
          ),
        ),
      ],
    );
    if (first) {
      return body;
    }
    return Container(
      padding: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.divider)),
      ),
      child: body,
    );
  }
}

/// Кадр камеры с рамкой дефекта (.c-thumb): фрагмент camera.jpg, увеличенный так, что сторона миниатюры 56 -
/// это 30 % ширины кадра, с центром на рамке распознавания.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.detection, required this.size});

  final Detection? detection;
  final double size;

  static const double _crop = 56;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Detection? d = detection;
    if (d == null) {
      return SizedBox.square(dimension: size);
    }
    const double w = _crop / 0.3;
    const double h = w * 1688 / 780;
    final double cx = (d.x + d.w / 2) / 100 * w;
    final double cy = (d.y + d.h / 2) / 100 * h;
    final double px = -(cx - _crop / 2);
    final double py = -(cy - _crop / 2);
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          children: [
            Positioned(
              left: px,
              top: py,
              width: w,
              height: h,
              child: Image.asset('assets/images/camera.jpg', fit: BoxFit.fill, cacheWidth: (w * dpr).round(), gaplessPlayback: true),
            ),
            Positioned(
              left: d.x / 100 * w + px,
              top: d.y / 100 * h + py,
              width: d.w / 100 * w,
              height: d.h / 100 * h,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: c.arDefect, width: 1.5),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Подпись акта: «Решение принимает инженер», должность и дата, росчерк фамилии и инициалы.
class _Sign extends StatelessWidget {
  const _Sign({required this.who, required this.title, required this.date});

  final String who;
  final String title;
  final String date;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final TextStyle base = DefaultTextStyle.of(context).style;
    final List<String> parts = who.split(' ');
    final String last = parts.length > 1 ? parts[1] : who;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Решение принимает инженер', style: base.copyWith(fontSize: 9.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('$title · $date', style: base.copyWith(fontSize: 8.5, color: c.text2)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 130,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.only(bottom: 1),
                  margin: const EdgeInsets.only(bottom: 2),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.text2)),
                  ),
                  child: Text(
                    last,
                    textAlign: TextAlign.center,
                    style: base.copyWith(fontSize: 13, fontStyle: FontStyle.italic, color: c.brandDeep),
                  ),
                ),
                Text(
                  KvFormat.typo(ServiceFormat.short(who)),
                  textAlign: TextAlign.center,
                  style: base.copyWith(fontSize: 9, color: c.text2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// Сводка осмотра в акте: время, охват узлов, сработавшие правила и дефекты камеры.
class _Facts extends StatelessWidget {
  const _Facts({required this.summary});

  final InspectionSummary summary;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final TextStyle base = DefaultTextStyle.of(context).style;
    final List<(String, String)> rows = [
      ('Время', KvFormat.typo('${summary.date}, ${summary.start}${summary.end.isEmpty ? '' : '-${summary.end}'}${summary.duration.isEmpty ? '' : ' · ${summary.duration}'}')),
      ('Узлы', '${summary.nodesChecked} из ${summary.nodesTotal} осмотрено'),
      ('Находки', '${summary.findings.length} · дефектов на камере ${summary.cameraDefects}'),
      ('Правила', 'сработало ${summary.rulesFired}'),
      ('Снимки', '${summary.photos}'),
    ];
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(6)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (String k, String v) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  SizedBox(width: 62, child: Text(k, style: base.copyWith(fontSize: 9, color: c.text3))),
                  Expanded(child: Text(v, style: base.copyWith(fontSize: 9.5, fontWeight: FontWeight.w500))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
