import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/navigation/kv_page.dart';
import '../../../app/routes/engineer_service_routes.dart';
import '../../../app/routes/entry_routes.dart';
import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../service_common.dart';

/// Профиль инженера (profile): сотрудник и роль, сервер цеха и синхронизация, уведомления, настройки,
/// повтор знакомства и выход из учётной записи.
class ProfileScreen extends ConsumerWidget {
  /// Создаёт экран.
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppUser? user = ref.watch(sessionProvider.select((AuthSession? s) => s?.user));
    final Site? site = ref.watch(siteProvider).value;
    final int? ping = ref.watch(serverPingProvider).value;
    final int unread = ref.watch(unreadNotificationsProvider);
    final String now = KvFormat.time(ref.watch(clockProvider).now());
    return KvScreen(
      header: KvRootHeader(title: 'Профиль', subtitle: site?.name ?? ' '),
      children: [
        if (user != null) PersonCard(name: user.name, line: user.title, role: user.roleTitle, shift: user.shift),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.info,
              title: 'Как пользоваться',
              subtitle: 'Кнопки, экраны и порядок работы',
              onTap: () => context.kvPush(EntryPaths.guide),
            ),
            KvRow(
              icon: KvIcons.server,
              iconStatus: KvStatus.ok,
              title: 'Сервер цеха',
              subtitle: KvFormat.typo('${site?.server ?? ''} · отклик ${ping ?? '-'} мс'),
              trailing: const KvChip('На связи', status: KvStatus.ok),
              chevron: false,
              onTap: () => showServerSheet(context),
            ),
            KvRow(
              icon: KvIcons.sync,
              title: 'Синхронизация',
              subtitle: 'Всё передано · $now',
              onTap: () => context.kvPush(EngineerServicePaths.cQueueOk),
            ),
          ],
        ),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.bell,
              title: 'Уведомления',
              trailing: unread == 0 ? null : KvBadge('$unread', info: true),
              onTap: () => context.kvPush(EngineerServicePaths.cNotif),
            ),
            KvRow(
              icon: KvIcons.settings,
              title: 'Настройки',
              subtitle: 'Тема, сканер, вход',
              onTap: () => context.kvPush(EngineerServicePaths.cSettings),
            ),
            KvRow(icon: KvIcons.sparkle, title: 'Показать знакомство снова', onTap: () => context.kvUp(EntryPaths.aOnb1)),
          ],
        ),
        KvButton('Выйти из учётной записи', kind: KvButtonKind.secondary, icon: KvIcons.logout, onPressed: () => showLogoutDialog(context)),
        const VersionLine('КСТ Визор $kvAppVersion · команда AIst'),
      ],
    );
  }
}

/// Карточка сотрудника (.c-person): аватар 64, имя, должность или почта, чип роли и смена.
class PersonCard extends StatelessWidget {
  /// Создаёт карточку.
  const PersonCard({super.key, required this.name, required this.line, required this.role, required this.shift});

  /// Имя и фамилия.
  final String name;

  /// Вторая строка: должность или почта.
  final String line;

  /// Название роли для чипа.
  final String role;

