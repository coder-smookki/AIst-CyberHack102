import 'package:flutter/widgets.dart';

import '../icons/kv_icon.dart';
import '../theme/kv_theme.dart';
import 'kv_pressable.dart';

/// Полоса прогресса 6 px (.progress), тонкая - 4 px; цвет по статусу, без статуса - фирменный синий.
class KvProgress extends StatelessWidget {
  /// Создаёт полосу с долей [value] от 0 до 1.
  const KvProgress({super.key, required this.value, this.status, this.thin = false});

  /// Доля заполнения от 0 до 1.
  final double value;

  /// Цвет заполнения: ok, warn, bad; null или info - синий.
  final KvStatus? status;

  /// Тонкая полоса 4 px.
  final bool thin;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final double h = thin ? 4 : 6;
    final Color fill = switch (status) {
      KvStatus.ok => c.ok,
      KvStatus.warn => c.warn,
      KvStatus.bad => c.bad,
      _ => c.brand,
    };
    return Container(
      height: h,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: c.surface3, borderRadius: BorderRadius.circular(h / 2)),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: value.clamp(0.0, 1.0),
        child: DecoratedBox(decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(h / 2))),
      ),
    );
  }
}

/// Размер аватара.
enum KvAvatarSize {
  /// 32 px.
  small,

  /// 40 px.
  normal,

  /// 64 px.
  large,
}

/// Аватар с инициалами (.avatar): «Алексей Смирнов» - «АС».
class KvAvatar extends StatelessWidget {
  /// Создаёт аватар по имени или готовым инициалам [nameOrInitials].
  const KvAvatar(this.nameOrInitials, {super.key, this.size = KvAvatarSize.normal});

  /// Имя или инициалы.
  final String nameOrInitials;

  /// Размер.
  final KvAvatarSize size;

  /// Инициалы из имени: первые буквы двух первых слов.
  static String initials(String s) {
    final String v = s.trim();
    if (v.length <= 2) {
      return v.toUpperCase();
    }
    return v.split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).take(2).map((String w) => w[0]).join().toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final (double d, double fs) = switch (size) {
      KvAvatarSize.small => (32.0, 12.0),
      KvAvatarSize.normal => (40.0, 14.0),
      KvAvatarSize.large => (64.0, 22.0),
    };
    return Container(
      width: d,
      height: d,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.tint, shape: BoxShape.circle),
      child: Text(
        initials(nameOrInitials),
        style: TextStyle(fontFamily: KvTextStyles.kvFontFamily, fontSize: fs, fontWeight: FontWeight.w600, color: c.brand, height: 1),
      ),
    );
  }
}

/// Событие хронологии для [KvTimeline].
@immutable
class KvTimelineItem {
  /// Создаёт событие.
  const KvTimelineItem({required this.time, required this.title, this.text, this.status = KvStatus.unk, this.onTap});

  /// Время или дата.
  final String time;

  /// Заголовок.
  final String title;

  /// Подробности.
  final String? text;

  /// Цвет точки.
  final KvStatus status;

  /// Касание события.
  final VoidCallback? onTap;
}

/// Хронология (.timeline): точки статуса, соединённые линией, время, заголовок и текст.
class KvTimeline extends StatelessWidget {
  /// Создаёт хронологию.
  const KvTimeline({super.key, required this.items});

  /// События сверху вниз.
  final List<KvTimelineItem> items;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < items.length; i++)
          _TimelineRow(item: items[i], last: i == items.length - 1, colors: c, text: t),
      ],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.item, required this.last, required this.colors, required this.text});

  final KvTimelineItem item;
  final bool last;
  final KvColors colors;
  final KvTextStyles text;

  @override
  Widget build(BuildContext context) {
    final Color ring = item.status == KvStatus.info ? colors.brand : colors.status(item.status);
    final Widget row = Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : KvSpace.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: colors.surface, shape: BoxShape.circle, border: Border.all(color: ring, width: 2)),
              child: Container(width: 8, height: 8, decoration: BoxDecoration(color: ring, shape: BoxShape.circle)),
            ),
          ),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.time,
                  style: text.label.copyWith(fontWeight: FontWeight.w400, color: colors.text3),
                  strutStyle: StrutStyle(
                    fontFamily: KvTextStyles.kvFontFamily,
                    fontSize: 15,
                    height: KvTextStyles.normalHeight(15),
                    leadingDistribution: TextLeadingDistribution.even,
                    forceStrutHeight: true,
                  ),
                ),
                const SizedBox(height: 1),
                Text(item.title, style: text.sm.copyWith(fontWeight: FontWeight.w500, height: 1.35)),
                if (item.text != null) ...[
                  const SizedBox(height: 2),
                  Text(item.text!, style: text.caption),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    final Widget withLine = last
        ? row
        : Stack(
            children: [
              Positioned(left: 9, top: 18, bottom: -2, child: SizedBox(width: 2, child: ColoredBox(color: colors.divider))),
              row,
            ],
          );
    if (item.onTap == null) {
      return withLine;
    }
    return KvPressable(onTap: item.onTap, pressedScale: 0.985, semanticLabel: item.title, child: withLine);
  }
}

/// Пустое состояние (.empty): круглый значок, заголовок, текст и действие.
class KvEmpty extends StatelessWidget {
  /// Создаёт пустое состояние.
  const KvEmpty({super.key, required this.title, this.text, this.icon = KvIcons.search, this.action});

  /// Заголовок.
  final String title;

  /// Пояснение.
  final String? text;

