import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../icons/kv_icon.dart';
import '../theme/kv_theme.dart';
import 'kv_chip.dart';
import 'kv_pressable.dart';

/// Вид кнопки (.btn-primary, .btn-secondary, .btn-tonal, .btn-danger, .btn-danger-soft, .btn-ghost).
enum KvButtonKind {
  /// Синяя основная.
  primary,

  /// Белая с рамкой и синим текстом.
  secondary,

  /// Светло-синяя.
  tonal,

  /// Красная.
  danger,

  /// Светло-красная.
  dangerSoft,

  /// Без фона.
  ghost,
}

/// Кнопка дизайна: высота 54 (малая - 44), скругление 16, текст 16 полужирный, значок 20 слева или справа.
///
/// [wait] показывает спиннер 0,9 с перед действием, как data-wait в прототипе; [loading] - спиннер постоянно;
/// без [onPressed] кнопка неактивна и полупрозрачна. Пример:
/// `KvButton('Начать осмотр', icon: KvIcons.scan, onPressed: () => context.push(...))`.
class KvButton extends StatefulWidget {
  /// Создаёт кнопку с текстом [label].
  const KvButton(
    this.label, {
    super.key,
    this.onPressed,
    this.kind = KvButtonKind.primary,
    this.icon,
    this.iconRight,
    this.small = false,
    this.expand,
    this.loading = false,
    this.wait = false,
  });

  /// Текст кнопки.
  final String label;

  /// Действие; null - кнопка неактивна.
  final VoidCallback? onPressed;

  /// Вид кнопки.
  final KvButtonKind kind;

  /// Значок слева.
  final KvIcons? icon;

  /// Значок справа.
  final KvIcons? iconRight;

  /// Малая кнопка: высота 44, текст 14, ширина по содержимому.
  final bool small;

  /// Растягивать на всю ширину; по умолчанию обычная растягивается, малая - нет.
  final bool? expand;

  /// Постоянный спиннер вместо текста.
  final bool loading;

  /// Спиннер 0,9 с перед действием.
  final bool wait;

  @override
  State<KvButton> createState() => _KvButtonState();
}

class _KvButtonState extends State<KvButton> {
  bool _waiting = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _press() {
    final VoidCallback? action = widget.onPressed;
    if (action == null || _waiting) {
      return;
    }
    if (!widget.wait || context.kvReduceMotion) {
      action();
      return;
    }
    setState(() => _waiting = true);
    _timer = Timer(KvMotion.wait, () {
      if (!mounted) {
        return;
      }
      setState(() => _waiting = false);
      action();
    });
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final (Color bg, Color fg, Color? border) = switch (widget.kind) {
      KvButtonKind.primary => (c.btnPrimary, c.onBrand, null),
      KvButtonKind.secondary => (c.surface, c.brand, c.border),
      KvButtonKind.tonal => (c.tint, c.brand, null),
      KvButtonKind.danger => (c.bad, const Color(0xFFFFFFFF), null),
      KvButtonKind.dangerSoft => (c.badBg, c.bad, null),
      KvButtonKind.ghost => (const Color(0x00000000), c.brand, null),
    };
    final bool busy = widget.loading || _waiting;
    final bool enabled = widget.onPressed != null;
    final double height = widget.small ? 44 : 54;
    final double radius = widget.small ? 14 : KvRadius.btn;
    final double fontSize = widget.small ? 14 : 16;
    final bool expand = widget.expand ?? !widget.small;
    final Color spinner = switch (widget.kind) {
      KvButtonKind.secondary || KvButtonKind.tonal || KvButtonKind.ghost => c.brand,
      _ => c.onBrand,
    };
    final TextStyle style = context.kvText.btn.copyWith(fontSize: fontSize, color: fg);
    Widget label = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[KvIcon(widget.icon!, size: 20, color: fg), const SizedBox(width: KvSpace.s2)],
        Flexible(child: Text(widget.label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false)),
        if (widget.iconRight != null) ...[const SizedBox(width: KvSpace.s2), KvIcon(widget.iconRight!, size: 20, color: fg)],
      ],
    );
    label = Stack(
      alignment: Alignment.center,
      children: [
        Opacity(opacity: busy ? 0 : 1, child: label),
        if (busy) KvSpinner(color: spinner),
      ],
    );
    final Widget box = Container(
      height: height,
      width: expand ? double.infinity : null,
      padding: expand ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: widget.small ? KvSpace.s4 : KvSpace.s5),
      alignment: expand ? Alignment.center : null,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: border == null ? null : Border.all(color: border),
      ),
      child: expand ? label : Center(widthFactor: 1, child: label),
    );
    return Semantics(
      button: true,
      enabled: enabled && !busy,
      label: widget.label,
      excludeSemantics: true,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.42,
        duration: KvMotion.std,
        child: IgnorePointer(
          ignoring: !enabled || busy,
          child: KvPressable(
            onTap: _press,
            immediate: true,
            button: false,
            borderRadius: BorderRadius.circular(radius),
            child: box,
          ),
        ),
      ),
    );
  }
}

