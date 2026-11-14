import 'package:flutter/foundation.dart';

import 'json.dart';

/// Правило диагностики (data/rules.json, KV.data.rules).
@immutable
class RuleDef {
  /// Создаёт правило.
  const RuleDef({
    required this.id,
    required this.title,
    required this.camera,
    required this.sensor,
    required this.status,
    required this.severity,
    required this.recommendation,
  });

  /// Из ответа сервера.
  factory RuleDef.fromJson(Map<String, dynamic> j) => RuleDef(
        id: Json.str(j, 'id'),
        title: Json.str(j, 'title'),
        camera: Json.str(j, 'camera'),
        sensor: Json.str(j, 'sensor'),
        status: Json.str(j, 'status'),
        severity: Json.integer(j, 'severity', 1),
        recommendation: Json.str(j, 'recommendation'),
      );

  /// «R01».
  final String id;

  /// Название.
  final String title;

  /// Признак для камеры.
  final String camera;

  /// Признак по датчикам.
  final String sensor;

  /// defect или check.
  final String status;

  /// Тяжесть 1-3: 3 критично, 2 планово, 1 проверить.
  final int severity;

  /// Рекомендация.
  final String recommendation;
}

/// Основание вывода: камера, датчик, данные.
@immutable
class Evidence {
  /// Создаёт основание.
  const Evidence({required this.source, required this.text, this.met = true});

  /// Из ответа сервера (evidence[] в diagnose).
  factory Evidence.fromJson(Map<String, dynamic> j) =>
      Evidence(source: Json.str(j, 'source'), text: Json.str(j, 'what', Json.str(j, 'text')), met: Json.flag(j, 'met', true));

  /// camera, sensor, data, resource, manual.
  final String source;

  /// Текст основания.
  final String text;

  /// Условие выполнено.
  final bool met;
}

/// Результат правила по агрегату в текущем осмотре (GET /equipment/{id}/diagnosis, findings[]).
@immutable
class DiagnosisResult {
  /// Создаёт результат.
  const DiagnosisResult({
    required this.ruleId,
    required this.status,
    required this.result,
    required this.title,
    required this.text,
    this.evidence = const <Evidence>[],
    this.missing = const <String>[],
    this.firedAt = '',
  });

  /// Из ответа сервера.
  factory DiagnosisResult.fromJson(Map<String, dynamic> j) => DiagnosisResult(
        ruleId: Json.str(j, 'rule_id'),
        status: Json.str(j, 'status'),
        result: Json.str(j, 'result', 'match'),
        title: Json.str(j, 'title'),
        text: Json.str(j, 'diagnosis'),
        evidence: Json.list(j, 'evidence', Evidence.fromJson),
        missing: Json.strings(j, 'missing'),
        firedAt: Json.str(j, 'fired_at'),
      );

  /// Время срабатывания правила «08:12»; пусто - неизвестно.
  final String firedAt;

  /// Правило.
  final String ruleId;

  /// Тон: bad, warn.
  final String status;

  /// match (все условия), partial, camera (только камера), warn (уставка).
  final String result;

  /// Заголовок.
  final String title;

  /// Вывод осторожной формулировкой.
  final String text;

  /// Основания.
  final List<Evidence> evidence;

  /// Что ещё нужно проверить камерой.
  final List<String> missing;
}

/// Пункт чек-листа осмотра.
@immutable
class ChecklistItem {
  /// Создаёт пункт.
  const ChecklistItem({required this.id, required this.label, required this.state, this.note = ''});

  /// Код.
  final String id;

  /// Что проверить.
  final String label;

  /// ok, warn, bad.
  final String state;

  /// Отметка инженера.
  final String note;
}

/// Рамка распознавания на кадре камеры в процентах кадра (WS /ws/inspect boxes).
@immutable
class Detection {
  /// Создаёт рамку.
  const Detection({required this.kind, required this.label, required this.x, required this.y, required this.w, required this.h, this.unitId = ''});

  /// part, defect, gauge.
  final String kind;

  /// Агрегат, на кадре которого найдена рамка; пусто - общий кадр без привязки.
  final String unitId;

  /// Подпись.
  final String label;

  /// Левый край, %.
  final double x;

  /// Верхний край, %.
  final double y;

  /// Ширина, %.
  final double w;

  /// Высота, %.
  final double h;
}

