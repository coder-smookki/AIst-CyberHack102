import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import 'settings_store.dart';

export 'settings_store.dart';

/// Хранилище настроек. В main.dart подменяется загруженным [PrefsSettingsStore].
final Provider<KvSettingsStore> settingsStoreProvider = Provider<KvSettingsStore>((Ref ref) => MemorySettingsStore());

/// Настройки устройства, которые переживают перезапуск.
@immutable
class DeviceSettings {
  /// Создаёт настройки.
  const DeviceSettings({required this.themeMode, required this.onboardingSeen});

  /// Тема: системная, светлая, тёмная.
  final ThemeMode themeMode;

  /// Знакомство уже показано (показывается только при первом запуске).
  final bool onboardingSeen;

  /// Копия с изменениями.
  DeviceSettings copyWith({ThemeMode? themeMode, bool? onboardingSeen}) =>
      DeviceSettings(themeMode: themeMode ?? this.themeMode, onboardingSeen: onboardingSeen ?? this.onboardingSeen);
}

/// Настройки устройства: тема и признак пройденного знакомства, с сохранением.
class DeviceSettingsController extends Notifier<DeviceSettings> {
  static const String _themeKey = 'theme_mode';
  static const String _onboardingKey = 'onboarding_seen';

  @override
  DeviceSettings build() {
    final KvSettingsStore store = ref.watch(settingsStoreProvider);
    final ThemeMode mode = switch (store.getString(_themeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return DeviceSettings(themeMode: mode, onboardingSeen: store.getBool(_onboardingKey) ?? false);
  }

  /// Выбрать тему.
  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await ref.read(settingsStoreProvider).setString(_themeKey, mode.name);
  }

  /// Отметить знакомство пройденным.
  Future<void> completeOnboarding() async {
    state = state.copyWith(onboardingSeen: true);
    await ref.read(settingsStoreProvider).setBool(_onboardingKey, true);
  }
}

/// Настройки устройства.
final NotifierProvider<DeviceSettingsController, DeviceSettings> deviceSettingsProvider =
    NotifierProvider<DeviceSettingsController, DeviceSettings>(DeviceSettingsController.new);

/// Текущий сеанс: null - не выполнен вход. Роль сеанса определяет домашний экран и панель вкладок.
class SessionController extends Notifier<AuthSession?> {
  /// Токен обновления последнего входа на устройстве: остаётся после выхода для входа по биометрии.
  String? _lastRefreshToken;

  @override
  AuthSession? build() => null;

  /// Вход по почте и паролю. Ошибки - [KvApiException] для уведомления на экране входа.
  Future<AuthSession> login(String email, String password) async {
    final AuthSession session = await ref.read(authRepositoryProvider).login(email, password);
    _lastRefreshToken = session.refreshToken;
    state = session;
    return session;
  }

  /// Вход по биометрии с токеном последнего сеанса.
  Future<AuthSession> loginWithBiometrics() async {
    final String token = _lastRefreshToken ?? 'mock-refresh-u-101';
    final AuthSession session = await ref.read(authRepositoryProvider).loginWithBiometrics(token);
    state = session;
    return session;
  }

  /// Смена временного пароля при первом входе.
  Future<AuthSession> changePassword(String password) async {
    final AuthSession session = await ref.read(authRepositoryProvider).changePassword(password);
    state = session;
    return session;
  }

  /// Подставить готовый сеанс (снимки дизайна и тесты).
  void restore(AuthSession session) => state = session;

  /// Выход.
  Future<void> logout() async {
    await ref.read(authRepositoryProvider).logout();
    state = null;
  }
}

/// Текущий сеанс.
final NotifierProvider<SessionController, AuthSession?> sessionProvider = NotifierProvider<SessionController, AuthSession?>(SessionController.new);

/// Роль интерфейса текущего сеанса.
final Provider<KvRole?> currentRoleProvider = Provider<KvRole?>((Ref ref) => ref.watch(sessionProvider.select((AuthSession? s) => s?.user.role)));
