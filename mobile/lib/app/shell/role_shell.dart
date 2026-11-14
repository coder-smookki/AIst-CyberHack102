import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/kv.dart';
import '../../data/providers.dart';
import '../navigation/kv_page.dart';
import 'role_tabs.dart';

/// Счётчики для точек на вкладках: ключ - [KvTabSpec.badgeKey]. Точка «Находки» горит, пока есть находки,
/// ждущие подтверждения.
final Provider<Set<String>> tabBadgesProvider = Provider<Set<String>>((Ref ref) {
  final List<Finding> pending = ref.watch(findingsProvider((status: 'new', unitId: null))).value ?? const <Finding>[];
  return {if (pending.isNotEmpty) 'findings'};
});

/// Оболочка роли: вложенный навигатор экранов с панелью вкладок и плавающая панель вкладок поверх них.
///
/// Панель стоит на месте, пока экраны внутри вкладки сменяют друг друга; экраны без панели (сканер, формы)
/// открываются поверх оболочки в корневом навигаторе.
class RoleShell extends ConsumerWidget {
  /// Создаёт оболочку роли [role] с текущим путём [location].
  const RoleShell({super.key, required this.role, required this.location, required this.child});

  /// Роль.
  final KvRole role;

  /// Текущий путь.
  final String location;

  /// Вложенный навигатор.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<KvTabSpec> tabs = kvRoleTabs[role]!;
    final List<String> segments = Uri.parse(location).pathSegments;
    final String key = segments.length > 1 ? segments[1] : tabs.first.key;
    final int active = tabs.indexWhere((KvTabSpec t) => t.key == key && !t.center);
    final Set<String> badges = ref.watch(tabBadgesProvider);
    return KvTabBarScope(
      child: Stack(
        children: [
          Positioned.fill(child: child),
          Positioned(
            left: KvSpace.gutter,
            right: KvSpace.gutter,
            bottom: KvTabBarScope.bottomOf(context),
            child: KvTabBar(
              activeIndex: active,
              items: [
                for (final KvTabSpec t in tabs)
                  KvTabBarItem(icon: t.icon, label: t.label, center: t.center, badge: t.badgeKey != null && badges.contains(t.badgeKey)),
              ],
              onTap: (int i) {
                final KvTabSpec t = tabs[i];
                if (t.center) {
                  context.push(t.path, extra: const KvNavExtra(transition: KvTransition.up));
                } else if (i == active) {
                  if (Uri.parse(location).path != t.path) {
                    context.go(t.path, extra: const KvNavExtra(transition: KvTransition.fade));
                  }
                } else {
                  context.go(t.path, extra: const KvNavExtra(transition: KvTransition.fade));
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}
