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

/// Заготовка своей роли из сценария (Старший инженер), пока роль не создана.
final FutureProvider<Role?> secRoleTemplateProvider = FutureProvider<Role?>((Ref ref) {
  ref.watch(revisionProvider(KvDomain.security));
  return ref.watch(securityRepositoryProvider).roleTemplate();
});

/// Новая роль (e-role-new): название, описание, права на основе системной роли.
class SecRoleNewScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const SecRoleNewScreen({super.key});

  @override
  ConsumerState<SecRoleNewScreen> createState() => _SecRoleNewScreenState();
}

class _SecRoleNewScreenState extends ConsumerState<SecRoleNewScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _about = TextEditingController(text: 'Инженер, который подтверждает находки и смотрит отчёты смены');
  String _base = 'engineer';
  bool _named = false;
  String? _created;

  @override
  void dispose() {
    _name.dispose();
    _about.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<Role> roles = ref.watch(rolesProvider).value ?? const <Role>[];
    final List<Permission> perms = ref.watch(permissionsProvider).value ?? const <Permission>[];
    final AsyncValue<Role?> template = ref.watch(secRoleTemplateProvider);
    if (!template.hasValue || roles.isEmpty || perms.isEmpty) {
      return KvScreen(
        header: KvHeader(
          title: 'Новая роль',
          subtitle: 'Своя роль на основе системной',
          onBack: () => context.kvBack(AdminsPaths.secRoles),
        ),
        children: const [KvSkeleton.card(height: 300)],
      );
    }
    final Role? t = template.value;
    if (!_named) {
      _named = true;
      _name.text = t?.name ?? '';
    }
    final Role base = roles.where((Role r) => r.id == _base).firstOrNull ?? roles.first;
    final Role engineer = roles.where((Role r) => r.id == 'engineer').firstOrNull ?? base;
    final List<String> extra = [...?t?.permissions.where((String k) => !engineer.permissions.contains(k))];
    final List<String> result = [...base.permissions, ...extra.where((String k) => !base.permissions.contains(k))];
    return KvScreen(
      header: KvHeader(title: 'Новая роль', subtitle: 'Своя роль на основе системной', onBack: () => context.kvBack(AdminsPaths.secRoles)),
      foot: AdmBusyButton(
        'Создать роль',
        work: () async {
          final String name = _name.text.trim();
          if (name.isEmpty) {
            throw const KvApiException(KvFailure.validation, 'Укажите название роли');
          }
          final String id = t != null && name == t.name ? t.id : 'role-${roles.length + 1}';
          final Role r = await ref.read(securityRepositoryProvider).createRole(id: id, name: name, permissions: result);
          _created = r.id;
        },
        onDone: () {
          final String? id = _created;
          if (id != null && mounted) {
            context.pushReplacement(AdminsPaths.role(id, fresh: true), extra: const KvNavExtra(transition: KvTransition.fade));
          }
        },
      ),
      children: [
        KvField(label: 'Название', controller: _name, autofocus: true, fieldKey: const ValueKey<String>('role-name')),
        KvField(label: 'Описание', controller: _about, area: true),
        const KvSectionLabel('Права'),
        KvList(
          children: [
            KvRow(
              icon: KvIcons.copy,
              title: 'Скопировать из «${base.name}»',
              subtitle: admRights(base.permissions.length),
              onTap: () => _pickBase(roles.where((Role r) => r.system).toList()),
            ),
          ],
        ),
        KvCard(
          title: 'Будет включено ${result.length} из ${perms.length}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdmChips(
                chips: [
                  for (final String k in result)
                    if (!base.permissions.contains(k))
                      ('+ ${admPermLabel(perms, k)}', KvStatus.ok, false)
                    else
                      (admPermLabel(perms, k), null, false),
                ],
              ),
              const AdmCaption('Точную настройку можно сделать после создания.', top: KvSpace.s2),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickBase(List<Role> system) async {
    final String? id = await showKvSheet<String>(
      context,
      builder: (BuildContext sheet) => _CopySheet(roles: system, initial: _base),
    );
    if (id != null && mounted) {
      setState(() => _base = id);
    }
  }
}

/// Скопировать права из системной роли (e-role-new-copy).
class _CopySheet extends StatefulWidget {
  const _CopySheet({required this.roles, required this.initial});

  final List<Role> roles;
  final String initial;

  @override
  State<_CopySheet> createState() => _CopySheetState();
}

class _CopySheetState extends State<_CopySheet> {
  late String _pick = widget.initial;

  @override
  Widget build(BuildContext context) {
    return KvSheet(
      title: 'Скопировать права из',
      actions: [KvButton('Выбрать', onPressed: () => Navigator.of(context).pop(_pick))],
      children: [
        KvList(
          children: [
            for (final Role r in widget.roles)
              AdmRadioRow(
                icon: admRoleIcon(r.id),
                title: r.name,
                subtitle: admRights(r.permissions.length),
                selected: r.id == _pick,
                onTap: () => setState(() => _pick = r.id),
              ),
          ],
        ),
        const AdmCaption('Права можно изменить после создания роли.'),
      ],
    );
  }
}
