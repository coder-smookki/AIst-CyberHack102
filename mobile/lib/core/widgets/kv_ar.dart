import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';

import '../icons/kv_icon.dart';
import '../theme/kv_theme.dart';
import 'kv_button.dart';
import 'kv_pressable.dart';

/// Кадр камеры с увеличением (KV.cam.view): изображение camera.jpg шириной [k] ширин области, точка кадра
/// ([cx], [cy]) в долях попадает в точку области ([tx], [ty]), насколько позволяют края изображения.
@immutable
class KvCamView {
  /// Создаёт вид кадра; [elementAspect] - отношение ширины области к высоте (по умолчанию как у экрана).
  const KvCamView({this.k = 1, this.cx = 0.5, this.cy = 0.5, this.tx = 0.5, this.ty = 0.5, this.elementAspect});

  /// Отношение ширины к высоте кадра camera.jpg (780 × 1688).
  static const double imageAspect = 780 / 1688;

  /// Путь к кадру камеры.
  static const String asset = 'assets/images/camera.jpg';

  /// Увеличение по ширине.
  final double k;

  /// Точка кадра по горизонтали, доля.
  final double cx;

  /// Точка кадра по вертикали, доля.
  final double cy;

  /// Куда в области поставить точку по горизонтали, доля.
  final double tx;

  /// Куда в области поставить точку по вертикали, доля.
  final double ty;

  /// Отношение ширины области к высоте.
  final double? elementAspect;

  double get _ky => k * (elementAspect ?? imageAspect) / imageAspect;

  double get _px => k > 1 ? ((k * cx - tx) / (k - 1)).clamp(0.0, 1.0) : 0.5;

  double get _py => _ky > 1 ? ((_ky * cy - ty) / (_ky - 1)).clamp(0.0, 1.0) : 0.5;

  /// Прямоугольник изображения внутри области размера [size].
  Rect imageRect(Size size) {
    final double w = size.width * k;
    final double h = w / imageAspect;
    return Rect.fromLTWH((size.width - w) * _px, (size.height - h) * _py, w, h);
  }

  /// Рамка распознавания в процентах кадра → в процентах области.
  Rect map(Rect detectionPercent) => Rect.fromLTWH(
        k * detectionPercent.left - _px * (k - 1) * 100,
        _ky * detectionPercent.top - _py * (_ky - 1) * 100,
        detectionPercent.width * k,
        detectionPercent.height * _ky,
      );
}

/// Вид рамки AR.
enum KvArKind {
  /// Узел (синяя).
  part,

  /// Признак дефекта (красная со свечением).
  defect,

  /// Манометр (зелёная).
  gauge,
}

/// Положение подписи относительно рамки (KV.cam.label).
enum KvArLabelPosition {
  /// Над рамкой слева.
  above,

  /// Над рамкой справа.
  aboveRight,

  /// Под рамкой.
  below,

  /// Слева от рамки.
  left,

  /// Справа от рамки.
  right,

  /// На нижней кромке рамки.
  edge,
}

/// Рамка поверх видео для [KvArStage].
@immutable
class KvArBoxData {
  /// Создаёт рамку в процентах области.
  const KvArBoxData(
    this.rect, {
    this.kind = KvArKind.part,
    this.onTap,
    this.label,
    this.labelPosition = KvArLabelPosition.above,
    this.labelIcon,
    this.semanticLabel,
    this.color,
  });

  /// Положение и размер в процентах области.
  final Rect rect;

  /// Вид.
  final KvArKind kind;

  /// Касание рамки.
  final VoidCallback? onTap;

  /// Подпись.
  final String? label;

  /// Где подпись.
  final KvArLabelPosition labelPosition;

  /// Значок подписи.
  final KvIcons? labelIcon;

  /// Подпись нажимаемой рамки для диктора; по умолчанию «Открыть».
  final String? semanticLabel;