/// Находка (дефект или признак): от фиксации инженером до решения мастера.
///
/// Статусы дизайна: new (ждёт подтверждения), confirmed, planned (запланировано ТО), closed, rejected.
/// На сервере им соответствуют state open, in_work, resolved.
@immutable
class Finding {
  /// Создаёт находку.
  const Finding({
    required this.id,
    required this.unitId,
    required this.title,
    required this.ruleId,
    required this.severity,
    required this.status,
    required this.source,
    required this.date,
    required this.time,
    required this.author,
    required this.node,
    this.evidence = const <String>[],
    this.recommendation = '',
    this.confirmedBy,
    this.confirmedAt,
    this.planned,
    this.closedBy,
    this.closedNote,
    this.rejectReason,
    this.comment,
    this.keepRunning = false,
    this.masterComment,
    this.rejectedAt,
  });

  /// Из ответа сервера.
  factory Finding.fromJson(Map<String, dynamic> j) => Finding(
        id: Json.str(j, 'id'),
        unitId: Json.str(j, 'equipment_id'),
        title: Json.str(j, 'title'),
        ruleId: Json.str(j, 'rule_id'),
        severity: Json.integer(j, 'severity', 1),
        status: switch (Json.str(j, 'state')) {
          'in_work' => 'confirmed',
          'resolved' => 'closed',
          _ => Json.str(j, 'status_design', 'new'),
        },
        source: Json.str(j, 'source'),
        date: Json.str(j, 'date'),
        time: Json.str(j, 'time'),
        author: Json.str(j, 'author'),
        node: Json.str(j, 'node_name'),
        evidence: Json.list(j, 'evidence', (Map<String, dynamic> e) => Json.str(e, 'what')),
        recommendation: Json.str(j, 'recommendation'),
        comment: Json.strOrNull(j, 'comment'),
      );

  /// «F-1043».
  final String id;

  /// Агрегат.
  final String unitId;

  /// Заголовок.
  final String title;

  /// Правило.
  final String ruleId;

  /// Тяжесть 1-3.
  final int severity;

  /// Статус дизайна.
  final String status;

  /// Источник: «Осмотр INS-2209», «Правило R08, датчики».
  final String source;

  /// Дата.
  final String date;

  /// Время.
  final String time;

  /// Автор.
  final String author;

  /// Узел.
  final String node;

  /// Основания.
  final List<String> evidence;

  /// Рекомендация.
  final String recommendation;

  /// Кто подтвердил.
  final String? confirmedBy;

  /// Когда подтвердил.
  final String? confirmedAt;

  /// Что запланировано: «Ремонт уплотнения 15.11, 08:00».
  final String? planned;

  /// Кто закрыл.
  final String? closedBy;

  /// Пояснение при закрытии.
  final String? closedNote;

  /// Причина отклонения.
  final String? rejectReason;

  /// Комментарий автора при фиксации находки (поле comment сервера); решение мастера - в [masterComment].
  final String? comment;

  /// Оставлен в работе до ТО-2 с обоснованием.
  final bool keepRunning;

  /// Комментарий или обоснование мастера: виден инженеру и в отчёте (поле дизайна).
  final String? masterComment;

  /// Когда мастер отклонил находку: «09:45» (поле дизайна).
  final String? rejectedAt;

  /// Копия с изменённым решением.
  Finding copyWith({
    String? status,
    String? confirmedBy,
    String? confirmedAt,
    String? planned,
    String? closedBy,
    String? closedNote,
    String? rejectReason,
    String? comment,
    bool? keepRunning,
    String? masterComment,
    String? rejectedAt,
  }) =>
      Finding(
        id: id,
        unitId: unitId,
        title: title,
        ruleId: ruleId,
        severity: severity,
        status: status ?? this.status,
        source: source,
        date: date,
        time: time,
        author: author,
        node: node,
        evidence: evidence,
        recommendation: recommendation,
        confirmedBy: confirmedBy ?? this.confirmedBy,
        confirmedAt: confirmedAt ?? this.confirmedAt,
        planned: planned ?? this.planned,
        closedBy: closedBy ?? this.closedBy,
        closedNote: closedNote ?? this.closedNote,
        rejectReason: rejectReason ?? this.rejectReason,
        comment: comment ?? this.comment,
        keepRunning: keepRunning ?? this.keepRunning,
        masterComment: masterComment ?? this.masterComment,
        rejectedAt: rejectedAt ?? this.rejectedAt,
      );
}

