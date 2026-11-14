import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../role_scope_screen.dart';
import '../widgets/adm_widgets.dart';

/// Профиль администратора ИБ (sec-profile): активные сеансы, права роли, тема и выход.
class SecProfileScreen extends ConsumerWidget {
  /// Создаёт экран.
  const SecProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Person? me = ref.watch(peopleProvider.select((AsyncValue<Map<String, Person>> a) => a.value?['sec']));
    final int? sessions = ref.watch(sessionsProvider(null).select((AsyncValue<List<UserSession>> a) => a.value?.length));
    return KvScreen(
      header: KvRootHeader(title: 'Профиль', subtitle: me == null ? ' ' : ty(me.shift)),
      children: [
        if (me == null) const KvSkeleton.card() else AdmProfileCard(person: me, roleLabel: 'Админ ИБ'),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.phone,
              title: 'Активные сеансы',
              subtitle: 'Все сотрудники',
              value: sessions == null ? null : '$sessions',
              onTap: () => context.kvPush(AdminsPaths.eSecSessions),
            ),
            KvRow(
              icon: KvIcons.key,
              title: 'Права роли',
              subtitle: 'Доступные разделы',
              onTap: () => context.kvPush(AdminsPaths.eSecScope),
            ),
          ],
        ),
        const AdmThemeCard(),
        KvNote(
          icon: KvIcons.shield,
          text: 'Оборудование, осмотры и показания этой роли недоступны.',
          onTap: () => context.kvPush(AdminsPaths.eSecScope),
        ),
        KvButton(
          'Выйти из учётной записи',
          kind: KvButtonKind.secondary,
          icon: KvIcons.logout,
          onPressed: () => showAdmLogout(context, ref, text: 'Для входа понадобятся почта, пароль и второй фактор.'),
        ),
      ],
    );
  }
}
