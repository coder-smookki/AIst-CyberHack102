import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../core/kv.dart';

/// Рамка распознавания на кадре в процентах изображения camera.jpg.
@immutable
class MoFrameBox {
  /// Создаёт рамку.
  const MoFrameBox(this.x, this.y, this.w, this.h, {this.kind = KvArKind.defect, this.label});

  /// Левый край, % ширины кадра.
  final double x;

  /// Верхний край, % высоты кадра.
  final double y;

  /// Ширина, %.
  final double w;

  /// Высота, %.
  final double h;

  /// Вид рамки.
  final KvArKind kind;

  /// Подпись.
  final String? label;
}

/// Вырез кадра камеры: центр ([cx], [cy]) в долях, видимая доля ширины [vw] и отношение высоты к ширине [r].
@immutable
class MoFrameCrop {
  /// Создаёт вырез.
  const MoFrameCrop({required this.cx, required this.cy, required this.vw, required this.r});

  /// Центр по горизонтали.
  final double cx;

  /// Центр по вертикали.
  final double cy;

  /// Видимая доля ширины кадра.
  final double vw;

  /// Высота области к ширине.
  final double r;

  /// Кадр Н-101 с течью у вала.
  static const MoFrameCrop n101 = MoFrameCrop(cx: 0.42, cy: 0.60, vw: 0.64, r: 0.56);

  /// Кадр АМС-2: пол, основание и лужа.
  static const MoFrameCrop ams2 = MoFrameCrop(cx: 0.32, cy: 0.83, vw: 0.7, r: 0.5);
}

/// Признак «Течь у вала» на кадре Н-101.
const MoFrameBox moLeakBox = MoFrameBox(31, 57, 11, 11, label: 'Течь у вала');

/// Признак «Лужа под агрегатом» на кадре АМС-2.
const MoFrameBox moPuddleBox = MoFrameBox(13, 77.3, 30, 7, label: 'Лужа под агрегатом');

/// Врезка кадра камеры в карточке (.d-frame): вырез camera.jpg со скруглением 20, рамки признаков,
/// подпись кадра слева внизу и необязательная кнопка справа внизу.
class MoFrame extends StatelessWidget {
  /// Создаёт врезку.
  const MoFrame({super.key, required this.crop, this.boxes = const <MoFrameBox>[], this.chip, this.action});

  /// Вырез кадра.
  final MoFrameCrop crop;

  /// Рамки признаков.
  final List<MoFrameBox> boxes;

  /// Подпись кадра: «Кадр 09:31 · INS-2209».
  final String? chip;

  /// Кнопка поверх кадра справа внизу.
  final Widget? action;

  /// Отношение высоты к ширине исходного кадра.
  static const double imageAspect = 1688 / 780;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return AspectRatio(
      aspectRatio: 1 / crop.r,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(KvRadius.card),
        child: ColoredBox(
          color: c.surface3,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final double w = box.maxWidth;
              final double h = box.maxHeight;
              final double vw = crop.vw;
              final double vh = vw * crop.r / imageAspect;
              final double left = math.max(0, math.min(1 - vw, crop.cx - vw / 2));
              final double top = math.max(0, math.min(1 - vh, crop.cy - vh / 2));
              final double iw = w / vw;
              final double ih = iw * imageAspect;
              final double dpr = MediaQuery.devicePixelRatioOf(context);
              final List<Widget> layers = [
                Positioned(
                  left: -left * iw,
                  top: -top * ih,
                  width: iw,
                  height: ih,
                  child: Image.asset(
                    KvCamView.asset,
                    fit: BoxFit.fill,
                    cacheWidth: math.min(780, (iw * dpr).round()),
                    gaplessPlayback: true,
                  ),
                ),
              ];
              for (final MoFrameBox b in boxes) {
                final double x = (b.x / 100 - left) / vw * w;
                final double y = (b.y / 100 - top) / vh * h;
                final double bw = b.w / 100 / vw * w;
                final double bh = b.h / 100 / vh * h;
                layers.add(
                  Positioned(
                    left: x,
                    top: y,
                    width: bw,
                    height: bh,
                    child: _FrameBox(kind: b.kind),
                  ),
                );
                if (b.label != null) {
                  final double yp = y / h * 100;
                  final double ly = math.max(y, 0);
                  layers.add(
                    Positioned(
                      left: x,
                      top: yp < 17 ? ly + 6 : ly - 26 - 6,
                      child: KvArLabel(text: b.label!, kind: b.kind),
                    ),
                  );
                }
              }
              if (chip != null) {
                layers.add(Positioned(left: 10, bottom: 10, child: MoFrameChip(chip!)));
              }
              if (action != null) {
                layers.add(Positioned(right: 8, bottom: 8, child: action!));
              }
              return Stack(children: layers);
            },
          ),
        ),
      ),
    );
  }
}

class _FrameBox extends StatelessWidget {
  const _FrameBox({required this.kind});

  final KvArKind kind;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Color color = switch (kind) {
      KvArKind.part => c.arPart,
      KvArKind.defect => c.arDefect,
      KvArKind.gauge => c.arGauge,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: kind == KvArKind.defect ? const Color(0x14E5483D) : null,
        borderRadius: BorderRadius.circular(KvRadius.xs),
        border: Border.all(color: color, width: 2),
        boxShadow: const [BoxShadow(color: Color(0x1F000000), spreadRadius: 1)],
      ),
    );
  }
}

/// Подпись кадра (.d-frame-chip): стеклянная таблетка 28 со значком камеры.
class MoFrameChip extends StatelessWidget {
  /// Создаёт подпись с текстом [text].
  const MoFrameChip(this.text, {super.key});

  /// Текст.
  final String text;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: c.arGlass, borderRadius: BorderRadius.circular(14)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KvIcon(KvIcons.camera, size: 16, color: c.arText),
          const SizedBox(width: 6),
          Text(KvFormat.typo(text), maxLines: 1, softWrap: false, style: context.kvText.label.copyWith(color: c.arText, height: 1.2)),
        ],
      ),
    );
  }
}

/// Уголки рамки прицела камеры (.ar-corners): белая скруглённая рамка 3 px, видны только углы 28 × 28.
class MoAimCorners extends StatelessWidget {
  /// Создаёт уголки.
  const MoAimCorners({super.key});

  @override
  Widget build(BuildContext context) => const CustomPaint(painter: _CornersPainter());
}

class _CornersPainter extends CustomPainter {
  const _CornersPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const double s = 28;
    canvas.save();
    final Path clip = Path()
      ..addRect(const Rect.fromLTWH(0, 0, s, s))
      ..addRect(Rect.fromLTWH(size.width - s, 0, s, s))
      ..addRect(Rect.fromLTWH(0, size.height - s, s, s))
      ..addRect(Rect.fromLTWH(size.width - s, size.height - s, s, s));
    canvas.clipPath(clip);
    canvas.drawRRect(
      RRect.fromRectAndRadius((Offset.zero & size).deflate(1.5), const Radius.circular(16.5)),
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CornersPainter oldDelegate) => false;
}
