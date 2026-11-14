import 'package:flutter/foundation.dart';

import '../../core/icons/kv_icon.dart';
import '../../data/models/people.dart';

/// Вкладка роли (KV.TABS в js/core.js): ключ совпадает со вторым сегментом пути экрана: /engineer/objects/...
@immutable
class KvTabSpec {
  /// Создаёт вкладку.
  const KvTabSpec({required this.key, required this.icon, required this.label, required this.path, this.center = false, this.badgeKey});

  /// Ключ вкладки.
  final String key;

  /// Значок.
  final KvIcons icon;

  /// Подпись для диктора.
  final String label;

  /// Путь корневого экрана вкладки или экрана, который поднимается снизу (центральная кнопка).
  final String path;

  /// Центральная кнопка: экран поднимается снизу поверх оболочки.
  final bool center;

  /// Ключ счётчика для точки на вкладке ([tabBadgesProvider]).
  final String? badgeKey;
}

/// Вкладки каждой роли.
const Map<KvRole, List<KvTabSpec>> kvRoleTabs = {
  KvRole.engineer: [
    KvTabSpec(key: 'objects', icon: KvIcons.grid, label: 'Объекты', path: '/engineer/objects'),
    KvTabSpec(key: 'history', icon: KvIcons.clock, label: 'История', path: '/engineer/history'),
    KvTabSpec(key: 'scan', icon: KvIcons.scan, label: 'Сканер', path: '/engineer/scanner', center: true),
    KvTabSpec(key: 'assistant', icon: KvIcons.chat, label: 'Ассистент', path: '/engineer/assistant'),
    KvTabSpec(key: 'profile', icon: KvIcons.user, label: 'Профиль', path: '/engineer/profile'),
  ],
  KvRole.master: [
    KvTabSpec(key: 'shift', icon: KvIcons.clipboard, label: 'Смена', path: '/master/shift'),
    KvTabSpec(key: 'findings', icon: KvIcons.alertCircle, label: 'Находки', path: '/master/findings', badgeKey: 'findings'),
    KvTabSpec(key: 'scan', icon: KvIcons.scan, label: 'Сканер', path: '/engineer/scanner', center: true),
    KvTabSpec(key: 'plan', icon: KvIcons.calendar, label: 'План ТО', path: '/master/plan'),
    KvTabSpec(key: 'profile', icon: KvIcons.user, label: 'Профиль', path: '/master/profile'),
  ],
  KvRole.operator: [
    KvTabSpec(key: 'objects', icon: KvIcons.grid, label: 'Объекты', path: '/operator/objects'),
    KvTabSpec(key: 'history', icon: KvIcons.clock, label: 'История', path: '/operator/history'),
    KvTabSpec(key: 'report', icon: KvIcons.megaphone, label: 'Сообщить', path: '/operator/op-report', center: true),
    KvTabSpec(key: 'assistant', icon: KvIcons.chat, label: 'Ассистент', path: '/operator/assistant'),
    KvTabSpec(key: 'profile', icon: KvIcons.user, label: 'Профиль', path: '/operator/profile'),
  ],
  KvRole.admin: [
    KvTabSpec(key: 'system', icon: KvIcons.server, label: 'Система', path: '/admin/system'),
    KvTabSpec(key: 'sources', icon: KvIcons.plug, label: 'Источники', path: '/admin/sources'),
    KvTabSpec(key: 'models', icon: KvIcons.cpu, label: 'Модели', path: '/admin/models'),
    KvTabSpec(key: 'log', icon: KvIcons.list, label: 'Журнал', path: '/admin/log'),
    KvTabSpec(key: 'profile', icon: KvIcons.user, label: 'Профиль', path: '/admin/profile'),
  ],
  KvRole.sec: [
    KvTabSpec(key: 'users', icon: KvIcons.users, label: 'Пользователи', path: '/sec/users'),
    KvTabSpec(key: 'roles', icon: KvIcons.key, label: 'Роли', path: '/sec/roles'),
    KvTabSpec(key: 'log', icon: KvIcons.list, label: 'Журнал', path: '/sec/log'),
    KvTabSpec(key: 'policy', icon: KvIcons.shield, label: 'Политика', path: '/sec/policy'),
    KvTabSpec(key: 'profile', icon: KvIcons.user, label: 'Профиль', path: '/sec/profile'),
  ],
  KvRole.senior: [
    KvTabSpec(key: 'objects', icon: KvIcons.grid, label: 'Объекты', path: '/senior/objects'),
    KvTabSpec(key: 'findings', icon: KvIcons.alertCircle, label: 'Находки', path: '/senior/findings', badgeKey: 'findings'),
    KvTabSpec(key: 'scan', icon: KvIcons.scan, label: 'Сканер', path: '/engineer/scanner', center: true),
    KvTabSpec(key: 'assistant', icon: KvIcons.chat, label: 'Ассистент', path: '/senior/assistant'),
    KvTabSpec(key: 'profile', icon: KvIcons.user, label: 'Профиль', path: '/senior/profile'),
  ],
};

/// Префикс путей роли: /engineer, /master, /operator, /admin, /sec, /senior.
String kvRolePrefix(KvRole role) => '/${role.name}';

/// Домашний экран роли - первая вкладка.
String kvRoleHome(KvRole role) => kvRoleTabs[role]!.first.path;
