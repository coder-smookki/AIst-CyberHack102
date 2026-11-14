import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/state/settings_store.dart';

/// Адрес цехового сервера по умолчанию.
const String kDefaultServerUrl = 'https://kct-vizor.lumnex.ru:4433';

/// Подключение приложения: демонстрационный режим на данных в памяти или настоящий цеховой сервер.
@immutable
class ApiConfig {
  /// Создаёт настройки подключения.
  const ApiConfig({required this.demo, this.baseUrl = kDefaultServerUrl});

  /// Демонстрационный режим: все данные из встроенного демонстрационного сервера.
  final bool demo;

  /// Адрес цехового сервера: «https://kct-vizor.lumnex.ru:4433».
  final String baseUrl;

  /// Копия с изменениями.
  ApiConfig copyWith({bool? demo, String? baseUrl}) => ApiConfig(demo: demo ?? this.demo, baseUrl: baseUrl ?? this.baseUrl);

  @override
  bool operator ==(Object other) => other is ApiConfig && other.demo == demo && other.baseUrl == baseUrl;

  @override
  int get hashCode => Object.hash(demo, baseUrl);
}

/// Хранилище настроек подключения; в main.dart подменяется хранилищем устройства.
final Provider<KvSettingsStore> apiSettingsStoreProvider = Provider<KvSettingsStore>((Ref ref) => MemorySettingsStore());

/// Настройки подключения с сохранением на телефоне. Без сохранённого значения - демонстрационный режим.
class ApiConfigController extends Notifier<ApiConfig> {
  static const String _modeKey = 'api_mode';
  static const String _urlKey = 'api_url';

  @override
  ApiConfig build() {
    final KvSettingsStore store = ref.watch(apiSettingsStoreProvider);
    return ApiConfig(demo: store.getString(_modeKey) != 'server', baseUrl: store.getString(_urlKey) ?? kDefaultServerUrl);
  }

  /// Включить или выключить демонстрационный режим.
  Future<void> setDemo(bool demo) async {
    state = state.copyWith(demo: demo);
    await ref.read(apiSettingsStoreProvider).setString(_modeKey, demo ? 'demo' : 'server');
  }

  /// Сохранить адрес сервера [url]; адрес без схемы дополняется «http://».
  Future<void> setBaseUrl(String url) async {
    final String clean = normalizeServerUrl(url);
    state = state.copyWith(baseUrl: clean);
    await ref.read(apiSettingsStoreProvider).setString(_urlKey, clean);
  }

  /// Режим по умолчанию для первого запуска на телефоне: настоящий сервер, если режим ещё не выбирали.
  static Future<void> ensureServerDefault(KvSettingsStore store) async {
    if (store.getString(_modeKey) == null) {
      await store.setString(_modeKey, 'server');
    }
  }
}

/// Адрес сервера без пробелов и косой черты в конце, со схемой http по умолчанию.
String normalizeServerUrl(String url) {
  String v = url.trim();
  if (v.isEmpty) {
    return kDefaultServerUrl;
  }
  if (!v.startsWith('http://') && !v.startsWith('https://')) {
    v = 'http://$v';
  }
  while (v.endsWith('/')) {
    v = v.substring(0, v.length - 1);
  }
  return v;
}

/// Настройки подключения.
final NotifierProvider<ApiConfigController, ApiConfig> apiConfigProvider = NotifierProvider<ApiConfigController, ApiConfig>(ApiConfigController.new);
