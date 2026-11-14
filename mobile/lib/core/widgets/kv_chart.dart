import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../format/kv_format.dart';
import '../theme/kv_theme.dart';
import 'kv_chip.dart';

/// Данные графика: значения, уставки, подписи оси. Строится из ряда телеметрии.
@immutable
class KvSeriesData {
  /// Создаёт данные графика.
  const KvSeriesData({
    required this.values,
    this.warn,
    this.alarm,
    this.min,
    this.max,
    this.unit,
    this.digits,
    this.labels = const <String>[],
  });

  /// Значения слева направо, последнее - текущее показание.
  final List<double> values;

  /// Уставка предупреждения.
  final double? warn;

  /// Аварийная уставка.
  final double? alarm;

  /// Нижняя граница шкалы вместо расчётной.
  final double? min;

  /// Верхняя граница шкалы вместо расчётной.
  final double? max;

  /// Единица измерения для пузыря и легенды.
  final String? unit;

  /// Знаков после запятой.
  final int? digits;

  /// Подписи под осью.
  final List<String> labels;

  /// Последнее значение.
  double get last => values.last;
}

/// Уровень цвета значения: 0 - норма, 1 - предупреждение, 2 - авария, плавно у уставок (KV.level).
double kvLevel(double v, double? warn, double? alarm, double band) {
  double smooth(double e0, double e1, double x) {
    final double t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  double l = 0;
  if (warn != null) {
    l += smooth(warn - band, warn + band, v);
  }
  if (alarm != null) {
    l += smooth(alarm - band, alarm + band, v);
  }
  return l;
}

/// Цвет уровня: синий, смешение с жёлтым, жёлтый, смешение с красным, красный (KV.levelColor).
Color kvLevelColor(KvColors c, double l) {
  if (l <= 0.001) {
    return c.chartOk;
  }
  if (l < 0.999) {
    return Color.lerp(c.chartOk, c.chartWarn, (l * 100).round() / 100)!;
  }
  if (l <= 1.001) {
    return c.chartWarn;
  }
  if (l < 1.999) {
    return Color.lerp(c.chartWarn, c.chartAlarm, ((l - 1) * 100).round() / 100)!;
  }
  return c.chartAlarm;
}

/// Границы шкалы графика как в прототипе: уставки попадают в шкалу, минимальный размах, поля 12 %.
({double min, double max}) kvChartBounds(KvSeriesData d, {bool setpoints = true, double minSpan = 0.18}) {
  double lo = d.values.reduce(math.min);
  double hi = d.values.reduce(math.max);
  if (setpoints) {
    if (d.warn != null) {
      lo = math.min(lo, d.warn!);
      hi = math.max(hi, d.warn!);
    }
    if (d.alarm != null && d.alarm! < hi * 1.6) {
      hi = math.max(hi, d.alarm!);
    }
  }
  final double mid = (hi + lo) / 2;
  double span = mid.abs() * minSpan;
  if (span == 0) {
    span = 1;
  }
  if (hi - lo < span) {
    lo = mid - span / 2;
    hi = mid + span / 2;
  }
  double pad = (hi - lo) * 0.12;
  if (pad == 0) {
    pad = 1;
  }
  return (min: d.min ?? lo - pad, max: d.max ?? hi + pad);
}

/// График по уставкам (KV.areaChart): плавная линия и заливка меняют цвет синий - жёлтый - красный по значению,
/// полосатая заливка, пунктир уставок, точка и пузырь последнего значения, прорисовка слева направо при появлении.
class KvAreaChart extends StatelessWidget {
  /// Создаёт график.
  const KvAreaChart({
    super.key,
    required this.data,
    this.height = 200,
    this.stripes = true,
    this.setpoints = true,
    this.bubble,
    this.showBubble = false,
    this.dot = true,
    this.legend = false,
    this.legendItems,
    this.showLabels = true,
    this.strokeWidth = 2.6,
    this.minSpan = 0.18,
    this.reveal = true,
  });

  /// Данные.
  final KvSeriesData data;

  /// Высота области графика.
  final double height;

  /// Полосатая заливка.
  final bool stripes;

  /// Пунктир уставок и учёт уставок в шкале.
  final bool setpoints;

  /// Свой текст пузыря.
  final String? bubble;

  /// Показать пузырь с последним значением и единицей.
  final bool showBubble;

  /// Точка последнего значения.
  final bool dot;

  /// Легенда «норма / выше уставки / выше аварийной».
  final bool legend;

  /// Своя легенда: пары цвет - подпись.
  final List<(Color, String)>? legendItems;

  /// Подписи оси из [KvSeriesData.labels].
  final bool showLabels;

  /// Толщина линии.
  final double strokeWidth;

  /// Минимальный размах шкалы, доля от среднего.
  final double minSpan;

  /// Прорисовка слева направо при появлении.
  final bool reveal;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final ({double min, double max}) b = kvChartBounds(data, setpoints: setpoints, minSpan: minSpan);
    final double band = (b.max - b.min) * 0.035;
    final double last = data.last;
    final double lastY = 6 + (1 - (last - b.min) / (b.max - b.min)) * (height - 12);
    final Color lastColor = kvLevelColor(c, kvLevel(last, data.warn, data.alarm, band));
    final int digits = data.digits ?? 1;
    final String? bubbleText = bubble ?? (showBubble ? '${KvFormat.num(last, digits)}${data.unit == null ? '' : '${KvFormat.nbsp}${data.unit}'}' : null);
    final Widget plot = SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double w = box.maxWidth;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _AreaPainter(
                      data: data,
                      colors: c,
                      min: b.min,
                      max: b.max,
                      band: band,
                      stripes: stripes,
                      setpoints: setpoints,
                      strokeWidth: strokeWidth,
                    ),
                  ),
                ),
              ),
              if (dot)
                Positioned(
                  left: w - 6,
                  top: lastY - 6,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: c.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: lastColor, width: 2.5),
                    ),
                  ),
                ),
              if (bubbleText != null)
                Positioned(
                  right: -6,
                  bottom: height - lastY,
                  child: FractionalTranslation(
                    translation: const Offset(0, -0.3),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(12), boxShadow: c.shadow2),
                      child: Text(bubbleText, maxLines: 1, softWrap: false, style: t.caption.copyWith(fontWeight: FontWeight.w600, color: c.text, height: 1.25)),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    final List<Widget> parts = [reveal ? _Reveal(child: plot) : plot];
    if (showLabels && data.labels.isNotEmpty) {
      parts.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [for (final String l in data.labels) Text(l, style: t.label.copyWith(fontWeight: FontWeight.w400, color: c.chartAxis))],
        ),
      ));
    }
    if (legend || legendItems != null) {
      final List<(Color, String)> items = legendItems ??
          [
            (c.chartOk, 'норма'),
            if (data.warn != null) (c.chartWarn, 'выше ${KvFormat.num(data.warn, digits)}'),
            if (data.alarm != null)
              (c.chartAlarm, 'выше ${KvFormat.num(data.alarm, digits)}${data.unit == null ? '' : '${KvFormat.nbsp}${data.unit}'}'),
          ];
      parts.add(Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Wrap(
          spacing: 14,
          runSpacing: 6,
          children: [
            for (final (Color color, String label) in items)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  KvDot(color: color),
                  const SizedBox(width: 6),
                  Text(label, style: t.label.copyWith(fontWeight: FontWeight.w400)),
                ],
              ),
          ],
        ),
      ));
    }
    if (parts.length == 1) {
      return parts.first;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: parts);
  }
}

