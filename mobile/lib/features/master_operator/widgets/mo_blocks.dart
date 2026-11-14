import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../core/kv.dart';

/// Узкий экран (контейнерный запрос прототипа max-width: 370px).
bool moNarrow(BuildContext context) => MediaQuery.sizeOf(context).width <= 370;

/// Подпись раздела (.section-label): в листе снизу отступ сверху 2 вместо 8 (.sheet .section-label).
class MoLabel extends StatelessWidget {
  /// Создаёт подпись раздела.
  const MoLabel(this.text, {super.key});

  /// Текст подписи.
  final String text;

  @override
  Widget build(BuildContext context) {
    final bool inSheet = KvSheetScope.maybeOf(context) != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(KvSpace.s1, inSheet ? 2 : KvSpace.s2, KvSpace.s1, 0),
      child: Text(text, style: context.kvText.caption.copyWith(fontWeight: FontWeight.w500, height: KvTextStyles.normalHeight(13))),
    );
  }
}

/// Плашка-баннер раздела (.d-banner): значок в белом квадрате, заголовок 14 и подпись, шеврон при касании.
class MoBanner extends StatelessWidget {
  /// Создаёт баннер.
  const MoBanner({super.key, required this.icon, required this.title, this.subtitle, this.tone, this.iconStatus, this.onTap});

  /// Значок.
  final KvIcons icon;

  /// Заголовок.
  final String title;

  /// Подпись.
  final String? subtitle;

  /// Тон подложки: warn, bad, info (светло-синяя); null - белая с тенью.
  final KvStatus? tone;

  /// Тон значка.
  final KvStatus? iconStatus;

  /// Касание баннера.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final Color bg = switch (tone) {
      KvStatus.warn => c.warnBg,
      KvStatus.bad => c.badBg,
      KvStatus.info => c.tint2,
      _ => c.surface,
    };
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    final Widget body = Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: bg, borderRadius: radius, boxShadow: tone == null ? c.shadow1 : null),
      child: Row(
        children: [
          KvRowIcon(icon: icon, status: iconStatus, background: c.surface),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: t.sm.copyWith(fontWeight: FontWeight.w600, height: 1.3)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: t.caption.copyWith(height: 1.35)),
                ],
              ],
            ),
          ),
          if (onTap != null) ...[const SizedBox(width: KvSpace.s3), KvIcon(KvIcons.chevronRight, size: 20, color: c.text3)],
        ],
      ),
    );
    if (onTap == null) {
      return body;
    }
    return KvPressable(onTap: onTap, borderRadius: radius, pressedScale: 0.985, semanticLabel: title, child: body);
  }
}

/// Ряд из двух блоков одинаковой высоты (.grid2): высота ряда - наибольшая из блоков, но не меньше [minHeight].
///
/// Блоки сначала измеряются по содержимому, затем раскладываются в общую высоту, как ячейки CSS-сетки.
class MoGridRow extends MultiChildRenderObjectWidget {
  /// Создаёт ряд из блоков [children] с промежутком [gap].
  const MoGridRow({super.key, required super.children, this.gap = KvSpace.s3, this.minHeight = 0});

  /// Промежуток между блоками.
  final double gap;

  /// Наименьшая высота ряда.
  final double minHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGridRow(gap, minHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderGridRow renderObject) {
    renderObject
      ..gap = gap
      ..minHeight = minHeight;
  }
}

class _GridRowData extends ContainerBoxParentData<RenderBox> {}

class _RenderGridRow extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _GridRowData>, RenderBoxContainerDefaultsMixin<RenderBox, _GridRowData> {
  _RenderGridRow(this._gap, this._minHeight);

  double _gap;
  double _minHeight;

  set gap(double v) {
    if (v != _gap) {
      _gap = v;
      markNeedsLayout();
    }
  }

