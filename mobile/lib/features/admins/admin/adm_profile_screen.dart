import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../role_scope_screen.dart';
import '../widgets/adm_widgets.dart';

/// Профиль администратора системы (adm-profile): обновления, устройства, права роли, тема и выход.
class AdmProfileScreen extends ConsumerWidget {
  /// Создаёт экран.
  const AdmProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Map<String, Person>? people = ref.watch(peopleProvider).value;
    final Person? me = people?['admin'];
    final Person? sec = people?['sec'];
    final ServerStatus? s = ref.watch(serverStatusProvider).value;
    final int devices = ref.watch(devicesProvider).value?.length ?? 0;
    return KvScreen(
      header: KvRootHeader(title: 'Профиль', subtitle: me == null ? ' ' : ty(me.shift)),
      children: [
        if (me == null) const KvSkeleton.card() else AdmProfileCard(person: me, roleLabel: 'Админ'),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.archive,
              title: 'Обновления и резерв',
              subtitle: s?.updateAvailable == null ? 'Установлена последняя версия' : 'Доступна версия ${s!.updateAvailable}',
              onTap: () => context.kvPush(AdminsPaths.eAdmMaint),
            ),
            KvRow(
              icon: KvIcons.phone,
              title: 'Устройства',
              subtitle: '$devices в сети',
              onTap: () => context.kvPush(AdminsPaths.eAdmDevices),
            ),
            KvRow(
              icon: KvIcons.key,
              title: 'Права роли',
              subtitle: 'Доступные разделы',
              onTap: () => context.kvPush(AdminsPaths.eAdmScope),
            ),
          ],
        ),
        const AdmThemeCard(),
        KvNote(
          icon: KvIcons.shield,
          text: ty('Учётными записями и ролями управляет администратор ИБ - ${sec?.name ?? 'Дмитрий Захаров'}.'),
        ),
        KvButton(
          'Выйти из учётной записи',
          kind: KvButtonKind.secondary,
          icon: KvIcons.logout,
          onPressed: () => showAdmLogout(context, ref, text: 'Для входа понадобятся почта и пароль.'),
        ),
      ],
    );
  }
}
