import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/navigation/kv_page.dart';
import '../../app/routes/entry_routes.dart';
import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';

/// Следит, что сеанс ещё действует: после каждого изменения учётных записей спрашивает сервер (GET /auth/me),
/// и если администратор ИБ заблокировал учётную запись, поверх текущего экрана показывает диалог
/// «Сеанс завершён» (f-e-kicked) с переходом ко входу.
///
/// [navigatorKey] - корневой навигатор приложения: диалог открывается в нём.
class EntrySessionWatch extends ConsumerStatefulWidget {
  /// Создаёт наблюдатель над поддеревом [child].
  const EntrySessionWatch({super.key, required this.navigatorKey, required this.child});

  /// Корневой навигатор приложения.
  final GlobalKey<NavigatorState> navigatorKey;

  /// Приложение.
  final Widget child;

  @override
  ConsumerState<EntrySessionWatch> createState() => _EntrySessionWatchState();
}

class _EntrySessionWatchState extends ConsumerState<EntrySessionWatch> {
  bool _shown = false;

  Future<void> _check() async {
    final AuthSession? session = ref.read(sessionProvider);
    if (session == null || _shown) {
      return;
    }
    try {
      await ref.read(authRepositoryProvider).checkSession();
    } on KvApiException catch (e) {
      if (e.failure != KvFailure.blocked || !mounted || ref.read(sessionProvider)?.user.id != session.user.id) {
        return;
      }
      final BuildContext? root = widget.navigatorKey.currentContext;
      if (root == null || !root.mounted) {
        return;
      }
      _shown = true;
      await showEntryKickedDialog(root, email: session.user.email);
      _shown = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<int>>(revisionProvider(KvDomain.auth), (AsyncValue<int>? previous, AsyncValue<int> next) => _check());
    return widget.child;
  }
}

/// Диалог «Сеанс завершён» (f-e-kicked): учётную запись заблокировали, черновик остался на устройстве;
/// «Ко входу» закрывает сеанс и открывает вход с почтой этой учётной записи.
Future<void> showEntryKickedDialog(BuildContext root, {required String email}) {
  return showKvDialog<void>(
    root,
    dismissible: false,
    builder: (BuildContext dialog) => KvDialog(
      icon: KvIcons.lock,
      tone: KvStatus.bad,
      title: 'Сеанс завершён',
      text: 'Администратор ИБ заблокировал учётную запись. Черновик осмотра остался на устройстве и не отправлен.',
      vertical: true,
      actions: [
        Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) => KvButton(
            'Ко входу',
            onPressed: () async {
              Navigator.of(dialog).pop();
              root.go(EntryPaths.aBlockedLogin, extra: KvNavExtra(transition: KvTransition.fade, data: email));
              await ref.read(sessionProvider.notifier).logout();
            },
          ),
        ),
      ],
    ),
  );
}