  set minHeight(double v) {
    if (v != _minHeight) {
      _minHeight = v;
      markNeedsLayout();
    }
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _GridRowData) {
      child.parentData = _GridRowData();
    }
  }

  @override
  void performLayout() {
    final int n = childCount;
    if (n == 0) {
      size = constraints.constrain(Size(constraints.maxWidth, _minHeight));
      return;
    }
    final double w = (constraints.maxWidth - _gap * (n - 1)) / n;
    double h = _minHeight;
    RenderBox? child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints(minWidth: w, maxWidth: w), parentUsesSize: true);
      h = math.max(h, child.size.height);
      child = childAfter(child);
    }
    child = firstChild;
    double x = 0;
    while (child != null) {
      child.layout(BoxConstraints.tightFor(width: w, height: h));
      (child.parentData! as _GridRowData).offset = Offset(x, 0);
      x += w + _gap;
      child = childAfter(child);
    }
    size = constraints.constrain(Size(constraints.maxWidth, h));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);
}

/// Полоса состояния агрегатов (.d-sbar): по сегменту на агрегат цвета его статуса.
class MoStatusBar extends StatelessWidget {
  /// Создаёт полосу из сегментов [items]; null - серый сегмент.
  const MoStatusBar(this.items, {super.key});

  /// Статусы сегментов.
  final List<KvStatus?> items;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return SizedBox(
      height: 8,
      child: Row(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(color: items[i] == null ? c.surface3 : c.status(items[i]!), borderRadius: BorderRadius.circular(4)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Кольцо охвата (.d-ring): дорожка и дуга фирменного цвета с процентом в центре, дуга дорисовывается за 1 с.
class MoRing extends StatefulWidget {
  /// Создаёт кольцо с долей [percent] от 0 до 100.
  const MoRing(this.percent, {super.key});

  /// Процент охвата.
  final double percent;

  @override
  State<MoRing> createState() => _MoRingState();
}

class _MoRingState extends State<MoRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1150));
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: const Interval(150 / 1150, 1, curve: KvMotion.ease));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
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
    final KvColors c = context.kv;
    final double d = moNarrow(context) ? 48 : 54;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: d,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _t,
                builder: (BuildContext context, Widget? _) => CustomPaint(painter: _RingPainter(widget.percent / 100 * _t.value, c.surface3, c.brand)),
              ),
            ),
            Text(
              '${widget.percent.round()}%',
              style: context.kvText.label.copyWith(fontWeight: FontWeight.w600, color: c.brand, height: KvTextStyles.normalHeight(12)),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction, this.track, this.value);

  final double fraction;
  final Color track;
  final Color value;

  @override
  void paint(Canvas canvas, Size size) {
    final double k = size.width / 54;
    final Rect r = Rect.fromCircle(center: size.center(Offset.zero), radius: 22 * k);
    canvas.drawArc(r, 0, math.pi * 2, false, Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6 * k);
    if (fraction > 0) {
      canvas.drawArc(r, -math.pi / 2, math.pi * 2 * fraction, false, Paint()
        ..color = value
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 6 * k);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction || old.track != track || old.value != value;
}

/// Плитка-счётчик сводки смены (.tile.d-kpi): подпись, крупное число с пояснением, спарклайн, полоса или кольцо,
/// подпись внизу. Высота плитки задаётся рядом [MoGridRow]; подпись прижимается к низу.
class MoKpiTile extends StatelessWidget {
  /// Создаёт плитку.
  const MoKpiTile({super.key, required this.label, required this.value, this.unit, required this.sub, this.subWarn = false, this.spark, this.bar, this.ring, this.onTap});

  /// Подпись сверху.
  final String label;

  /// Крупное число.
  final String value;

  /// Пояснение рядом с числом.
  final String? unit;

  /// Подпись внизу.
  final String sub;

  /// Подпись внизу цвета «внимание».
  final bool subWarn;

  /// Значения спарклайна.
  final List<double>? spark;

  /// Сегменты полосы состояния.
  final List<KvStatus?>? bar;

  /// Процент кольца охвата.
  final double? ring;

  /// Касание плитки; с ним справа от подписи появляется шеврон.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool narrow = moNarrow(context);
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    final Widget top = SizedBox(
      height: onTap != null ? 18 : 17,
      child: Row(
        children: [
          Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13)))),
          if (onTap != null) ...[const SizedBox(width: 6), KvIcon(KvIcons.chevronRight, size: 18, color: c.text3)],
        ],
      ),
    );
    final Widget val = Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Text(value, maxLines: 1, softWrap: false, style: t.numL.copyWith(fontSize: narrow ? 32 : 36, height: 1, color: c.text)),
          if (unit != null) ...[
            const SizedBox(width: 5),
            Flexible(
              child: Text(unit!, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: t.unit.copyWith(height: KvTextStyles.normalHeight(13))),
            ),
          ],
          if (ring != null) ...[const Spacer(), MoRing(ring!)],
        ],
      ),
    );
    final Widget body = Container(
      padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 14, vertical: 12),
      decoration: BoxDecoration(color: c.surface, borderRadius: radius, boxShadow: c.shadow1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              top,
              const SizedBox(height: 4),
              val,
              if (spark != null) ...[
                const SizedBox(height: 4 + 2),
                SizedBox(
                  height: 34,
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints box) => OverflowBox(
                      minWidth: box.maxWidth + 4,
                      maxWidth: box.maxWidth + 4,
                      child: KvSparkline(data: KvSeriesData(values: spark!), height: 34),
                    ),
                  ),
                ),
              ],
              if (bar != null) ...[
                const SizedBox(height: 4 + 12),
                MoStatusBar(bar!),
                const SizedBox(height: 6),
              ],
              const SizedBox(height: 4),
            ],
          ),
          Text(sub, style: t.label.copyWith(fontWeight: FontWeight.w400, height: 1.3, color: subWarn ? c.warnText : c.text2)),
        ],
      ),
    );
    if (onTap == null) {
      return body;
    }
    return KvPressable(onTap: onTap, borderRadius: radius, pressedScale: 0.985, semanticLabel: label, child: body);
  }
}