  /// Цвет рамки и подписи вместо цвета вида: жёлтый «проверить» на живом видео.
  final Color? color;
}

/// Видео камеры с рамками распознавания (.ar-stage, .ar-box, .ar-label). Кадр - camera.jpg через [view].
class KvArStage extends StatelessWidget {
  /// Создаёт видео с рамками.
  const KvArStage({
    super.key,
    this.view = const KvCamView(),
    this.boxes = const <KvArBoxData>[],
    this.radius = 0,
    this.boxRadius = KvRadius.xs,
    this.glow = true,
    this.background,
  });

  /// Вид кадра.
  final KvCamView view;

  /// Рамки.
  final List<KvArBoxData> boxes;

  /// Скругление области (для врезок в карточках).
  final double radius;

  /// Скругление рамок: 8 на живом видео, 10 во врезках кадра (.b-frame .ar-box).
  final double boxRadius;

  /// Красное свечение рамок дефекта, как на живом видео (.b-cam); во врезках кадра его нет.
  final bool glow;

  /// Живое видео камеры вместо демонстрационного кадра: рисуется на всю область, рамки - в процентах области.
  final Widget? background;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: const Color(0xFF0E141C),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final Size size = box.biggest;
            final Rect img = view.imageRect(size);
            final double dpr = MediaQuery.devicePixelRatioOf(context);
            final List<Widget> layers = [
              if (background != null)
                Positioned.fill(child: background!)
              else
                Positioned.fromRect(
                  rect: img,
                  child: Image.asset(KvCamView.asset, fit: BoxFit.fill, cacheWidth: math.min(780, (img.width * dpr).round()), gaplessPlayback: true),
                ),
            ];
            for (final KvArBoxData b in boxes) {
              final Rect r = _clamp(b.rect);
              final Rect px = Rect.fromLTWH(r.left / 100 * size.width, r.top / 100 * size.height, r.width / 100 * size.width, r.height / 100 * size.height);
              layers.add(Positioned.fromRect(rect: px, child: _ArBox(kind: b.kind, onTap: b.onTap, colors: c, radius: boxRadius, glow: glow, semanticLabel: b.semanticLabel, color: b.color)));
            }
            for (final KvArBoxData b in boxes) {
              if (b.label != null) {
                layers.add(_label(b, size, c));
              }
            }
            return Stack(children: layers);
          },
        ),
      ),
    );
  }

  static Rect _clamp(Rect r) {
    final double x0 = math.max(r.left, 0);
    final double y0 = math.max(r.top, 0);
    final double x1 = math.min(r.right, 100);
    final double y1 = math.min(r.bottom, 100);
    return Rect.fromLTRB(x0, y0, x1, y1);
  }

  Widget _label(KvArBoxData b, Size s, KvColors c) {
    final Rect r = b.rect;
    double px(double v) => v / 100 * s.width;
    double py(double v) => v / 100 * s.height;
    final Widget label = KvArLabel(text: b.label!, kind: b.kind, icon: b.labelIcon, color: b.color);
    return switch (b.labelPosition) {
      KvArLabelPosition.below => Positioned(left: px(r.left), top: py(r.bottom) + 6, child: label),
      KvArLabelPosition.left => Positioned(right: s.width - px(r.left) + 6, top: py(r.top) + 6, child: label),
      KvArLabelPosition.right => Positioned(left: px(r.right) + 6, top: py(r.top), child: label),
      KvArLabelPosition.edge => Positioned(left: px(r.left) + 10, top: py(r.bottom) - 13, child: label),
      KvArLabelPosition.aboveRight => Positioned(right: s.width - px(r.right), top: py(r.top) - 32, child: label),
      KvArLabelPosition.above => Positioned(left: px(r.left), top: py(r.top) - 32, child: label),
    };
  }
}

class _ArBox extends StatelessWidget {
  const _ArBox({required this.kind, required this.onTap, required this.colors, required this.radius, required this.glow, this.semanticLabel, this.color});

