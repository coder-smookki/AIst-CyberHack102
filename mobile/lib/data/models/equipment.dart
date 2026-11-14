import 'package:flutter/foundation.dart';

import 'json.dart';

/// Показание датчика с уставками (KV.data.units[].readings; GET /equipment/{id}/telemetry).
@immutable
class Reading {
  /// Создаёт показание.
  const Reading({
    required this.key,
    required this.label,
    required this.short,
    required this.value,
    required this.unit,
    this.warn,
    this.alarm,
    this.digits = 1,
  });

  /// Из ответа сервера.
  factory Reading.fromJson(Map<String, dynamic> j) => Reading(
        key: Json.str(j, 'code'),
        label: Json.str(j, 'name'),
        short: Json.str(j, 'short', Json.str(j, 'name')),
        value: Json.number(j, 'value'),
        unit: Json.str(j, 'unit'),
        warn: Json.numOrNull(j, 'warn'),
        alarm: Json.numOrNull(j, 'alarm'),
        digits: Json.integer(j, 'digits', 1),
      );

  /// Ключ показания: vib1x, vib2x, vibHf, tBearing, tWinding, pressOut, pressIn, current, unbalance, flow.
  final String key;

  /// Полное название: «Температура подшипника».
  final String label;

  /// Короткое название для плитки: «Подшипник».
  final String short;

  /// Текущее значение.
  final double value;

  /// Единица.
  final String unit;

  /// Уставка предупреждения.
  final double? warn;

  /// Аварийная уставка.
  final double? alarm;

  /// Знаков после запятой.
  final int digits;

  /// Статус относительно уставок: 'ok', 'warn', 'bad'.
  String get status => alarm != null && value > alarm! ? 'bad' : (warn != null && value > warn! ? 'warn' : 'ok');

  /// Копия с другим значением.
  Reading withValue(double v) => Reading(key: key, label: label, short: short, value: v, unit: unit, warn: warn, alarm: alarm, digits: digits);

  /// Код параметра сервера для ключа показания (server telemetry codes).
  static const Map<String, String> serverCodes = {
    'vib1x': 'vib_1x',
    'vib2x': 'vib_2x',
    'vibHf': 'vib_hf',
    'tBearing': 'temp_bearing',
    'tWinding': 'temp_winding',
    'pressOut': 'press_out',
    'pressIn': 'press_in',
    'current': 'current_a',
    'unbalance': 'current_unbalance',
    'flow': 'flow',
  };
}

/// Ресурс узла или агрегата: сколько наработано из нормы.
@immutable
class Resource {
  /// Создаёт ресурс.
  const Resource({required this.label, required this.used, required this.total, required this.left, required this.status});

  /// Из ответа сервера.
  factory Resource.fromJson(Map<String, dynamic> j) => Resource(
        label: Json.str(j, 'label'),
        used: Json.number(j, 'used'),
        total: Json.number(j, 'total'),
        left: Json.number(j, 'left'),
        status: Json.str(j, 'status', 'ok'),
      );

  /// «Ресурс подшипников».
  final String label;

  /// Наработано, ч.
  final double used;

  /// Норма, ч.
  final double total;

  /// Осталось, ч.
  final double left;

  /// Статус: ok, warn, bad.
  final String status;

  /// Доля использованного ресурса.
  double get fraction => total == 0 ? 0 : used / total;
}

/// Ближайшее обслуживание.
@immutable
class NextMaintenance {
  /// Создаёт запись о ближайшем ТО.
  const NextMaintenance({required this.code, required this.inHours, required this.atHours, required this.date});

  /// Из ответа сервера.
  factory NextMaintenance.fromJson(Map<String, dynamic> j) => NextMaintenance(
        code: Json.str(j, 'code'),
        inHours: Json.number(j, 'in_hours'),
        atHours: Json.number(j, 'at_hours'),
        date: Json.str(j, 'date'),
      );

  /// «ТО-2».
  final String code;

  /// Через сколько часов наработки.
  final double inHours;

