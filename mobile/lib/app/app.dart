import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/kv_theme.dart';
import 'router.dart';
import 'state/app_state.dart';

/// Приложение «КСТ Визор»: темы дизайна, русская локаль, маршрутизатор ролей.
class KvApp extends ConsumerWidget {
  /// Создаёт приложение.
  const KvApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GoRouter router = ref.watch(routerProvider);
    final ThemeMode mode = ref.watch(deviceSettingsProvider.select((DeviceSettings s) => s.themeMode));
    return MaterialApp.router(
      title: 'КСТ Визор',
      debugShowCheckedModeBanner: false,
      theme: KvTheme.light,
      darkTheme: KvTheme.dark,
      themeMode: mode,
      themeAnimationDuration: KvMotion.std,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: mq.textScaler.clamp(minScaleFactor: 1, maxScaleFactor: 1.3)),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
