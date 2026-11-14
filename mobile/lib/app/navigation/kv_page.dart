import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/kv_theme.dart';

/// Вид перехода между экранами (data-nav прототипа, движок js/app.js).
enum KvTransition {
  /// Вперёд и назад: новый экран въезжает справа за 300 мс, старый сдвигается на 28 % и темнеет.
  push,

  /// Снизу вверх за 380 мс (сканер, сообщение оператора), старый экран чуть уменьшается; назад - 340 мс.
  up,

  /// Наплыв за 220 мс: смена вкладки, замена экрана.
  fade,

  /// Смена пункта сегмента (Сейчас / Графики / История): шапка стоит, плашка едет, тело экрана меняется наплывом.
  seg,

  /// Без анимации.
  none,
}

/// Параметры перехода, передаваемые через `extra` go_router: вид перехода и пункт сегмента, с которого едет плашка.
///
/// Пример: `context.replace(path, extra: const KvNavExtra(transition: KvTransition.seg, fromSegment: 0))`.
@immutable
class KvNavExtra {
  /// Создаёт параметры перехода.
  const KvNavExtra({this.transition, this.fromSegment, this.data});

  /// Вид перехода вместо обычного для экрана.
  final KvTransition? transition;

  /// Индекс пункта сегмента на предыдущем экране.
  final int? fromSegment;

  /// Произвольные данные для экрана.
  final Object? data;

  /// Параметры из состояния маршрута или null.
  static KvNavExtra? of(GoRouterState state) => state.extra is KvNavExtra ? state.extra! as KvNavExtra : null;
}

/// Страница go_router с переходами дизайна. Обычный вид перехода экрана задаёт [transition];
/// `extra` типа [KvNavExtra] может его заменить для одной навигации.
class KvPage<T> extends Page<T> {
  /// Создаёт страницу.
  const KvPage({required this.child, this.transition = KvTransition.push, super.key, super.name, super.arguments, super.restorationId});

  /// Страница для маршрута [state] с переходом по умолчанию [transition].
  factory KvPage.of(GoRouterState state, Widget child, {KvTransition transition = KvTransition.push}) => KvPage<T>(
        key: state.pageKey,
        name: state.name ?? state.path,
        arguments: state.extra,
        restorationId: state.pageKey.value,
        transition: KvNavExtra.of(state)?.transition ?? transition,
        child: child,
      );

  /// Содержимое страницы.
  final Widget child;

  /// Вид перехода.
  final KvTransition transition;

  @override
  Route<T> createRoute(BuildContext context) => _KvPageRoute<T>(this);
}

class _KvPageRoute<T> extends PageRoute<T> {
  _KvPageRoute(KvPage<T> page) : super(settings: page);

  KvPage<T> get _page => settings as KvPage<T>;

  KvTransition get _type => _page.transition;

  @override
  Duration get transitionDuration => switch (_type) {
        KvTransition.push => KvMotion.nav,
        KvTransition.up => KvMotion.up,
        KvTransition.fade => KvMotion.fade,
        KvTransition.seg => const Duration(milliseconds: 160),
        KvTransition.none => Duration.zero,
      };

  @override
  Duration get reverseTransitionDuration => switch (_type) {
        KvTransition.up => KvMotion.upBack,
        _ => transitionDuration,
      };

  @override
  bool get opaque => true;

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => _page.child;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => _exitOf(_type);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return child;
    }
    final bool linear = popGestureInProgress;
    Widget enter = switch (_type) {
      KvTransition.push => _Slide(animation: animation, linear: linear, vertical: false, child: child),
      KvTransition.up => _Slide(animation: animation, linear: linear, vertical: true, child: child),
      KvTransition.fade || KvTransition.seg => FadeTransition(opacity: CurvedAnimation(parent: animation, curve: KvMotion.easeOut), child: child),
      KvTransition.none => child,
    };
    if (_type == KvTransition.push && Theme.of(context).platform == TargetPlatform.iOS) {
      enter = _BackSwipe(route: this, child: enter);
    }
    return _exitOf(_type)?.call(context, animation, secondaryAnimation, allowSnapshotting, enter) ?? enter;
  }
}

DelegatedTransitionBuilder? _exitOf(KvTransition type) => switch (type) {
      KvTransition.push => _pushExit,
      KvTransition.up => _upExit,
      KvTransition.fade => _fadeExit,
      KvTransition.seg => _fadeExit,
      KvTransition.none => null,
    };

