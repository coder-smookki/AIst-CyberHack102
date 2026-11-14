import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';

/// Недавно открытые карточки сотрудников (по умолчанию - как в прототипе: Елена Титова и Алексей Смирнов).
const List<String> kSecRecentUsers = ['u-106', 'u-101'];

/// Поиск пользователя (e-user-search): по имени, почте или названию роли, с подсветкой совпадения.
class SecUserSearchScreen extends ConsumerStatefulWidget {
  /// Создаёт экран.
  const SecUserSearchScreen({super.key});

  @override
  ConsumerState<SecUserSearchScreen> createState() => _SecUserSearchScreenState();
}

class _SecUserSearchScreenState extends ConsumerState<SecUserSearchScreen> {
  final TextEditingController _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _q.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  static int _rank(AdminUser u, String q) {
    final String name = u.name.toLowerCase();
    if (name.split(' ').any((String w) => w.startsWith(q))) {
      return 0;
    }
    if (name.contains(q)) {
      return 1;
    }
    if (u.email.toLowerCase().contains(q)) {
      return 2;
    }
    if (u.roleLabel.toLowerCase().startsWith(q)) {
      return 3;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final List<AdminUser> users = ref.watch(adminUsersProvider).value ?? const <AdminUser>[];
    final String q = _q.text.trim().toLowerCase();
    final List<AdminUser> found = q.isEmpty
        ? const <AdminUser>[]
        : (users.where((AdminUser u) => _rank(u, q) >= 0).toList()..sort((AdminUser a, AdminUser b) => _rank(a, q).compareTo(_rank(b, q))));
    final List<AdminUser> recent = [for (final String id in kSecRecentUsers) ...users.where((AdminUser u) => u.id == id)];
    return KvScreen(
      header: KvHeader(title: 'Поиск', subtitle: 'Имя, почта или роль', onBack: () => context.kvBack(AdminsPaths.secUsers)),
      stagger: KvStagger.none,
      children: [
        KvField(
          controller: _q,
          lead: KvIcons.search,
          end: KvIcons.close,
          onEnd: () => context.kvBack(AdminsPaths.secUsers),
          autofocus: true,
          textInputAction: TextInputAction.search,
          fieldKey: const ValueKey<String>('user-search'),
        ),
        if (q.isNotEmpty) ...[
          KvSectionLabel('Найдено ${found.length}'),
          if (found.isEmpty)
            const KvEmpty(title: 'Никого не найдено', text: 'Проверьте написание имени или почты')
          else
            KvList(
              children: [
                for (final AdminUser u in found)
                  KvRow(
                    avatar: u.name,
                    title: u.name,
                    titleWidget: _Highlight(text: u.name, query: q),
                    subtitle: '${u.roleLabel} · ${u.email}',
                    onTap: () => context.kvPush(AdminsPaths.user(u.id)),
                  ),
              ],
            ),
        ],
        const KvSectionLabel('Недавно открывали'),
        KvList(
          children: [
            for (final AdminUser u in recent)
              KvRow(
                icon: KvIcons.history,
                iconStatus: KvStatus.unk,
                title: u.name,
                subtitle: u.roleLabel,
                onTap: () => context.kvPush(AdminsPaths.user(u.id)),
              ),
          ],
        ),
      ],
    );
  }
}

/// Имя с подсвеченным совпадением (mark.e-hl).
class _Highlight extends StatelessWidget {
  const _Highlight({required this.text, required this.query});

  final String text;
  final String query;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final TextStyle style = context.kvText.bodyM.copyWith(height: 1.3, color: c.text);
    final int i = text.toLowerCase().indexOf(query);
    if (i < 0) {
      return Text(text, style: style);
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: text.substring(0, i)),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(color: c.tint, borderRadius: BorderRadius.circular(4)),
              child: Text(text.substring(i, i + query.length), style: style.copyWith(color: c.brand)),
            ),
          ),
          TextSpan(text: text.substring(i + query.length)),
        ],
      ),
    );
  }
}
