import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../service_common.dart';

/// Уведомления инженера (c-notif): новые и прочитанные, касание открывает задание, диагностику или карточку;
/// меню «ещё» - отметить все прочитанными и настройки уведомлений.
class NotificationsScreen extends ConsumerWidget {
  /// Создаёт экран.
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<AppNotification>> value = ref.watch(notificationsProvider('engineer'));
    final List<AppNotification> all = value.value ?? const <AppNotification>[];
    final List<AppNotification> unread = all.where((AppNotification n) => !n.read).toList();
    final List<AppNotification> read = all.where((AppNotification n) => n.read).toList();
    return KvScreen(
      header: KvHeader(
        title: 'Уведомления',
        subtitle: unread.isEmpty ? 'Нет новых' : '${unread.length} ${KvFormat.plural(unread.length, 'новое', 'новых', 'новых')}',
        status: unread.isEmpty ? null : KvStatus.info,
        onBack: () => context.kvBack(EngineerServicePaths.profile),
        onMore: () => showNotificationsMenu(context, unread.length),
      ),
      children: [
        if (!value.hasValue) const KvSkeleton.card(height: 220),
        if (unread.isNotEmpty) ...[
          const KvSectionLabel('Новые'),
          KvList(children: [for (final AppNotification n in unread) _NotificationRow(n)]),
        ],
        if (read.isNotEmpty) ...[
          const KvSectionLabel('Прочитанные'),
          KvList(children: [for (final AppNotification n in read) _NotificationRow(n)]),
        ],
      ],
    );
  }
}

/// Строка уведомления (.c-notif .row): значок вида, заголовок (новое - полужирный), текст, время и точка новизны.
class _NotificationRow extends StatelessWidget {
  const _NotificationRow(this.n);

  final AppNotification n;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return KvRow(
      icon: ServiceFormat.notificationIcon(n),
      iconStatus: ServiceFormat.notificationTone(n),
      title: n.title,
      titleWidget: Text(
        KvFormat.typo(n.title),
        style: t.bodyM.copyWith(height: 1.3, fontWeight: n.read ? FontWeight.w500 : FontWeight.w600),
      ),
      subtitle: KvFormat.typo(n.text),
      minHeight: 72,
      padding: const EdgeInsets.symmetric(horizontal: KvSpace.s4, vertical: 12),
      crossAxisAlignment: CrossAxisAlignment.start,
      chevron: false,
      trailing: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              n.time,
              style: t.caption.copyWith(color: c.text3, height: KvTextStyles.normalHeight(13)),
            ),
            if (!n.read) ...[const SizedBox(height: KvSpace.s2), KvDot(color: c.brand)],
          ],
        ),
      ),
      onTap: n.target == null || !n.target!.startsWith('/') ? null : () => context.kvPush(n.target!),
    );
  }
}

/// Меню уведомлений (лист c-notif-menu): отметить все прочитанными и настройки уведомлений.
Future<void> showNotificationsMenu(BuildContext context, int unread) {
  final BuildContext screen = context;
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => Consumer(
      builder: (BuildContext sheet, WidgetRef ref, Widget? child) => KvSheet(
        title: 'Уведомления',
        children: [
          KvList(
            children: [
              KvRow(
                icon: KvIcons.checkCircle,
                title: 'Отметить все прочитанными',
                onTap: () async {
                  Navigator.of(sheet).pop();
                  await ref.read(workflowRepositoryProvider).markNotificationsRead('engineer');
                  if (screen.mounted) {
                    showKvToast(
                      screen,
                      kind: KvToastKind.ok,
                      title: 'Готово',
                      text: unread == 0
                          ? 'Новых уведомлений нет'
                          : '$unread ${KvFormat.plural(unread, 'уведомление отмечено', 'уведомления отмечены', 'уведомлений отмечены')} прочитанными',
                    );
                  }
                },
              ),
              KvRow(
                icon: KvIcons.settings,
                title: 'Настройки уведомлений',
                subtitle: 'Вибрация при находке, звук',
                onTap: () {
                  Navigator.of(sheet).pop();
                  screen.kvPush(EngineerServicePaths.cSettings);
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
