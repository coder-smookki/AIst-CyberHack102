import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:path_parsing/path_parsing.dart';

import '../../../core/kv.dart';
import 'entry_motion.dart';

/// Оформление фигуры иллюстрации знакомства (классы .oa-* прототипа; цвета только из темы).
enum _Look {
  /// Мягкий круг фона: заливка tint.
  blob,

  /// Белая карточка с синим контуром 3.
  cardStroke,

  /// Серая подложка экрана: surface-2.
  soft,

  /// Синий контур 3 без заливки.
  stroke,

  /// Белая заливка и синий контур 2.
  stroke2,

  /// Рёбра двигателя: синий контур 2, прозрачность 0,45.
  fin,

  /// Пунктирная орбита обхода: синий контур 2, штрих 3 / 7, прозрачность 0,55.
  dash,

  /// Синяя заливка.
  ink,

  /// Синяя заливка с кольцом tint-2 толщиной 5.
  inkRing,

  /// Тонкое внутреннее кольцо: белый контур 1,6, прозрачность 0,35.
  inner,

  /// Строки текста: заливка text-3, прозрачность 0,55.
  mute,

  /// Зелёная заливка.
  ok,

  /// Жёлтая заливка.
  warn,

  /// Зелёные уголки рамки: контур 3.
  okStroke,

  /// Жёлтые уголки рамки: контур 3.
  warnStroke,

  /// Белая галочка: контур 3,4.
  white,

  /// Белая галочка поменьше: контур 2,4.
  white2,

  /// Белая точка.
  whiteDot,

  /// Линия сканирования: синяя, движется сверху вниз.
  scan,
}

/// Фигура иллюстрации в координатах viewBox 320 × 260.
class _Shape {
  const _Shape.rect(this.look, double x, double y, double w, double h, double r)
    : kind = 0,
      pop = 0,
      a = x,
      b = y,
      c = w,
      d = h,
      e = r,
      path = null;

  const _Shape.circle(this.look, double cx, double cy, double r, {this.pop = 0})
    : kind = 1,
      a = cx,
      b = cy,
      c = r,
      d = r,
      e = 0,
      path = null;

  const _Shape.ellipse(this.look, double cx, double cy, double rx, double ry)
    : kind = 1,
      a = cx,
      b = cy,
      c = rx,
      d = ry,
      e = 0,
      pop = 0,
      path = null;

  const _Shape.path(this.look, String this.path, {this.pop = 0}) : kind = 2, a = 0, b = 0, c = 0, d = 0, e = 0;

  final _Look look;
  final int kind;
  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final String? path;

  /// Группа всплытия: 0 - без анимации, 1 - через 0,3 с, 2 - через 0,48 с.
  final int pop;
}

