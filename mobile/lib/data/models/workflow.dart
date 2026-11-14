import 'package:flutter/foundation.dart';

import 'json.dart';

/// Задание мастера инженеру на осмотр (GET /tasks, task_view).
@immutable
class InspectionTask {
  /// Создаёт задание.
  const InspectionTask({
    required this.id,
    required this.unitId,
    required this.title,
    required this.due,
    required this.from,
    required this.to,
    required this.status,
    required this.statusLabel,
    required this.reason,
    this.priority = 'normal',
    this.faultReportId,
    this.assignedAt = '',
    this.instructions = '',
  });

  /// Из ответа сервера.
  factory InspectionTask.fromJson(Map<String, dynamic> j) => InspectionTask(
        assignedAt: _clock(Json.time(j, 'created_at')),
        instructions: Json.str(j, 'instructions'),
        id: Json.str(j, 'id'),
        unitId: Json.str(j, 'equipment_id'),
        title: Json.str(j, 'title', Json.str(j, 'reason')),
        due: Json.str(j, 'due_date'),
        from: Json.str(Json.obj(j, 'assigned_by'), 'name'),
        to: Json.str(Json.obj(j, 'assignee'), 'name'),
        status: switch (Json.str(j, 'status')) {
          'done' => 'done',
          'cancelled' => 'cancelled',
          _ => 'progress',
        },
        statusLabel: Json.str(j, 'status_title'),
        reason: Json.str(j, 'reason'),
        priority: Json.str(j, 'priority', 'normal'),
        faultReportId: Json.strOrNull(Json.obj(j, 'fault_report'), 'id'),
      );

  /// «T-318».
  final String id;

  /// Агрегат.
  final String unitId;

  /// Заголовок.
  final String title;

  /// Срок «14.11, 10:00».
  final String due;

  /// От кого.
  final String from;

  /// Кому.
  final String to;

  /// new, progress, done, cancelled.
  final String status;

  /// «Выполняется».
  final String statusLabel;

  /// Причина.
  final String reason;

  /// low, normal, high, urgent.
  final String priority;

  /// Сообщение оператора, по которому назначено.
  final String? faultReportId;

  /// Когда назначено, «09:12» (created_at сервера).
  final String assignedAt;

  /// Что сделать на месте: указание мастера к осмотру (поле дизайна; сервер пока передаёт только reason).
  final String instructions;

  /// Время «09:12» из момента ISO; пустая строка без момента.
  static String _clock(DateTime? at) => at == null ? '' : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

  /// Копия с другим состоянием.
  InspectionTask copyWith({String? status, String? statusLabel, String? assignedAt, String? instructions}) => InspectionTask(
        id: id,
        unitId: unitId,
        title: title,
        due: due,
        from: from,
        to: to,
        status: status ?? this.status,
        statusLabel: statusLabel ?? this.statusLabel,
        reason: reason,
        priority: priority,
        faultReportId: faultReportId,
        assignedAt: assignedAt ?? this.assignedAt,
        instructions: instructions ?? this.instructions,
      );
}

/// Шаг хронологии сообщения о неисправности.
@immutable
class FaultStep {
  /// Создаёт шаг.
  const FaultStep({required this.time, required this.title, required this.who});

  /// Время.
  final String time;

  /// Что произошло.
  final String title;

  /// Кто.
  final String who;
}

/// Сообщение оператора о неисправности (GET /fault-reports, fault_view).
@immutable
class FaultReport {
  /// Создаёт сообщение.
  const FaultReport({
    required this.id,
    required this.unitId,
    required this.author,
    required this.date,
    required this.time,
    required this.kind,
    required this.text,
    required this.status,
    required this.statusLabel,
    this.timeline = const <FaultStep>[],
  });

  /// Из ответа сервера.
  factory FaultReport.fromJson(Map<String, dynamic> j) => FaultReport(
        id: Json.str(j, 'id'),
        unitId: Json.str(j, 'equipment_id'),
        author: Json.str(Json.obj(j, 'author'), 'name'),
        date: Json.str(j, 'date'),
        time: Json.str(j, 'time'),
        kind: Json.list(j, 'signs', (Map<String, dynamic> s) => Json.str(s, 'title')).join(', '),
        text: Json.str(j, 'comment'),
        status: Json.str(j, 'status'),
        statusLabel: Json.str(j, 'status_title'),
      );

  /// «S-077».
  final String id;

  /// Агрегат.
  final String unitId;

  /// Автор.
  final String author;

  /// Дата.
  final String date;

  /// Время.
  final String time;

  /// Вид неисправности: «Течь».
  final String kind;

  /// Описание.
  final String text;

  /// new, assigned, repair, closed, rejected.
  final String status;

  /// «На ремонте».
  final String statusLabel;

  /// Хронология обработки.
  final List<FaultStep> timeline;

  /// Копия с другим состоянием и новым шагом.
  FaultReport copyWith({String? status, String? statusLabel, List<FaultStep>? timeline}) => FaultReport(
        id: id,
        unitId: unitId,
        author: author,
        date: date,
        time: time,
        kind: kind,
        text: text,
        status: status ?? this.status,
        statusLabel: statusLabel ?? this.statusLabel,
        timeline: timeline ?? this.timeline,
      );
}