  /// Смена.
  final String shift;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    return KvCard(
      child: Row(
        children: [
          KvAvatar(name, size: KvAvatarSize.large),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name, style: t.h2),
                const SizedBox(height: 2),
                Text(KvFormat.typo(line), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.caption),
                const SizedBox(height: 2 + 6),
                Wrap(
                  spacing: KvSpace.s2,
                  runSpacing: KvSpace.s2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    KvChip(role, status: KvStatus.info, dot: false),
                    Text(KvFormat.typo(shift), style: t.label.copyWith(height: 1.33)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка версии внизу профиля и настроек (.c-ver).
class VersionLine extends StatelessWidget {
  /// Создаёт строку [text].
  const VersionLine(this.text, {super.key});

  /// Текст.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        KvFormat.typo(text),
        textAlign: TextAlign.center,
        style: context.kvText.micro.copyWith(fontWeight: FontWeight.w400, height: KvTextStyles.normalHeight(11)),
      ),
    );
  }
}

/// Лист «Сервер цеха» (c-server): связь и отклик, адрес, сеть, версия, время синхронизации и проверка связи.
Future<void> showServerSheet(BuildContext context) {
  final BuildContext screen = context;
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => Consumer(
      builder: (BuildContext sheet, WidgetRef ref, Widget? child) {
        final KvColors c = sheet.kv;
        final KvTextStyles t = sheet.kvText;
        final Site? site = ref.watch(siteProvider).value;
        final ServerStatus? s = ref.watch(serverStatusProvider).value;
        final int? ping = ref.watch(serverPingProvider).value;
        final String now = KvFormat.time(ref.watch(clockProvider).now());
        return KvSheet(
          title: 'Сервер цеха',
          actions: [
            KvButton(
              'Проверить связь',
              kind: KvButtonKind.tonal,
              icon: KvIcons.refresh,
              wait: true,
              onPressed: () async {
                final int ms = await ref.read(siteRepositoryProvider).ping();
                if (screen.mounted) {
                  showKvToast(
                    screen,
                    kind: KvToastKind.ok,
                    icon: KvIcons.wifi,
                    title: 'Связь в норме',
                    text: KvFormat.typo('${site?.server ?? ''} · отклик $ms мс'),
                  );
                }
              },
            ),
          ],
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const KvRowIcon(icon: KvIcons.wifi, status: KvStatus.ok),
                const SizedBox(width: KvSpace.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        KvFormat.typo('На связи · отклик ${ping ?? '-'} мс'),
                        style: t.body.copyWith(fontWeight: FontWeight.w600, color: c.text, height: KvTextStyles.normalHeight(15)),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Телефон работает без интернета: данные идут только на сервер цеха по Wi-Fi.',
                        style: t.caption.copyWith(height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            KvKeyValues([
              ('Сервер', site?.server ?? ''),
              ('Адрес', s?.ip ?? ''),
              ('Сеть Wi-Fi', s?.wifi ?? site?.wifi ?? ''),
              ('Версия', s?.version ?? ''),
              ('Синхронизация', 'сегодня, $now'),
            ]),
          ],
        );
      },
    ),
  );
}

/// Диалог выхода (c-logout для инженера, f-d-logout для старшего инженера): после подтверждения сеанс
/// закрывается и открывается вход.
Future<void> showLogoutDialog(BuildContext context, {bool senior = false}) {
  return showKvDialog<void>(
    context,
    builder: (BuildContext dialog) =>
        Consumer(builder: (BuildContext dialog, WidgetRef ref, Widget? child) => _LogoutDialog(senior: senior)),
  );
}

class _LogoutDialog extends ConsumerStatefulWidget {
  const _LogoutDialog({required this.senior});

  final bool senior;

  @override
  ConsumerState<_LogoutDialog> createState() => _LogoutDialogState();
}

class _LogoutDialogState extends ConsumerState<_LogoutDialog> {
  bool _busy = false;

  Future<void> _logout() async {
    setState(() => _busy = true);
    final GoRouter router = GoRouter.of(context);
    final NavigatorState nav = Navigator.of(context);
    if (!widget.senior && !context.kvReduceMotion) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
    }
    if (!mounted) {
      return;
    }
    hideKvTransients();
    nav.pop();
    await ref.read(sessionProvider.notifier).logout();
    router.go(EntryPaths.login, extra: const KvNavExtra(transition: KvTransition.fade));
  }

  @override
  Widget build(BuildContext context) {
    return KvDialog(
      icon: KvIcons.logout,
      tone: widget.senior ? null : KvStatus.bad,
      title: 'Выйти из учётной записи?',
      text: widget.senior
          ? 'Несохранённый осмотр останется на устройстве и отправится после входа.'
          : 'Все осмотры переданы на сервер цеха. Для входа потребуется пароль или биометрия.',
      actions: [
        KvButton('Отмена', kind: KvButtonKind.secondary, onPressed: _busy ? null : () => Navigator.of(context).pop()),
        KvButton('Выйти', kind: KvButtonKind.danger, loading: _busy, onPressed: () => unawaited(_logout())),
      ],
    );
  }
}
