import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/state/app_state.dart';
import 'core/theme/kv_theme.dart';
import 'data/api_exception.dart';

/// Запуск: только портретная ориентация, прозрачные системные панели, настройки устройства из хранилища.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(KvSystemUi.darkIcons);
  final PrefsSettingsStore store = await PrefsSettingsStore.load();
  runApp(
    ProviderScope(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
      retry: (int count, Object error) => error is KvApiException || count >= 2 ? null : Duration(milliseconds: 300 * (count + 1)),
      child: const KvApp(),
    ),
  );
}
