import 'package:flutter/widgets.dart';

import '../theme/kv_theme.dart';
import 'kv_pressable.dart';

/// Точка статуса 8 px (.dot).
class KvDot extends StatelessWidget {
  /// Создаёт точку статуса [status] или произвольного цвета [color].
  const KvDot({super.key, this.status = KvStatus.unk, this.color, this.size = 8});

  /// Статус.
  final KvStatus status;

  /// Цвет вместо цвета статуса.
  final Color? color;

  /// Диаметр.
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(decoration: BoxDecoration(color: color ?? context.kv.status(status), shape: BoxShape.circle)),
    );
  }
}

/// Статусный чип высотой 28 (.chip): «Внимание», «Норма», «На ремонте».
class KvChip extends StatelessWidget {
  /// Создаёт чип с текстом [label] и статусом [status]; без статуса - серый.
  const KvChip(this.label, {super.key, this.status, this.dot = true});

  /// Текст.
  final String label;

  /// Статус; null - нейтральный серый чип.
  final KvStatus? status;

  /// Показывать точку слева.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Color bg = status == null ? c.unkBg : c.statusBg(status!);
    final Color fg = status == null ? c.text2 : c.statusText(status!);
    final Color dotColor = status == null ? c.unk : c.status(status!);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(KvRadius.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[KvDot(color: dotColor, size: 7), const SizedBox(width: 6)],
          Text(label, maxLines: 1, softWrap: false, style: context.kvText.caption.copyWith(fontWeight: FontWeight.w500, color: fg, height: 1.2)),
        ],
      ),
    );
  }
}

/// Точка статуса с подписью (.stat): «● Внимание · Wilo IL 65/160».
class KvStatusDot extends StatelessWidget {
  /// Создаёт подпись [text] с точкой статуса [status].
  const KvStatusDot(this.text, {super.key, this.status = KvStatus.unk});

  /// Текст.
  final String text;

  /// Статус точки.
  final KvStatus status;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        KvDot(status: status),
        const SizedBox(width: 6),
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.kvText.caption.copyWith(height: KvTextStyles.normalHeight(13)))),
      ],
    );
  }
}

/// Счётчик (.badge): красный кружок с числом; без числа - точка с белой обводкой.
class KvBadge extends StatelessWidget {
  /// Создаёт счётчик [count]; null - точка.
  const KvBadge(this.count, {super.key, this.info = false});

  /// Число или текст; null - точка без текста.
  final String? count;

  /// Синий вместо красного.
  final bool info;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Color bg = info ? c.brand : c.bad;
    if (count == null) {
      return Container(
        width: 13,
        height: 13,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle, border: Border.all(color: c.surface, width: 2)),
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(9)),
      child: Text(
        count!,
        style: const TextStyle(fontFamily: KvTextStyles.kvFontFamily, fontSize: 11, fontWeight: FontWeight.w600, height: 1, color: Color(0xFFFFFFFF)),
      ),
    );
  }
}

/// Пункт фильтра для [KvFilterChips].
@immutable
class KvFilterItem {
  /// Создаёт пункт с подписью [label] и необязательным счётчиком [count].
  const KvFilterItem(this.label, {this.count});

  /// Подпись.
  final String label;

  /// Счётчик справа от подписи.
  final String? count;
}

/// Фильтры-чипы (.fchips): область 44 px, видимая таблетка 36 px, выбранный - синий.
///
/// Один выбранный ([selected] - индекс) или несколько ([multi] и [selectedSet]).
class KvFilterChips extends StatelessWidget {
  /// Создаёт группу с выбором одного пункта.
  const KvFilterChips({super.key, required this.items, required this.selected, required this.onSelected, this.spacing = KvSpace.s2})
      : multi = false,
        selectedSet = const <int>{};

  /// Создаёт группу с выбором нескольких пунктов.
  const KvFilterChips.multi({super.key, required this.items, required this.selectedSet, required this.onSelected, this.spacing = KvSpace.s2})
      : multi = true,
        selected = -1;

  /// Промежуток между чипами по горизонтали и между рядами при переносе (gap у .fchips).
  final double spacing;

  /// Пункты.
  final List<KvFilterItem> items;

  /// Выбранный пункт (одиночный выбор).
  final int selected;

  /// Выбранные пункты (множественный выбор).
  final Set<int> selectedSet;

  /// Множественный выбор.
  final bool multi;

  /// Касание пункта.
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: [
        for (int i = 0; i < items.length; i++)
          _FilterChip(
            item: items[i],
            on: multi ? selectedSet.contains(i) : i == selected,
            onTap: () => onSelected(i),
            colors: c,
          ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.item, required this.on, required this.onTap, required this.colors});

  final KvFilterItem item;
  final bool on;
  final VoidCallback onTap;
  final KvColors colors;

  @override
  Widget build(BuildContext context) {
    final TextStyle base = context.kvText.sm.copyWith(fontWeight: FontWeight.w500, height: 1.2);
    final Color fg = on ? colors.onBrand : colors.text2;
    return KvPressable(
      onTap: onTap,
      immediate: true,
      highlight: false,
      semanticLabel: item.label,
      child: SizedBox(
        height: KvLayout.touch,
        child: AnimatedContainer(
          duration: KvMotion.std,
          curve: KvMotion.ease,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: on ? colors.btnPrimary : colors.surface,
            borderRadius: BorderRadius.circular(KvRadius.pill),
            boxShadow: colors.shadow1,
          ),
          child: AnimatedDefaultTextStyle(
            duration: KvMotion.std,
            style: base.copyWith(color: fg),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.label),
                if (item.count != null) ...[
                  const SizedBox(width: 6),
                  Opacity(opacity: 0.75, child: Text(item.count!, style: TextStyle(fontSize: 12, color: fg))),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
