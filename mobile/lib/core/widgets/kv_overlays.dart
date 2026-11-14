import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../icons/kv_icon.dart';
import '../theme/kv_theme.dart';
import 'kv_button.dart';
import 'kv_list.dart';
import 'kv_pressable.dart';
import 'kv_screen.dart';

/// Открывает лист снизу (.sheet): затемнение 260 мс, подъём 420 мс с лёгким перелётом, закрытие 260 мс;
/// закрывается касанием затемнения, кнопкой «закрыть» или жестом вниз. Возвращает результат [Navigator.pop].
Future<T?> showKvSheet<T>(BuildContext context, {required WidgetBuilder builder, bool dismissible = true}) {
  return Navigator.of(context, rootNavigator: true).push<T>(_KvSheetRoute<T>(builder: builder, dismissible: dismissible, scrimColor: context.kv.scrim));
}

/// Открывает диалог по центру (.dialog): появление с масштаба 0,94 за 240 мс, затемнение 260 мс.
Future<T?> showKvDialog<T>(BuildContext context, {required WidgetBuilder builder, bool dismissible = true}) {
  return Navigator.of(context, rootNavigator: true).push<T>(_KvDialogRoute<T>(builder: builder, dismissible: dismissible, scrimColor: context.kv.scrim));
}

class _KvSheetRoute<T> extends PopupRoute<T> {
  _KvSheetRoute({required this.builder, required this.dismissible, required this.scrimColor});

  final WidgetBuilder builder;
  final bool dismissible;
  final Color scrimColor;

  @override
  Color? get barrierColor => scrimColor;

  @override
  bool get barrierDismissible => dismissible;

  @override
  String? get barrierLabel => 'Закрыть';

  @override
  Duration get transitionDuration => KvMotion.sheet;

  @override
  Duration get reverseTransitionDuration => KvMotion.overlayClose;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return _SheetFrame(
      route: this,
      child: Builder(builder: builder),
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    if (context.kvReduceMotion) {
      return child;
    }
    final Animation<double> t = CurvedAnimation(parent: animation, curve: KvMotion.easeSheet, reverseCurve: KvMotion.easeOut.flipped);
    return AnimatedBuilder(
      animation: t,
      builder: (BuildContext context, Widget? c) => FractionalTranslation(translation: Offset(0, 1 - t.value), child: c),
      child: child,
    );
  }

  void dragBy(double fraction) => controller!.value = (controller!.value - fraction).clamp(0.0, 1.0);