/// Строка «до работы осталось» (.d-next): крупное число часов с единицей, пояснение и полоса прогресса.
class MoNext extends StatelessWidget {
  /// Создаёт строку.
  const MoNext({super.key, required this.value, required this.unit, required this.title, required this.text, this.tone = KvStatus.warn, this.progress, this.progressStatus});

  /// Число.
  final String value;

  /// Единица: «ч», «дн».
  final String unit;

  /// Заголовок пояснения.
  final String title;

  /// Текст пояснения.
  final String text;

  /// Цвет числа: warn - жёлтый текст, info - фирменный, unk - серый, bad - красный.
  final KvStatus tone;

  /// Доля полосы прогресса 0-1; null - без полосы.
  final double? progress;

  /// Цвет полосы.
  final KvStatus? progressStatus;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final Color color = switch (tone) {
      KvStatus.warn => c.warnText,
      KvStatus.info => c.brand,
      KvStatus.bad => c.bad,
      _ => c.text2,
    };
    final double size = moNarrow(context) ? 38 : 44;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, maxLines: 1, softWrap: false, style: t.numXl.copyWith(fontSize: size, letterSpacing: -0.02 * size, color: color)),
                const SizedBox(width: 6),
                Text(unit, maxLines: 1, softWrap: false, style: t.title.copyWith(fontWeight: FontWeight.w300, height: 1, color: color)),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '$title\n', style: t.sm.copyWith(fontWeight: FontWeight.w500, color: c.text, height: 1.38)),
                    TextSpan(text: text),
                  ],
                ),
                style: t.caption.copyWith(height: 1.38),
              ),
            ),
          ],
        ),
        if (progress != null) ...[const SizedBox(height: 10), KvProgress(value: progress!, status: progressStatus)],
      ],
    );
  }
}

/// Строка работы плана ТО (.d-mt): название с интервалом, остаток часов цветом срока и тонкая полоса.
class MoMtRow extends StatelessWidget {
  /// Создаёт строку.
  const MoMtRow({super.key, required this.name, this.every, required this.left, required this.fraction, required this.tone, this.first = false, this.last = false});

  /// Название работы.
  final String name;

  /// Интервал: «каждые 4 000 ч».
  final String? every;