  /// На какой наработке.
  final double atHours;

  /// Ожидаемая дата «15.11.2026».
  final String date;
}

/// Последний осмотр агрегата.
@immutable
class LastInspection {
  /// Создаёт запись.
  const LastInspection({required this.date, required this.time, required this.who, required this.id});

  /// Из ответа сервера.
  factory LastInspection.fromJson(Map<String, dynamic> j) =>
      LastInspection(date: Json.str(j, 'date'), time: Json.str(j, 'time'), who: Json.str(j, 'who'), id: Json.str(j, 'id'));

  /// Дата.
  final String date;

  /// Время.
  final String time;

  /// Кто осматривал.
  final String who;

  /// Номер осмотра.
  final String id;
}

/// Вид обслуживания по регламенту (data/equipment.json maintenance[]).
@immutable
class MaintenanceItem {
  /// Создаёт вид обслуживания.
  const MaintenanceItem({
    required this.code,
    this.interval,
    this.lastAt,
    this.lastDate,
    this.nextAt,
    required this.inHours,
    required this.work,
  });

  /// Из ответа сервера.
  factory MaintenanceItem.fromJson(Map<String, dynamic> j) => MaintenanceItem(
        code: Json.str(j, 'code'),
        interval: Json.numOrNull(j, 'interval'),
        lastAt: Json.numOrNull(j, 'last_at'),
        lastDate: Json.strOrNull(j, 'last_date'),
        nextAt: Json.numOrNull(j, 'next_at'),
        inHours: Json.number(j, 'in_hours'),
        work: Json.str(j, 'work'),
      );

  /// «ТО-1».
  final String code;

  /// Межремонтный интервал, ч.
  final double? interval;

  /// Наработка при последнем ТО.
  final double? lastAt;

  /// Дата последнего ТО.
  final String? lastDate;

  /// Наработка следующего ТО.
  final double? nextAt;

  /// Осталось часов.
  final double inHours;

  /// Состав работ.
  final String work;
}

/// Узел агрегата (GET /equipment/{id}/nodes).
@immutable
class EquipmentNode {
  /// Создаёт узел.
  const EquipmentNode({required this.id, required this.name, this.hours, this.norm, required this.status});

  /// Из ответа сервера.
  factory EquipmentNode.fromJson(Map<String, dynamic> j) => EquipmentNode(
        id: Json.str(j, 'code', Json.str(j, 'id')),
        name: Json.str(j, 'name'),
        hours: Json.numOrNull(j, 'hours'),
        norm: Json.numOrNull(j, 'norm_hours'),
        status: Json.str(j, 'status', 'ok'),
      );

  /// Код узла.
  final String id;

  /// Название.
  final String name;

  /// Наработка узла.
  final double? hours;

  /// Норма наработки.
  final double? norm;

  /// Статус: ok, warn, bad.
  final String status;
}

/// Документ агрегата.
@immutable
class EquipmentDocument {
  /// Создаёт документ.
  const EquipmentDocument({required this.name, required this.type, required this.size});

  /// Из ответа сервера.
  factory EquipmentDocument.fromJson(Map<String, dynamic> j) =>
      EquipmentDocument(name: Json.str(j, 'name'), type: Json.str(j, 'type'), size: Json.str(j, 'size'));

  /// Название.
  final String name;

  /// Формат: «PDF».
  final String type;

  /// Размер: «2,4 МБ».
  final String size;
}

/// Наработка за месяц.
@immutable
class MonthRun {
  /// Создаёт запись.
  const MonthRun({required this.label, required this.value, this.highlight = false});

  /// Из ответа сервера.
  factory MonthRun.fromJson(Map<String, dynamic> j) =>
      MonthRun(label: Json.str(j, 'label'), value: Json.number(j, 'value'), highlight: Json.flag(j, 'hl'));

  /// «Ноя».
  final String label;

  /// Часы.
  final double value;

  /// Текущий месяц.
  final bool highlight;
}

