import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../icons/kv_icon.dart';
import '../theme/kv_theme.dart';
import 'kv_button.dart';
import 'kv_chip.dart';

/// Сведения о плавающей панели вкладок для экранов внутри оболочки роли: экран оставляет под неё место.
class KvTabBarScope extends InheritedWidget {
  /// Создаёт область с панелью вкладок.
  const KvTabBarScope({super.key, required super.child, this.visible = true});

  /// Панель показана.
  final bool visible;

  /// Ближайшая область или null (экран без панели).
  static KvTabBarScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<KvTabBarScope>();

  /// Расстояние от низа экрана до панели: 24 в рамке прототипа, больше при высокой системной панели.
  static double bottomOf(BuildContext context) => math.max(KvLayout.tabBarBottom, MediaQuery.viewPaddingOf(context).bottom - 10);

  @override
  bool updateShouldNotify(KvTabBarScope oldWidget) => oldWidget.visible != visible;
}

/// Сведения об экране для всплывающих элементов: есть ли панель вкладок и закреплённая кнопка.
class KvScreenScope extends InheritedWidget {
  /// Создаёт область экрана.
  const KvScreenScope({super.key, required super.child, required this.hasTabBar, required this.hasFoot});

  /// На экране есть панель вкладок.
  final bool hasTabBar;

  /// На экране есть закреплённая кнопка.
  final bool hasFoot;

  /// Ближайшая область экрана или null.
  static KvScreenScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<KvScreenScope>();

  @override
  bool updateShouldNotify(KvScreenScope oldWidget) => oldWidget.hasTabBar != hasTabBar || oldWidget.hasFoot != hasFoot;
}

/// Появление содержимого экрана.
enum KvStagger {
  /// Первые 14 блоков поднимаются по очереди: 420 мс, шаг 45 мс (переход на экран).
  appear,

  /// Тело экрана после смены пункта сегмента: 260 мс, шаг 30 мс, без первых [KvScreen.staggerSkip] блоков.
  seg,

  /// Без анимации.
  none,
}

/// Каркас экрана дизайна (.scr): фон, отступ строки состояния, шапка, прокручиваемое тело с промежутком 12,
/// закреплённая кнопка снизу и место под плавающую панель вкладок роли.
///
/// Цвет значков строки состояния: [lightStatusBar] - светлые (фото, камера); по умолчанию - по теме.
/// [immersive] - содержимое уходит под строку состояния (вход, камера). Тело задаётся списком [children]
/// (ленивый список с промежутком [gap]) или своим виджетом [body].
class KvScreen extends StatefulWidget {
  /// Создаёт экран.
  const KvScreen({
    super.key,
    this.header,
    this.children,
    this.body,
    this.foot,
    this.surface = false,
    this.immersive = false,
    this.lightStatusBar,
    this.lightHome,
    this.gap = KvSpace.s3,
    this.padding = const EdgeInsets.symmetric(horizontal: KvSpace.gutter),
    this.stagger = KvStagger.appear,
    this.staggerSkip = 0,
    this.scrollController,
    this.background,
    this.overlays = const <Widget>[],
  }) : assert(children == null || body == null, 'Укажите либо children, либо body');

  /// Шапка: [KvHeader], [KvRootHeader] или своя.
  final Widget? header;

  /// Блоки прокручиваемого тела.
  final List<Widget>? children;

  /// Своё тело вместо [children]; занимает всё место под шапкой.
  final Widget? body;

  /// Закреплённое действие снизу: обычно [KvButton] или колонка кнопок.
  final Widget? foot;

  /// Фон - поверхность карточек вместо фона экрана.
  final bool surface;

  /// Содержимое под строкой состояния.
  final bool immersive;

  /// Светлые значки строки состояния; null - по теме.
  final bool? lightStatusBar;

  /// Светлый индикатор «домой»; null - как у строки состояния для полноэкранных экранов, иначе по теме.
  final bool? lightHome;

  /// Промежуток между блоками тела.
  final double gap;

  /// Боковые поля тела.
  final EdgeInsets padding;

  /// Появление блоков тела.
  final KvStagger stagger;

  /// Сколько первых блоков не анимировать.
  final int staggerSkip;

  /// Контроллер прокрутки тела.
  final ScrollController? scrollController;