  /// Остаток часов.
  final double left;

  /// Доля выработки 0-1.
  final double fraction;

  /// Тон срока: ok, warn, bad, unk (пауза).
  final KvStatus tone;

  /// Первая строка карточки (без разделителя сверху).
  final bool first;

  /// Последняя строка карточки (нижний отступ 2).
  final bool last;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final String lbl = left <= 0
        ? 'просрочено'
        : tone == KvStatus.unk
            ? 'пауза · ${KvFormat.num(left)} ч'
            : 'через ${KvFormat.num(left)} ч';
    final Color lc = switch (tone) {
      KvStatus.warn => c.warnText,
      KvStatus.bad => c.bad,
      KvStatus.unk => c.text2,
      _ => c.brand,
    };
    return Container(
      padding: EdgeInsets.only(top: 11, bottom: last ? 2 : 11),
      decoration: first ? null : BoxDecoration(border: Border(top: BorderSide(color: c.divider))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: name),
                      if (every != null) TextSpan(text: ' · ${KvFormat.typo(every!)}', style: TextStyle(color: c.text2, fontWeight: FontWeight.w400)),
                    ],
                  ),
                  style: t.sm.copyWith(fontWeight: FontWeight.w500, height: 1.3),
                ),
              ),
              const SizedBox(width: 10),
              Text(KvFormat.typo(lbl), maxLines: 1, softWrap: false, style: t.sm.copyWith(fontWeight: FontWeight.w600, color: lc, height: KvTextStyles.normalHeight(14))),
            ],
          ),
          const SizedBox(height: 7),
          KvProgress(value: fraction, status: tone == KvStatus.warn || tone == KvStatus.bad ? tone : null, thin: true),
        ],
      ),
    );
  }
}

/// Серая плашка с пояснением (.d-repair): значок 18 фирменного цвета, полужирная первая строка и подпись.
class MoRepairNote extends StatelessWidget {
  /// Создаёт плашку.
  const MoRepairNote({super.key, required this.icon, required this.title, required this.text});

  /// Значок.
  final KvIcons icon;

  /// Первая строка.
  final String title;

  /// Вторая строка.
  final String text;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          KvIcon(icon, size: 18, color: c.brand),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${KvFormat.typo(title)}\n', style: TextStyle(color: c.text, fontWeight: FontWeight.w500)),
                  TextSpan(text: KvFormat.typo(text)),
                ],
              ),
              style: t.caption.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка «живые показания» (.d-live): пульсирующая зелёная точка и подпись по центру.
class MoLiveLine extends StatelessWidget {
  /// Создаёт строку с текстом [text].
  const MoLiveLine(this.text, {super.key});

  /// Текст.
  final String text;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const MoPulseDot(),
          const SizedBox(width: KvSpace.s2),
          Flexible(child: Text(KvFormat.typo(text), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.kvText.caption.copyWith(height: KvTextStyles.normalHeight(13)))),
        ],
      ),
    );
  }
}

/// Зелёная точка с расходящимся кольцом (.dot.pulse): 1,8 с по кругу; при уменьшении движения неподвижна.
class MoPulseDot extends StatefulWidget {
  /// Создаёт точку.
  const MoPulseDot({super.key});

  @override
  State<MoPulseDot> createState() => _MoPulseDotState();
}

class _MoPulseDotState extends State<MoPulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

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
    final Color ok = context.kv.ok;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (BuildContext context, Widget? _) {
          final double p = (_c.value / 0.7).clamp(0.0, 1.0);
          final bool on = _c.isAnimating && _c.value < 0.7;
          return Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: ok,
              shape: BoxShape.circle,
              boxShadow: on ? [BoxShadow(color: ok.withValues(alpha: 0.5 * (1 - p)), spreadRadius: 8 * p)] : null,
            ),
          );
        },
      ),
    );
  }
}

