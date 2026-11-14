import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:path_parsing/path_parsing.dart';

import 'kv_icon_data.dart';

export 'kv_icon_data.dart';

/// Значок дизайна: линии 1,8 в сетке 24 × 24, рисуются синхронно и чётко в любом размере.
///
/// Пример: `KvIcon(KvIcons.scan, size: 26, color: context.kv.onBrand)`. Без [color] берётся цвет
/// из ближайшего [IconTheme] или [DefaultTextStyle].
class KvIcon extends StatelessWidget {
  /// Создаёт значок [icon] размером [size].
  const KvIcon(this.icon, {super.key, this.size = 24, this.color, this.semanticLabel});

  /// Какой значок рисовать.
  final KvIcons icon;

  /// Сторона квадрата значка.
  final double size;

  /// Цвет линий; по умолчанию цвет из [IconTheme].
  final Color? color;

  /// Подпись для экранного диктора; без неё значок считается декоративным.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Color resolved = color ?? IconTheme.of(context).color ?? DefaultTextStyle.of(context).style.color ?? const Color(0xFF000000);
    final Widget painted = CustomPaint(
      size: Size.square(size),
      painter: _KvIconPainter(icon, resolved),
    );
    if (semanticLabel == null) {
      return ExcludeSemantics(child: painted);
    }
    return Semantics(label: semanticLabel, image: true, child: painted);
  }
}

class _KvIconPainter extends CustomPainter {
  _KvIconPainter(this.icon, this.color);

  final KvIcons icon;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final _ParsedIcon parsed = _ParsedIcon.of(icon);
    final double k = size.shortestSide / 24;
    canvas.save();
    canvas.scale(k);
    if (parsed.stroke != null) {
      canvas.drawPath(
        parsed.stroke!,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
    }
    if (parsed.fill != null) {
      canvas.drawPath(parsed.fill!, Paint()..color = color..isAntiAlias = true);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_KvIconPainter oldDelegate) => oldDelegate.icon != icon || oldDelegate.color != color;
}

/// Разобранные контуры значка; каждый значок разбирается один раз за запуск.
class _ParsedIcon {
  _ParsedIcon(this.stroke, this.fill);

  final ui.Path? stroke;
  final ui.Path? fill;

  static final List<_ParsedIcon?> _cache = List<_ParsedIcon?>.filled(KvIcons.values.length, null);

  static _ParsedIcon of(KvIcons icon) => _cache[icon.index] ??= _parse(icon);

  static _ParsedIcon _parse(KvIcons icon) {
    ui.Path? stroke;
    ui.Path? fill;
    for (final KvIconPart part in icon.parts) {
      final _PathWriter writer = _PathWriter();
      writeSvgPathDataToPath(part.d, writer);
      if (part.filled) {
        (fill ??= ui.Path()).addPath(writer.path, Offset.zero);
      } else {
        (stroke ??= ui.Path()).addPath(writer.path, Offset.zero);
      }
    }
    return _ParsedIcon(stroke, fill);
  }
}

class _PathWriter extends PathProxy {
  final ui.Path path = ui.Path();

  @override
  void close() => path.close();

  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x3, double y3) => path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);
}
