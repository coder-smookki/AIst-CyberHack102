import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../master/master_profile_screen.dart';
import '../widgets/mo_blocks.dart';
import '../widgets/mo_common.dart';

/// Профиль оператора: карточка сотрудника, уведомления, права роли, настройки и выход.
class OpProfileScreen extends ConsumerWidget {
  /// Создаёт экран.
  const OpProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Site? site = ref.watch(siteProvider).value;
    final Person? me = moMe(ref, 'operator');
    final List<AppNotification> notes = ref.watch(notificationsProvider('operator')).value ?? const <AppNotification>[];
    return KvScreen(
      header: KvRootHeader(title: 'Профиль', subtitle: site?.name ?? ' '),
      children: [
        if (me == null)
          const KvSkeleton.card(height: 230)
        else
          MoProfileCard(name: me.name, title: me.title, email: me.email, role: me.roleLabel, shift: me.shift),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.bell,
              title: 'Уведомления',
              subtitle: '${notes.length} за смену',
              onTap: () => context.kvPush(MasterOperatorPaths.dOpNotif),
            ),
            KvRow(icon: KvIcons.key, title: 'Мои права', subtitle: 'Просмотр и сообщения', onTap: () => showOpAccessSheet(context)),
            KvRow(
              icon: KvIcons.settings,
              title: 'Настройки',
              subtitle: 'Тема, уведомления, биометрия',
              onTap: () => showMoSettingsSheet(context, notifications: 'Статусы агрегатов, ответы мастера'),
            ),
          ],
        ),
        KvButton(
          'Выйти из учётной записи',
          kind: KvButtonKind.secondary,
          icon: KvIcons.logout,
          onPressed: () => showMoLogoutDialog(context),
        ),
      ],
    );
  }
}

/// Лист прав роли «Оператор»: что доступно и что закрыто, кто назначает права.
Future<void> showOpAccessSheet(BuildContext context) {
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) {
      KvRow allowed(String title, String sub) =>
          KvRow(icon: KvIcons.checkCircle, iconStatus: KvStatus.ok, title: title, subtitle: sub, chevron: false);
      KvRow locked(String title) =>
          KvRow(icon: KvIcons.lock, iconStatus: KvStatus.unk, title: title, subtitle: 'Доступно инженеру и мастеру', chevron: false);
      return KvSheet(
        title: 'Роль: Оператор',
        actions: [KvButton('Понятно', onPressed: () => Navigator.of(sheet).pop())],
        children: [
          KvList(
            children: [
              allowed('Состояние и показания', 'Все агрегаты станции'),
              allowed('Сообщение о неисправности', 'С кадром камеры'),
              allowed('Ассистент', 'Вопросы по агрегатам'),
              locked('Осмотр со сканером'),
              locked('Находки и режимы агрегатов'),
            ],
          ),
          const _AccessCaption(),
        ],
      );
    },
  );
}

/// Подпись о том, кто назначает права: администратор ИБ площадки.
class _AccessCaption extends ConsumerWidget {
  const _AccessCaption();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Person? sec = (ref.watch(peopleProvider).value ?? const <String, Person>{})['sec'];
    return Text(
      'Права назначает администратор ИБ · ${sec?.name ?? 'Дмитрий Захаров'}',
      style: context.kvText.caption.copyWith(height: 1.35),
    );
  }
}
