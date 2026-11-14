import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/entry_routes.dart';
import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import 'mo_blocks.dart';

/// Имя с инициалом: «Алексей Смирнов» - «А. Смирнов».
String moShortName(String name) {
  final List<String> p = name.trim().split(RegExp(r'\s+'));
  if (p.length < 2) {
    return name;
  }
  return '${p.first[0]}. ${p.sublist(1).join(' ')}';
}

/// Фамилия: «Алексей Смирнов» - «Смирнов».
String moSurname(String name) {
  final List<String> p = name.trim().split(RegExp(r'\s+'));
  return p.length < 2 ? name : p[1];
}

/// Дата без года: «14.11.2026» - «14.11».
String moDay(String date) => date.length >= 5 ? date.substring(0, 5) : date;

/// Лист настроек профиля (settingsSheet прототипа): тема приложения, уведомления, биометрия, вибрация.
Future<void> showMoSettingsSheet(BuildContext context, {required String notifications}) {
  return showKvSheet<void>(context, builder: (BuildContext sheet) => _SettingsSheet(notifications: notifications));
}

class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet({required this.notifications});

  final String notifications;

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet> {
  bool _notify = true;
  bool _bio = true;
  bool _vibrate = true;

  @override
  Widget build(BuildContext context) {
    final ThemeMode mode = ref.watch(deviceSettingsProvider.select((DeviceSettings s) => s.themeMode));
    final int index = switch (mode) {
      ThemeMode.light => 0,
      ThemeMode.dark => 1,
      ThemeMode.system => 2,
    };
    return KvSheet(
      title: 'Настройки',
      children: [
        const MoLabel('Тема'),
        KvSegment(
          items: const ['Светлая', 'Тёмная', 'Как в системе'],
          index: index,
          onChanged: (int i) => ref.read(deviceSettingsProvider.notifier).setThemeMode(const [ThemeMode.light, ThemeMode.dark, ThemeMode.system][i]),
        ),
        KvList(
          children: [
            MoSwitchRow(icon: KvIcons.bell, title: 'Уведомления', subtitle: widget.notifications, value: _notify, onChanged: (bool v) => setState(() => _notify = v)),
            MoSwitchRow(icon: KvIcons.finger, title: 'Вход по биометрии', subtitle: 'Отпечаток или лицо', value: _bio, onChanged: (bool v) => setState(() => _bio = v)),
            MoSwitchRow(icon: KvIcons.vibrate, title: 'Вибрация при событиях', value: _vibrate, onChanged: (bool v) => setState(() => _vibrate = v)),
          ],
        ),
      ],
      actions: [KvButton('Готово', onPressed: () => Navigator.of(context).pop())],
    );
  }
}

/// Диалог выхода из учётной записи (logoutDialog прототипа): выход закрывает сеанс и ведёт на вход.
Future<void> showMoLogoutDialog(BuildContext context) {
  final BuildContext screen = context;
  return showKvDialog<void>(
    context,
    builder: (BuildContext dialog) => Consumer(
      builder: (BuildContext dialog, WidgetRef ref, Widget? child) => KvDialog(
        icon: KvIcons.logout,
        title: 'Выйти из учётной записи?',
        text: 'Уведомления смены перестанут приходить на этот телефон.',
        actions: [
          KvButton('Отмена', kind: KvButtonKind.secondary, onPressed: () => Navigator.of(dialog).pop()),
          KvButton(
            'Выйти',
            kind: KvButtonKind.danger,
            onPressed: () async {
              Navigator.of(dialog).pop();
              hideKvTransients();
              await ref.read(sessionProvider.notifier).logout();
              if (screen.mounted) {
                screen.kvFade(EntryPaths.login);
              }
            },
          ),
        ],
      ),
    ),
  );
}

