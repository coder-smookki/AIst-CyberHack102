import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../admin_design.dart';
import '../widgets/adm_widgets.dart';

/// Отбор списка учётных записей: роли, состояние и порядок.
@immutable
class SecUserFilter {
  /// Создаёт отбор.
  const SecUserFilter({this.roles = const <String>{}, this.status = 0, this.byLogin = false});

  /// Коды ролей; пусто - все роли.
  final Set<String> roles;

  /// Состояние: 0 - все, 1 - активные, 2 - временный пароль, 3 - заблокированные.
  final int status;

  /// По последнему входу вместо имени.
  final bool byLogin;

  /// Учётная запись проходит отбор.
  bool accepts(AdminUser u) {
    if (roles.isNotEmpty && !roles.contains(u.roleCode)) {
      return false;
    }
    return switch (status) {
      1 => u.status == 'active',
      2 => u.status == 'temp',
      3 => u.status == 'blocked',
      _ => true,
    };
  }

  /// Отобранные и упорядоченные записи.
  List<AdminUser> apply(List<AdminUser> users) {
    final List<AdminUser> list = users.where(accepts).toList();
    if (byLogin) {
      list.sort((AdminUser a, AdminUser b) => _loginKey(b).compareTo(_loginKey(a)));
    }
    return list;
  }

  static String _loginKey(AdminUser u) {
    final RegExpMatch? m = RegExp(r'(\d{2})\.(\d{2}) (\d{2}):(\d{2})').firstMatch(u.lastLogin);
    return m == null ? '' : '${m[2]}${m[1]}${m[3]}${m[4]}';
  }
}

/// Пользователи (sec-users): учётные записи со статусами, поиск, отбор и создание новой записи.
class SecUsersScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const SecUsersScreen({super.key});

  @override
  ConsumerState<SecUsersScreen> createState() => _SecUsersScreenState();
}

class _SecUsersScreenState extends ConsumerState<SecUsersScreen> {
  int _chip = 0;
  SecUserFilter _filter = const SecUserFilter();

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<AdminUser>> async = ref.watch(adminUsersProvider);
    final List<AdminUser> users = async.value ?? const <AdminUser>[];
    final List<SecLogEntry> log = ref.watch(securityLogProvider).value ?? const <SecLogEntry>[];
    final int blocked = users.where((AdminUser u) => u.status == 'blocked').length;
    final int active = users.length - blocked;
    final SecLogEntry? fail = log.where((SecLogEntry e) => e.kind == 'fail').firstOrNull;
    final AdminUser? failUser = fail?.userId == null ? null : users.where((AdminUser u) => u.id == fail!.userId).firstOrNull;
    final List<AdminUser> shown = _filter.apply(users).where((AdminUser u) => _chip == 0 || (_chip == 1 ? u.status != 'blocked' : u.status == 'blocked')).toList();
    return KvScreen(
      header: KvRootHeader(
        title: 'Пользователи',
        subtitle: async.hasValue
            ? '${users.length} ${KvFormat.plural(users.length, 'учётная запись', 'учётные записи', 'учётных записей')} · $blocked ${KvFormat.plural(blocked, 'заблокирована', 'заблокированы', 'заблокировано')}'
            : ' ',
      ),
      foot: KvButton('Новый пользователь', icon: KvIcons.userPlus, onPressed: () => context.kvPush(AdminsPaths.eUserNew)),
      children: [
        Row(
          children: [
            Expanded(child: KvSearchPill('Имя или почта', onTap: () => context.kvPush(AdminsPaths.eUserSearch))),
            const SizedBox(width: KvSpace.s2),
            KvRoundButton(icon: KvIcons.sliders, semanticLabel: 'Фильтр', onPressed: () => _openFilter(users)),
          ],
        ),
        KvFilterChips(
          items: [const KvFilterItem('Все'), KvFilterItem('Активные', count: '$active'), KvFilterItem('Блок', count: '$blocked')],
          selected: _chip,
          onSelected: (int i) => setState(() => _chip = i),
        ),
        if (fail != null)
          AdmBoldNote(
            tone: KvStatus.warn,
            icon: KvIcons.alert,
            bold: '${fail.title ?? fail.text} · ${fail.time}',
            text: '${fail.who.split('@').first}, ${failUser?.status == 'blocked' ? 'учётная запись заблокирована ${failUser!.blockedAt?.substring(0, 5) ?? ''}' : 'учётная запись активна'}',
            onTap: () => context.kvFade(AdminsPaths.secLogOpen('fail')),
          ),
        if (!async.hasValue)
          const KvSkeleton.card(height: 500)
        else if (shown.isEmpty)
          const KvEmpty(title: 'Никого не найдено', text: 'Измените отбор или сбросьте фильтр', icon: KvIcons.users)
        else
          KvList(children: [for (final AdminUser u in shown) SecUserRow(user: u)]),
      ],
    );
  }

  Future<void> _openFilter(List<AdminUser> users) async {
    final SecUserFilter? f = await showKvSheet<SecUserFilter>(
      context,
      builder: (BuildContext sheet) => _FilterSheet(initial: _filter, users: users),
    );
    if (f != null && mounted) {
      setState(() {
        _filter = f;
        _chip = 0;
      });
    }
  }
}

