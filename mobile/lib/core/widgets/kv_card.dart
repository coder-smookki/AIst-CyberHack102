import 'package:flutter/widgets.dart';

import '../format/kv_format.dart';
import '../icons/kv_icon.dart';
import '../theme/kv_theme.dart';
import 'kv_chart.dart';
import 'kv_chip.dart';
import 'kv_pressable.dart';

/// Вид карточки (.card, .pad-l, .flush, .tinted, .outline).
enum KvCardStyle {
  /// Белая с тенью, поля 16.
  normal,

  /// Белая с тенью, поля 20.
  padL,

  /// Без полей, содержимое обрезается по скруглению.
  flush,

  /// Светло-синяя без тени.
  tinted,

  /// С рамкой без тени.
  outline,
}

/// Карточка дизайна: скругление 20, белая поверхность, мягкая тень; с [title] - заголовок 17 и [trailing] справа.
class KvCard extends StatelessWidget {
  /// Создаёт карточку с содержимым [child].
  const KvCard({
    super.key,
    this.child,
    this.title,
    this.trailing,
    this.style = KvCardStyle.normal,
    this.onTap,
    this.padding,
    this.semanticLabel,
  });

  /// Содержимое под заголовком.
  final Widget? child;

  /// Заголовок карточки.
  final String? title;

  /// Виджет справа от заголовка.
  final Widget? trailing;

  /// Вид карточки.
  final KvCardStyle style;

  /// Касание всей карточки.
  final VoidCallback? onTap;

  /// Свои поля вместо полей вида.
  final EdgeInsets? padding;

  /// Подпись для диктора.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final EdgeInsets pad = padding ??
        switch (style) {
          KvCardStyle.padL => const EdgeInsets.all(KvSpace.s5),
          KvCardStyle.flush => EdgeInsets.zero,
          _ => const EdgeInsets.all(KvSpace.s4),
        };
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    final Widget? head = (title != null || trailing != null)
        ? Padding(
            padding: const EdgeInsets.only(bottom: KvSpace.s3),
            child: Row(
              children: [
                Expanded(child: Text(title ?? '', style: context.kvText.h2)),
                if (trailing != null) ...[const SizedBox(width: KvSpace.s2), trailing!],
              ],
            ),
          )
        : null;
    Widget body = head == null
        ? (child ?? const SizedBox.shrink())
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [head, ?child]);
    body = Container(
      padding: pad,
      clipBehavior: style == KvCardStyle.flush ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: style == KvCardStyle.tinted ? c.tint2 : c.surface,
        borderRadius: radius,
        boxShadow: style == KvCardStyle.tinted || style == KvCardStyle.outline ? null : c.shadow1,
        border: style == KvCardStyle.outline ? Border.all(color: c.border) : null,
      ),
      child: body,
    );
    if (onTap == null) {
      return body;
    }
    return KvPressable(onTap: onTap, borderRadius: radius, pressedScale: 0.985, semanticLabel: semanticLabel, child: body);
  }
}

/// Плитка показания (.tile): подпись, точка статуса, крупное значение с единицей и спарклайн.
class KvTile extends StatelessWidget {
  /// Создаёт плитку показания.
  const KvTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.status,
    this.spark,
    this.extra,
    this.onTap,
    this.sparkHeight = KvSparkline.defaultHeight,
    this.stretch = false,
  });

  /// Высота спарклайна.
  final double sparkHeight;

  /// Плитка растянута по высоте ряда: подпись сверху, спарклайн прижат к низу (justify-content: space-between).
  final bool stretch;

  /// Подпись: «Вибрация 1X».
  final String label;

  /// Значение, уже отформатированное: «3,1».
  final String value;

  /// Единица: «мм/с».
  final String? unit;

  /// Точка статуса справа от подписи.
  final KvStatus? status;

  /// Спарклайн под значением.
  final KvSeriesData? spark;

  /// Дополнительное содержимое внизу.
  final Widget? extra;

  /// Касание плитки.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    final Widget body = Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(color: c.surface, borderRadius: radius, boxShadow: c.shadow1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: stretch ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: stretch ? MainAxisAlignment.spaceBetween : MainAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13)))),
              if (status != null) ...[const SizedBox(width: 6), KvDot(status: status!)],
            ],
          ),
          if (!stretch) const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, maxLines: 1, softWrap: false, style: t.numM),
              if (unit != null) ...[const SizedBox(width: 3), Text(unit!, maxLines: 1, softWrap: false, style: t.unit)],
            ],
          ),
          if (spark != null) ...[
            if (!stretch) const SizedBox(height: 8),
            SizedBox(
              height: sparkHeight,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints box) => OverflowBox(
                  minWidth: box.maxWidth + 4,
                  maxWidth: box.maxWidth + 4,
                  child: KvSparkline(data: spark!, height: sparkHeight),
                ),
              ),
            ),
          ],
          ?extra,
        ],
      ),
    );
    if (onTap == null) {
      return body;
    }
    return KvPressable(onTap: onTap, borderRadius: radius, pressedScale: 0.985, semanticLabel: label, child: body);
  }
}