/// Осмотр (GET /inspections/{id}).
@immutable
class Inspection {
  /// Создаёт осмотр.
  const Inspection({
    required this.id,
    required this.unitId,
    required this.date,
    required this.time,
    required this.duration,
    required this.who,
    required this.status,
    required this.defects,
    required this.checks,
    this.note = '',
    this.findingIds = const <String>[],
  });

  /// Из ответа сервера.
  factory Inspection.fromJson(Map<String, dynamic> j) => Inspection(
        id: Json.str(j, 'id'),
        unitId: Json.str(j, 'equipment_id'),
        date: Json.str(j, 'date'),
        time: Json.str(j, 'time'),
        duration: Json.str(j, 'duration'),
        who: Json.str(Json.obj(j, 'user'), 'name'),
        status: Json.str(j, 'status') == 'finished' ? 'done' : 'draft',
        defects: Json.integer(Json.obj(j, 'summary'), 'defects'),
        checks: Json.integer(Json.obj(j, 'summary'), 'checks'),
        note: Json.str(j, 'note'),
      );

  /// «INS-2209».
  final String id;

  /// Агрегат.
  final String unitId;

  /// Дата.
  final String date;

  /// Время начала.
  final String time;

  /// Длительность «14 мин».
  final String duration;

  /// Кто осматривал.
  final String who;

  /// draft (идёт) или done.
  final String status;

  /// Найдено дефектов.
  final int defects;

  /// Проверено пунктов.
  final int checks;

  /// Итог.
  final String note;

  /// Находки осмотра.
  final List<String> findingIds;

  /// Копия с другим состоянием.
  Inspection copyWith({String? status, int? defects, int? checks, String? duration, String? note, List<String>? findingIds}) => Inspection(
        id: id,
        unitId: unitId,
        date: date,
        time: time,
        duration: duration ?? this.duration,
        who: who,
        status: status ?? this.status,
        defects: defects ?? this.defects,
        checks: checks ?? this.checks,
        note: note ?? this.note,
        findingIds: findingIds ?? this.findingIds,
      );
}

/// Событие истории агрегата (GET /equipment/{id}/history).
@immutable
class HistoryEvent {
  /// Создаёт событие.
  const HistoryEvent({
    required this.date,
    required this.time,
    required this.status,
    required this.title,
    required this.text,
    required this.who,
    this.unitId = '',
    this.kind = '',
    this.label = '',
    this.target,
  });

  /// Дата.
  final String date;

  /// Время.
  final String time;

  /// Тон: ok, warn, bad, info.
  final String status;

  /// Заголовок.
  final String title;

  /// Подробности.
  final String text;

  /// Кто или «Система».
  final String who;

  /// Агрегат события в общей ленте; пусто - лента одного агрегата.
  final String unitId;

  /// Вид события: inspection, rule, plan, alarm, reading; пусто - не задан.
  final String kind;

  /// Подпись итога для чипа: «Дефект», «Внимание», «Без находок»; пусто - без чипа.
  final String label;

  /// Путь экрана приложения, который открывает касание, или null.
  final String? target;
}

/// Находка в итоге осмотра: правило, основания, тяжесть и рекомендация (findings[] в GET /inspections/{id}).
@immutable
class SummaryFinding {
  /// Создаёт находку итога.
  const SummaryFinding({
    required this.ruleId,
    required this.title,
    required this.severity,
    required this.sources,
    this.relatedRules = const <String>[],
    this.evidence = const <Evidence>[],
    this.recommendation = '',
    this.frame,
  });

  /// Правило: «R01».
  final String ruleId;

  /// Название находки.
  final String title;

  /// Группа тяжести: critical, planned, check.
  final String severity;

  /// Чем подтверждена: «камера и датчики», «только камера, рекомендуется проверка».
  final String sources;

  /// Уставки, сработавшие вместе с правилом: S01, S04.
  final List<String> relatedRules;

  /// Основания для отчёта.
  final List<Evidence> evidence;

  /// Рекомендация для отчёта.
  final String recommendation;

  /// Подпись рамки кадра камеры для миниатюры: «Течь у вала»; null - без кадра.
  final String? frame;
}

/// Заметка осмотра: голосовая или текстовая.
@immutable
class SummaryNote {
  /// Создаёт заметку.
  const SummaryNote({required this.title, required this.time, this.length = '', this.sentAt});

  /// Тема: «шум подшипника».
  final String title;

  /// Время записи.
  final String time;

