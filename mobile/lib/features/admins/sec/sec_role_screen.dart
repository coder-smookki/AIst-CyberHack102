import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Роль и редактор прав (e-role-*): права по группам с переключателями, сохранение, удаление своей роли.
class SecRoleScreen extends ConsumerStatefulWidget {
  /// Создаёт экран роли [roleId]; [fresh] - роль только что создана.
  const SecRoleScreen({super.key, required this.roleId, this.fresh = false});

  /// Код роли.
  final String roleId;

  /// Роль только что создана.
  final bool fresh;

  @override
  ConsumerState<SecRoleScreen> createState() => _SecRoleScreenState();
}

class _SecRoleScreenState extends ConsumerState<SecRoleScreen> {
  Set<String>? _perms;

  @override
  Widget build(BuildContext context) {
    final Role? r = ref.watch(
      rolesProvider.select((AsyncValue<List<Role>> a) => a.value?.where((Role x) => x.id == widget.roleId).firstOrNull),
    );
    final List<Permission> perms = ref.watch(permissionsProvider).value ?? const <Permission>[];
    if (r == null || perms.isEmpty) {
      return KvScreen(
        header: KvHeader(title: 'Роль', subtitle: ' ', onBack: () => context.kvBack(AdminsPaths.secRoles)),
        children: const [KvSkeleton.card(height: 300)],
      );
    }
    final Set<String> on = _perms ??= {...r.permissions};
    final KvColors c = context.kv;
    return KvScreen(
      header: KvHeader(
        title: r.name,
        subtitle: '${r.system ? 'Системная' : 'Своя'} · ${admUsersWord(r.users)}',
        status: r.system ? KvStatus.info : KvStatus.ok,
        onBack: () => context.kvBack(AdminsPaths.secRoles),
        onMore: () => _menu(context, r),
      ),
      foot: r.system
          ? AdmBusyButton(
              'Сохранить изменения',
              work: () => ref
                  .read(securityRepositoryProvider)
                  .updateRole(
                    r.id,
                    permissions: [
                      for (final Permission p in perms)
                        if (on.contains(p.key)) p.key,
                    ],
                  ),
              onDone: () => showKvToast(
                context,
                title: 'Права роли сохранены',
                text: '${r.name} · применятся при следующем входе',
                kind: KvToastKind.ok,
              ),
            )
          : KvButton('Назначить сотруднику', icon: KvIcons.userPlus, onPressed: () => context.kvPush(AdminsPaths.user('u-106'))),
      children: [
        if (r.system)
          KvNote(icon: KvIcons.lock, text: ty('Системную роль нельзя удалить. Права можно изменить, они применятся при следующем входе.'))
        else if (widget.fresh)
          const AdmBoldNote(
            tone: KvStatus.ok,
            icon: KvIcons.checkCircle,
            bold: 'Роль создана',
            text: 'Назначьте её сотрудникам в их карточках.',
          )
        else
          KvNote(icon: KvIcons.info, text: ty('Своя роль. Её можно удалить, если она никому не назначена.')),
        KvCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Включено ${on.length} из ${perms.length}', style: context.kvText.bodyM)),
                  const SizedBox(width: KvSpace.s3),
                  Text('${kAdmPermGroups.length} групп', style: context.kvText.caption),
                ],
              ),
              const SizedBox(height: KvSpace.s2),
              KvProgress(value: on.length / perms.length, thin: true),
            ],
          ),
        ),
        for (final AdmPermGroup g in kAdmPermGroups) ...[
          KvSectionLabel(g.name),
          KvList(
            noIcons: true,
            children: [
              for (final String k in g.keys)
                KvRow(
                  title: admPermLabel(perms, k),
                  titleWidget: Text(admPermLabel(perms, k), style: context.kvText.bodyM.copyWith(height: 1.3, color: c.text)),
                  trailing: KvToggle(
                    value: on.contains(k),
                    semanticLabel: admPermLabel(perms, k),
                    onChanged: (bool v) => setState(() => v ? on.add(k) : on.remove(k)),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  void _menu(BuildContext context, Role r) {
    final BuildContext screen = context;
    showKvSheet<void>(
      context,
      builder: (BuildContext sheet) => KvSheet(
        title: 'Роль «${r.name}»',
        children: [
          KvList(
            children: [
              KvRow(
                icon: KvIcons.users,
                title: 'Сотрудники с ролью',
                subtitle: admUsersWord(r.users),
                onTap: () => admCloseThen(sheet, () => screen.kvFade(AdminsPaths.secUsers)),
              ),
              KvRow(
                icon: KvIcons.copy,
                title: 'Создать роль на основе этой',
                onTap: () => admCloseThen(sheet, () => screen.kvPush(AdminsPaths.eRoleNew)),
              ),
              if (r.system)
                KvRow(
                  icon: KvIcons.lock,
                  iconStatus: KvStatus.unk,
                  title: 'Удалить роль',
                  titleWidget: Text('Удалить роль', style: sheet.kvText.bodyM.copyWith(height: 1.3, color: sheet.kv.text3)),
                  subtitle: 'Системные роли защищены',
                  onTap: () => showKvToast(
                    sheet,
                    title: 'Системную роль нельзя удалить',
                    text: 'Можно изменить её права',
                    kind: KvToastKind.info,
                    icon: KvIcons.lock,
                  ),
                )
              else
                KvRow(
                  icon: KvIcons.trash,
                  iconStatus: KvStatus.bad,
                  danger: true,
                  title: 'Удалить роль',
                  onTap: () => admCloseThen(sheet, () => _delete(screen, r)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _delete(BuildContext screen, Role r) {
    showKvDialog<void>(
      screen,
      builder: (BuildContext dialog) => KvDialog(
        icon: KvIcons.trash,
        tone: KvStatus.bad,
        title: 'Удалить роль «${r.name}»?',
        text: r.users == 0
            ? 'Роль ещё не назначена сотрудникам. Удаление нельзя отменить, права придётся настроить заново.'
            : 'Роль назначена сотрудникам: ${r.users}. Сначала назначьте им другую роль.',
        actions: [
          AdmDialogActions(
            okText: 'Удалить',
            kind: KvButtonKind.danger,
            work: () => ref.read(securityRepositoryProvider).deleteRole(r.id),
            onDone: () {
              Navigator.of(dialog).pop();
              if (screen.mounted) {
                screen.kvFade(AdminsPaths.secRoles);
              }
            },
          ),
        ],
      ),
    );
  }
}