/// Спарклайн плитки (KV.sparkline): та же окраска по уставкам, без полос, пунктира и точки.
class KvSparkline extends StatelessWidget {
  /// Создаёт спарклайн.
  const KvSparkline({super.key, required this.data, this.height = defaultHeight});

  /// Высота по умолчанию.
  static const double defaultHeight = 36;

  /// Данные.
  final KvSeriesData data;

  /// Высота.
  final double height;

  @override
  Widget build(BuildContext context) {
    return KvAreaChart(
      data: KvSeriesData(values: data.values, warn: data.warn, alarm: data.alarm, min: data.min, max: data.max),
      height: height,
      minSpan: 0.1,
      stripes: false,
      setpoints: false,
      dot: false,
      showLabels: false,
      strokeWidth: 2.2,
    );
  }
}

class _AreaPainter extends CustomPainter {
  _AreaPainter({
    required this.data,
    required this.colors,
    required this.min,
    required this.max,
    required this.band,
    required this.stripes,
    required this.setpoints,
    required this.strokeWidth,
  });

  final KvSeriesData data;
  final KvColors colors;
  final double min;
  final double max;
  final double band;
  final bool stripes;
  final bool setpoints;
  final double strokeWidth;

  double _y(double v, double h) => 6 + (1 - (v - min) / (max - min)) * (h - 12);