  void dragEnd(double velocity) {
    if (velocity > 700 || controller!.value < 0.6) {
      navigator?.pop();
    } else {
      controller!.forward();
    }
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.route, required this.child});

  final _KvSheetRoute<dynamic> route;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height - 64),
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onVerticalDragUpdate: route.dismissible ? (DragUpdateDetails d) => route.dragBy(d.primaryDelta! / (context.size?.height ?? 400)) : null,
          onVerticalDragEnd: route.dismissible ? (DragEndDetails d) => route.dragEnd(d.velocity.pixelsPerSecond.dy) : null,
          child: Padding(
            padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Лист снизу: ручка, заголовок 20 с кнопкой «закрыть», прокручиваемое тело с промежутком 12 и действия.
///
/// Пример: `showKvSheet(context, builder: (_) => KvSheet(title: 'Н-101 · Wilo IL 65/160', children: [KvList(...)]))`.
class KvSheet extends StatelessWidget {
  /// Создаёт лист.
  const KvSheet({super.key, this.title, this.children = const <Widget>[], this.actions = const <Widget>[], this.close = true, this.grab = true});

  /// Заголовок.
  final String? title;

  /// Тело.
  final List<Widget> children;

  /// Кнопки внизу.
  final List<Widget> actions;

  /// Кнопка «закрыть» справа от заголовка.
  final bool close;

  /// Ручка сверху.
  final bool grab;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final double bottom = math.max(42, MediaQuery.viewPaddingOf(context).bottom + 8);
    return Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle(
        style: context.kvText.base,
        child: KvSheetScope(
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(KvSpace.s5, 10, KvSpace.s5, bottom),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(KvRadius.sheet)),
              boxShadow: c.shadowSheet,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (grab)
                  Center(
                    child: Container(
                      width: 38,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 2),
                      decoration: BoxDecoration(color: c.surface3, borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                if (title != null) ...[
                  const SizedBox(height: KvSpace.s4),
                  Row(
                    children: [
                      Expanded(child: Text(title!, style: context.kvText.title.copyWith(fontSize: 20, height: 1.25))),
                      if (close) ...[
                        const SizedBox(width: KvSpace.s3),
                        KvRoundButton(
                          icon: KvIcons.close,
                          iconSize: 22,
                          variant: KvRoundVariant.ghost,
                          semanticLabel: 'Закрыть',
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      ],
                    ],
                  ),
                ],
                if (children.isNotEmpty) ...[
                  const SizedBox(height: KvSpace.s4),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (int i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: KvSpace.s3), children[i]],
                        ],
                      ),
                    ),
                  ),
                ],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: KvSpace.s4),
                  for (int i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(height: KvSpace.s2), actions[i]],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KvDialogRoute<T> extends PopupRoute<T> {
  _KvDialogRoute({required this.builder, required this.dismissible, required this.scrimColor});

  final WidgetBuilder builder;
  final bool dismissible;
  final Color scrimColor;

  @override
  Color? get barrierColor => scrimColor;

  @override
  bool get barrierDismissible => dismissible;

  @override
  String? get barrierLabel => 'Закрыть';

  @override
  Duration get transitionDuration => KvMotion.dialog;

  @override
  Duration get reverseTransitionDuration => KvMotion.overlayClose;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return Center(child: Builder(builder: builder));
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    if (context.kvReduceMotion) {
      return child;
    }
    final bool closing = animation.status == AnimationStatus.reverse;
    final Animation<double> t = CurvedAnimation(parent: animation, curve: KvMotion.ease, reverseCurve: KvMotion.easeOut.flipped);
    return FadeTransition(
      opacity: t,
      child: ScaleTransition(
        scale: Tween<double>(begin: closing ? 0.96 : 0.94, end: 1).animate(t),
        child: child,
      ),
    );
  }
}

/// Диалог (.dialog): значок в круге, заголовок 19, текст 14, кнопки. Ширина - экран минус 48, не больше 340.
class KvDialog extends StatelessWidget {
  /// Создаёт диалог.
  const KvDialog({super.key, required this.title, this.text, this.icon, this.tone, this.body, this.actions = const <Widget>[], this.vertical = false});

  /// Заголовок.
  final String title;

  /// Текст.
  final String? text;

  /// Значок в круге.
  final KvIcons? icon;

  /// Тон значка: ok, warn, bad; null - синий.
  final KvStatus? tone;

  /// Дополнительное содержимое под текстом.
  final Widget? body;

  /// Кнопки: в ряд или столбиком при [vertical].
  final List<Widget> actions;

