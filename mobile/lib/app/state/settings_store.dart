import 'package:shared_preferences/shared_preferences.dart';

/// Хранилище настроек устройства: тема и признак пройденного знакомства.
abstract interface class KvSettingsStore {
  /// Строковое значение или null.
  String? getString(String key);

  /// Логическое значение или null.
  bool? getBool(String key);

  /// Сохранить строку.
  Future<void> setString(String key, String value);

  /// Сохранить логическое значение.
  Future<void> setBool(String key, bool value);
}

/// Настройки в SharedPreferences.
class PrefsSettingsStore implements KvSettingsStore {
  /// Создаёт хранилище поверх загруженных [prefs].
  PrefsSettingsStore(this.prefs);

  /// Загруженные настройки.
  final SharedPreferences prefs;

  /// Загружает настройки устройства.
  static Future<PrefsSettingsStore> load() async => PrefsSettingsStore(await SharedPreferences.getInstance());

  @override
  String? getString(String key) => prefs.getString(key);

  @override
  bool? getBool(String key) => prefs.getBool(key);

  @override
  Future<void> setString(String key, String value) => prefs.setString(key, value);

  @override
  Future<void> setBool(String key, bool value) => prefs.setBool(key, value);
}

/// Настройки в памяти: тесты и снимки дизайна.
class MemorySettingsStore implements KvSettingsStore {
  /// Создаёт хранилище с начальными значениями [values].
  MemorySettingsStore([Map<String, Object>? values]) : _values = {...?values};

  final Map<String, Object> _values;

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  bool? getBool(String key) => _values[key] as bool?;

  @override
  Future<void> setString(String key, String value) async => _values[key] = value;

  @override
  Future<void> setBool(String key, bool value) async => _values[key] = value;
}