/// Иллюстрации трёх шагов знакомства (ART в screens/10_entry.js) и центры групп всплытия.
const List<List<_Shape>> _art = [
  [
    _Shape.circle(_Look.blob, 262, 66, 34),
    _Shape.circle(_Look.blob, 58, 200, 26),
    _Shape.rect(_Look.cardStroke, 104, 20, 112, 220, 22),
    _Shape.rect(_Look.soft, 114, 36, 92, 190, 13),
    _Shape.rect(_Look.mute, 146, 26, 28, 4, 2),
    _Shape.path(_Look.stroke, 'M124 100v-12h12M184 88h12v12M196 158v12h-12M136 170h-12v-12'),
    _Shape.rect(_Look.stroke2, 134, 106, 52, 46, 6),
    _Shape.rect(_Look.ink, 141, 115, 24, 5, 2.5),
    _Shape.rect(_Look.mute, 141, 127, 38, 4, 2),
    _Shape.rect(_Look.mute, 141, 137, 30, 4, 2),
    _Shape.rect(_Look.scan, 126, 94, 68, 3, 1.5),
    _Shape.circle(_Look.inkRing, 212, 198, 22, pop: 1),
    _Shape.path(_Look.white, 'M202 198l7 7 13-14', pop: 1),
  ],
  [
    _Shape.ellipse(_Look.dash, 160, 128, 114, 104),
    _Shape.path(_Look.stroke, 'M30 128h24M30 128l8-8M30 128l8 8'),
    _Shape.path(_Look.stroke, 'M290 128h-24M290 128l-8-8M290 128l-8 8'),
    _Shape.rect(_Look.cardStroke, 142, 26, 36, 12, 5),
    _Shape.rect(_Look.cardStroke, 128, 38, 64, 84, 14),
    _Shape.path(_Look.fin, 'M146 54v52M160 54v52M174 54v52'),
    _Shape.rect(_Look.cardStroke, 148, 122, 24, 14, 3),
    _Shape.rect(_Look.cardStroke, 130, 136, 60, 46, 16),
    _Shape.rect(_Look.cardStroke, 72, 196, 176, 26, 13),
    _Shape.circle(_Look.cardStroke, 90, 209, 7),
    _Shape.circle(_Look.mute, 230, 209, 7),
    _Shape.path(_Look.okStroke, 'M118 32v-12h12M190 20h12v12M202 116v12h-12M130 128h-12v-12'),
    _Shape.path(_Look.warnStroke, 'M120 140v-8h8M192 132h8v8M200 180v8h-8M128 188h-8v-8'),
    _Shape.circle(_Look.ok, 160, 80, 13, pop: 1),
    _Shape.path(_Look.white2, 'M154 80l4 4 8-8', pop: 1),
    _Shape.circle(_Look.warn, 160, 159, 13, pop: 2),
    _Shape.path(_Look.white2, 'M160 152v8', pop: 2),
    _Shape.circle(_Look.whiteDot, 160, 165.5, 1.8, pop: 2),
  ],
  [
    _Shape.circle(_Look.blob, 254, 62, 30),
    _Shape.circle(_Look.blob, 64, 206, 24),
    _Shape.rect(_Look.cardStroke, 92, 24, 136, 204, 16),
    _Shape.rect(_Look.soft, 108, 40, 104, 68, 8),
    _Shape.path(_Look.stroke, 'M114 98l24-26 18 16 20-26 30 32'),
    _Shape.circle(_Look.mute, 198, 54, 5),
    _Shape.rect(_Look.mute, 108, 122, 96, 5, 2.5),
    _Shape.rect(_Look.mute, 108, 134, 70, 5, 2.5),
    _Shape.rect(_Look.mute, 108, 146, 84, 5, 2.5),
    _Shape.path(_Look.stroke, 'M116 182h18M125 173v18'),
    _Shape.circle(_Look.inkRing, 222, 196, 30, pop: 1),
    _Shape.circle(_Look.inner, 222, 196, 22, pop: 1),
    _Shape.path(_Look.white, 'M210 196l8 8 16-17', pop: 1),
    _Shape.circle(_Look.ok, 74, 90, 11, pop: 2),
    _Shape.path(_Look.white2, 'M69 90l3.5 3.5 6.5-7', pop: 2),
  ],
];

/// Центры групп всплытия по шагам: transform-origin центра круга группы.
const List<List<Offset>> _popCenters = [
  [Offset(212, 198)],
  [Offset(160, 80), Offset(160, 159)],
  [Offset(222, 196), Offset(74, 90)],
];

/// Иллюстрация шага знакомства [step] (1-3): штриховая графика в цветах темы, значки всплывают при появлении,
/// на первом шаге линия сканирования проходит по шильдику.
class OnboardingArt extends StatefulWidget {
  /// Создаёт иллюстрацию шага.
  const OnboardingArt({super.key, required this.step});

  /// Номер шага 1-3.
  final int step;

  @override
  State<OnboardingArt> createState() => _OnboardingArtState();
}