  final KvArKind kind;
  final VoidCallback? onTap;
  final KvColors colors;
  final double radius;
  final bool glow;
  final String? semanticLabel;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color color = this.color ??
        switch (kind) {
          KvArKind.part => colors.arPart,
          KvArKind.defect => colors.arDefect,
          KvArKind.gauge => colors.arGauge,
        };
    final List<BoxShadow> shadows = kind == KvArKind.defect && glow
        ? [BoxShadow(color: colors.arGlass, spreadRadius: 1), kvCssShadow(0, 0, 18, colors.arDefect)]
        : const [BoxShadow(color: Color(0x1F000000), spreadRadius: 1)];
    final Widget box = CustomPaint(
      painter: _OuterShadowPainter(shadows: shadows, radius: radius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: kind == KvArKind.defect ? const Color(0x14E5483D) : null,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: color, width: 2),
        ),
      ),
    );
    if (onTap == null) {
      return box;
    }
    return KvPressable(onTap: onTap, highlight: false, semanticLabel: semanticLabel ?? 'Открыть', child: box);
  }
}

/// Внешняя тень рамки как CSS box-shadow: рисуется только снаружи рамки и не просвечивает через прозрачную заливку.
class _OuterShadowPainter extends CustomPainter {
  _OuterShadowPainter({required this.shadows, required this.radius});

  final List<BoxShadow> shadows;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect inner = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    canvas.save();
    canvas.clipPath(Path.combine(PathOperation.difference, Path()..addRect(inner.outerRect.inflate(80)), Path()..addRRect(inner)));
    for (final BoxShadow s in shadows) {
      canvas.drawRRect(inner.shift(s.offset).inflate(s.spreadRadius), s.toPaint());
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OuterShadowPainter old) => old.radius != radius || !listEquals(old.shadows, shadows);
}

/// Подпись рамки AR: таблетка 26 px цвета рамки с белым текстом 12.
class KvArLabel extends StatelessWidget {
  /// Создаёт подпись.
  const KvArLabel({super.key, required this.text, this.kind = KvArKind.part, this.icon, this.color});

  /// Текст.
  final String text;

  /// Вид (цвет).
  final KvArKind kind;

  /// Значок 14 слева.
  final KvIcons? icon;

  /// Цвет таблетки вместо цвета вида.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Color bg = color ??
        switch (kind) {
          KvArKind.part => c.arPart,
          KvArKind.defect => c.arDefect,
          KvArKind.gauge => c.arGauge,
        };
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(13), boxShadow: [kvCssShadow(0, 2, 8, const Color(0x40000000))]),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[KvIcon(icon!, size: 14, color: c.arText), const SizedBox(width: 5)],
          Text(text, maxLines: 1, softWrap: false, style: context.kvText.label.copyWith(fontWeight: FontWeight.w600, color: c.arText, height: 1.2)),
        ],
      ),
    );
  }
}

/// Стеклянная плашка состояния поверх видео (.ar-pill): точка «в эфире» или спиннер и текст.
class KvArPill extends StatelessWidget {
  /// Создаёт плашку.
  const KvArPill({super.key, required this.text, this.spinning = false, this.waiting = false});

  /// Текст: «Анализ видео · 24 кадр/с».
  final String text;

  /// Спиннер вместо точки.
  final bool spinning;

  /// Жёлтая точка ожидания вместо зелёной.
  final bool waiting;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return KvGlass(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: c.arGlass, borderRadius: BorderRadius.circular(22)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (spinning)
              KvSpinner(color: c.arText, size: 16, stroke: 2, period: const Duration(milliseconds: 900))
            else
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: waiting ? c.warn : c.arGauge,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: c.arGlass, spreadRadius: 3)],
                ),
              ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.kvText.sm.copyWith(fontWeight: FontWeight.w500, color: c.arText, height: 1.2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