  @override
  void paint(Canvas canvas, Size size) {
    final List<double> vals = data.values;
    final int n = vals.length;
    if (n < 2 || size.width <= 0) {
      return;
    }
    final double w = size.width;
    final double h = size.height;
    final List<Offset> pts = [for (int i = 0; i < n; i++) Offset(i / (n - 1) * w, _y(vals[i], h))];
    final Path line = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (int i = 0; i < n - 1; i++) {
      final Offset p0 = i > 0 ? pts[i - 1] : pts[i];
      final Offset p1 = pts[i];
      final Offset p2 = pts[i + 1];
      final Offset p3 = i + 2 < n ? pts[i + 2] : p2;
      line.cubicTo(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
        p2.dx,
        p2.dy,
      );
    }
    final Path area = Path.from(line)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    final int step = math.max(1, n ~/ 90);
    final List<Color> stopColors = [];
    final List<double> stops = [];
    for (int i = 0; i < n; i += step) {
      stops.add(i / (n - 1));
      stopColors.add(kvLevelColor(colors, kvLevel(vals[i], data.warn, data.alarm, band)));
    }
    if ((n - 1) % step != 0) {
      stops.add(1);
      stopColors.add(kvLevelColor(colors, kvLevel(vals[n - 1], data.warn, data.alarm, band)));
    }
    final ui.Gradient hGrad = ui.Gradient.linear(Offset.zero, Offset(w, 0), stopColors, stops);

    if (setpoints) {
      if (data.warn != null && data.warn! < max) {
        _dash(canvas, _y(data.warn!, h), w, colors.chartWarn);
      }
      if (data.alarm != null && data.alarm! < max) {
        _dash(canvas, _y(data.alarm!, h), w, colors.chartAlarm);
      }
    }

    final Rect bounds = Rect.fromLTWH(0, 0, w, h);
    canvas.saveLayer(bounds, Paint());
    canvas.drawPath(area, Paint()..shader = hGrad);
    canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.dstIn);
    final double topAlpha = stripes ? 0.22 : 0.30;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, h),
          [Color.fromRGBO(255, 255, 255, topAlpha), const Color.fromRGBO(255, 255, 255, 0)],
        ),
    );
    if (stripes) {
      final double pw = math.max(8, 1000 / math.min(n, 70)) * w / 1000;
      final Paint stripe = Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, h),
          [const Color.fromRGBO(255, 255, 255, 0.62), const Color.fromRGBO(255, 255, 255, 0.06)],
        );
      for (double x = 0; x < w; x += pw) {
        canvas.drawRect(Rect.fromLTWH(x, 0, pw * 0.42, h), stripe);
      }
    }
    canvas.restore();
    canvas.restore();

    canvas.drawPath(
      line,
      Paint()
        ..shader = hGrad
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _dash(Canvas canvas, double y, double w, Color color) {
    final Paint p = Paint()
      ..color = color.withValues(alpha: 0.9 * color.a)
      ..strokeWidth = 1.4;
    for (double x = 0; x < w; x += 10) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, w), y), p);
    }
  }

  @override
  bool shouldRepaint(_AreaPainter old) =>
      old.data != data || old.colors != colors || old.min != min || old.max != max || old.stripes != stripes || old.strokeWidth != strokeWidth;
}

