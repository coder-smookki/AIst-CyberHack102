import '../models/workflow.dart';

/// Задания, сообщения о неисправностях, уведомления, план ТО (/tasks, /fault-reports, /notifications).
abstract interface class WorkflowRepository {
  /// Задания; [assignee] - только задания этому сотруднику.
  Future<List<InspectionTask>> tasks({String? assignee});

  /// Задание по номеру.
  Future<InspectionTask> task(String id);

  /// Назначить осмотр инженеру.
  Future<InspectionTask> assignInspection({
    required String unitId,
    required String assignee,
    required String reason,
    required String due,
    String priority,
    String? faultReportId,
  });

  /// Виды неисправностей для сообщения оператора.
  Future<List<String>> faultKinds();

  /// Сообщения о неисправностях; [author] - только этого сотрудника.
  Future<List<FaultReport>> faultReports({String? author});

  /// Сообщение по номеру.
  Future<FaultReport> faultReport(String id);

  /// Сообщить о неисправности: мастер получает уведомление.
  Future<FaultReport> reportFault({required String unitId, required String kind, required String text, required String author});

  /// Лента уведомлений роли (ключ роли дизайна).
  Future<List<AppNotification>> notifications(String roleKey);

  /// Отметить уведомления роли прочитанными.
  Future<void> markNotificationsRead(String roleKey);

  /// План ТО.
  Future<List<PlanItem>> plan();

  /// Перенести работу плана.
  Future<PlanItem> movePlanItem(String id, {required String date, required String time});

  /// Назначить исполнителя работы плана.
  Future<PlanItem> assignPlanItem(String id, String who);
}
