import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Карточка сотрудника (e-user-*): состояние учётной записи, роль, пароль, биометрия, сеансы, блокировка.
///
/// Состояния прототипа (активна, временный пароль, заблокирована, новая роль) берутся из данных сервера;
/// [assigned] показывает плашку о только что назначенной своей роли.
class SecUserScreen extends ConsumerWidget {
  /// Создаёт карточку сотрудника [userId].
  const SecUserScreen({super.key, required this.userId, this.assigned = false});

  /// Номер учётной записи.
  final String userId;

  /// Роль только что назначена.
  final bool assigned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AdminUser? u = ref.watch(adminUsersProvider.select((AsyncValue<List<AdminUser>> a) => a.value?.where((AdminUser x) => x.id == userId).firstOrNull));
    final List<Role> roles = ref.watch(rolesProvider).value ?? const <Role>[];
    final List<UserSession> sessions = ref.watch(sessionsProvider(userId)).value ?? const <UserSession>[];
    final String? me = ref.watch(sessionProvider.select((AuthSession? s) => s?.user.id));
    if (u == null || roles.isEmpty) {
      return KvScreen(
        header: KvHeader(title: 'Сотрудник', subtitle: ' ', onBack: () => context.kvBack(AdminsPaths.secUsers)),
        children: const [KvSkeleton.card(height: 120), KvSkeleton.card(height: 200)],
      );
    }
    final SecUserCtx x = SecUserCtx(user: u, role: roles.where((Role r) => r.id == u.roleCode).firstOrNull, roles: roles, sessions: sessions, me: me);
    final (String stateLabel, KvStatus tone) = admUserState(u.status);
    return KvScreen(
      header: KvHeader(
        title: u.name,
        subtitle: '$stateLabel · ${x.roleName}',
        status: tone,
        onBack: () => context.kvBack(AdminsPaths.secUsers),
        onMore: () => showUserMenu(context, ref, x),
      ),
      children: [
        ..._notes(context, x),
        _ProfileCard(user: u),
        const KvSectionLabel('Доступ'),
        _access(context, ref, x),
        const KvSectionLabel('Сеансы и устройства'),
        _sessions(context, ref, x),
        if (x.self)
          KvNote(icon: KvIcons.info, text: ty('Свою учётную запись нельзя заблокировать. Это может сделать другой администратор ИБ.'))
        else if (u.status == 'blocked')
          KvButton('Разблокировать', kind: KvButtonKind.secondary, icon: KvIcons.unlock, onPressed: () => showUnblockDialog(context, ref, x))
        else
          KvButton('Заблокировать учётную запись', kind: KvButtonKind.dangerSoft, icon: KvIcons.ban, onPressed: () => showBlockDialog(context, ref, x)),
      ],
    );
  }

  List<Widget> _notes(BuildContext context, SecUserCtx x) {
    final AdminUser u = x.user;
    if (assigned && u.status != 'blocked' && x.role != null && !x.role!.system) {
      final bool senior = x.role!.permissions.contains('confirm') && x.role!.permissions.contains('reports_all');
      return [
        AdmBoldNote(
          tone: KvStatus.ok,
          icon: KvIcons.checkCircle,
          bold: 'Роль «${x.roleName}» назначена',
          text: senior
              ? 'При следующем входе добавятся разделы: подтверждение находок, отчёты смены.'
              : 'Набор разделов изменится при следующем входе.',
        ),
      ];
    }
    if (u.status == 'blocked') {
      final String reason = (u.blockReason ?? '').isEmpty ? 'Решение администратора ИБ' : u.blockReason!;
      return [
        AdmBoldNote(
          tone: KvStatus.bad,
          icon: KvIcons.ban,
          bold: 'Заблокирована ${u.blockedAt ?? ''}',
          text: '$reason. Сеансы завершены, при входе сотрудник увидит экран блокировки.',
        ),
      ];
    }
    if (u.status == 'temp') {
      final String until = (u.tempUntil ?? '').replaceFirst(' ', ', ');
      return [
        KvNote(
          tone: KvStatus.warn,
          icon: KvIcons.key,
          text: ty(
            admNeverLoggedIn(u)
                ? 'Временный пароль действует до $until. Сотрудник ещё не входил, свой пароль задаст при первом входе.'
                : 'Временный пароль действует до $until. Свой пароль сотрудник задаст при следующем входе.',
          ),
        ),
      ];
    }
    return const <Widget>[];
  }

  Widget _access(BuildContext context, WidgetRef ref, SecUserCtx x) {
    final AdminUser u = x.user;
    if (u.status == 'blocked') {
      return KvList(
        children: [KvRow(icon: KvIcons.key, iconStatus: KvStatus.unk, title: x.roleName, subtitle: 'Роль · ${admRights(x.rights)} · не действует')],
      );
    }
    final bool temp = u.status == 'temp';
    return KvList(
      children: [
        if (x.self)
          KvRow(icon: admRoleIcon(u.roleCode), title: x.roleName, subtitle: 'Свою роль изменить нельзя')
        else
          KvRow(icon: admRoleIcon(u.roleCode), title: x.roleName, subtitle: 'Роль · ${admRights(x.rights)}', onTap: () => showRoleSheet(context, ref, x)),
        KvRow(
          icon: KvIcons.lock,
          title: temp ? 'Временный пароль' : 'Пароль',
          subtitle: temp ? 'Выдать новый' : ty('Сменён 20.09 · срок 90 дн'),
          onTap: () => showResetDialog(context, ref, x),
        ),
        KvRow(
          icon: KvIcons.finger,
          title: 'Вход по биометрии',
          subtitle: u.biometrics ? 'Включён на устройстве' : 'Не настроен',
          trailing: AdmToggle(initial: u.biometrics, semanticLabel: 'Вход по биометрии'),
        ),
      ],
    );
  }

  Widget _sessions(BuildContext context, WidgetRef ref, SecUserCtx x) {
    final AdminUser u = x.user;
    final List<UserSession> list = u.status == 'blocked' ? const <UserSession>[] : x.sessions;
    if (list.isEmpty) {
      return KvList(
        children: [
          KvRow(
            icon: KvIcons.phone,
            iconStatus: KvStatus.unk,
            title: 'Активных сеансов нет',
            subtitle: admNeverLoggedIn(u) ? 'Устройство появится после первого входа' : ty('Последний вход ${u.lastLogin}'),
          ),
        ],
      );
    }
    return KvList(
      children: [
        for (final UserSession s in list)
          KvRow(
            icon: KvIcons.phone,
            iconStatus: KvStatus.ok,
            title: s.device.split(' · ').first,
            subtitle: ty('${s.method.isEmpty ? 'Вход' : s.method} · с ${s.since}'),
            trailing: s.userId == x.me
                ? const KvChip('Это устройство', status: KvStatus.info, dot: false)
                : KvButton('Завершить', kind: KvButtonKind.dangerSoft, small: true, onPressed: () => showSessionDialog(context, ref, x, session: s)),
          ),
      ],
    );
  }
}

