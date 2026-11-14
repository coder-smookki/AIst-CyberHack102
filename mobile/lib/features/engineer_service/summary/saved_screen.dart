import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_inspect_routes.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../service_common.dart';

/// Осмотр сохранён (c-saved): зелёная отметка с появлением, итог передачи на сервер цеха, три счётчика,
/// строка синхронизации и кнопки «К объектам» и «Открыть отчёт».
class SavedScreen extends ConsumerWidget {
  /// Создаёт экран.
  const SavedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final String? id = ref.watch(currentInspectionIdProvider).value;
    final InspectionSummary? s = id == null ? null : ref.watch(inspectionSummaryProvider(id)).value;
    final Equipment? unit = s == null ? null : ref.watch(unitProvider(s.unitId)).value;
    final Site? site = ref.watch(siteProvider).value;
    final String now = KvFormat.time(ref.watch(clockProvider).now());
    final int findings = s?.findings.length ?? 0;
    final int photos = s?.photos ?? 0;
    final String text = s == null
        ? ''
        : '${unit?.code ?? s.unitId} · $findings ${KvFormat.plural(findings, 'находка', 'находки', 'находок')} и $photos '
              '${KvFormat.plural(photos, 'снимок', 'снимка', 'снимков')} переданы на сервер цеха. Мастер получит уведомление.';
    final NextMaintenance? next = unit?.nextTo;
    return KvScreen(
      surface: true,
      stagger: KvStagger.none,
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          KvButton('К объектам', onPressed: () => context.kvFade(EngineerInspectPaths.objects)),
          const SizedBox(height: KvSpace.s2),
          KvButton(
            'Открыть отчёт',
            kind: KvButtonKind.secondary,
            icon: KvIcons.file,
            onPressed: () => context.kvPush(EngineerServicePaths.cReport),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(KvSpace.gutter, 0, KvSpace.gutter, KvLayout.footSpace),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: math.max(0, box.maxHeight - KvLayout.footSpace)),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _OkMark(),
                    const SizedBox(height: 12 + 10),
                    Text('Осмотр сохранён', textAlign: TextAlign.center, style: t.title.copyWith(fontSize: 24, height: 1.2)),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 300),
                      child: Text(
                        KvFormat.typo(text),
                        textAlign: TextAlign.center,
                        style: t.body.copyWith(color: c.text2),
                      ),
                    ),
                    if (s?.verdict != null) ...[
                      const SizedBox(height: 12),
                      InspectionVerdictBlock(verdict: s?.verdict, center: true),
                    ],
                    const SizedBox(height: 12 + 10),
                    Row(
                      children: [
                        Expanded(
                          child: _Stat(value: s?.duration ?? '', label: 'Длительность', color: c.brand),
                        ),
                        const SizedBox(width: KvSpace.s2),
                        Expanded(
                          child: _Stat(value: '$findings', label: 'Находки', color: c.bad),
                        ),
                        const SizedBox(width: KvSpace.s2),
                        Expanded(
                          child: _Stat(
                            value: next == null ? '' : KvFormat.typo('${KvFormat.num(next.inHours)} ч'),
                            label: next == null ? '' : 'До ${next.code.startsWith('ТО') ? next.code : 'ТО'}',
                            color: c.warnText,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12 + KvSpace.s2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        KvIcon(KvIcons.checkCircle, size: 16, color: c.ok),
                        const SizedBox(width: 6),
                        Text(
                          KvFormat.typo('${site?.server ?? ''} · $now'),
                          style: t.caption.copyWith(height: KvTextStyles.normalHeight(13)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Счётчик под текстом (.c-stat): серое поле, число 22 цвета смысла и подпись 12.
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.color});

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: t.numS.copyWith(color: color, height: 1.1),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            style: t.label.copyWith(fontWeight: FontWeight.w400, height: KvTextStyles.normalHeight(12)),
          ),
        ],
      ),
    );
  }
}

/// Отметка успеха (.c-ok-ring): кольцо появляется с пружинкой за 550 мс, галочка прорисовывается за 500 мс
/// с задержкой 300 мс; при уменьшении движения - сразу в конечном виде.
class _OkMark extends StatefulWidget {
  const _OkMark();

  @override
  State<_OkMark> createState() => _OkMarkState();
}

class _OkMarkState extends State<_OkMark> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
  bool _started = false;

  late final Animation<double> _scale =
      TweenSequence<double>([
        TweenSequenceItem<double>(tween: Tween<double>(begin: 0.6, end: 1.04), weight: 70),
        TweenSequenceItem<double>(tween: Tween<double>(begin: 1.04, end: 1), weight: 30),
      ]).animate(
        CurvedAnimation(
          parent: _c,
          curve: const Interval(0, 550 / 800, curve: KvMotion.ease),
        ),
      );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: const Interval(0, 550 * 0.7 / 800, curve: KvMotion.ease),
  );

  late final Animation<double> _draw = CurvedAnimation(
    parent: _c,
    curve: const Interval(300 / 800, 1, curve: KvMotion.easeOut),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    if (context.kvReduceMotion) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _fade,
        child: ScaleTransition(
          scale: _scale,
          child: Container(
            width: 132,
            height: 132,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.okBg, shape: BoxShape.circle),
            child: Container(
              width: 92,
              height: 92,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.ok, shape: BoxShape.circle),
              child: CustomPaint(
                size: const Size.square(46),
                painter: _CheckPainter(progress: _draw, color: c.onBrand),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Галочка значка check (m5 12.5 4.5 4.5L19 7.5), прорисованная на долю [progress].
class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.progress, required this.color}) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  static final Path _path = Path()
    ..moveTo(5, 12.5)
    ..lineTo(9.5, 17)
    ..lineTo(19, 7.5);

  @override
  void paint(Canvas canvas, Size size) {
    final double t = progress.value.clamp(0.0, 1.0);
    if (t <= 0) {
      return;
    }
    canvas.save();
    canvas.scale(size.shortestSide / 24);
    final Path part = Path();
    for (final ui.PathMetric m in _path.computeMetrics()) {
      part.addPath(m.extractPath(0, m.length * t), Offset.zero);
    }
    canvas.drawPath(
      part,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) => oldDelegate.color != color;
}