/// Цифровая карточка агрегата (GET /equipment/{id}; поля дизайна сверх ответа сервера помечены в описании).
@immutable
class Equipment {
  /// Создаёт карточку.
  const Equipment({
    required this.id,
    required this.code,
    required this.name,
    required this.kind,
    required this.kindShort,
    required this.model,
    required this.modelShort,
    required this.modelFull,
    required this.manufacturer,
    required this.serial,
    required this.location,
    required this.commissioned,
    required this.status,
    required this.statusLabel,
    required this.mode,
    required this.modeLabel,
    required this.summary,
    required this.runHours,
    required this.resource,
    required this.nextTo,
    required this.lastInspection,
    this.specs = const <(String, String)>[],
    this.readings = const <String, Reading>{},
    this.maintenance = const <MaintenanceItem>[],
    this.nodes = const <EquipmentNode>[],
    this.documents = const <EquipmentDocument>[],
    this.runByMonth = const <MonthRun>[],
    this.openFindings = 0,
    this.stoppedAt,
    this.stopNote,
  });

  /// Из ответа сервера.
  factory Equipment.fromJson(Map<String, dynamic> j) => Equipment(
        id: Json.str(j, 'id'),
        code: Json.str(j, 'code', Json.str(j, 'id')),
        name: Json.str(j, 'name'),
        kind: Json.str(j, 'type'),
        kindShort: Json.str(j, 'type_short'),
        model: Json.str(j, 'model'),
        modelShort: Json.str(j, 'model_short', Json.str(j, 'model')),
        modelFull: Json.str(j, 'model_full', Json.str(j, 'model')),
        manufacturer: Json.str(j, 'manufacturer'),
        serial: Json.str(j, 'serial'),
        location: Json.str(j, 'location'),
        commissioned: Json.str(j, 'commissioned'),
        status: Json.str(j, 'status', 'unk'),
        statusLabel: Json.str(j, 'status_title'),
        mode: Json.str(j, 'mode'),
        modeLabel: Json.str(j, 'mode_title'),
        summary: Json.str(j, 'summary'),
        runHours: Json.number(j, 'run_hours'),
        resource: Resource.fromJson(Json.obj(j, 'resource')),
        nextTo: NextMaintenance.fromJson(Json.obj(j, 'next_maintenance')),
        lastInspection: LastInspection.fromJson(Json.obj(j, 'last_inspection')),
        specs: ((j['specs'] as List<dynamic>?) ?? const <dynamic>[])
            .map((dynamic e) => ((e as List<dynamic>)[0].toString(), e[1].toString()))
            .toList(growable: false),
        readings: {for (final Reading r in Json.list(j, 'readings', Reading.fromJson)) r.key: r},
        maintenance: Json.list(j, 'maintenance', MaintenanceItem.fromJson),
        nodes: Json.list(j, 'nodes', EquipmentNode.fromJson),
        documents: Json.list(j, 'documents', EquipmentDocument.fromJson),
        runByMonth: Json.list(j, 'run_by_month', MonthRun.fromJson),
        openFindings: Json.integer(j, 'open_findings'),
        stoppedAt: Json.strOrNull(j, 'stopped_at'),
        stopNote: Json.strOrNull(j, 'stop_note'),
      );

  /// Идентификатор: 'N-101', 'AMS-1', 'AMS-2'.
  final String id;

  /// Обозначение на станции: «Н-101» (дизайн).
  final String code;

  /// Полное название.
  final String name;

  /// Тип: «Центробежный насос in-line».
  final String kind;

  /// Коротко: «насос» (дизайн).
  final String kindShort;

  /// Модель.
  final String model;

  /// Модель коротко: «Wilo IL 65/160» (дизайн).
  final String modelShort;

  /// Полное обозначение по шильдику.
  final String modelFull;

  /// Производитель.
  final String manufacturer;

  /// Серийный номер.
  final String serial;

  /// Место установки.
  final String location;

  /// Дата ввода.
  final String commissioned;

  /// Статус: ok, warn, bad, info (на ремонте).
  final String status;

