import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../app/routes/entry_routes.dart';
import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../profile/profile_screen.dart';
import '../service_common.dart';

/// Профиль старшего инженера (f-d-senior-profile): сотрудник с новой ролью, права роли с отметкой новых,
/// кто и когда изменил роль, история осмотров, настройки и выход.
class SeniorProfileScreen extends ConsumerWidget {
  /// Создаёт экран.
  const SeniorProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppUser? user = ref.watch(sessionProvider.select((AuthSession? s) => s?.user));
    final Site? site = ref.watch(siteProvider).value;
    final Map<String, Person> people = ref.watch(peopleProvider).value ?? const <String, Person>{};
    final List<Permission> catalog = ref.watch(permissionsProvider).value ?? const <Permission>[];
    final List<Role> roles = ref.watch(rolesProvider).value ?? const <Role>[];
    final ({String when, String by})? changed = ref.watch(roleChangeProvider).value;
    final Person? person = user == null ? null : people.values.where((Person p) => p.id == user.id).firstOrNull;
    final List<String> base = roles.where((Role r) => r.id == 'engineer').firstOrNull?.permissions ?? const <String>[];
    final List<String> perms = user?.permissions ?? const <String>[];
    String label(String key) => catalog.where((Permission p) => p.key == key).firstOrNull?.label ?? key;
    return KvScreen(
      header: KvRootHeader(title: 'Профиль', subtitle: site?.name ?? ' '),
      children: [
        if (user != null) PersonCard(name: user.name, line: user.email, role: user.roleTitle, shift: person?.shift ?? user.shift),
        KvCard(
          title: 'Права роли · ${perms.length}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final String key in perms) _Permission(label: label(key), added: base.isNotEmpty && !base.contains(key)),
              if (changed != null) ...[
                const SizedBox(height: KvSpace.s2),
                Text(KvFormat.typo('Изменено ${changed.when} · ${changed.by}'), style: context.kvText.caption),
              ],
            ],
          ),
        ),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.info,
              title: 'Как пользоваться',
              subtitle: 'Кнопки, экраны и порядок работы',
              onTap: () => context.kvPush(EntryPaths.guide),
            ),
            KvRow(
              icon: KvIcons.history,
              title: 'История осмотров',
              subtitle: 'Все агрегаты',
              onTap: () => context.kvPush(EngineerServicePaths.seniorHistory),
            ),
            KvRow(
              icon: KvIcons.settings,
              title: 'Настройки',
              subtitle: 'Тема, сканер, вход',
              onTap: () => context.kvPush(EngineerServicePaths.cSettings),
            ),
          ],
        ),
        KvButton(
          'Выйти из учётной записи',
          kind: KvButtonKind.secondary,
          icon: KvIcons.logout,
          onPressed: () => showLogoutDialog(context, senior: true),
        ),
      ],
    );
  }
}

/// Право роли (.f-perm): зелёная галочка или синий плюс с чипом «Новое» для прав, добавленных к роли инженера.
class _Permission extends StatelessWidget {
  const _Permission({required this.label, required this.added});

  final String label;
  final bool added;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 36),
      child: Row(
        children: [
          KvIcon(added ? KvIcons.plus : KvIcons.check, size: 18, color: added ? c.brand : c.ok),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: t.sm.copyWith(height: 1.3, color: added ? c.brand : c.text, fontWeight: added ? FontWeight.w600 : FontWeight.w400),
            ),
          ),
          if (added) ...[const SizedBox(width: 10), const KvChip('Новое', status: KvStatus.info, dot: false)],
        ],
      ),
    );
  }
}