  /// Длительность голосовой заметки «0:14»; пусто - текстовая.
  final String length;

  /// Когда передана на сервер; null - ещё на телефоне.
  final String? sentAt;
}

/// Узел, который в осмотре не был осмотрен: код и название.
typedef UninspectedNode = ({String code, String name});

/// Общий итог осмотра от сервера: статус, его название и неосмотренные узлы. Все поля нового формата читаются
/// только здесь; старый сервер без них даёт null, и экраны показывают итог, как раньше.
@immutable
class InspectionVerdict {
  /// Создаёт итог.
  const InspectionVerdict({required this.status, required this.title, this.uninspected = const <UninspectedNode>[]});

  /// Статус «осмотр неполный».
  static const String incompleteStatus = 'incomplete';

  /// Из ответа сервера: GET /inspections/{id} и ответ завершения (summary.status, summary.status_title,
  /// summary.uninspected) или данные отчёта (overall.status, overall.title, uninspected верхнего уровня).
  /// Неизвестные и повреждённые поля пропускаются; null - сервер итога не прислал.
  static InspectionVerdict? fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> summary = j['summary'] is Map<String, dynamic> ? j['summary'] as Map<String, dynamic> : const {};
    final Map<String, dynamic> overall = j['overall'] is Map<String, dynamic> ? j['overall'] as Map<String, dynamic> : const {};
    String text(Object? v) => v is String ? v.trim() : '';
    final String status = text(summary['status']).isNotEmpty ? text(summary['status']) : text(overall['status']);
    final String title = text(summary['status_title']).isNotEmpty ? text(summary['status_title']) : text(overall['title']);
    final Object? raw = summary['uninspected'] is List ? summary['uninspected'] : j['uninspected'];
    final List<UninspectedNode> nodes = [
      if (raw is List)
        for (final Object? n in raw)
          if (n is Map && text(n['code'] ?? n['name']).isNotEmpty)
            (code: text(n['code'] ?? n['name']), name: text(n['name']).isNotEmpty ? text(n['name']) : text(n['code']))
          else if (n is String && n.trim().isNotEmpty)
            (code: n.trim(), name: n.trim()),
    ];
    if (title.isEmpty && nodes.isEmpty && status != incompleteStatus) {
      return null;
    }
    return InspectionVerdict(
      status: status.isEmpty && nodes.isNotEmpty ? incompleteStatus : status,
      title: title.isNotEmpty ? title : (status == incompleteStatus || (status.isEmpty && nodes.isNotEmpty) ? 'Осмотр неполный' : ''),
      uninspected: nodes,
    );
  }

  /// Статус сервера: ok, check, defect, incomplete.
  final String status;

  /// Название итога: «Осмотр неполный».
  final String title;

  /// Узлы без осмотра.
  final List<UninspectedNode> uninspected;

  /// Обход не закончен: статус «неполный» или есть неосмотренные узлы.
  bool get incomplete => status == incompleteStatus || uninspected.isNotEmpty;

  /// Неосмотренные узлы через запятую.
  String get uninspectedText => uninspected.map((UninspectedNode n) => n.name).join(', ');
}

/// Итог осмотра для экранов «Итог», «Осмотр сохранён», отчёта PDF и очереди отправки
/// (GET /inspections/{id}: coverage, findings, summary).
@immutable
class InspectionSummary {
  /// Создаёт итог.
  const InspectionSummary({
    required this.inspectionId,
    required this.unitId,
    required this.date,
    required this.start,
    required this.end,
    required this.duration,
    required this.nodesChecked,
    required this.nodesTotal,
    required this.rulesFired,
    required this.cameraDefects,
    required this.photos,
    required this.sizeMb,
    this.reportSizeMb = 0,
    this.reportPages = 0,
    this.findings = const <SummaryFinding>[],
    this.notes = const <SummaryNote>[],
    this.sentAt,
    this.reportAt,
    this.verdict,
  });

  /// Осмотр.
  final String inspectionId;

  /// Агрегат.
  final String unitId;

  /// Дата «14.11.2026».
  final String date;

  /// Начало «09:20».
  final String start;

  /// Окончание «09:34».
  final String end;

  /// Длительность «14 мин».
  final String duration;

  /// Осмотрено узлов.
  final int nodesChecked;

  /// Всего узлов.
  final int nodesTotal;

  /// Сработало правил.
  final int rulesFired;

  /// Дефектов, выделенных камерой.
  final int cameraDefects;

