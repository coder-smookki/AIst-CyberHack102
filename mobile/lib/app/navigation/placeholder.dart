import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/kv.dart';
import 'kv_page.dart';

/// Маршрут-заготовка экрана, который ещё не свёрстан: показывает идентификатор экрана прототипа и кнопку «назад».
GoRoute kvPlaceholderRoute(
  String path, {
  required String id,
  required String title,
  KvTransition transition = KvTransition.push,
  List<RouteBase> routes = const <RouteBase>[],
}) {
  return GoRoute(
    path: path,
    name: id,
    routes: routes,
    pageBuilder: (BuildContext context, GoRouterState state) => KvPage<void>.of(state, PlaceholderScreen(id: id, title: title), transition: transition),
  );
}

/// Экран-заготовка: идентификатор и название экрана прототипа.
class PlaceholderScreen extends StatelessWidget {
  /// Создаёт заготовку.
  const PlaceholderScreen({super.key, required this.id, required this.title});

  /// Идентификатор экрана прототипа.
  final String id;

  /// Название экрана.
  final String title;

  @override
  Widget build(BuildContext context) {
    return KvScreen(
      header: KvHeader(
        title: title,
        subtitle: id,
        onBack: () => context.canPop() ? context.pop() : context.go('/'),
      ),
      children: [
        KvEmpty(icon: KvIcons.layers, title: 'Экран в работе', text: 'Макет «$title» ($id) будет свёрстан по прототипу.'),
      ],
    );
  }
}