  /// Кнопки столбиком.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final double w = math.min(340, MediaQuery.sizeOf(context).width - 48);
    final (Color bg, Color fg) = switch (tone) {
      KvStatus.bad => (c.badBg, c.bad),
      KvStatus.warn => (c.warnBg, c.warn),
      KvStatus.ok => (c.okBg, c.ok),
      _ => (c.tint2, c.brand),
    };
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: w,
        padding: const EdgeInsets.fromLTRB(KvSpace.s5, KvSpace.s6, KvSpace.s5, KvSpace.s5),
        decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(KvRadius.lg), boxShadow: c.shadow2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (icon != null) ...[
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                  child: KvIcon(icon!, size: 28, color: fg),
                ),
              ),
              const SizedBox(height: 4 + KvSpace.s3),
            ],
            Text(title, textAlign: TextAlign.center, style: t.title.copyWith(fontSize: 19, height: 1.3)),
            if (text != null) ...[
              const SizedBox(height: KvSpace.s3),
              Text(
                text!,
                textAlign: TextAlign.center,
                style: t.sm.copyWith(color: c.text2, height: 1.45),
              ),
            ],
            if (body != null) ...[const SizedBox(height: KvSpace.s3), body!],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: KvSpace.s3 + KvSpace.s2),
              if (vertical)
                for (int i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(height: KvSpace.s3), actions[i]]
              else
                Row(
                  children: [
                    for (int i = 0; i < actions.length; i++) ...[if (i > 0) const SizedBox(width: KvSpace.s3), Expanded(child: actions[i])],
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Тон уведомления сверху.
enum KvToastKind {
  /// Ошибка (по умолчанию): красный значок.
  bad,

  /// Успех: зелёный.
  ok,

  /// Предупреждение: жёлтый.
  warn,

  /// Сведения: синий.
  info,
}

OverlayEntry? _toastEntry;
OverlayEntry? _snackEntry;

void _removeEntry(OverlayEntry? entry) {
  if (entry != null && entry.mounted) {
    entry.remove();
  }
}

/// Показывает уведомление сверху (.toast): въезжает за 380 мс, через 2,5 с уходит.
/// С [onTap] уведомление нажимается, как push-уведомление, и открывает связанный экран.
void showKvToast(BuildContext context, {required String title, String? text, KvToastKind kind = KvToastKind.bad, KvIcons? icon, VoidCallback? onTap}) {
  final OverlayState overlay = Overlay.of(context, rootOverlay: true);
  _removeEntry(_toastEntry);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext ctx) => _Transient(
      top: true,
      duration: KvMotion.toast,
      onDone: () {
        if (_toastEntry == entry) {
          _toastEntry = null;
        }
        _removeEntry(entry);
      },
      child: KvToast(title: title, text: text, kind: kind, icon: icon, onTap: onTap),
    ),
  );
  _toastEntry = entry;
  overlay.insert(entry);
}

/// Показывает уведомление снизу (.snack) на 3,2 с: над панелью вкладок или закреплённой кнопкой экрана [context].
void showKvSnack(BuildContext context, {required String text, KvIcons? icon = KvIcons.checkCircle, String? actionLabel, VoidCallback? onAction}) {
  final OverlayState overlay = Overlay.of(context, rootOverlay: true);
  final KvScreenScope? scope = KvScreenScope.maybeOf(context);
  final double homeGap = math.max(KvLayout.homeIndicator, MediaQuery.viewPaddingOf(context).bottom);
  final double bottom = (scope?.hasTabBar ?? false)
      ? KvTabBarScope.bottomOf(context) + 80
      : (scope?.hasFoot ?? false)
      ? 78 + homeGap
      : homeGap;
  _removeEntry(_snackEntry);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext ctx) => _Transient(
      top: false,
      bottom: bottom,
      duration: KvMotion.snack,
      onDone: () {
        if (_snackEntry == entry) {
          _snackEntry = null;
        }
        _removeEntry(entry);
      },
      child: KvSnack(text: text, icon: icon, actionLabel: actionLabel, onAction: onAction),
    ),
  );
  _snackEntry = entry;
  overlay.insert(entry);
}

/// Убирает показанные уведомления (при выходе из учётной записи и в тестах).
void hideKvTransients() {
  _removeEntry(_toastEntry);
  _toastEntry = null;
  _removeEntry(_snackEntry);
  _snackEntry = null;
}

class _Transient extends StatefulWidget {
  const _Transient({required this.top, required this.duration, required this.onDone, required this.child, this.bottom = 0});

  final bool top;
  final double bottom;
  final Duration duration;
  final VoidCallback onDone;
  final Widget child;

  @override
  State<_Transient> createState() => _TransientState();
}

