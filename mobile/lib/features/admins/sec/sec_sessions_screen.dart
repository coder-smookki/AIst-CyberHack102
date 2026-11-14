import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/admins_routes.dart';
import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';
import '../widgets/adm_widgets.dart';
import 'sec_policy_screen.dart';

/// Активные сеансы (e-sec-sessions): устройства всех сотрудников в сети, завершение одного или всех чужих сеансов.
class SecSessionsScreen extends ConsumerWidget {
  /// Создаёт экран.
  const SecSessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<UserSession>> async = ref.watch(sessionsProvider(null));
    final List<UserSession> sessions = async.value ?? const <UserSession>[];
    final List<AdminUser> users = ref.watch(adminUsersProvider).value ?? const <AdminUser>[];
    final int? hours = ref.watch(policyProvider.select((AsyncValue<SecurityPolicy> p) => p.value?.sessionHours));
    final String? me = ref.watch(sessionProvider.select((AuthSession? s) => s?.user.id));
    final int others = sessions.where((UserSession s) => s.userId != me).length;
    final int n = sessions.length;
    return KvScreen(
      header: KvHeader(
        title: 'Активные сеансы',
        subtitle: async.hasValue ? '$n ${KvFormat.plural(n, 'устройство', 'устройства', 'устройств')} в сети' : ' ',
        status: KvStatus.ok,
        onBack: () => context.kvBack(AdminsPaths.secProfile),
      ),
      foot: others == 0
          ? null
          : KvButton(
              'Завершить все, кроме моего',
              kind: KvButtonKind.dangerSoft,
              onPressed: () => _confirm(context, ref, count: others),
            ),
      children: [
        if (!async.hasValue)
          const KvSkeleton.card(height: 320)
        else if (sessions.isEmpty)
          const KvEmpty(title: 'Активных сеансов нет', text: 'Сотрудники вошли и вышли, открытых сеансов не осталось', icon: KvIcons.phone)
        else
          KvList(
            children: [
              for (final UserSession s in sessions)
                () {
                  final String name = users.where((AdminUser u) => u.id == s.userId).firstOrNull?.name ?? s.userId;
                  return KvRow(
                    avatar: name,
                    title: name,
                    titleWidget: admWrapTitle(context, name),
                    subtitle: ty('${s.device.split(' · ').first} · с ${s.since}'),
                    trailing: s.userId == me
                        ? const KvChip('Вы', status: KvStatus.info, dot: false)
                        : KvButton(
                            'Завершить',
                            kind: KvButtonKind.dangerSoft,
                            small: true,
                            onPressed: () => _confirm(context, ref, session: s, name: name),
                          ),
                  );
                }(),
            ],
          ),
        if (hours != null) KvNote(icon: KvIcons.timer, text: ty('Сеанс длится ${secSessionText(hours)}, затем нужен повторный вход.')),
      ],
    );
  }

  /// Завершение одного сеанса (e-sess-smirnov и другие) или всех чужих (e-sess-all); итог - уведомление (e-sess-done).
  void _confirm(BuildContext context, WidgetRef ref, {UserSession? session, String? name, int count = 0}) {
    final BuildContext screen = context;
    final bool all = session == null;
    showKvDialog<void>(
      context,
      builder: (BuildContext dialog) => KvDialog(
        icon: KvIcons.logout,
        tone: KvStatus.bad,
        title: all ? 'Завершить $count ${KvFormat.plural(count, 'сеанс', 'сеанса', 'сеансов')}?' : 'Завершить сеанс?',
        text: all
            ? 'Сотрудникам потребуется войти заново. Несохранённые осмотры останутся на устройствах.'
            : ty('$name выйдет на устройстве ${session.device.split(' · ').first}. Несохранённый осмотр останется на устройстве.'),
        actions: [
          AdmDialogActions(
            okText: 'Завершить',
            kind: KvButtonKind.danger,
            work: () => all
                ? ref.read(securityRepositoryProvider).revokeSessions()
                : ref.read(securityRepositoryProvider).revokeSessions(sessionId: session.id),
            onDone: () => admCloseThen(dialog, () {
              if (screen.mounted) {
                showKvToast(
                  screen,
                  title: 'Сеанс завершён',
                  text: 'Действие записано в журнал безопасности',
                  kind: KvToastKind.ok,
                  icon: KvIcons.logout,
                );
              }
            }),
          ),
        ],
      ),
    );
  }
}