/// Данные карточки сотрудника для листов и диалогов.
class SecUserCtx {
  /// Создаёт данные.
  const SecUserCtx({required this.user, required this.role, required this.roles, required this.sessions, required this.me});

  /// Учётная запись.
  final AdminUser user;

  /// Роль сотрудника.
  final Role? role;

  /// Все роли.
  final List<Role> roles;

  /// Открытые сеансы сотрудника.
  final List<UserSession> sessions;

  /// Номер учётной записи текущего администратора.
  final String? me;

  /// Это своя учётная запись.
  bool get self => user.id == me;

  /// Название роли.
  String get roleName => role?.name ?? user.roleLabel;

  /// Число прав роли.
  int get rights => role?.permissions.length ?? 0;

  /// Сеансы на чужих устройствах.
  List<UserSession> get otherSessions => sessions.where((UserSession s) => s.userId != me).toList();
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.user});

  final AdminUser user;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    final AdminUser u = user;
    final TextStyle cap = t.caption.copyWith(height: KvTextStyles.normalHeight(13));
    return KvCard(
      child: Row(
        children: [
          KvAvatar(u.name, size: KvAvatarSize.large),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(u.email, style: t.body.copyWith(fontWeight: FontWeight.w500, height: KvTextStyles.normalHeight(15))),
                const SizedBox(height: 3),
                Text(admNeverLoggedIn(u) ? 'Ещё не входил' : ty('Последний вход ${u.lastLogin}'), style: cap),
                const SizedBox(height: 3),
                Text(u.biometrics ? 'Вход по паролю и биометрии' : 'Вход по паролю', style: cap),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Меню учётной записи (e-user-*-menu).
void showUserMenu(BuildContext context, WidgetRef ref, SecUserCtx x) {
  final BuildContext screen = context;
  final AdminUser u = x.user;
  final int n = x.otherSessions.length;
  showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => KvSheet(
      title: u.name,
      children: [
        KvList(
          children: [
            KvRow(
              icon: KvIcons.list,
              title: 'Журнал действий сотрудника',
              subtitle: 'Входы, изменения роли и пароля',
              onTap: () => admCloseThen(sheet, () => screen.kvFade(AdminsPaths.secLog)),
            ),
            if (u.status == 'blocked')
              KvRow(icon: KvIcons.unlock, iconStatus: KvStatus.ok, title: 'Разблокировать', onTap: () => admCloseThen(sheet, () => showUnblockDialog(screen, ref, x)))
            else ...[
              KvRow(
                icon: KvIcons.key,
                title: 'Сбросить пароль',
                subtitle: ty('Выдать временный на 24 ч'),
                onTap: () => admCloseThen(sheet, () => showResetDialog(screen, ref, x)),
              ),
              if (n > 0)
                KvRow(
                  icon: KvIcons.logout,
                  title: 'Завершить все сеансы',
                  subtitle: '$n ${KvFormat.plural(n, 'устройство', 'устройства', 'устройств')}',
                  onTap: () => admCloseThen(sheet, () => showSessionDialog(screen, ref, x)),
                ),
              if (!x.self)
                KvRow(
                  icon: KvIcons.ban,
                  iconStatus: KvStatus.bad,
                  danger: true,
                  title: 'Заблокировать',
                  onTap: () => admCloseThen(sheet, () => showBlockDialog(screen, ref, x)),
                ),
            ],
          ],
        ),
      ],
    ),
  );
}

/// Выбор роли сотрудника (e-user-*-role): своя роль показывается плашкой на карточке, системная - уведомлением.
void showRoleSheet(BuildContext context, WidgetRef ref, SecUserCtx x) {
  final BuildContext screen = context;
  showKvSheet<void>(context, builder: (BuildContext sheet) => _RoleSheet(x: x, screen: screen));
}

class _RoleSheet extends ConsumerStatefulWidget {
  const _RoleSheet({required this.x, required this.screen});

  final SecUserCtx x;
  final BuildContext screen;

  @override
  ConsumerState<_RoleSheet> createState() => _RoleSheetState();
}

class _RoleSheetState extends ConsumerState<_RoleSheet> {
  late String _pick = widget.x.user.roleCode;

  @override
  Widget build(BuildContext context) {
    final SecUserCtx x = widget.x;
    final List<Role> roles = ref.watch(rolesProvider).value ?? x.roles;
    return KvSheet(
      title: 'Роль сотрудника',
      actions: [
        AdmBusyButton(
          'Назначить роль',
          work: () => ref.read(securityRepositoryProvider).changeRole(x.user.id, _pick),
          onDone: () {
            final Role? r = roles.where((Role r) => r.id == _pick).firstOrNull;
            final bool changed = _pick != x.user.roleCode;
            Navigator.of(context).pop();
            final BuildContext screen = widget.screen;
            if (!screen.mounted) {
              return;
            }
            if (changed && r != null && !r.system) {
              screen.replace(AdminsPaths.user(x.user.id, assigned: true));
            } else {
              showKvToast(screen, title: 'Роль сохранена', text: '${x.user.name} · ${r?.name ?? ''}', kind: KvToastKind.ok);
            }
          },
        ),
      ],
      children: [
        AdmCaption('${x.user.name} · сейчас «${x.roleName}»'),
        KvList(
          children: [
            for (final Role r in roles)
              AdmRadioRow(
                icon: admRoleIcon(r.id),
                iconStatus: r.system ? null : KvStatus.ok,
                title: r.name,
                subtitle: '${admRights(r.permissions.length)}${r.system ? ' · системная' : ' · своя роль'}',
                selected: r.id == _pick,
                onTap: () => setState(() => _pick = r.id),
              ),
          ],
        ),
        const AdmCaption('Набор разделов у сотрудника изменится при следующем входе.'),
      ],
    );
  }
}

/// Сброс пароля (e-user-*-reset) и временный пароль (e-user-*-reset-done).
void showResetDialog(BuildContext context, WidgetRef ref, SecUserCtx x) {
  final BuildContext screen = context;
  final AdminUser u = x.user;
  final bool temp = u.status == 'temp';
  final int hours = ref.read(policyProvider).value?.tempPwdHours ?? 24;
  showKvDialog<void>(
    context,
    builder: (BuildContext dialog) => KvDialog(
      icon: KvIcons.key,
      tone: KvStatus.warn,
      title: temp ? 'Выдать новый пароль?' : 'Сбросить пароль?',
      text: ty('Текущий пароль перестанет действовать, сеансы на устройствах завершатся. ${admShortName(u.name)} получит временный пароль на $hours ч.'),
      actions: [
        AdmDialogActions(
          okText: temp ? 'Выдать' : 'Сбросить',
          work: () => ref.read(securityRepositoryProvider).resetPassword(u.id),
          onDone: () => admCloseThen(dialog, () {
            if (screen.mounted) {
              showTempPasswordSheet(screen, ref, u.id);
            }
          }),
        ),
      ],
    ),
  );
}

/// Лист с временным паролем, который показывается один раз.
void showTempPasswordSheet(BuildContext context, WidgetRef ref, String userId) {
  showKvSheet<void>(
    context,
    builder: (BuildContext sheet) => Consumer(
      builder: (BuildContext c, WidgetRef r, Widget? _) {
        final AdminUser? u = r.watch(adminUsersProvider).value?.where((AdminUser x) => x.id == userId).firstOrNull;
        return KvSheet(
          title: 'Временный пароль',
          actions: [KvButton('Готово', onPressed: () => Navigator.of(sheet).pop())],
          children: [
            AdmCaption('Сотрудник: ${u?.name ?? ''}. Пароль показан один раз.'),
            AdmPassword(u?.tempPassword ?? ''),
            KvKeyValues([('Действует до', (u?.tempUntil ?? '').replaceFirst(' ', ', ')), ('При первом входе', 'задаст свой пароль')]),
            KvNote(tone: KvStatus.warn, icon: KvIcons.shield, text: 'Передайте пароль лично. Не отправляйте его в мессенджерах и почте.'),
          ],
        );
      },
    ),
  );
}

/// Завершение сеанса (e-user-*-sess): одного [session] или всех сеансов сотрудника.
void showSessionDialog(BuildContext context, WidgetRef ref, SecUserCtx x, {UserSession? session}) {
  final BuildContext screen = context;
  final UserSession? s = session ?? x.otherSessions.firstOrNull;
  if (s == null) {
    return;
  }
  showKvDialog<void>(
    context,
    builder: (BuildContext dialog) => KvDialog(
      icon: KvIcons.logout,
      title: 'Завершить сеанс?',
      text: ty('На устройстве ${s.device.split(' · ').first} потребуется войти заново. Несохранённый осмотр останется на устройстве.'),
      actions: [
        AdmDialogActions(
          okText: 'Завершить',
          kind: KvButtonKind.danger,
          work: () => session != null
              ? ref.read(securityRepositoryProvider).revokeSessions(sessionId: session.id)
              : ref.read(securityRepositoryProvider).revokeSessions(userId: x.user.id),
          onDone: () => admCloseThen(dialog, () {
            if (screen.mounted) {
              showKvToast(screen, title: 'Сеанс завершён', text: ty(s.device), kind: KvToastKind.ok, icon: KvIcons.logout);
            }
          }),
        ),
      ],
    ),
  );
}

/// Блокировка учётной записи с причиной (e-user-*-block).
void showBlockDialog(BuildContext context, WidgetRef ref, SecUserCtx x) {
  showKvDialog<void>(context, builder: (BuildContext dialog) => _BlockDialog(x: x));
}

class _BlockDialog extends ConsumerStatefulWidget {
  const _BlockDialog({required this.x});

  final SecUserCtx x;

  @override
  ConsumerState<_BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends ConsumerState<_BlockDialog> {
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AdminUser u = widget.x.user;
    return KvDialog(
      icon: KvIcons.ban,
      tone: KvStatus.bad,
      title: 'Заблокировать учётную запись?',
      text: ty('${admShortName(u.name)} не сможет войти, активные сеансы завершатся сразу.'),
      body: KvField(label: 'Причина', placeholder: 'Укажите причину', area: true, controller: _reason, fieldKey: const ValueKey<String>('block-reason')),
      actions: [
        AdmDialogActions(
          okText: 'Заблокировать',
          kind: KvButtonKind.danger,
          work: () => ref.read(securityRepositoryProvider).block(u.id, reason: _reason.text.trim()),
          onDone: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// Разблокировка (e-user-*-unblock).
void showUnblockDialog(BuildContext context, WidgetRef ref, SecUserCtx x) {
  final AdminUser u = x.user;
  showKvDialog<void>(
    context,
    builder: (BuildContext dialog) => KvDialog(
      icon: KvIcons.unlock,
      tone: KvStatus.ok,
      title: 'Разблокировать?',
      text: ty('${admShortName(u.name)} снова сможет войти. Рекомендуется сразу выдать новый временный пароль.'),
      actions: [
        AdmDialogActions(
          okText: 'Разблокировать',
          work: () => ref.read(securityRepositoryProvider).unblock(u.id),
          onDone: () => Navigator.of(dialog).pop(),
        ),
      ],
    ),
  );
}