/// Уведомление в ленте сотрудника (GET /notifications).
@immutable
class AppNotification {
  /// Создаёт уведомление.
  const AppNotification({required this.id, required this.time, required this.kind, required this.title, required this.text, this.target, this.read = false});

  /// Из ответа сервера.
  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: Json.str(j, 'id'),
        time: Json.str(j, 'at'),
        kind: Json.str(j, 'kind'),
        title: Json.str(j, 'title'),
        text: Json.str(j, 'text'),
        target: Json.strOrNull(j, 'deeplink'),
      );

  /// Номер.
  final String id;

  /// Время «09:12» или «вчера».
  final String time;

  /// Тон: bad, warn, info, ok.
  final String kind;

  /// Заголовок.
  final String title;

  /// Текст.
  final String text;

  /// Куда ведёт касание: путь экрана приложения или ссылка kstvizor://.
  final String? target;

  /// Прочитано.
  final bool read;
}

/// Работа в плане ТО (KV.data.plan).
@immutable
class PlanItem {
  /// Создаёт работу.
  const PlanItem({required this.id, required this.unitId, required this.work, required this.date, required this.time, required this.who, required this.status, required this.basis});

  /// «P-501».
  final String id;

  /// Агрегат.
  final String unitId;

  /// Состав работ.
  final String work;

  /// Дата.
  final String date;

  /// Время.
  final String time;

  /// Исполнитель или «не назначен».
  final String who;

  /// planned или draft.
  final String status;

  /// Основание.
  final String basis;

  /// Копия с другой датой, временем или исполнителем.
  PlanItem copyWith({String? date, String? time, String? who, String? status}) => PlanItem(
        id: id,
        unitId: unitId,
        work: work,
        date: date ?? this.date,
        time: time ?? this.time,
        who: who ?? this.who,
        status: status ?? this.status,
        basis: basis,
      );
}

/// Отчёт PDF или Excel (GET /inspections/{id}/report.pdf|.xlsx).
@immutable
class Report {
  /// Создаёт отчёт.
  const Report({required this.id, required this.title, required this.format, required this.createdAt, required this.size, this.unitId, this.inspectionId});

  /// Номер.
  final String id;

  /// Название.
  final String title;

  /// pdf или xlsx.
  final String format;

  /// Когда сформирован.
  final String createdAt;

  /// Размер.
  final String size;

  /// Агрегат.
  final String? unitId;

  /// Осмотр.
  final String? inspectionId;
}

/// Сообщение в диалоге с ассистентом (POST /assistant/ask).
@immutable
class AssistantMessage {
  /// Создаёт сообщение.
  const AssistantMessage({
    required this.fromUser,
    required this.text,
    this.refs = const <String>[],
    this.links = const <AssistantLink>[],
    this.time,
    this.source,
    this.found = true,
    this.facts = const <AssistantFact>[],
  });

  /// Ответ ассистента из ответа сервера.
  factory AssistantMessage.fromAnswer(Map<String, dynamic> j) => AssistantMessage(
        fromUser: false,
        text: Json.str(j, 'answer'),
        links: Json.list(j, 'links', AssistantLink.fromJson),
        source: Json.strOrNull(j, 'source'),
        found: Json.flag(j, 'found', true),
        facts: Json.list(j, 'facts', AssistantFact.fromJson),
      );

  /// Время сообщения «09:38»; null - не передано.
  final String? time;

  /// Откуда ответ: «По данным датчиков и истории Н-101».
  final String? source;

  /// Ответ найден в данных; false - «Записей не нашёл».
  final bool found;

  /// Строки-сводка ответа: «15.11, 08:00» - «АМС-2 · ремонт уплотнения».
  final List<AssistantFact> facts;

  /// Написал сотрудник.
  final bool fromUser;

  /// Текст.
  final String text;

  /// Ссылки на источники: «R08», «Паспорт IL 65/160, с. 34».
  final List<String> refs;

  /// Переходы, которые открывает приложение.
  final List<AssistantLink> links;
}

/// Ссылка из ответа ассистента.
@immutable
class AssistantLink {
  /// Создаёт ссылку.
  const AssistantLink({required this.title, required this.deeplink, required this.kind});

  /// Из ответа сервера.
  factory AssistantLink.fromJson(Map<String, dynamic> j) =>
      AssistantLink(title: Json.str(j, 'title'), deeplink: Json.str(j, 'deeplink'), kind: Json.str(j, 'kind'));

  /// Подпись.
  final String title;

  /// kstvizor://...
  final String deeplink;

  /// Вид объекта.
  final String kind;
}

/// Строка сводки в ответе ассистента: выделенная метка и текст.
@immutable
class AssistantFact {
  /// Создаёт строку.
  const AssistantFact({required this.label, required this.text});

  /// Из ответа сервера.
  factory AssistantFact.fromJson(Map<String, dynamic> j) => AssistantFact(label: Json.str(j, 'label'), text: Json.str(j, 'text'));

  /// Метка: «15.11, 08:00», «через 10 ч».
  final String label;

  /// Текст: «АМС-2 · ремонт уплотнения».
  final String text;
}
