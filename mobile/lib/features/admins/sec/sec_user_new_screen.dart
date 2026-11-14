import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/navigation/kv_page.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Новый пользователь (e-user-new): имя, почта, роль и биометрия; временный пароль создаётся автоматически.
class SecUserNewScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const SecUserNewScreen({super.key});

  @override
  ConsumerState<SecUserNewScreen> createState() => _SecUserNewScreenState();
}

class _SecUserNewScreenState extends ConsumerState<SecUserNewScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  String _role = 'engineer';
  String? _created;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final String name = _name.text.trim();
    final String email = _email.text.trim();
    if (name.isEmpty || !email.contains('@')) {
      throw const KvApiException(KvFailure.validation, 'Укажите имя и рабочую почту сотрудника');
    }
    final AdminUser u = await ref.read(securityRepositoryProvider).createUser(name: name, email: email, roleCode: _role);
    _created = u.id;
  }

  @override
  Widget build(BuildContext context) {
    final List<Role> roles = ref.watch(rolesProvider).value ?? const <Role>[];
    final Role? role = roles.where((Role r) => r.id == _role).firstOrNull;
    return KvScreen(
      header: KvHeader(
        title: 'Новый пользователь',
        subtitle: 'Учётная запись сотрудника',
        onBack: () => context.kvBack(AdminsPaths.secUsers),
      ),
      foot: AdmBusyButton(
        'Создать учётную запись',
        wait: const Duration(milliseconds: 1200),
        work: _create,
        onDone: () {
          final String? id = _created;
          if (id != null && mounted) {
            context.pushReplacement(AdminsPaths.userNewDone(id), extra: const KvNavExtra(transition: KvTransition.fade));
          }
        },
      ),
      children: [
        KvField(
          label: 'Имя и фамилия',
          controller: _name,
          lead: KvIcons.user,
          textInputAction: TextInputAction.next,
          fieldKey: const ValueKey<String>('user-name'),
        ),
        KvField(
          label: 'Почта',
          controller: _email,
          lead: KvIcons.mail,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          fieldKey: const ValueKey<String>('user-email'),
        ),
        const KvSectionLabel('Роль'),
        KvList(
          children: [
            KvRow(
              icon: admRoleIcon(_role),
              iconStatus: role == null || role.system ? null : KvStatus.ok,
              title: role?.name ?? 'Инженер',
              subtitle: '${admRights(role?.permissions.length ?? 0)} · ${role?.system ?? true ? 'системная роль' : 'своя роль'}',
              onTap: () => _pickRole(roles),
            ),
          ],
        ),
        const KvList(
          children: [
            KvRow(
              icon: KvIcons.finger,
              title: 'Разрешить вход по биометрии',
              subtitle: 'После первого входа с паролем',
              trailing: AdmToggle(initial: true, semanticLabel: 'Разрешить вход по биометрии'),
            ),
          ],
        ),
        KvNote(icon: KvIcons.key, text: ty('Временный пароль на 24 ч создаётся автоматически и показывается один раз.')),
      ],
    );
  }

  Future<void> _pickRole(List<Role> roles) async {
    final String? id = await showKvSheet<String>(
      context,
      builder: (BuildContext sheet) => _RolePickSheet(roles: roles, initial: _role),
    );
    if (id != null && mounted) {
      setState(() => _role = id);
    }
  }
}

/// Роль нового сотрудника (e-user-new-role).
class _RolePickSheet extends StatefulWidget {
  const _RolePickSheet({required this.roles, required this.initial});

  final List<Role> roles;
  final String initial;

  @override
  State<_RolePickSheet> createState() => _RolePickSheetState();
}

class _RolePickSheetState extends State<_RolePickSheet> {
  late String _pick = widget.initial;

  @override
  Widget build(BuildContext context) {
    return KvSheet(
      title: 'Роль',
      actions: [KvButton('Выбрать', onPressed: () => Navigator.of(context).pop(_pick))],
      children: [
        KvList(
          children: [
            for (final Role r in widget.roles)
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
      ],
    );
  }
}

/// Учётная запись создана (e-user-new-done): временный пароль показывается один раз.
class SecUserNewDoneScreen extends ConsumerWidget {
  /// Создаёт экран для записи [userId]; без него - последняя запись с временным паролем.
  const SecUserNewDoneScreen({super.key, this.userId});

  /// Номер созданной записи.
  final String? userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<AdminUser> users = ref.watch(adminUsersProvider).value ?? const <AdminUser>[];
    final AdminUser? u = userId == null
        ? users.where((AdminUser x) => x.status == 'temp').lastOrNull
        : users.where((AdminUser x) => x.id == userId).firstOrNull;
    return KvScreen(
      surface: true,
      foot: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KvButton('Готово', onPressed: () => context.kvFade(AdminsPaths.secUsers)),
          const SizedBox(height: KvSpace.s2),
          KvButton(
            'Открыть карточку',
            kind: KvButtonKind.secondary,
            onPressed: u == null
                ? null
                : () => context.pushReplacement(AdminsPaths.user(u.id), extra: const KvNavExtra(transition: KvTransition.fade)),
          ),
        ],
      ),
      children: u == null
          ? const [KvSkeleton.card(height: 300)]
          : [
              AdmDone(title: 'Учётная запись создана', text: '${u.name} · ${u.roleLabel}'),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const AdmSub('Временный пароль'),
                  const SizedBox(height: KvSpace.s2),
                  AdmPassword(u.tempPassword ?? ''),
                  const SizedBox(height: KvSpace.s2),
                  AdmCaption('Действует до ${(u.tempUntil ?? '').replaceFirst(' ', ', ')}. При первом входе сотрудник задаст свой пароль.'),
                ],
              ),
              const KvNote(tone: KvStatus.warn, icon: KvIcons.shield, text: 'Пароль показан один раз. Передайте его лично.'),
            ],
    );
  }
}
