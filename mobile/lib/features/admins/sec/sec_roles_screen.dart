import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Роли и права (sec-roles): системные и свои роли с числом сотрудников и прав.
class SecRolesScreen extends ConsumerWidget {
  /// Создаёт экран.
  const SecRolesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Role>> async = ref.watch(rolesProvider);
    final List<Role> roles = async.value ?? const <Role>[];
    final List<Role> system = roles.where((Role r) => r.system).toList();
    final List<Role> own = roles.where((Role r) => !r.system).toList();
    Widget row(Role r) => KvRow(
      icon: admRoleIcon(r.id),
      iconStatus: r.system ? null : KvStatus.ok,
      title: r.name,
      subtitle: '${admUsersWord(r.users)} · ${admRights(r.permissions.length)}',
      trailing: r.system ? KvIcon(KvIcons.lock, size: 18, color: context.kv.text3) : null,
      onTap: () => context.kvPush(AdminsPaths.role(r.id)),
    );
    return KvScreen(
      header: KvRootHeader(
        title: 'Роли и права',
        subtitle: async.hasValue
            ? '${system.length} ${KvFormat.plural(system.length, 'системная', 'системных', 'системных')} · ${own.length} ${KvFormat.plural(own.length, 'своя', 'свои', 'своих')}'
            : ' ',
      ),
      foot: KvButton('Создать роль', icon: KvIcons.plus, onPressed: () => context.kvPush(AdminsPaths.eRoleNew)),
      children: [
        const KvSectionLabel('Системные'),
        if (!async.hasValue) const KvSkeleton.card(height: 300) else KvList(children: [for (final Role r in system) row(r)]),
        const KvSectionLabel('Свои роли'),
        if (own.isEmpty)
          KvList(
            children: [
              KvRow(
                icon: KvIcons.plus,
                iconStatus: KvStatus.unk,
                title: 'Своих ролей пока нет',
                subtitle: 'Создайте роль на основе системной',
                onTap: () => context.kvPush(AdminsPaths.eRoleNew),
              ),
            ],
          )
        else
          KvList(children: [for (final Role r in own) row(r)]),
        KvNote(
          icon: KvIcons.info,
          text: ty('Системные роли нельзя удалить, их права можно изменить. Свою роль можно создать на основе любой системной.'),
        ),
      ],
    );
  }
}