/// Круглый значок результата (.d-done-ic): зелёный с ореолом для успеха, мягкие тона для остальных состояний;
/// появляется с лёгким увеличением, галочка дорисовывается.
class MoResultIcon extends StatefulWidget {
  /// Создаёт значок; без [icon] рисуется галочка.
  const MoResultIcon({super.key, this.icon, this.tone = KvStatus.ok, this.iconSize = 36});

  /// Значок; null - анимированная галочка.
  final KvIcons? icon;

  /// Тон: ok - залитый зелёный, info, warn, bad, unk - мягкие.
  final KvStatus tone;

  /// Размер значка.
  final double iconSize;

  @override
  State<MoResultIcon> createState() => _MoResultIconState();
}

class _MoResultIconState extends State<MoResultIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 850));
  late final Animation<double> _pop = TweenSequence<double>([
    TweenSequenceItem<double>(tween: Tween<double>(begin: 0.6, end: 1.06), weight: 70),
    TweenSequenceItem<double>(tween: Tween<double>(begin: 1.06, end: 1), weight: 30),
  ]).animate(CurvedAnimation(parent: _c, curve: const Interval(120 / 850, 670 / 850, curve: KvMotion.ease)));
  late final Animation<double> _fade = CurvedAnimation(parent: _c, curve: const Interval(120 / 850, 505 / 850));
  late final Animation<double> _draw = CurvedAnimation(parent: _c, curve: const Interval(400 / 850, 1, curve: KvMotion.ease));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
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
    final KvColors c = context.kv;
    final (Color bg, Color fg, Color halo) = switch (widget.tone) {
      KvStatus.info => (c.tint, c.brand, c.tint2),
      KvStatus.warn => (c.warnBg, c.warn, c.warnBg),
      KvStatus.bad => (c.badBg, c.bad, c.badBg),
      KvStatus.unk => (c.unkBg, c.unk, c.unkBg),
      KvStatus.ok => (c.ok, c.onBrand, c.okBg),
    };
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (BuildContext context, Widget? _) => Opacity(
          opacity: _fade.value,
          child: Transform.scale(
            scale: _pop.value,
            child: Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle, boxShadow: [BoxShadow(color: halo, spreadRadius: 12)]),
              child: widget.icon != null
                  ? KvIcon(widget.icon!, size: widget.iconSize, color: fg)
                  : CustomPaint(size: Size.square(widget.iconSize), painter: _CheckPainter(_draw.value, fg)),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.t, this.color);

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double k = size.width / 24;
    final Path full = Path()
      ..moveTo(5 * k, 12.5 * k)
      ..lineTo(9.5 * k, 17 * k)
      ..lineTo(19 * k, 7.5 * k);
    final Paint p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (t >= 1) {
      canvas.drawPath(full, p);
      return;
    }
    if (t <= 0) {
      return;
    }
    final Path part = Path();
    for (final PathMetric m in full.computeMetrics()) {
      part.addPath(m.extractPath(0, m.length * t), Offset.zero);
    }
    canvas.drawPath(part, p);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.t != t || old.color != color;
}

/// Блок результата (.d-done / .d-status): значок, заголовок 22 и текст по центру.
class MoResult extends StatelessWidget {
  /// Создаёт блок результата.
  const MoResult({super.key, required this.title, this.text, this.icon, this.tone = KvStatus.ok, this.iconSize = 36, this.status = false});

  /// Заголовок.
  final String title;

  /// Текст.
  final String? text;

  /// Значок; null - галочка.
  final KvIcons? icon;

  /// Тон значка.
  final KvStatus tone;

  /// Размер значка.
  final double iconSize;

