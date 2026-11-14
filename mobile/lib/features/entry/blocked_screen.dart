import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/entry_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'entry_state.dart';
import 'widgets/entry_blocks.dart';

/// «Учётная запись заблокирована» (a-blocked): красный замок, кто и когда закрыл доступ и почему, контакт
/// администратора ИБ, «Связаться с администратором ИБ» и «Вернуться ко входу».
class BlockedScreen extends ConsumerWidget {
  /// Создаёт экран для учётной записи с почтой [email].
  const BlockedScreen({super.key, required this.email});

  /// Почта учётной записи, которой отказано во входе.
  final String email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final BlockedAccount? account = email.isEmpty ? null : ref.watch(entryBlockedAccountProvider(email)).value;
    final SupportContact? sec = ref.watch(entrySecurityContactProvider).value;
    final String shown = account?.email ?? email;
    return KvScreen(
      padding: const EdgeInsets.fromLTRB(KvSpace.gutter, KvSpace.s5, KvSpace.gutter, 0),
      children: [
        EntryStateHero(
          icon: KvIcons.lock,
          title: 'Учётная запись заблокирована',
          text: TextSpan(
            children: [
              if (shown.isEmpty)
                const TextSpan(text: 'Доступ закрыл администратор ИБ.')
              else ...[
                const TextSpan(text: 'Доступ для '),
                entryStrong(context, shown),
                const TextSpan(text: ' закрыл администратор ИБ.'),
              ],
              const TextSpan(text: ' Войти с этой учётной записью нельзя.'),
            ],
          ),
        ),
        if (account != null)
          EntryKeyValueCard([
            ('Сотрудник', account.name),
            ('Заблокирована', account.blockedAt),
            if (account.reason.isNotEmpty) ('Причина', account.reason),
          ]),
        if (sec != null)
          KvList(
            children: [
              KvRow(avatar: sec.name, title: sec.name, subtitle: sec.role, onTap: () => showEntryContactSheet(context)),
            ],
          ),
      ],
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          KvButton('Связаться с администратором ИБ', icon: KvIcons.phone, onPressed: () => showEntryContactSheet(context)),
          const SizedBox(height: KvSpace.s2),
          KvButton('Вернуться ко входу', kind: KvButtonKind.ghost, onPressed: () => context.kvBack(EntryPaths.login)),
        ],
      ),
    );
  }
}

/// Лист «Администратор ИБ» (a-blocked-contact): аватар, часы работы, звонок, копирование почты и пояснение,
/// что разблокировать учётную запись может только администратор ИБ.
Future<void> showEntryContactSheet(BuildContext context) => showKvSheet<void>(context, builder: (_) => const _ContactSheet());

class _ContactSheet extends ConsumerWidget {
  const _ContactSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SupportContact? sec = ref.watch(entrySecurityContactProvider).value;
    if (sec == null) {
      return const KvSheet(title: 'Администратор ИБ', children: [KvSkeleton.card(height: 220)]);
    }
    final KvTextStyles t = context.kvText;
    return KvSheet(
      title: sec.role,
      children: [
        Row(
          children: [
            KvAvatar(sec.name, size: KvAvatarSize.large),
            const SizedBox(width: KvSpace.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sec.name, style: t.bodyM),
                  Text(sec.hours, style: t.caption),
                ],
              ),
            ),
          ],
        ),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.phone,
              title: KvFormat.typo(sec.phone),
              subtitle: 'Позвонить',
              onTap: () => showKvToast(context, kind: KvToastKind.info, icon: KvIcons.phone, title: 'Вызов', text: KvFormat.typo('${sec.name} · ${sec.phone}')),
            ),
            KvRow(
              icon: KvIcons.mail,
              title: sec.email,
              subtitle: 'Скопировать адрес',
              onTap: () {
                Clipboard.setData(ClipboardData(text: sec.email));
                showKvToast(context, kind: KvToastKind.ok, icon: KvIcons.copy, title: 'Адрес скопирован', text: sec.email);
              },
            ),
          ],
        ),
        const KvNote(icon: KvIcons.shield, text: 'Сообщите почту учётной записи. Разблокировать её может только администратор ИБ.'),
      ],
    );
  }
}
