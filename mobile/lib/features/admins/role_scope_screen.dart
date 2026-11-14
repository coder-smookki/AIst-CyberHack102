import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/entry_routes.dart';
import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'admin_design.dart';
import 'widgets/adm_widgets.dart';

/// Права роли (e-adm-scope, e-sec-scope): доступные права и недоступные группы разделов.
class RoleScopeScreen extends ConsumerWidget {
  /// Создаёт экран для роли [roleId] с возвратом на [back].
  const RoleScopeScreen({super.key, required this.roleId, required this.back});

  /// Код роли: admin, security_admin.
  final String roleId;

  /// Путь возврата.
  final String back;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Role? role = ref.watch(rolesProvider).value?.where((Role r) => r.id == roleId).firstOrNull;
    final List<Permission> perms = ref.watch(permissionsProvider).value ?? const <Permission>[];
    if (role == null || perms.isEmpty) {
      return KvScreen(
        header: KvHeader(title: 'Права роли', subtitle: ' ', onBack: () => context.kvBack(back)),
        children: const [KvSkeleton.card(height: 300)],
      );
    }
    final List<Widget> on = [];
    final List<Widget> off = [];
    for (final AdmPermGroup g in kAdmPermGroups) {
      final List<String> has = g.keys.where(role.permissions.contains).toList();
      for (final String k in has) {
        on.add(KvRow(icon: KvIcons.check, iconStatus: KvStatus.ok, title: admPermLabel(perms, k)));
      }
      if (has.isEmpty) {
        final List<String> labels = [
          for (int i = 0; i < g.keys.length; i++) i == 0 ? admPermLabel(perms, g.keys[i]) : _lowerFirst(admPermLabel(perms, g.keys[i])),
        ];
        off.add(
          KvRow(
            icon: KvIcons.lock,
            iconStatus: KvStatus.unk,
            title: g.name,
            titleWidget: Text(g.name, style: context.kvText.bodyM.copyWith(height: 1.3, color: context.kv.text3)),
            subtitle: labels.join(', '),
          ),
        );
      }
    }
    final bool sec = role.id == 'security_admin' || role.id == 'sec';
    return KvScreen(
      header: KvHeader(
        title: 'Права роли',
        subtitle: '${role.name} · ${admRights(role.permissions.length)}',
        status: KvStatus.info,
        onBack: () => context.kvBack(back),
      ),
      children: [
        KvNote(
          icon: KvIcons.info,
          text: sec
              ? 'Агрегаты, осмотры и показания этой роли не видны. Поэтому в нижнем меню только пользователи, роли, журнал и политика.'
              : 'Учётные записи и роли настраивает администратор ИБ. Осмотров и находок в нижнем меню нет.',
        ),
        const KvSectionLabel('Доступно'),
        KvList(children: on),
        const KvSectionLabel('Недоступно'),
        KvList(children: off),
      ],
    );
  }

  static String _lowerFirst(String s) => s.isEmpty ? s : '${s[0].toLowerCase()}${s.substring(1)}';
}

/// Подтверждение выхода из учётной записи (e-adm-logout, e-sec-logout): после выхода - экран входа.
void showAdmLogout(BuildContext context, WidgetRef ref, {required String text}) {
  final BuildContext screen = context;
  showKvDialog<void>(
    context,
    builder: (BuildContext dialog) => KvDialog(
      icon: KvIcons.logout,
      title: 'Выйти из учётной записи?',
      text: text,
      actions: [
        AdmDialogActions(
          okText: 'Выйти',
          kind: KvButtonKind.danger,
          wait: Duration.zero,
          onDone: () {
            Navigator.of(dialog).pop();
            hideKvTransients();
            unawaited(_logout(ref, screen));
          },
        ),
      ],
    ),
  );
}

/// Завершает сеанс и открывает экран входа.
Future<void> _logout(WidgetRef ref, BuildContext screen) async {
  await ref.read(sessionProvider.notifier).logout();
  if (screen.mounted) {
    screen.kvFade(EntryPaths.login);
  }
}
