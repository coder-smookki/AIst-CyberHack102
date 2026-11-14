import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../../core/kv.dart';

/// Кривая всплытия kvPopIn прототипа: cubic-bezier(.2, 1.5, .4, 1) - с перелётом.
const Curve kEntryPopCurve = Cubic(0.2, 1.5, 0.4, 1);

/// Очередь появления блоков своего тела экрана (.stg прототипа): блоки по [EntryStaggerItem.index]
/// поднимаются на 12 px и проявляются за 420 мс с шагом 45 мс после задержки 60 мс.
///
/// Нужна там, где тело экрана - своя раскладка, а не список блоков [KvScreen.children].
class EntryStagger extends StatefulWidget {
  /// Создаёт очередь появления для поддерева [child].
  const EntryStagger({super.key, required this.child});

  /// Поддерево с блоками [EntryStaggerItem].
  final Widget child;

  @override
  State<EntryStagger> createState() => _EntryStaggerState();
}

class _EntryStaggerState extends State<EntryStagger> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: _total);
  bool _started = false;

  static const Duration _total = Duration(milliseconds: 60 + 14 * 45 + 420);

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
  Widget build(BuildContext context) => _StaggerScope(animation: _c, child: widget.child);
}

class _StaggerScope extends InheritedWidget {
  const _StaggerScope({required this.animation, required super.child});

  final Animation<double> animation;

  @override
  bool updateShouldNotify(_StaggerScope oldWidget) => oldWidget.animation != animation;
}

/// Блок очереди появления [EntryStagger]: номер [index] задаёт задержку; [duration] - длительность подъёма
/// (420 мс; ряд значков роли - 360 мс). Вне очереди показывается сразу.
class EntryStaggerItem extends StatelessWidget {
  /// Создаёт блок очереди.
  const EntryStaggerItem({super.key, required this.index, required this.child, this.duration = 420});

  /// Номер блока в очереди (0 - первый).
  final int index;

  /// Длительность подъёма, мс.
  final int duration;

  /// Содержимое блока.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Animation<double>? parent = context.dependOnInheritedWidgetOfExactType<_StaggerScope>()?.animation;
    if (parent == null || index >= 14) {
      return child;
    }
    const double total = 60 + 14 * 45 + 420;
    final double start = 60 + index * 45.0;
    final Animation<double> t = CurvedAnimation(
      parent: parent,
      curve: Interval(start / total, math.min(1, (start + duration) / total), curve: KvMotion.ease),
    );
    return FadeTransition(
      opacity: t,
      child: AnimatedBuilder(
        animation: t,
        builder: (BuildContext context, Widget? c) => t.value >= 1 ? c! : Transform.translate(offset: Offset(0, 12 * (1 - t.value)), child: c),
        child: child,
      ),
    );
  }
}

/// Всплытие при появлении (kvPopIn): масштаб от 0,4 до 1 и проявление за [duration] после задержки [delay].
class EntryPopIn extends StatefulWidget {
  /// Создаёт всплывающий блок.
  const EntryPopIn({
    super.key,
    required this.child,
    this.delay = const Duration(milliseconds: 100),
    this.duration = const Duration(milliseconds: 550),
  });

  /// Содержимое.
  final Widget child;

  /// Задержка перед всплытием.
  final Duration delay;

  /// Длительность всплытия.
  final Duration duration;

  @override
  State<EntryPopIn> createState() => _EntryPopInState();
}

class _EntryPopInState extends State<EntryPopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.delay + widget.duration);
  bool _started = false;

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
    final double total = (widget.delay + widget.duration).inMilliseconds.toDouble();
    final Animation<double> t = CurvedAnimation(parent: _c, curve: Interval(widget.delay.inMilliseconds / total, 1, curve: kEntryPopCurve));
    return AnimatedBuilder(
      animation: t,
      builder: (BuildContext context, Widget? c) {
        if (_c.isCompleted) {
          return c!;
        }
        final double v = t.value;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.4 + 0.6 * v, child: c),
        );
      },
      child: widget.child,
    );
  }
}
