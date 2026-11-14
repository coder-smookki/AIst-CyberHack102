import '../../core/kv.dart';
import '../../data/providers.dart';

/// Перевод данных в параметры компонентов дизайна.
extension TelemetrySeriesChart on TelemetrySeries {
  /// Данные графика для [KvAreaChart] и [KvSparkline].
  KvSeriesData get chart => KvSeriesData(values: values, warn: warn, alarm: alarm, unit: unit, digits: digits, labels: labels);
}

/// Статус показания для точки и цвета.
extension ReadingStatus on Reading {
  /// Статус дизайна по уставкам.
  KvStatus get kvStatus => KvStatus.parse(status);
}

/// Статус агрегата для чипа и точки.
extension EquipmentStatus on Equipment {
  /// Статус дизайна: норма, внимание, авария, на ремонте.
  KvStatus get kvStatus => KvStatus.parse(status);
}

/// Группа тяжести результата правила (KV.sevOf): «Критично», «Планово», «Проверить».
enum KvSeverity {
  /// Критично (красный): тяжесть 3 при совпадении всех условий.
  critical('Критично', KvStatus.bad),

  /// Планово (жёлтый): тяжесть 2.
  planned('Планово', KvStatus.warn),

  /// Проверить (синий): тяжесть 1, только камера или частичное совпадение.
  check('Проверить', KvStatus.info);

  const KvSeverity(this.label, this.status);

  /// Подпись.
  final String label;

  /// Тон.
  final KvStatus status;

  /// Группа результата [d] по правилу [rule].
  static KvSeverity of(DiagnosisResult d, RuleDef? rule) {
    if (d.result == 'camera' || d.result == 'partial') {
      return KvSeverity.check;
    }
    return switch (rule?.severity ?? 1) {
      3 => KvSeverity.critical,
      2 => KvSeverity.planned,
      _ => KvSeverity.check,
    };
  }
}