  /// Фон под всем содержимым (фото, камера).
  final Widget? background;

  /// Слои поверх экрана (верхняя панель камеры и подобное).
  final List<Widget> overlays;

  @override
  State<KvScreen> createState() => _KvScreenState();
}

class _KvScreenState extends State<KvScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _stagger = AnimationController(vsync: this, duration: _staggerTotal);
  bool _started = false;

  Duration get _staggerTotal => widget.stagger == KvStagger.seg
      ? const Duration(milliseconds: 60 + 6 * 30 + 260)
      : KvMotion.staggerDelay + KvMotion.staggerStep * 13 + KvMotion.stagger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) {
      return;
    }
    _started = true;
    if (widget.stagger == KvStagger.none || context.kvReduceMotion) {
      _stagger.value = 1;
    } else {
      _stagger.forward();
    }
  }

  @override
  void dispose() {
    _stagger.dispose();
    super.dispose();
  }

  Widget _item(int i, Widget child) {
    if (widget.stagger == KvStagger.none || i < widget.staggerSkip) {
      return child;
    }
    final int k = i - widget.staggerSkip;
    final double total = _staggerTotal.inMilliseconds.toDouble();
    final bool seg = widget.stagger == KvStagger.seg;
    if (!seg && k >= 14) {
      return child;
    }
    final double start = seg ? 60 + math.min(k, 6) * 30 : 60 + k * 45.0;
    final double length = seg ? 260 : 420;
    final Animation<double> t = CurvedAnimation(
      parent: _stagger,
      curve: Interval(start / total, math.min(1, (start + length) / total), curve: seg ? KvMotion.easeOut : KvMotion.ease),
    );
    return FadeTransition(opacity: t, child: _Lift(animation: t, distance: seg ? 6 : 12, child: child));
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final MediaQueryData mq = MediaQuery.of(context);
    final bool hasTab = KvTabBarScope.maybeOf(context)?.visible ?? false;
    final bool hasFoot = widget.foot != null;
    final double tabBottom = KvTabBarScope.bottomOf(context);
    final double tabTop = tabBottom + KvLayout.tabBarHeight;
    final double homeGap = math.max(KvLayout.homeIndicator, mq.viewPadding.bottom);
    final double keyboard = mq.viewInsets.bottom;
    final double bodyBottom = switch ((hasTab, hasFoot)) {
          (true, true) => tabTop + 24 + 76,
          (true, false) => tabTop + 24,
          (false, true) => KvLayout.footSpace + homeGap - KvLayout.homeIndicator,
          (false, false) => 40,
        } +
        keyboard;
    final bool lightStatus = widget.lightStatusBar ?? c.isDark;
    final bool lightHome = widget.lightHome ?? (widget.immersive ? lightStatus : c.isDark);
    final Color bg = widget.surface ? c.surface : c.bg;

    Widget body;
    if (widget.body != null) {
      body = widget.body!;
    } else {
      final List<Widget> items = widget.children ?? const <Widget>[];
      body = ListView.separated(
        controller: widget.scrollController,
        padding: EdgeInsets.only(left: widget.padding.left, right: widget.padding.right, top: widget.padding.top, bottom: bodyBottom),
        itemCount: items.length,
        separatorBuilder: (BuildContext context, int i) => SizedBox(height: widget.gap),
        itemBuilder: (BuildContext context, int i) => _item(i, items[i]),
      );
    }

    final List<Widget> layers = [
      if (widget.background != null) Positioned.fill(child: widget.background!),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.immersive) SizedBox(height: mq.padding.top),
          ?widget.header,
          Expanded(child: body),
        ],
      ),
      if (hasTab)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: tabTop + 26,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [bg.withValues(alpha: 0), bg],
                  stops: const [0, 0.7],
                ),
              ),
            ),
          ),
        ),
      if (hasFoot)
        Positioned(
          left: 0,
          right: 0,
          bottom: (hasTab ? tabTop : 0) + keyboard,
          child: _FootGradient(
            color: bg,
            child: Padding(
              padding: EdgeInsets.fromLTRB(KvSpace.gutter, 18, KvSpace.gutter, hasTab ? 12 : (keyboard > 0 ? 12 : homeGap)),
              child: widget.foot,
            ),
          ),
        ),
      ...widget.overlays,
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: KvSystemUi.of(lightStatus: lightStatus, lightHome: lightHome),
      child: KvScreenScope(
        hasTabBar: hasTab,
        hasFoot: hasFoot,
        child: Material(
          type: MaterialType.transparency,
          child: DefaultTextStyle(
            style: context.kvText.base,
            child: ColoredBox(color: bg, child: Stack(children: layers)),
          ),
        ),
      ),
    );
  }
}