Widget? _pushExit(BuildContext context, Animation<double> animation, Animation<double> secondary, bool allowSnapshotting, Widget? child) {
  final Animation<double> t = CurvedAnimation(parent: secondary, curve: KvMotion.ease, reverseCurve: KvMotion.ease.flipped);
  return _Dim(
    animation: t,
    child: SlideTransition(position: Tween<Offset>(begin: Offset.zero, end: const Offset(-KvMotion.pushShift, 0)).animate(t), child: child),
  );
}

Widget? _upExit(BuildContext context, Animation<double> animation, Animation<double> secondary, bool allowSnapshotting, Widget? child) {
  final Animation<double> t = CurvedAnimation(parent: secondary, curve: KvMotion.ease, reverseCurve: KvMotion.ease.flipped);
  return _Dim(animation: t, child: ScaleTransition(scale: Tween<double>(begin: 1, end: 0.96).animate(t), child: child));
}

Widget? _fadeExit(BuildContext context, Animation<double> animation, Animation<double> secondary, bool allowSnapshotting, Widget? child) =>
    FadeTransition(opacity: Tween<double>(begin: 1, end: 0).animate(CurvedAnimation(parent: secondary, curve: KvMotion.easeOut)), child: child);

/// Въезд экрана справа или снизу с тенью по ведущему краю.
class _Slide extends StatelessWidget {
  const _Slide({required this.animation, required this.linear, required this.vertical, required this.child});

  final Animation<double> animation;
  final bool linear;
  final bool vertical;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Animation<double> t = linear ? animation : CurvedAnimation(parent: animation, curve: KvMotion.ease, reverseCurve: KvMotion.ease.flipped);
    final Offset from = vertical ? const Offset(0, 1) : const Offset(1, 0);
    return SlideTransition(
      position: Tween<Offset>(begin: from, end: Offset.zero).animate(t),
      child: AnimatedBuilder(
        animation: animation,
        builder: (BuildContext context, Widget? c) {
          final bool moving = !animation.isCompleted && !animation.isDismissed;
          if (!moving) {
            return c!;
          }
          return DecoratedBox(
            decoration: BoxDecoration(
              boxShadow: [
                vertical
                    ? kvCssShadow(0, -10, 40, const Color(0x2E000000))
                    : kvCssShadow(-12, 0, 32, const Color(0x24000000)),
              ],
            ),
            child: c,
          );
        },
        child: child,
      ),
    );
  }
}

/// Затемнение старого экрана при переходе вперёд (до 22 % чёрного).
class _Dim extends StatelessWidget {
  const _Dim({required this.animation, required this.child});

  final Animation<double> animation;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (BuildContext context, Widget? c) {
        final double v = animation.value;
        if (v <= 0) {
          return c ?? const SizedBox.shrink();
        }
        return Stack(
          fit: StackFit.passthrough,
          children: [
            ?c,
            Positioned.fill(child: IgnorePointer(child: ColoredBox(color: Color.fromRGBO(0, 0, 0, KvMotion.pushDim * v)))),
          ],
        );
      },
      child: child,
    );
  }
}

/// Возврат свайпом от левого края на iOS: тянет переход назад вслед за пальцем.
class _BackSwipe extends StatefulWidget {
  const _BackSwipe({required this.route, required this.child});

  final _KvPageRoute<dynamic> route;
  final Widget child;

  @override
  State<_BackSwipe> createState() => _BackSwipeState();
}

class _BackSwipeState extends State<_BackSwipe> {
  bool _active = false;

  void _start(DragStartDetails d) {
    if (!widget.route.popGestureEnabled) {
      return;
    }
    _active = true;
    widget.route.handleStartBackGesture(progress: 1);
  }

  void _update(DragUpdateDetails d) {
    if (!_active) {
      return;
    }
    final double w = context.size?.width ?? 1;
    final double progress = (widget.route.animation!.value - d.primaryDelta! / w).clamp(0.0, 1.0);
    widget.route.handleUpdateBackGestureProgress(progress: progress);
  }

  void _end(DragEndDetails d) {
    if (!_active) {
      return;
    }
    _active = false;
    final double w = context.size?.width ?? 1;
    final double velocity = d.velocity.pixelsPerSecond.dx / w;
    final bool pop = velocity > 1 || (velocity > -1 && widget.route.animation!.value < 0.5);
    if (pop) {
      widget.route.handleCommitBackGesture();
    } else {
      widget.route.handleCancelBackGesture();
    }
  }

  @override
  Widget build(BuildContext context) {
    final double edge = MediaQuery.paddingOf(context).left + 20;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: edge,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _start,
            onHorizontalDragUpdate: _update,
            onHorizontalDragEnd: _end,
            onHorizontalDragCancel: () {
              if (_active) {
                _active = false;
                widget.route.handleCancelBackGesture();
              }
            },
          ),
        ),
      ],
    );
  }
}
