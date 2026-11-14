import 'package:flutter/widgets.dart';

import '../icons/kv_icon.dart';
import '../theme/kv_theme.dart';
import 'kv_chip.dart';
import 'kv_pressable.dart';

/// Пункт плавающей панели вкладок.
@immutable
class KvTabBarItem {
  /// Создаёт пункт.
  const KvTabBarItem({required this.icon, required this.label, this.center = false, this.badge = false});

  /// Значок.
  final KvIcons icon;

  /// Подпись для диктора.
  final String label;

  /// Центральная синяя кнопка (сканер, «Сообщить»).
  final bool center;

  /// Красная точка, пока вкладка не выбрана.
  final bool badge;
}

/// Плавающая панель вкладок роли (.tabbar): таблетка 68 px со скруглением 34, активная вкладка в светло-синем круге,
/// центральная кнопка 56 px. Касание активной вкладки слегка «пружинит».
class KvTabBar extends StatelessWidget {
  /// Создаёт панель.
  const KvTabBar({super.key, required this.items, required this.activeIndex, required this.onTap});

  /// Пункты.
  final List<KvTabBarItem> items;

  /// Выбранный пункт или -1.
  final int activeIndex;

  /// Касание пункта.
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return Container(
      height: KvLayout.tabBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.tabBar,
        borderRadius: BorderRadius.circular(34),
        boxShadow: c.shadowTab,
        border: c.tabBarBorder == null ? null : Border.all(color: c.tabBarBorder!),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (int i = 0; i < items.length; i++) _TabItem(item: items[i], active: i == activeIndex, onTap: () => onTap(i), colors: c),
        ],
      ),
    );
  }
}

class _TabItem extends StatefulWidget {
  const _TabItem({required this.item, required this.active, required this.onTap, required this.colors});

  final KvTabBarItem item;
  final bool active;
  final VoidCallback onTap;
  final KvColors colors;

  @override
  State<_TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<_TabItem> with SingleTickerProviderStateMixin {
  late final AnimationController _bounce = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem<double>(tween: Tween<double>(begin: 1, end: 0.9), weight: 1),
    TweenSequenceItem<double>(tween: Tween<double>(begin: 0.9, end: 1), weight: 1),
  ]).animate(CurvedAnimation(parent: _bounce, curve: KvMotion.ease));

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  void _tap() {
    if (widget.active && !widget.item.center && !context.kvReduceMotion) {
      _bounce.forward(from: 0);
    }
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = widget.colors;
    final bool center = widget.item.center;
    final double d = center ? 56 : 52;
    final Color bg = center ? c.btnPrimary : (widget.active ? c.tint : const Color(0x00000000));
    final Color fg = center ? c.onBrand : (widget.active ? c.brand : c.text2);
    return KvPressable(
      onTap: _tap,
      immediate: widget.active,
      shape: BoxShape.circle,
      semanticLabel: widget.item.label,
      child: ScaleTransition(
        scale: _scale,
        child: AnimatedContainer(
          duration: KvMotion.std,
          curve: KvMotion.ease,
          width: d,
          height: d,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            boxShadow: center ? [kvCssShadow(0, 6, 16, const Color(0x52135AA6))] : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              KvIcon(widget.item.icon, size: center ? 26 : 24, color: fg),
              if (widget.item.badge && !widget.active) const Positioned(top: 9, right: 9, child: KvBadge(null)),
            ],
          ),
        ),
      ),
    );
  }
}
