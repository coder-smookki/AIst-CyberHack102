/// Чтение полей ответа сервера: безопасные приведения типов для fromJson моделей.
abstract final class Json {
  /// Строка или пустая строка.
  static String str(Map<String, dynamic> j, String key, [String fallback = '']) => j[key]?.toString() ?? fallback;

  /// Строка или null.
  static String? strOrNull(Map<String, dynamic> j, String key) => j[key]?.toString();

  /// Целое число или [fallback].
  static int integer(Map<String, dynamic> j, String key, [int fallback = 0]) => (j[key] as num?)?.toInt() ?? fallback;

  /// Целое число или null.
  static int? intOrNull(Map<String, dynamic> j, String key) => (j[key] as num?)?.toInt();

  /// Дробное число или [fallback].
  static double number(Map<String, dynamic> j, String key, [double fallback = 0]) => (j[key] as num?)?.toDouble() ?? fallback;

  /// Дробное число или null.
  static double? numOrNull(Map<String, dynamic> j, String key) => (j[key] as num?)?.toDouble();

  /// Логическое значение.
  static bool flag(Map<String, dynamic> j, String key, [bool fallback = false]) => j[key] as bool? ?? fallback;

  /// Вложенный объект.
  static Map<String, dynamic> obj(Map<String, dynamic> j, String key) => (j[key] as Map<String, dynamic>?) ?? const <String, dynamic>{};

  /// Вложенный объект или null.
  static Map<String, dynamic>? objOrNull(Map<String, dynamic> j, String key) => j[key] as Map<String, dynamic>?;

  /// Список объектов, приведённый функцией [f].
  static List<T> list<T>(Map<String, dynamic> j, String key, T Function(Map<String, dynamic>) f) =>
      ((j[key] as List<dynamic>?) ?? const <dynamic>[]).map((dynamic e) => f(e as Map<String, dynamic>)).toList(growable: false);

  /// Список строк.
  static List<String> strings(Map<String, dynamic> j, String key) =>
      ((j[key] as List<dynamic>?) ?? const <dynamic>[]).map((dynamic e) => e.toString()).toList(growable: false);

  /// Момент времени в формате ISO или null.
  static DateTime? time(Map<String, dynamic> j, String key) {
    final String? v = j[key] as String?;
    return v == null ? null : DateTime.tryParse(v);
  }
}
