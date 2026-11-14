import '../models/inspection.dart';

/// Диагностика, осмотры и находки (GET /equipment/{id}/diagnosis, /route; /inspections; /inspections/findings).
abstract interface class InspectionRepository {
  /// Все правила диагностики.
  Future<List<RuleDef>> rules();

  /// Правило по коду.
  Future<RuleDef> rule(String id);

  /// Подписи тяжести правил 1-3.
  Future<Map<int, String>> severityLabels();

  /// Результаты правил по агрегату в текущем осмотре.
  Future<List<DiagnosisResult>> diagnosis(String unitId);

  /// Маршрут осмотра: узлы по приоритету.
  Future<List<RouteStep>> route(String unitId);

  /// Отметить итог осмотра узла [nodeId] маршрута; следующий неосмотренный узел становится «далее». Возвращает маршрут.
  Future<List<RouteStep>> markRouteStep(String unitId, String nodeId, {required String result, String note = ''});

  /// Разбор правила [ruleId] по агрегату: условия, основания и вывод.
  Future<RuleCheck> ruleCheck(String unitId, String ruleId);

  /// Чек-лист осмотра.
  Future<List<ChecklistItem>> checklist(String inspectionId);

  /// Рамки распознавания на текущем кадре.
  Future<List<Detection>> detections(String unitId);

  /// Осмотры, новые сверху; [unitId] - только по агрегату.
  Future<List<Inspection>> inspections({String? unitId});

  /// Осмотр по номеру.
  Future<Inspection> inspection(String id);

  /// Итог осмотра: полнота обхода, находки с основаниями, снимки и отчёт.
  Future<InspectionSummary> summary(String inspectionId);

  /// Лента осмотров и событий по всем агрегатам, новые сверху.
  Future<List<HistoryEvent>> activity();

  /// Идущий осмотр агрегата или null.
  Future<Inspection?> activeInspection(String unitId);

  /// Начать осмотр.
  Future<Inspection> start(String unitId);

  /// Зафиксировать находку в осмотре.
  Future<Finding> addFinding(
    String inspectionId, {
    required String node,
    required String title,
    required String ruleId,
    required int severity,
    String? comment,
    List<String> evidence,
  });

  /// Отметить признак камеры «не дефект».
  Future<void> dismissDetection(String inspectionId, String label);

  /// Завершить осмотр; задания по агрегату закрываются.
  Future<Inspection> finish(String inspectionId);

  /// Находки с отбором по статусу и агрегату.
  Future<List<Finding>> findings({String? status, String? unitId});

  /// Находка по номеру.
  Future<Finding> finding(String id);

  /// Подтвердить находку; тяжесть 3 по умолчанию переводит агрегат в резерв, [keepRunning] - оставить в работе с обоснованием.
  Future<Finding> confirmFinding(String id, {bool keepRunning = false, String? justification});

  /// Отклонить находку с причиной и описанием проверки на месте.
  Future<Finding> rejectFinding(String id, {required String reason, required String note});

  /// Запланировать работу по находке.
  Future<Finding> scheduleFinding(String id, {required String when});

  /// Комментарий мастера к находке.
  Future<Finding> commentFinding(String id, String text);

  /// Вернуть отклонённую находку на подтверждение мастеру.
  Future<Finding> reopenFinding(String id);
}