/// Круглая кнопка 44 × 44 (.btn-round): назад, «ещё», закрыть листа, кнопки поверх камеры.
class KvRoundButton extends StatelessWidget {
  /// Создаёт круглую кнопку со значком [icon].
  const KvRoundButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.semanticLabel,
    this.variant = KvRoundVariant.solid,
    this.size = 44,
    this.iconSize = 24,
    this.badge,
    this.active = false,
  });

  /// Значок.
  final KvIcons icon;

  /// Действие.
  final VoidCallback? onPressed;

  /// Подпись для диктора: «Назад», «Ещё», «Закрыть».
  final String? semanticLabel;

  /// Вид: белая с тенью, прозрачная или стеклянная поверх видео.
  final KvRoundVariant variant;

  /// Диаметр (не меньше 44).
  final double size;

  /// Размер значка.
  final double iconSize;

  /// Счётчик в углу; пустая строка - точка.
  final String? badge;

  /// Включённое состояние стеклянной кнопки (фонарик): белый фон и жёлтый значок.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final double d = math.max(size, KvLayout.touch);
    final (Color bg, Color fg, List<BoxShadow>? shadow) = switch (variant) {
      KvRoundVariant.solid => (c.surface, c.text, c.shadow1),
      KvRoundVariant.ghost => (const Color(0x00000000), c.text, null),
      KvRoundVariant.glass => active ? (c.surface, c.warn, null) : (c.arGlass, c.arText, null),
    };
    Widget body = Container(
      width: d,
      height: d,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle, boxShadow: shadow),
      child: KvIcon(icon, size: iconSize, color: fg),
    );
    if (variant == KvRoundVariant.glass && !active) {
      body = KvGlass(shape: BoxShape.circle, blur: 8, child: body);
    }
    if (badge != null) {
      body = Stack(
        clipBehavior: Clip.none,
        children: [
          body,
          Positioned(top: 6, right: 6, child: KvBadge(badge!.isEmpty ? null : badge)),
        ],
      );
    }
    return KvPressable(
      onTap: onPressed,
      shape: BoxShape.circle,
      semanticLabel: semanticLabel,
      child: SizedBox(width: d, height: d, child: body),
    );
  }
}

/// Вид круглой кнопки.
enum KvRoundVariant {
  /// Белая с тенью.
  solid,

  /// Прозрачная.
  ghost,

  /// Стеклянная поверх видео.
  glass,
}

/// Текстовая ссылка высотой 44 (.link): «Забыли пароль?», «Пропустить».
class KvLink extends StatelessWidget {
  /// Создаёт ссылку с текстом [label].
  const KvLink(this.label, {super.key, required this.onPressed, this.color});

  /// Текст.
  final String label;

  /// Действие.
  final VoidCallback? onPressed;

  /// Цвет текста; по умолчанию фирменный синий.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return KvPressable(
      onTap: onPressed,
      highlight: false,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: KvLayout.touch),
        child: Align(
          widthFactor: 1,
          child: Text(
            label,
            style: context.kvText.sm.copyWith(fontWeight: FontWeight.w500, color: color ?? context.kv.brand, height: 1.2),
          ),
        ),
      ),
    );
  }
}

/// Спиннер кнопки: кольцо 22 px толщиной 2,5 с прозрачной правой четвертью, оборот 0,8 с.
class KvSpinner extends StatefulWidget {
  /// Создаёт спиннер цвета [color].
  const KvSpinner({super.key, required this.color, this.size = 22, this.stroke = 2.5, this.period = const Duration(milliseconds: 800)});

  /// Цвет кольца.
  final Color color;

  /// Диаметр.
  final double size;

  /// Толщина кольца.
  final double stroke;

  /// Время одного оборота.
  final Duration period;

  @override
  State<KvSpinner> createState() => _KvSpinnerState();
}

class _KvSpinnerState extends State<KvSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.period);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.kvReduceMotion) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: RotationTransition(
        turns: _c,
        child: CustomPaint(size: Size.square(widget.size), painter: _RingPainter(widget.color, widget.stroke)),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.color, this.stroke);

  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(
      r,
      math.pi / 4,
      math.pi * 1.5,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) => oldDelegate.color != color || oldDelegate.stroke != stroke;
}

/// Стеклянная подложка поверх видео: размытие фона под формой. Используется кнопками и плашками камеры.
class KvGlass extends StatelessWidget {
  /// Создаёт стекло с размытием [blur] под формой [shape] или скруглением [borderRadius].
  const KvGlass({super.key, required this.child, this.blur = 10, this.shape = BoxShape.rectangle, this.borderRadius});

  /// Содержимое (обычно с полупрозрачным фоном arGlass).
  final Widget child;

  /// Радиус размытия в CSS-пикселях blur(); сигма равна половине.
  final double blur;

  /// Форма.
  final BoxShape shape;

  /// Скругление для прямоугольника.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final Widget filtered = BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: blur / 2, sigmaY: blur / 2),
      child: child,
    );
    if (shape == BoxShape.circle) {
      return ClipOval(child: filtered);
    }
    return ClipRRect(borderRadius: borderRadius ?? BorderRadius.zero, child: filtered);
  }
}