/// Сдвиг блока вверх на [distance] пикселей по мере анимации (часть очереди появления).
class _Lift extends AnimatedWidget {
  const _Lift({required Animation<double> animation, required this.distance, required this.child}) : super(listenable: animation);

  final double distance;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double t = (listenable as Animation<double>).value;
    if (t >= 1) {
      return child;
    }
    return Transform.translate(offset: Offset(0, distance * (1 - t)), child: child);
  }
}

/// Подложка закреплённой кнопки: прозрачная сверху, цвет фона с 22 px (linear-gradient прототипа).
class _FootGradient extends StatelessWidget {
  const _FootGradient({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _FootPainter(color), child: child);
  }
}

class _FootPainter extends CustomPainter {
  _FootPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0) {
      return;
    }
    final double stop = math.min(1, 22 / size.height);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0), color, color],
          stops: [0, stop, 1],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_FootPainter oldDelegate) => oldDelegate.color != color;
}

/// Шапка внутреннего экрана (.hdr): круглая «назад» слева, заголовок 18 по центру, точка статуса и подпись,
/// круглая «ещё» справа.
class KvHeader extends StatelessWidget {
  /// Создаёт шапку.
  const KvHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.status,
    this.onBack,
    this.onMore,
    this.leading,
    this.trailing,
  });

  /// Заголовок.
  final String title;

  /// Подпись под заголовком.
  final String? subtitle;

  /// Точка статуса перед подписью.
  final KvStatus? status;

  /// Назад; null - без кнопки.
  final VoidCallback? onBack;

  /// Меню «ещё»; null - без кнопки.
  final VoidCallback? onMore;

  /// Свой виджет слева вместо «назад».
  final Widget? leading;

  /// Свой виджет справа вместо «ещё».
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    final Widget left = leading ??
        (onBack != null ? KvRoundButton(icon: KvIcons.back, onPressed: onBack, semanticLabel: 'Назад') : const SizedBox(width: 44, height: 44));
    final Widget right = trailing ??
        (onMore != null ? KvRoundButton(icon: KvIcons.more, onPressed: onMore, semanticLabel: 'Ещё') : const SizedBox(width: 44, height: 44));
    return Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.gutter, 2, KvSpace.gutter, 12),
      child: Row(
        children: [
          SizedBox(width: 44, child: Align(alignment: Alignment.centerLeft, child: left)),
          const SizedBox(width: KvSpace.s2),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: t.hdr, semanticsLabel: title),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (status != null) ...[KvDot(status: status!), const SizedBox(width: 6)],
                        Flexible(child: Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13)))),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: KvSpace.s2),
          SizedBox(width: 44, child: Align(alignment: Alignment.centerRight, child: right)),
        ],
      ),
    );
  }
}

/// Шапка корневого экрана вкладки (.hdr-root): заголовок 22 и подпись по центру, без боковых кнопок.
class KvRootHeader extends StatelessWidget {
  /// Создаёт шапку.
  const KvRootHeader({super.key, required this.title, this.subtitle, this.status, this.trailing});

  /// Заголовок.
  final String title;

  /// Подпись.
  final String? subtitle;

  /// Точка статуса перед подписью.
  final KvStatus? status;

  /// Необязательная кнопка справа (уведомления и т. п.), не сдвигает заголовок.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    final Widget content = Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.gutter, 6, KvSpace.gutter, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, textAlign: TextAlign.center, style: t.title),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (status != null) ...[KvDot(status: status!), const SizedBox(width: 6)],
                  Flexible(child: Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13)))),
                ],
              ),
            ),
        ],
      ),
    );
    if (trailing == null) {
      return content;
    }
    return Stack(
      children: [
        content,
        Positioned(right: KvSpace.gutter, top: 0, child: trailing!),
      ],
    );
  }
}