/// Прорисовка графика слева направо за 1,1 с при первом показе (kvReveal).
class _Reveal extends StatefulWidget {
  const _Reveal({required this.child});

  final Widget child;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: KvMotion.chartReveal);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: KvMotion.easeOut);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.status == AnimationStatus.dismissed) {
      if (context.kvReduceMotion) {
        _c.value = 1;
      } else {
        _c.forward();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(clipper: _RevealClipper(_t), child: widget.child);
  }
}

class _RevealClipper extends CustomClipper<Rect> {
  _RevealClipper(this.t) : super(reclip: t);

  final Animation<double> t;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-20, -60, -20 + (size.width + 80) * t.value, size.height + 20);

  @override
  bool shouldReclip(_RevealClipper oldClipper) => oldClipper.t != t;
}

/// Столбики наработки по месяцам (KV.bars): подписи значений сверху, выделенный месяц синий.
class KvBars extends StatelessWidget {
  /// Создаёт столбики.
  const KvBars({super.key, required this.items, this.height = 150, this.digits = 0, this.max});

  /// Столбики: подпись, значение, выделение.
  final List<({String label, double value, bool highlight})> items;

  /// Высота области.
  final double height;

  /// Знаков после запятой в подписи значения.
  final int digits;

  /// Максимум шкалы; по умолчанию наибольшее значение.
  final double? max;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final double top = max ?? items.map((e) => e.value).reduce(math.max);
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(KvFormat.num(items[i].value, digits), maxLines: 1, softWrap: false, style: t.micro.copyWith(color: c.text2)),
                  const SizedBox(height: 6),
                  Flexible(
                    child: LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints box) => Container(
                        width: math.min(30, box.maxWidth),
                        height: math.min(box.maxHeight, height * math.max(4, items[i].value / top * 100 * 0.78) / 100),
                        decoration: BoxDecoration(
                          color: items[i].highlight ? c.btnPrimary : c.tint,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(8), bottom: Radius.circular(4)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(items[i].label, maxLines: 1, softWrap: false, style: t.micro.copyWith(fontWeight: FontWeight.w400)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Кольцо покрытия осмотра 44 × 44 (.b-ring): доля [done] из [total] и подпись «5/9».
class KvRingGauge extends StatelessWidget {
  /// Создаёт кольцо.
  const KvRingGauge({super.key, required this.done, required this.total, this.size = 44, this.stroke = 4, this.label});

  /// Сколько готово.
  final int done;

  /// Сколько всего.
  final int total;

  /// Диаметр.
  final double size;

  /// Толщина кольца.
  final double stroke;

  /// Своя подпись в центре.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _RingGaugePainter(fraction: total == 0 ? 0 : done / total, track: c.tint, fill: c.brand, stroke: stroke),
        child: Center(
          child: Text(
            label ?? '$done/$total',
            style: context.kvText.label.copyWith(fontWeight: FontWeight.w600, color: c.brand, height: 1),
          ),
        ),
      ),
    );
  }
}

class _RingGaugePainter extends CustomPainter {
  _RingGaugePainter({required this.fraction, required this.track, required this.fill, required this.stroke});

  final double fraction;
  final Color track;
  final Color fill;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final double r = size.shortestSide / 2 - stroke / 2 - 2;
    final Offset center = size.center(Offset.zero);
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(center, r, p..color = track);
    if (fraction > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        -math.pi / 2,
        2 * math.pi * fraction.clamp(0, 1),
        false,
        p
          ..color = fill
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_RingGaugePainter old) => old.fraction != fraction || old.track != track || old.fill != fill;
}