/// Лист «Поделиться» файлом отчёта (shareSheet прототипа): сохранить, отправить инженеру, открыть на телефоне.
Future<void> showMoShareSheet(BuildContext context, {required String title, required String file, required String size}) {
  final BuildContext screen = context;
  return showKvSheet<void>(
    context,
    builder: (BuildContext sheet) {
      void after(VoidCallback show) {
        Navigator.of(sheet).pop();
        show();
      }

      return KvSheet(
        title: title,
        children: [
          KvList(
            children: [
              KvRow(
                icon: KvIcons.download,
                title: 'Сохранить в «Файлы»',
                subtitle: KvFormat.typo('$file · $size'),
                onTap: () => after(() => showKvSnack(screen, text: 'Сохранено в «Файлы» · $file')),
              ),
              KvRow(
                icon: KvIcons.send,
                title: 'Отправить инженеру смены',
                subtitle: 'Алексей Смирнов · в приложении',
                onTap: () => after(
                  () => showKvToast(screen, kind: KvToastKind.ok, icon: KvIcons.send, title: 'Отправлено', text: 'Алексей Смирнов получит файл в приложении'),
                ),
              ),
              KvRow(
                icon: KvIcons.file,
                title: 'Открыть на телефоне',
                subtitle: 'Без интернета',
                onTap: () => after(() => showKvToast(screen, kind: KvToastKind.info, icon: KvIcons.file, title: 'Файл открыт', text: file)),
              ),
            ],
          ),
          Text('Файл хранится на цеховом сервере и доступен без интернета.', style: Theme.of(sheet).extension<KvTextStyles>()!.caption),
        ],
      );
    },
  );
}

/// Значок push-уведомления по его смыслу: сообщение оператора, правило, ремонт, задание или тон.
KvIcons moPushIcon(AppNotification n) {
  final String s = '${n.title} ${n.text}'.toLowerCase();
  if (s.contains('сообщил') || s.contains('сообщение')) {
    return KvIcons.megaphone;
  }
  if (s.contains('правило') || s.contains('вибрац')) {
    return KvIcons.activity;
  }
  if (s.contains('ремонт')) {
    return KvIcons.wrench;
  }
  if (s.contains('задани')) {
    return KvIcons.clipboard;
  }
  return switch (n.kind) {
    'ok' => KvIcons.checkCircle,
    'info' => KvIcons.info,
    _ => KvIcons.alert,
  };
}

/// Тон уведомления сверху по тону записи ленты.
KvToastKind moToastKind(String kind) => switch (kind) {
      'ok' => KvToastKind.ok,
      'warn' => KvToastKind.warn,
      'info' => KvToastKind.info,
      _ => KvToastKind.bad,
    };

/// Показывает новые записи ленты роли [roleKey] нажимаемым уведомлением сверху, пока экран на виду:
/// так мастер и оператор получают push цехового сервера. Касание открывает экран из записи.
class MoPushListener extends ConsumerWidget {
  /// Создаёт слушателя ленты роли [roleKey] вокруг экрана [child].
  const MoPushListener({super.key, required this.roleKey, required this.child});

  /// Ключ роли: master или operator.
  final String roleKey;

  /// Экран.
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<AsyncValue<List<AppNotification>>>(notificationsProvider(roleKey), (AsyncValue<List<AppNotification>>? prev, AsyncValue<List<AppNotification>> next) {
      final List<AppNotification>? before = prev?.value;
      final List<AppNotification>? now = next.value;
      if (before == null || now == null || now.isEmpty || !(ModalRoute.isCurrentOf(context) ?? true)) {
        return;
      }
      final Set<String> seen = {for (final AppNotification n in before) n.id};
      final AppNotification? fresh = now.where((AppNotification n) => !seen.contains(n.id)).firstOrNull;
      if (fresh == null) {
        return;
      }
      final String? target = fresh.target;
      showKvToast(
        context,
        kind: moToastKind(fresh.kind),
        icon: moPushIcon(fresh),
        title: fresh.title,
        text: KvFormat.typo(fresh.text),
        onTap: target == null || !target.startsWith('/') ? null : () => context.push(target),
      );
    });
    return child;
  }
}