  /// Значок в круге 72.
  final KvIcons icon;

  /// Действие под текстом, обычно [KvButton].
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KvSpace.s8, horizontal: KvSpace.s5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.tint2, shape: BoxShape.circle),
            child: KvIcon(icon, size: 32, color: c.brand),
          ),
          const SizedBox(height: KvSpace.s2 + KvSpace.s2),
          Text(title, textAlign: TextAlign.center, style: t.h2.copyWith(height: KvTextStyles.normalHeight(17))),
          if (text != null) ...[
            const SizedBox(height: KvSpace.s2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(text!, textAlign: TextAlign.center, style: t.sm.copyWith(color: c.text2)),
            ),
          ],
          if (action != null) ...[const SizedBox(height: KvSpace.s2 + KvSpace.s3), action!],
        ],
      ),
    );
  }
}

/// Тонированная плашка с пояснением (.note): синяя, жёлтая, красная или зелёная.
class KvNote extends StatelessWidget {
  /// Создаёт плашку с текстом [text] или своим содержимым [child].
  const KvNote({super.key, this.text, this.child, this.tone, this.icon = KvIcons.sparkle, this.onTap});

  /// Текст.
  final String? text;

  /// Содержимое вместо текста (например, RichText с полужирным началом).
  final Widget? child;

  /// Тон: warn, bad, ok; null - синий.
  final KvStatus? tone;

  /// Значок слева.
  final KvIcons icon;

  /// Касание плашки.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final (Color bg, Color fg) = switch (tone) {
      KvStatus.warn => (c.warnBg, c.warnText),
      KvStatus.bad => (c.badBg, c.bad),
      KvStatus.ok => (c.okBg, c.ok),
      _ => (c.tint2, c.brand),
    };
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    final Widget body = Container(
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.s4, vertical: 14),
      decoration: BoxDecoration(color: bg, borderRadius: radius),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: KvIcon(icon, size: 20, color: fg)),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: DefaultTextStyle.merge(
              style: context.kvText.sm.copyWith(fontWeight: FontWeight.w500, color: fg),
              child: child ?? Text(text ?? ''),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) {
      return body;
    }
    return KvPressable(onTap: onTap, borderRadius: radius, pressedScale: 0.985, child: body);
  }
}

/// Строки «ключ - значение» с разделителями (.kv).
class KvKeyValues extends StatelessWidget {
  /// Создаёт строки из пар [pairs].
  const KvKeyValues(this.pairs, {super.key});

  /// Пары ключ - значение.
  final List<(String, String)> pairs;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < pairs.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: i == 0 ? null : BoxDecoration(border: Border(top: BorderSide(color: c.divider))),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(pairs[i].$1, style: t.sm.copyWith(color: c.text2, height: KvTextStyles.normalHeight(14))),
                const SizedBox(width: KvSpace.s3),
                Expanded(
                  child: Text(pairs[i].$2, textAlign: TextAlign.right, style: t.sm.copyWith(fontWeight: FontWeight.w500, height: KvTextStyles.normalHeight(14))),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Логотип заказчика с сохранением пропорций 1758 × 417: белый для героя и тёмной темы, синий для светлой.
class KvLogo extends StatelessWidget {
  /// Создаёт логотип высотой [height].
  const KvLogo({super.key, this.white = false, this.height = 32});

  /// Логотип с учётом темы: синий в светлой, белый в тёмной.
  const KvLogo.themed({super.key, this.height = 32}) : white = null;

  /// Белый вариант; null - по теме.
  final bool? white;

  /// Высота.
  final double height;

  /// Отношение ширины логотипа к высоте.
  static const double aspect = 1758 / 417;

  @override
  Widget build(BuildContext context) {
    final bool w = white ?? context.kv.isDark;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return Image.asset(
      w ? 'assets/images/kst_logo_white.png' : 'assets/images/kst_logo_blue.png',
      height: height,
      width: (height * aspect).roundToDouble(),
      cacheHeight: (height * dpr).round(),
      semanticLabel: 'КСТ ЭНЕРГО ИНЖИНИРИНГ',
    );
  }
}

/// Заглушка загрузки: скруглённый блок с мягкой пульсацией; при уменьшении движения - неподвижный.
class KvSkeleton extends StatefulWidget {
  /// Создаёт заглушку размером [width] × [height].
  const KvSkeleton({super.key, this.width, this.height = 16, this.radius = 8});

  /// Заглушка размером с карточку.
  const KvSkeleton.card({super.key, this.width, this.height = 120}) : radius = KvRadius.card;

  /// Ширина; по умолчанию вся доступная.
  final double? width;

  /// Высота.
  final double height;

  /// Скругление.
  final double radius;

  @override
  State<KvSkeleton> createState() => _KvSkeletonState();
}

class _KvSkeletonState extends State<KvSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.kvReduceMotion) {
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
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
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.55, end: 1).animate(_c),
        child: Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(color: context.kv.surface3, borderRadius: BorderRadius.circular(widget.radius)),
        ),
      ),
    );
  }
}

/// Подпись раздела над карточками (.section-label).
class KvSectionLabel extends StatelessWidget {
  /// Создаёт подпись.
  const KvSectionLabel(this.text, {super.key});

  /// Текст.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(KvSpace.s1, KvSpace.s2, KvSpace.s1, 0),
      child: Text(text, style: context.kvText.caption.copyWith(fontWeight: FontWeight.w500, height: KvTextStyles.normalHeight(13))),
    );
  }
}