class _OnboardingArtState extends State<OnboardingArt> with TickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 480 + 550),
  );
  late final AnimationController _scan = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    if (context.kvReduceMotion) {
      _pop.value = 1;
      return;
    }
    _pop.forward();
    if (widget.step == 1) {
      _scan.repeat();
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    _scan.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ArtPainter(
          shapes: _art[widget.step - 1],
          centers: _popCenters[widget.step - 1],
          colors: c,
          pop: _pop,
          scan: widget.step == 1 && !context.kvReduceMotion ? _scan : null,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _ArtPainter extends CustomPainter {
  _ArtPainter({required this.shapes, required this.centers, required this.colors, required this.pop, required this.scan})
    : super(repaint: Listenable.merge([pop, ?scan]));

  final List<_Shape> shapes;
  final List<Offset> centers;
  final KvColors colors;
  final Animation<double> pop;
  final Animation<double>? scan;

  static final Map<String, Path> _paths = {};

  static Path _parse(String d) => _paths.putIfAbsent(d, () {
    final _Writer w = _Writer();
    writeSvgPathDataToPath(d, w);
    return w.path;
  });

  /// Прогресс всплытия группы [group] (kvPopIn: 550 мс, задержка 300 или 480 мс).
  double _popValue(int group) {
    final double ms = pop.value * 1030;
    final double start = group == 1 ? 300 : 480;
    return kEntryPopCurve.transform(((ms - start) / 550).clamp(0.0, 1.0));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const double vw = 320;
    const double vh = 260;
    final double maxW = size.width < 340 ? size.width : 340;
    final double k = (maxW / vw) < (size.height / vh) ? maxW / vw : size.height / vh;
    canvas.save();
    canvas.translate((size.width - vw * k) / 2, (size.height - vh * k) / 2);
    canvas.scale(k);
    int group = -1;
    for (final _Shape s in shapes) {
      if (s.pop != group) {
        if (group > 0) {
          canvas.restore();
        }
        group = s.pop;
        if (group > 0) {
          final double v = _popValue(group);
          final Offset o = centers[group - 1];
          if (v >= 1) {
            canvas.save();
          } else {
            canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, v.clamp(0.0, 1.0)));
          }
          canvas.translate(o.dx, o.dy);
          canvas.scale(0.4 + 0.6 * v);
          canvas.translate(-o.dx, -o.dy);
        }
      }
      _draw(canvas, s);
    }
    if (group > 0) {
      canvas.restore();
    }
    canvas.restore();
  }

  void _draw(Canvas canvas, _Shape s) {
    final KvColors c = colors;
    Path geometry() => switch (s.kind) {
      0 => Path()..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(s.a, s.b, s.c, s.d), Radius.circular(s.e))),
      1 => Path()..addOval(Rect.fromCenter(center: Offset(s.a, s.b), width: s.c * 2, height: s.d * 2)),
      _ => _parse(s.path!),
    };
    Paint fill(Color color, [double opacity = 1]) => Paint()..color = color.withValues(alpha: color.a * opacity);
    Paint stroke(Color color, double width, [double opacity = 1]) => Paint()
      ..color = color.withValues(alpha: color.a * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final Path p = geometry();
    switch (s.look) {
      case _Look.blob:
        canvas.drawPath(p, fill(c.tint));
      case _Look.cardStroke:
        canvas.drawPath(p, fill(c.surface));
        canvas.drawPath(p, stroke(c.brand, 3));
      case _Look.soft:
        canvas.drawPath(p, fill(c.surface2));
      case _Look.stroke:
        canvas.drawPath(p, stroke(c.brand, 3));
      case _Look.stroke2:
        canvas.drawPath(p, fill(c.surface));
        canvas.drawPath(
          p,
          stroke(c.brand, 2)
            ..strokeCap = StrokeCap.butt
            ..strokeJoin = StrokeJoin.miter,
        );
      case _Look.fin:
        canvas.drawPath(p, stroke(c.brand, 2, 0.45));
      case _Look.dash:
        canvas.drawPath(_dashed(p, 3, 7), stroke(c.brand, 2, 0.55));
      case _Look.ink:
        canvas.drawPath(p, fill(c.brand));
      case _Look.inkRing:
        canvas.drawPath(p, fill(c.brand));
        canvas.drawPath(p, stroke(c.tint2, 5)..strokeCap = StrokeCap.butt);
      case _Look.inner:
        canvas.drawPath(p, stroke(c.onBrand, 1.6, 0.35));
      case _Look.mute:
        canvas.drawPath(p, fill(c.text3, 0.55));
      case _Look.ok:
        canvas.drawPath(p, fill(c.ok));
      case _Look.warn:
        canvas.drawPath(p, fill(c.warn));
      case _Look.okStroke:
        canvas.drawPath(p, stroke(c.ok, 3));
      case _Look.warnStroke:
        canvas.drawPath(p, stroke(c.warn, 3));
      case _Look.white:
        canvas.drawPath(p, stroke(c.onBrand, 3.4));
      case _Look.white2:
        canvas.drawPath(p, stroke(c.onBrand, 2.4));
      case _Look.whiteDot:
        canvas.drawPath(p, fill(c.onBrand));
      case _Look.scan:
        final Animation<double>? a = scan;
        if (a == null) {
          return;
        }
        final double t = a.value;
        final double y = 68 * KvMotion.ease.transform(t);
        final double opacity = 0.55 * _scanOpacity(t);
        if (opacity <= 0) {
          return;
        }
        canvas.save();
        canvas.translate(0, y);
        canvas.drawPath(p, fill(c.brand, opacity));
        canvas.restore();
    }
  }

  /// Прозрачность линии сканирования onbScan: проявляется к 15 %, держится до 85 %, гаснет к концу.
  static double _scanOpacity(double t) {
    if (t < 0.15) {
      return KvMotion.ease.transform(t / 0.15);
    }
    if (t < 0.85) {
      return 1;
    }
    return 1 - KvMotion.ease.transform((t - 0.85) / 0.15);
  }

  /// Пунктир stroke-dasharray [dash] [gap] вдоль контура [source].
  static Path _dashed(Path source, double dash, double gap) {
    final Path out = Path();
    for (final ui.PathMetric m in source.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        out.addPath(m.extractPath(d, d + dash), Offset.zero);
        d += dash + gap;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(_ArtPainter oldDelegate) => oldDelegate.shapes != shapes || oldDelegate.colors != colors;
}

class _Writer extends PathProxy {
  final Path path = Path();

  @override
  void close() => path.close();

  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x3, double y3) => path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);
}