/// Строка учётной записи: аватар, имя, роль и последний вход, отметка «Блок» или «Новый».
class SecUserRow extends StatelessWidget {
  /// Создаёт строку.
  const SecUserRow({super.key, required this.user});

  /// Учётная запись.
  final AdminUser user;

  @override
  Widget build(BuildContext context) {
    final AdminUser u = user;
    return KvRow(
      avatar: u.name,
      title: u.name,
      subtitle: ty('${u.roleLabel} · ${admNeverLoggedIn(u) ? 'ещё не входил' : 'вход ${u.lastLogin}'}'),
      trailing: switch (u.status) {
        'blocked' => const KvChip('Блок', status: KvStatus.bad, dot: false),
        'temp' when admNeverLoggedIn(u) => const KvChip('Новый', status: KvStatus.warn, dot: false),
        _ => null,
      },
      onTap: () => context.kvPush(AdminsPaths.user(u.id)),
    );
  }
}

/// Родительный падеж ролей для подписи «Показать 4 инженера».
const Map<String, (String, String, String)> _roleForms = {
  'engineer': ('инженера', 'инженера', 'инженеров'),
  'master': ('мастера', 'мастера', 'мастеров'),
  'operator': ('оператора', 'оператора', 'операторов'),
};

/// Фильтр пользователей (e-users-filter): роли, состояние и порядок.
class _FilterSheet extends ConsumerStatefulWidget {
  const _FilterSheet({required this.initial, required this.users});

  final SecUserFilter initial;
  final List<AdminUser> users;

  @override
  ConsumerState<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends ConsumerState<_FilterSheet> {
  late Set<String> _roles = {...widget.initial.roles};
  late int _status = widget.initial.status;
  late bool _byLogin = widget.initial.byLogin;

  @override
  Widget build(BuildContext context) {
    final List<Role> roles = ref.watch(rolesProvider).value ?? const <Role>[];
    final SecUserFilter f = SecUserFilter(roles: _roles, status: _status, byLogin: _byLogin);
    final int n = widget.users.where(f.accepts).length;
    final (String, String, String)? forms = _roles.length == 1 ? _roleForms[_roles.first] : null;
    final String what = forms == null
        ? KvFormat.plural(n, 'сотрудника', 'сотрудников', 'сотрудников')
        : KvFormat.plural(n, forms.$1, forms.$2, forms.$3);
    return KvSheet(
      title: 'Фильтр',
      actions: [KvButton('Показать $n $what', onPressed: () => Navigator.of(context).pop(f))],
      children: [
        const AdmSub('Роль'),
        KvFilterChips.multi(
          items: [for (final Role r in roles) KvFilterItem(r.name)],
          selectedSet: {for (int i = 0; i < roles.length; i++) if (_roles.contains(roles[i].id)) i},
          onSelected: (int i) => setState(() {
            final String id = roles[i].id;
            _roles = _roles.contains(id) ? ({..._roles}..remove(id)) : {..._roles, id};
          }),
        ),
        const AdmSub('Статус'),
        KvFilterChips(
          items: const [KvFilterItem('Все'), KvFilterItem('Активные'), KvFilterItem('Временный пароль'), KvFilterItem('Заблокированные')],
          selected: _status,
          onSelected: (int i) => setState(() => _status = i),
        ),
        const AdmSub('Сортировка'),
        KvSegment(
          items: const ['По имени', 'По входу'],
          index: _byLogin ? 1 : 0,
          onBackground: true,
          onChanged: (int i) => setState(() => _byLogin = i == 1),
        ),
      ],
    );
  }
}