  /// Снимков.
  final int photos;

  /// Объём осмотра со снимками, МБ.
  final double sizeMb;

  /// Объём отчёта PDF, МБ; 0 - отчёт не сформирован.
  final double reportSizeMb;

  /// Страниц в отчёте PDF.
  final int reportPages;

  /// Находки.
  final List<SummaryFinding> findings;

  /// Заметки.
  final List<SummaryNote> notes;

  /// Когда осмотр передан на сервер цеха; null - ждёт отправки.
  final String? sentAt;

  /// Общий итог от сервера со списком неосмотренных узлов; null - сервер итога не прислал.
  final InspectionVerdict? verdict;

  /// Когда сформирован отчёт PDF.
  final String? reportAt;
}

/// Узел в маршруте осмотра (GET /equipment/{id}/route): порядок и причина приоритета.
@immutable
class RouteStep {
  /// Создаёт шаг маршрута.
  const RouteStep({
    required this.n,
    required this.nodeId,
    required this.name,
    required this.why,
    required this.reason,
    this.result,
    this.note = '',
  });

  /// Из ответа сервера (code, name, rank, group, reason); [index] - место узла в маршруте с нуля.
  factory RouteStep.fromJson(Map<String, dynamic> j, int index) => RouteStep(
        n: index + 1,
        nodeId: Json.str(j, 'code'),
        name: Json.str(j, 'name'),
        why: switch (Json.str(j, 'group')) {
          'previous_finding' => 'finding',
          final String g => g,
        },
        reason: Json.str(j, 'reason'),
        result: Json.strOrNull(j, 'result'),
        note: Json.str(j, 'note'),
      );

  /// Номер шага.
  final int n;

  /// Узел.
  final String nodeId;

  /// Название узла.
  final String name;

  /// Причина: finding, sensor, resource, routine.
  final String why;

  /// Пояснение причины.
  final String reason;

  /// Итог: ok, warn, bad, next или null (не осмотрен).
  final String? result;

  /// Итог осмотра узла словами инженера: «Шум со стороны привода»; пусто - нет записи.
  final String note;
}

/// Условие правила в разборе срабатывания: источник, условие, выполнено ли и что видно сейчас.
@immutable
class RuleCondition {
  /// Создаёт условие.
  const RuleCondition({required this.source, required this.label, this.what = '', required this.state, required this.value});

  /// Из ответа сервера (строка evidence с полем state или met).
  factory RuleCondition.fromJson(Map<String, dynamic> j) => RuleCondition(
        source: Json.str(j, 'source'),
        label: Json.str(j, 'label'),
        what: Json.str(j, 'what'),
        state: switch (Json.str(j, 'state', Json.flag(j, 'met') ? 'met' : 'unmet')) {
          'unmet' => 'not',
          'unknown' || 'weak' => 'missing',
          final String s => s,
        },
        value: Json.str(j, 'value'),
      );

  /// Источник: camera, sensor, data, manual.
  final String source;

  /// Подпись источника: «Камера», «Датчики», «Отметка инженера», «Нет данных», «Предупреждение».
  final String label;

  /// Условие; пусто - признак правила для этого источника ([RuleDef.camera] или [RuleDef.sensor]).
  final String what;

  /// Состояние: met (выполнено), not (не выполнено), missing (нет данных), soon (скоро).
  final String state;

  /// Что видно сейчас: значение, кадр, отметка.
  final String value;
}

/// Разбор правила по агрегату: вывод, сколько условий выполнено, условия и основания для показа (кадр, показание).
@immutable
class RuleCheck {
  /// Создаёт разбор.
  const RuleCheck({
    required this.ruleId,
    required this.unitId,
    required this.verdict,
    required this.count,
    this.conditions = const <RuleCondition>[],
    this.frameLabel,
    this.frameTime = '',
    this.chartKey,
  });

  /// Правило.
  final String ruleId;

  /// Агрегат.
  final String unitId;

  /// Вывод осторожной формулировкой: «Признаки возможного дефекта».
  final String verdict;

  /// Сколько условий выполнено: «Выполнено 3 из 3 условий».
  final String count;

  /// Условия.
  final List<RuleCondition> conditions;

  /// Подпись рамки распознавания на кадре-основании или null.
  final String? frameLabel;

  /// Время кадра-основания «09:31».
  final String frameTime;

  /// Ключ показания-основания или null.
  final String? chartKey;
}