  /// «Внимание», «Норма», «На ремонте».
  final String statusLabel;

  /// Режим: running, stopped, repair.
  final String mode;

  /// «В работе», «На ремонте».
  final String modeLabel;

  /// Сводка для списка: «Вибрация 1X 3,1 мм/с · подшипник 78 °C».
  final String summary;

  /// Наработка, ч.
  final double runHours;

  /// Ресурс главного узла.
  final Resource resource;

  /// Ближайшее ТО.
  final NextMaintenance nextTo;

  /// Последний осмотр.
  final LastInspection lastInspection;

  /// Паспортные характеристики.
  final List<(String, String)> specs;

  /// Показания по ключам.
  final Map<String, Reading> readings;

  /// Регламент обслуживания.
  final List<MaintenanceItem> maintenance;

  /// Узлы.
  final List<EquipmentNode> nodes;

  /// Документы.
  final List<EquipmentDocument> documents;

  /// Наработка по месяцам.
  final List<MonthRun> runByMonth;

  /// Незакрытые находки.
  final int openFindings;

  /// Момент остановки, если агрегат остановлен.
  final String? stoppedAt;

  /// Пояснение к показаниям остановленного агрегата.
  final String? stopNote;

  /// На ремонте.
  bool get inRepair => mode == 'repair';

  /// Копия с изменённым состоянием.
  Equipment copyWith({String? status, String? statusLabel, String? mode, String? modeLabel, String? summary, int? openFindings, Map<String, Reading>? readings}) =>
      Equipment(
        id: id,
        code: code,
        name: name,
        kind: kind,
        kindShort: kindShort,
        model: model,
        modelShort: modelShort,
        modelFull: modelFull,
        manufacturer: manufacturer,
        serial: serial,
        location: location,
        commissioned: commissioned,
        status: status ?? this.status,
        statusLabel: statusLabel ?? this.statusLabel,
        mode: mode ?? this.mode,
        modeLabel: modeLabel ?? this.modeLabel,
        summary: summary ?? this.summary,
        runHours: runHours,
        resource: resource,
        nextTo: nextTo,
        lastInspection: lastInspection,
        specs: specs,
        readings: readings ?? this.readings,
        maintenance: maintenance,
        nodes: nodes,
        documents: documents,
        runByMonth: runByMonth,
        openFindings: openFindings ?? this.openFindings,
        stoppedAt: stoppedAt,
        stopNote: stopNote,
      );
}

/// Период графика.
enum TelemetryPeriod {
  /// Последний час.
  hour('1h', '1 ч'),

  /// Сутки.
  day('24h', '24 ч'),

  /// Неделя.
  week('7d', '7 дн'),

  /// Месяц.
  month('30d', '30 дн');

  const TelemetryPeriod(this.code, this.label);

  /// Код периода.
  final String code;

  /// Подпись в переключателе.
  final String label;
}

/// Ряд значений показания за период (GET /equipment/{id}/telemetry/{code}?hours=).
@immutable
class TelemetrySeries {
  /// Создаёт ряд.
  const TelemetrySeries({
    required this.unitId,
    required this.key,
    required this.period,
    required this.values,
    required this.labels,
    required this.label,
    required this.unit,
    required this.digits,
    this.warn,
    this.alarm,
    required this.peakValue,
    required this.peakLabel,
  });

  /// Агрегат.
  final String unitId;

  /// Ключ показания.
  final String key;

  /// Период.
  final TelemetryPeriod period;

  /// Значения, последнее - текущее показание.
  final List<double> values;

  /// Подписи оси.
  final List<String> labels;

  /// Название показания.
  final String label;

  /// Единица.
  final String unit;

  /// Знаков после запятой.
  final int digits;

  /// Уставка предупреждения.
  final double? warn;

  /// Аварийная уставка.
  final double? alarm;

  /// Пиковое значение за период.
  final double peakValue;

  /// Дата пика «10.11».
  final String peakLabel;

  /// Текущее значение.
  double get last => values.last;
}