  /// Вид блока на экране (.d-status): поля 22/16/18 и отступ значка 14 вместо листа (.d-done).
  final bool status;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Padding(
      padding: status ? const EdgeInsets.fromLTRB(16, 22, 16, 18) : const EdgeInsets.fromLTRB(8, 4, 8, 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          MoResultIcon(icon: icon, tone: tone, iconSize: iconSize),
          SizedBox(height: (status ? 14 : 18) + 6.0),
          Text(KvFormat.typo(title), textAlign: TextAlign.center, style: t.title.copyWith(height: 1.25)),
          if (text != null) ...[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 310),
              child: Text(KvFormat.typo(text!), textAlign: TextAlign.center, style: t.sm.copyWith(color: c.text2, height: 1.45)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Серая карточка «ключ - значение» в листе результата (.d-kvcard): разделители цвета рамки.
class MoKvCard extends StatelessWidget {
  /// Создаёт карточку из пар [pairs].
  const MoKvCard(this.pairs, {super.key});

  /// Пары ключ - значение.
  final List<(String, String)> pairs;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(KvRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < pairs.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: i == 0 ? null : BoxDecoration(border: Border(top: BorderSide(color: c.border))),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(pairs[i].$1, style: t.sm.copyWith(color: c.text2, height: KvTextStyles.normalHeight(14))),
                  const SizedBox(width: KvSpace.s3),
                  Expanded(
                    child: Text(
                      KvFormat.typo(pairs[i].$2),
                      textAlign: TextAlign.right,
                      style: t.sm.copyWith(fontWeight: FontWeight.w500, height: KvTextStyles.normalHeight(14)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Лист результата (doneSheet прототипа): значок, заголовок, текст, серая карточка значений и кнопки.
class MoDoneSheet extends StatelessWidget {
  /// Создаёт лист.
  const MoDoneSheet({super.key, required this.title, this.text, this.icon, this.tone = KvStatus.ok, this.pairs, required this.actions});

  /// Заголовок.
  final String title;

  /// Текст.
  final String? text;

  /// Значок; null - галочка.
  final KvIcons? icon;

  /// Тон значка.
  final KvStatus tone;

  /// Пары «ключ - значение».
  final List<(String, String)>? pairs;

  /// Кнопки.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return KvSheet(
      children: [
        MoResult(title: title, text: text, icon: icon, tone: tone),
        if (pairs != null) MoKvCard(pairs!),
      ],
      actions: actions,
    );
  }
}

/// Кружок выбора строки-радио (.d-rad): кольцо 2 px, при выборе - синее кольцо и точка.
class MoRadio extends StatelessWidget {
  /// Создаёт кружок.
  const MoRadio({super.key, required this.on});

  /// Выбран.
  final bool on;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Duration d = context.kvReduceMotion ? Duration.zero : KvMotion.std;
    return AnimatedContainer(
      duration: d,
      curve: KvMotion.ease,
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: on ? c.brand : c.border, width: 2)),
      child: AnimatedScale(
        duration: d,
        curve: KvMotion.ease,
        scale: on ? 1 : 0,
        child: Container(width: 10, height: 10, decoration: BoxDecoration(color: c.brand, shape: BoxShape.circle)),
      ),
    );
  }
}

/// Строка выбора одного варианта (radioRow прототипа): значок или аватар, текст и кружок справа.
class MoRadioRow extends StatelessWidget {
  /// Создаёт строку.
  const MoRadioRow({super.key, required this.title, this.subtitle, this.icon, this.iconStatus, this.avatar, required this.on, required this.onTap});

  /// Заголовок.
  final String title;

  /// Подпись.
  final String? subtitle;

  /// Значок.
  final KvIcons? icon;

  /// Тон значка.
  final KvStatus? iconStatus;

  /// Имя для аватара.
  final String? avatar;

  /// Выбрана.
  final bool on;

  /// Выбор строки.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: on,
      child: KvRow(
        title: title,
        subtitle: subtitle == null ? null : KvFormat.typo(subtitle!),
        icon: icon,
        iconStatus: iconStatus,
        avatar: avatar,
        chevron: false,
        trailing: MoRadio(on: on),
        onTap: onTap,
      ),
    );
  }
}

/// Строка с переключателем (switchRow прототипа).
class MoSwitchRow extends StatelessWidget {
  /// Создаёт строку.
  const MoSwitchRow({super.key, required this.title, this.subtitle, this.icon, this.iconStatus, required this.value, required this.onChanged});

  /// Заголовок.
  final String title;

  /// Подпись.
  final String? subtitle;

  /// Значок.
  final KvIcons? icon;

  /// Тон значка.
  final KvStatus? iconStatus;

  /// Включён.
  final bool value;

  /// Смена состояния.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return KvRow(
      title: title,
      subtitle: subtitle == null ? null : KvFormat.typo(subtitle!),
      icon: icon,
      iconStatus: iconStatus,
      chevron: false,
      trailing: KvToggle(value: value, onChanged: onChanged, semanticLabel: title),
    );
  }
}