class _TransientState extends State<_Transient> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: KvMotion.toastIn, reverseDuration: KvMotion.toastOut);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _c.forward();
    _timer = Timer(widget.duration, _leave);
  }

  Future<void> _leave() async {
    _timer?.cancel();
    if (!mounted) {
      return;
    }
    await _c.reverse();
    if (mounted) {
      widget.onDone();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Animation<double> t = CurvedAnimation(parent: _c, curve: KvMotion.ease, reverseCurve: KvMotion.easeOut.flipped);
    final double topInset = MediaQuery.paddingOf(context).top;
    final Widget moving = AnimatedBuilder(
      animation: t,
      builder: (BuildContext context, Widget? c) => Opacity(
        opacity: t.value.clamp(0.0, 1.0),
        child: FractionalTranslation(translation: Offset(0, (widget.top ? -1.3 : 1.3) * (1 - t.value)), child: c),
      ),
      child: GestureDetector(
        onVerticalDragEnd: (DragEndDetails d) {
          final double v = d.velocity.pixelsPerSecond.dy;
          if ((widget.top && v < -200) || (!widget.top && v > 200)) {
            _leave();
          }
        },
        child: widget.child,
      ),
    );
    return Positioned(
      left: 12,
      right: 12,
      top: widget.top ? math.max(8, topInset - 2) : null,
      bottom: widget.top ? null : widget.bottom,
      child: SafeArea(top: false, bottom: false, child: moving),
    );
  }
}

/// Уведомление сверху: круглый значок тона, заголовок 15 и текст 13.
class KvToast extends StatelessWidget {
  /// Создаёт уведомление.
  const KvToast({super.key, required this.title, this.text, this.kind = KvToastKind.bad, this.icon, this.onTap});

  /// Заголовок.
  final String title;

  /// Текст.
  final String? text;

  /// Тон.
  final KvToastKind kind;

  /// Значок; по умолчанию по тону.
  final KvIcons? icon;

  /// Касание (push-уведомление).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final (Color bg, Color fg, KvIcons ic) = switch (kind) {
      KvToastKind.bad => (c.badBg, c.bad, KvIcons.alert),
      KvToastKind.ok => (c.okBg, c.ok, KvIcons.checkCircle),
      KvToastKind.warn => (c.warnBg, c.warn, KvIcons.alert),
      KvToastKind.info => (c.tint, c.brand, KvIcons.info),
    };
    final Widget box = Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, KvSpace.s4, 12),
        decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(18), boxShadow: c.shadow2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: KvIcon(icon ?? ic, size: 20, color: fg),
            ),
            const SizedBox(width: KvSpace.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: t.body.copyWith(fontWeight: FontWeight.w600, height: 1.3)),
                  if (text != null) ...[const SizedBox(height: 2), Text(text!, style: t.caption)],
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) {
      return Semantics(liveRegion: true, child: box);
    }
    return KvPressable(onTap: onTap, borderRadius: BorderRadius.circular(18), semanticLabel: title, child: box);
  }
}

/// Уведомление снизу: тёмная плашка, значок, текст и действие.
class KvSnack extends StatelessWidget {
  /// Создаёт уведомление.
  const KvSnack({super.key, required this.text, this.icon, this.actionLabel, this.onAction});

  /// Текст.
  final String text;

  /// Значок слева.
  final KvIcons? icon;

  /// Подпись действия.
  final String? actionLabel;

  /// Действие.
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        padding: const EdgeInsets.fromLTRB(KvSpace.s4, 8, 8, 8),
        decoration: BoxDecoration(color: c.snackBg, borderRadius: BorderRadius.circular(KvRadius.btn), boxShadow: c.shadow2),
        child: Row(
          children: [
            if (icon != null) ...[KvIcon(icon!, size: 20, color: c.snackAction), const SizedBox(width: KvSpace.s3)],
            Expanded(
              child: Text(text, style: context.kvText.sm.copyWith(color: c.snackText, height: 1.35)),
            ),
            if (actionLabel != null) ...[
              const SizedBox(width: KvSpace.s3),
              KvPressable(
                onTap: onAction,
                borderRadius: BorderRadius.circular(12),
                semanticLabel: actionLabel,
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  child: Text(
                    actionLabel!,
                    style: context.kvText.sm.copyWith(fontWeight: FontWeight.w600, color: c.snackAction),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
