/// Источник текущего времени. В демонстрации время истории - 14.11.2026 09:41.
abstract interface class KvClock {
  /// Текущий момент.
  DateTime now();
}

/// Часы, которые всегда показывают один момент: для тестов и снимков дизайна.
class FixedClock implements KvClock {
  /// Создаёт часы, остановленные на [at].
  const FixedClock(this.at);

  /// Момент.
  final DateTime at;

  @override
  DateTime now() => at;
}

/// Часы истории: стартуют в [start] и идут вместе с реальным временем с момента запуска приложения.
class StoryClock implements KvClock {
  /// Создаёт часы истории.
  StoryClock([DateTime? start]) : _start = start ?? storyNow, _since = DateTime.now();

  /// Момент истории 14.11.2026 09:41.
  static final DateTime storyNow = DateTime(2026, 11, 14, 9, 41);

  final DateTime _start;
  final DateTime _since;

  @override
  DateTime now() => _start.add(DateTime.now().difference(_since));
}

/// Часы телефона: настоящий сервер работает в текущем времени.
class SystemClock implements KvClock {
  /// Создаёт часы.
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}