/// Цитата сотрудника (.d-quote): аватар, подпись автора, текст и чипы под ним.
class MoQuote extends StatelessWidget {
  /// Создаёт цитату.
  const MoQuote({super.key, required this.avatar, required this.who, required this.text, this.chips = const <Widget>[], this.large = false});

  /// Имя или инициалы для аватара.
  final String avatar;

  /// Подпись автора.
  final String who;

  /// Текст.
  final String text;

  /// Чипы под текстом.
  final List<Widget> chips;

  /// Текст 15 (сообщение оператора) вместо 14.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        KvAvatar(avatar),
        const SizedBox(width: KvSpace.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(KvFormat.typo(who), style: t.caption.copyWith(height: KvTextStyles.normalHeight(13))),
              const SizedBox(height: 4),
              Text(KvFormat.typo(text), style: large ? t.body.copyWith(height: 1.45) : t.sm),
              if (chips.isNotEmpty) ...[
                const SizedBox(height: KvSpace.s2),
                Wrap(spacing: KvSpace.s2, runSpacing: KvSpace.s2, children: chips),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Карточка профиля (.card.d-prof): крупный аватар, имя, должность, почта и чипы роли и смены.
class MoProfileCard extends StatelessWidget {
  /// Создаёт карточку.
  const MoProfileCard({super.key, required this.name, required this.title, required this.email, required this.role, required this.shift});

  /// Имя.
  final String name;

  /// Должность.
  final String title;

  /// Почта.
  final String email;

  /// Подпись роли.
  final String role;

  /// Смена.
  final String shift;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    return KvCard(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          KvAvatar(name, size: KvAvatarSize.large),
          const SizedBox(height: 8 + 4),
          Text(name, textAlign: TextAlign.center, style: t.hdr),
          const SizedBox(height: 4),
          Text(title, textAlign: TextAlign.center, style: t.caption),
          const SizedBox(height: 4),
          Text(email, textAlign: TextAlign.center, style: t.caption),
          const SizedBox(height: 4 + 10),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: KvSpace.s2,
            runSpacing: KvSpace.s2,
            children: [KvChip(role, status: KvStatus.info), KvChip(shift, dot: false)],
          ),
        ],
      ),
    );
  }
}

/// Пункт-подсказка с переносом текста (.d-sugg .fchip): таблетка 36 в области 44, при выборе - синяя.
class MoSuggestChip extends StatelessWidget {
  /// Создаёт пункт.
  const MoSuggestChip({super.key, required this.label, this.on = false, required this.onTap});

  /// Текст.
  final String label;

  /// Выбран.
  final bool on;

  /// Касание.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Color fg = on ? c.onBrand : c.text2;
    return KvPressable(
      onTap: onTap,
      immediate: true,
      highlight: false,
      semanticLabel: label,
      child: Container(
        constraints: const BoxConstraints(minHeight: KvLayout.touch),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: AnimatedContainer(
          duration: KvMotion.std,
          curve: KvMotion.ease,
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(color: on ? c.btnPrimary : c.surface, borderRadius: BorderRadius.circular(KvRadius.pill), boxShadow: c.shadow1),
          child: Text(KvFormat.typo(label), style: context.kvText.sm.copyWith(fontWeight: FontWeight.w500, height: 1.25, color: fg)),
        ),
      ),
    );
  }
}

/// Группа подсказок (.fchips.d-sugg): перенос по строкам без промежутка между строками.
class MoSuggestChips extends StatelessWidget {
  /// Создаёт группу из пунктов [children].
  const MoSuggestChips({super.key, required this.children});

  /// Пункты, обычно [MoSuggestChip].
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(spacing: KvSpace.s2, children: children);
}