/// Счётчик KPI (.tile.kpi): крупная тонкая цифра цвета статуса и подпись.
class KvKpi extends StatelessWidget {
  /// Создаёт счётчик [value] с подписью [label].
  const KvKpi({super.key, required this.value, required this.label, this.status, this.onTap, this.labelMaxLines = 1});

  /// Значение.
  final String value;

  /// Подпись.
  final String label;

  /// Строк подписи: 1 - обрезка многоточием (.tile-label), больше - перенос (.c-kpi-row в итоге осмотра).
  final int labelMaxLines;

  /// Статус - цвет цифры.
  final KvStatus? status;

  /// Касание.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    final Color color = status == null ? c.text : (status == KvStatus.info ? c.brand : c.status(status!));
    final Widget body = Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(color: c.surface, borderRadius: radius, boxShadow: c.shadow1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, maxLines: 1, style: t.numL.copyWith(height: 1.05, color: color)),
          const SizedBox(height: 4),
          Text(label, maxLines: labelMaxLines, overflow: TextOverflow.ellipsis, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13))),
        ],
      ),
    );
    if (onTap == null) {
      return body;
    }
    return KvPressable(onTap: onTap, borderRadius: radius, pressedScale: 0.985, semanticLabel: '$value $label', child: body);
  }
}

/// Компактная карточка действия для сетки в две колонки (.act-card).
class KvActionCard extends StatelessWidget {
  /// Создаёт карточку действия.
  const KvActionCard({super.key, required this.icon, required this.title, this.subtitle, this.status, required this.onTap});

  /// Значок.
  final KvIcons icon;

  /// Заголовок.
  final String title;

  /// Подзаголовок.
  final String? subtitle;

  /// Тон значка.
  final KvStatus? status;

  /// Касание.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool narrow = MediaQuery.sizeOf(context).width <= 370;
    final double ic = narrow ? 34 : 38;
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    return KvPressable(
      onTap: onTap,
      borderRadius: radius,
      pressedScale: 0.985,
      semanticLabel: title,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: EdgeInsets.all(narrow ? 10 : 12),
        decoration: BoxDecoration(color: c.surface, borderRadius: radius, boxShadow: c.shadow1),
        child: Row(
          children: [
            KvRowIcon(icon: icon, status: status, size: ic, iconSize: 20),
            SizedBox(width: narrow ? 8 : 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: t.sm.copyWith(fontWeight: FontWeight.w600, height: 1.3)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 1),
                    Text(subtitle!, style: t.label.copyWith(fontWeight: FontWeight.w400, height: 1.3)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Значок строки 40 × 40 со скруглением 12 (.row-ic): светло-синий или цвета статуса.
class KvRowIcon extends StatelessWidget {
  /// Создаёт значок строки.
  const KvRowIcon({super.key, required this.icon, this.status, this.size = 40, this.iconSize = 22, this.background});

  /// Значок.
  final KvIcons icon;

  /// Тон: ok, warn, bad, unk; null или info - фирменный синий.
  final KvStatus? status;

  /// Сторона квадрата.
  final double size;

  /// Размер значка.
  final double iconSize;

  /// Свой цвет фона.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final (Color bg, Color fg) = switch (status) {
      null || KvStatus.info => (c.tint2, c.brand),
      KvStatus.ok => (c.okBg, c.ok),
      KvStatus.warn => (c.warnBg, c.warn),
      KvStatus.bad => (c.badBg, c.bad),
      KvStatus.unk => (c.unkBg, c.unk),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: background ?? bg, borderRadius: BorderRadius.circular(KvRadius.sm)),
      child: KvIcon(icon, size: iconSize, color: fg),
    );
  }
}

/// Значение с единицей в одну строку по базовой линии: «3,1 мм/с».
class KvValueUnit extends StatelessWidget {
  /// Создаёт значение [value] с единицей [unit] стилями [valueStyle] и [unitStyle].
  const KvValueUnit({super.key, required this.value, this.unit, this.digits, required this.valueStyle, this.unitStyle, this.gap = 3});

  /// Число.
  final num value;

  /// Единица.
  final String? unit;

  /// Знаков после запятой.
  final int? digits;

  /// Стиль числа.
  final TextStyle valueStyle;

  /// Стиль единицы.
  final TextStyle? unitStyle;

  /// Промежуток между числом и единицей.
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(KvFormat.num(value, digits), style: valueStyle),
        if (unit != null) ...[SizedBox(width: gap), Text(unit!, style: unitStyle ?? context.kvText.unit)],
      ],
    );
  }
}
