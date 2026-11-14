import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/navigation/kv_page.dart';
import '../../app/routes/entry_routes.dart';
import '../../app/shell/role_tabs.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';

/// Переход после успешного входа: первый вход с временным паролем - экран нового пароля (въезжает справа),
/// иначе - домашний экран роли наплывом.
///
/// Маршрутизатор сам перенаправляет сеанс на эти экраны; вызов через go не создаёт второй страницы.
void entryOpenHome(BuildContext context, AuthSession session) {
  if (session.mustChangePassword) {
    context.go(EntryPaths.aNewPass, extra: const KvNavExtra(transition: KvTransition.push));
    return;
  }
  context.kvFade(kvRoleHome(session.user.role));
}

/// Отказ во входе: заблокированная запись - экран блокировки, нет связи с сервером - «Сервер недоступен»,
/// неверный пароль и прочее - уведомление сверху «Не удалось войти».
void entryShowLoginFailure(BuildContext context, KvApiException e, {String? email}) {
  switch (e.failure) {
    case KvFailure.blocked:
      context.kvFade(EntryPaths.blocked(email));
    case KvFailure.network:
      context.kvFade(EntryPaths.aOffline);
    case KvFailure.invalidCredentials:
      final int? left = e.attemptsLeft;
      showKvToast(
        context,
        title: 'Не удалось войти',
        text: left == null ? '${e.message}.' : '${e.message}. Осталось попыток: ${left < 0 ? 0 : left}.',
      );
    default:
      showKvToast(context, title: 'Не удалось войти', text: e.message);
  }
}
