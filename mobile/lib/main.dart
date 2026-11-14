import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/state/app_state.dart';
import 'core/theme/kv_theme.dart';
import 'data/api/api_config.dart';
import 'data/api/bio_vault.dart';
import 'data/api_exception.dart';

/// Запуск: телефон - только портретная ориентация, планшет - любая; прозрачные системные панели, настройки устройства из хранилища.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final FlutterView view = WidgetsBinding.instance.platformDispatcher.views.first;
  final bool tablet = view.physicalSize.shortestSide / view.devicePixelRatio >= KvLayout.tablet;
  await SystemChrome.setPreferredOrientations(tablet ? const <DeviceOrientation>[] : const [DeviceOrientation.portraitUp]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(KvSystemUi.darkIcons);
  final PrefsSettingsStore store = await PrefsSettingsStore.load();
  await ApiConfigController.ensureServerDefault(store);
  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        apiSettingsStoreProvider.overrideWithValue(store),
        bioVaultProvider.overrideWithValue(DeviceBioVault()),
      ],
      retry: (int count, Object error) => error is KvApiException || count >= 2 ? null : Duration(milliseconds: 300 * (count + 1)),
      child: const KvApp(),
    ),
  );
}
