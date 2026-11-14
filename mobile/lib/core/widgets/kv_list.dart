import 'package:flutter/widgets.dart';

import '../icons/kv_icon.dart';
import '../theme/kv_theme.dart';
import 'kv_card.dart';
import 'kv_misc.dart';
import 'kv_pressable.dart';

/// Белый скруглённый список строк с разделителями (.list): разделитель начинается после значка строки.
class KvList extends StatelessWidget {
  /// Создаёт список из строк [children]; [noIcons] - разделители от левого поля.
  const KvList({super.key, required this.children, this.noIcons = false, this.dividerIndent});

  /// Строки, обычно [KvRow].
  final List<Widget> children;

  /// Строки без значков: разделитель с отступом 16.
  final bool noIcons;

  /// Свой отступ разделителя слева.
  final double? dividerIndent;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final bool inSheet = KvSheetScope.maybeOf(context) != null;
    final double indent = dividerIndent ?? (noIcons ? KvSpace.s4 : 68);
    final Color line = inSheet ? c.border.withValues(alpha: 0.6 * c.border.a) : c.divider;
    final List<Widget> rows = [
      for (int i = 0; i < children.length; i++)
        i == 0
            ? children[i]
            : Stack(
                children: [
                  children[i],
                  Positioned(
                    left: indent,
                    right: 0,
                    top: 0,
                    height: 1,
                    child: IgnorePointer(child: ColoredBox(color: line)),
                  ),
                ],
              ),
    ];
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: inSheet ? c.surface2 : c.surface,
        borderRadius: BorderRadius.circular(KvRadius.card),
        boxShadow: inSheet ? null : c.shadow1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: rows),
    );
  }
}

/// Отметка «внутри листа снизу»: списки в листе серые и без тени (.sheet .list прототипа).
class KvSheetScope extends InheritedWidget {
  /// Создаёт отметку.
  const KvSheetScope({super.key, required super.child});

  /// Ближайшая отметка или null.
  static KvSheetScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<KvSheetScope>();

  @override
  bool updateShouldNotify(KvSheetScope oldWidget) => false;
}

/// Строка списка (.row): значок или аватар, заголовок и подпись, значение и шеврон справа; высота от 60.
///
/// С [onTap] строка нажимается и по умолчанию показывает шеврон; [chevron] задаёт его явно.
class KvRow extends StatelessWidget {
  /// Создаёт строку.
  const KvRow({
    super.key,
    required this.title,
    this.titleWidget,
    this.subtitle,
    this.subtitleWidget,
    this.icon,
    this.iconStatus,
    this.avatar,
    this.leading,
    this.value,
    this.trailing,
    this.chevron,
    this.onTap,
    this.danger = false,
    this.minHeight = 60,
    this.padding = const EdgeInsets.symmetric(horizontal: KvSpace.s4, vertical: 10),
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  /// Заголовок.
  final String title;

  /// Заголовок со своим оформлением вместо [title].
  final Widget? titleWidget;

  /// Подпись под заголовком.
  final String? subtitle;

  /// Подпись со своим оформлением вместо [subtitle].
  final Widget? subtitleWidget;

  /// Значок слева в квадрате 40.
  final KvIcons? icon;

  /// Тон значка.
  final KvStatus? iconStatus;

  /// Имя или инициалы для аватара слева.
  final String? avatar;

  /// Свой виджет слева.
  final Widget? leading;

  /// Значение справа: «78 °C».
  final String? value;

  /// Виджет справа (чип, переключатель).
  final Widget? trailing;

  /// Показывать шеврон; по умолчанию - когда строка нажимается.
  final bool? chevron;

  /// Касание строки.
  final VoidCallback? onTap;

  /// Опасное действие: заголовок и значок красные.
  final bool danger;

  /// Минимальная высота.
  final double minHeight;

  /// Поля строки: по умолчанию 10 по вертикали и 16 по бокам; строки настроек - 4 по вертикали.
  final EdgeInsets padding;

  /// Выравнивание значка, текста и правой части по вертикали: по центру или по верху (уведомления).
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final Widget? lead =
        leading ??
        (avatar != null
            ? KvAvatar(avatar!)
            : icon != null
            ? KvRowIcon(icon: icon!, status: danger ? KvStatus.bad : iconStatus)
            : null);
    final bool showChevron = chevron ?? onTap != null;
    final Widget body = Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: padding,
      child: Row(
        crossAxisAlignment: crossAxisAlignment,
        children: [
          if (lead != null) ...[lead, const SizedBox(width: KvSpace.s3)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                titleWidget ?? Text(title, style: t.bodyM.copyWith(height: 1.3, color: danger ? c.bad : c.text)),
                if (subtitleWidget != null || subtitle != null) ...[
                  const SizedBox(height: 2),
                  subtitleWidget ?? Text(subtitle!, style: t.caption.copyWith(height: 1.35)),
                ],
              ],
            ),
          ),
          if (value != null || trailing != null || showChevron) ...[
            const SizedBox(width: KvSpace.s3),
            DefaultTextStyle.merge(
              style: t.caption.copyWith(color: c.text3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (value != null) Text(value!, style: t.bodyM.copyWith(height: KvTextStyles.normalHeight(15))),
                  if (value != null && (trailing != null || showChevron)) const SizedBox(width: 6),
                  ?trailing,
                  if (trailing != null && showChevron) const SizedBox(width: 6),
                  if (showChevron) KvIcon(KvIcons.chevronRight, size: 20, color: c.text3),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) {
      return body;
    }
    return KvPressable(onTap: onTap, pressedScale: 0.985, semanticLabel: title, child: body);
  }
}
