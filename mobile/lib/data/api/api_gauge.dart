import 'package:flutter/foundation.dart';

import '../models/json.dart';
import 'api_client.dart';

/// Шкала стрелочного манометра из карточки оборудования.
@immutable
class GaugeScale {
  /// Создаёт шкалу.
  const GaugeScale({required this.min, required this.max, required this.unit, this.ratedMax});

  /// Из поля gauge ответа GET /equipment/{id}; [specs] - паспортные данные карточки (max_pressure_bar).
  factory GaugeScale.fromJson(Map<String, dynamic> j, [Map<String, dynamic>? specs]) => GaugeScale(
        min: Json.number(j, 'min'),
        max: Json.number(j, 'max', 10),
        unit: Json.str(j, 'unit', 'бар'),
        ratedMax: specs == null ? null : Json.numOrNull(specs, 'max_pressure_bar'),
      );

  /// Низ шкалы.
  final double min;

  /// Верх шкалы.
  final double max;

  /// Единица.
  final String unit;

  /// Предельное давление агрегата по паспорту; null - в карточке не указано.
  final double? ratedMax;

  /// Показание [value] у края шкалы прибора: настоящее давление может быть за пределами диапазона.
  bool atEdge(double value) {
    final double span = (max - min).abs();
    return span > 0 && (value <= min + span * 0.02 || value >= max - span * 0.02);
  }
}

/// Ответ сервера на чтение манометра (POST /recognize/gauge). При ненадёжном чтении [ok] = false, [value] = null,
/// а [reason] объясняет отказ: сомнительное число сервер не возвращает.
@immutable
class GaugeReading {
  /// Создаёт показание.
  const GaugeReading({
    required this.ok,
    this.value,
    this.unit = '',
    this.reason,
    this.sensorValue,
    this.sensorReason,
    this.differencePercent,
    this.limitPercent = 15,
    this.exceeds,
    this.ruleTitle,
    this.recorded = false,
  });

  /// Из ответа сервера.
  factory GaugeReading.fromJson(Map<String, dynamic> j) {
    final bool ok = Json.flag(j, 'ok');
    final Map<String, dynamic>? finding = Json.objOrNull(j, 'finding');
    return GaugeReading(
      ok: ok,
      value: ok ? Json.numOrNull(j, 'value') : null,
      unit: Json.str(j, 'unit'),
      reason: Json.strOrNull(j, 'reason'),
      sensorValue: Json.numOrNull(j, 'sensor_value'),
      sensorReason: Json.strOrNull(j, 'sensor_reason'),
      differencePercent: ok ? Json.numOrNull(j, 'difference_percent') : null,
      limitPercent: Json.number(j, 'limit_percent', 15),
      exceeds: ok ? j['exceeds'] as bool? : null,
      ruleTitle: finding == null ? null : '${Json.str(finding, 'rule_id')} · ${Json.str(finding, 'title')}',
      recorded: ok && j['inspection_id'] != null,
    );
  }

  /// Показание прочитано надёжно.
  final bool ok;

  /// Показание манометра; null - не прочитано.
  final double? value;

  /// Единица шкалы.
  final String unit;

  /// Причина отказа: «Манометр не прочитан: кадр под углом».
  final String? reason;

  /// Показание электронного датчика того же параметра.
  final double? sensorValue;

  /// Почему нет показания датчика.
  final String? sensorReason;

  /// Расхождение манометра и датчика, %.
  final double? differencePercent;

  /// Допустимое расхождение по правилу R05, %.
  final double limitPercent;

  /// Расхождение больше допустимого; null - сравнить не с чем.
  final bool? exceeds;

  /// Сработавшее правило сверки: «R05 · Расхождение манометра и датчика».
  final String? ruleTitle;

  /// Сервер учёл показание в диагнозе идущего осмотра.
  final bool recorded;
}

/// Чтение стрелочного манометра на сервере.
class ApiGauge {
  /// Создаёт клиент поверх [api].
  ApiGauge(this.api);

  /// Клиент сервера.
  final ApiClient api;

  /// Шкала манометра агрегата [unitId] из карточки; null - манометра в карточке нет.
  Future<GaugeScale?> scale(String unitId) async {
    final Map<String, dynamic> card = await api.getJson('/equipment/${Uri.encodeComponent(unitId)}') as Map<String, dynamic>;
    final Map<String, dynamic>? g = Json.objOrNull(card, 'gauge');
    return g == null ? null : GaugeScale.fromJson(g, Json.objOrNull(card, 'specs'));
  }

  /// Отправляет вырезанный кадр прибора [crop] агрегата [unitId]; с номером идущего осмотра [inspectionId]
  /// надёжное показание входит в его диагноз (правило R05).
  Future<GaugeReading> read(String unitId, Uint8List crop, {String? inspectionId}) async {
    final dynamic j = await api.postForm(
      '/recognize/gauge',
      fields: {'equipment_id': unitId, 'inspection_id': ?inspectionId},
      frame: crop,
    );
    return GaugeReading.fromJson(j as Map<String, dynamic>);
  }
}
