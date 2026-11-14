import 'dart:async';

import 'package:flutter/widgets.dart';

import '../theme/kv_theme.dart';

/// Нажимаемая область с откликом дизайна: сжатие до [pressedScale] и лёгкая синяя подсветка (.is-pressed).
///
/// Действие [onTap] выполняется через 90 мс после касания, чтобы отклик был виден, как в прототипе;
/// при уменьшении движения - сразу. Без [onTap] виджет не реагирует на касания.
class KvPressable extends StatefulWidget {
  /// Создаёт нажимаемую область.
  const KvPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius = BorderRadius.zero,
    this.shape = BoxShape.rectangle,
    this.pressedScale = 0.97,
    this.highlight = true,
    this.semanticLabel,
    this.button = true,
    this.immediate = false,
  });

  /// Содержимое.
  final Widget child;

  /// Действие по касанию.
  final VoidCallback? onTap;

  /// Действие по долгому касанию.
  final VoidCallback? onLongPress;

  /// Скругление подсветки нажатия.
  final BorderRadius borderRadius;

  /// Форма подсветки: прямоугольник или круг.
  final BoxShape shape;

  /// Масштаб при нажатии: 0,97 для кнопок, 0,985 для строк и карточек.
  final double pressedScale;

  /// Рисовать ли подсветку поверх содержимого.
  final bool highlight;

  /// Подпись для экранного диктора.
  final String? semanticLabel;

  /// Сообщать диктору, что это кнопка.
  final bool button;

  /// Выполнять действие сразу, без паузы на отклик (переключатели, поля).
  final bool immediate;

  @override
  State<KvPressable> createState() => _KvPressableState();
}

class _KvPressableState extends State<KvPressable> {
  bool _pressed = false;
  DateTime _downAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _release;
  Timer? _action;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _down() {
    _release?.cancel();
    _downAt = DateTime.now();
    setState(() => _pressed = true);
  }

  void _up() {
    final int left = KvMotion.press.inMilliseconds - DateTime.now().difference(_downAt).inMilliseconds;
    _release?.cancel();
    if (left <= 0) {
      if (mounted) {
        setState(() => _pressed = false);
      }
      return;
    }
    _release = Timer(Duration(milliseconds: left), () {
      if (mounted) {
        setState(() => _pressed = false);
      }
    });
  }

  void _tap() {
    final VoidCallback? action = widget.onTap;
    if (action == null) {
      return;
    }
    if (widget.immediate || context.kvReduceMotion) {
      action();
      return;
    }
    _action?.cancel();
    _action = Timer(KvMotion.tapDelay, () {
      if (mounted) {
        action();
      }
    });
  }

  @override
  void dispose() {
    _release?.cancel();
    _action?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) {
      return widget.child;
    }
    final bool reduce = context.kvReduceMotion;
    Widget content = widget.child;
    if (widget.highlight) {
      content = DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          color: _pressed ? context.kv.press : null,
          borderRadius: widget.shape == BoxShape.circle ? null : widget.borderRadius,
          shape: widget.shape,
        ),
        child: content,
      );
    }
    return Semantics(
      button: widget.button,
      label: widget.semanticLabel,
      enabled: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _down(),
        onTapUp: (_) => _up(),
        onTapCancel: _up,
        onTap: widget.onTap == null ? null : _tap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _pressed ? widget.pressedScale : 1,
          duration: reduce ? Duration.zero : KvMotion.press,
          curve: KvMotion.ease,
          child: content,
        ),
      ),
    );
  }
}
