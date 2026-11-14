import '../../api_exception.dart';
import '../../models/equipment.dart';
import '../../models/workflow.dart';
import '../../repositories/change_feed.dart';
import '../../repositories/workflow_repository.dart';
import '../mock_backend.dart';
import '../mock_db.dart';

/// Задания, сообщения, уведомления и план ТО демонстрационного сервера.
class MockWorkflowRepository implements WorkflowRepository {
  /// Создаёт репозиторий поверх [backend].
  MockWorkflowRepository(this.backend);

  /// Демонстрационный сервер.
  final MockBackend backend;

  MockDb get _db => backend.db;

  @override
  Future<List<InspectionTask>> tasks({String? assignee}) =>
      backend.read(() => _db.tasks.where((InspectionTask t) => assignee == null || t.to == assignee).toList(growable: false));

  @override
  Future<InspectionTask> task(String id) => backend.read(
        () => _db.tasks.where((InspectionTask t) => t.id == id).firstOrNull ?? (throw const KvApiException(KvFailure.notFound, 'Задание не найдено')),
      );

  @override
  Future<InspectionTask> assignInspection({
    required String unitId,
    required String assignee,
    required String reason,
    required String due,
    String priority = 'normal',
    String? faultReportId,
  }) =>
      backend.write([KvDomain.workflow, KvDomain.notifications], () {
        final Equipment u = backend.unitOf(unitId);
        final InspectionTask t = InspectionTask(
          id: _db.nextId('T-', 319),
          unitId: u.id,
          title: faultReportId != null ? 'Осмотр по сообщению оператора' : 'Осмотр: $reason',
          due: due,
          from: backend.currentUserName,
          to: assignee,
          status: 'new',
          statusLabel: 'Назначено',
          reason: reason,
          priority: priority,
          faultReportId: faultReportId,
        );
        _db.tasks.insert(0, t);
        backend.pushNotification('engineer', kind: 'info', title: 'Новое задание от мастера', text: '${u.code} · ${t.title.toLowerCase()} до $due', target: '/engineer/objects/card/${u.id}');
        if (faultReportId != null) {
          final int i = _db.faultReports.indexWhere((FaultReport f) => f.id == faultReportId);
          if (i >= 0) {
            final FaultReport f = _db.faultReports[i];
            _db.faultReports[i] = f.copyWith(
              status: 'assigned',
              statusLabel: 'Назначен осмотр',
              timeline: [...f.timeline, FaultStep(time: backend.timeNow, title: 'Мастер назначил осмотр', who: '${backend.currentUserName} → $assignee')],
            );
            backend.pushNotification('operator', kind: 'ok', title: 'Сообщение принято мастером', text: 'Осмотр назначен инженеру', target: '/operator/history');
          }
        }
        return t;
      });

  @override
  Future<List<String>> faultKinds() => backend.read(() => List<String>.unmodifiable(_db.faultKinds));

  @override
  Future<List<FaultReport>> faultReports({String? author}) =>
      backend.read(() => _db.faultReports.where((FaultReport f) => author == null || f.author == author).toList(growable: false));

  @override
  Future<FaultReport> faultReport(String id) => backend.read(
        () => _db.faultReports.where((FaultReport f) => f.id == id).firstOrNull ?? (throw const KvApiException(KvFailure.notFound, 'Сообщение не найдено')),
      );

  @override
  Future<FaultReport> reportFault({required String unitId, required String kind, required String text, required String author}) =>
      backend.write([KvDomain.workflow, KvDomain.notifications, KvDomain.equipment], () {
        final Equipment u = backend.unitOf(unitId);
        final FaultReport f = FaultReport(
          id: _db.nextId('S-0', 77),
          unitId: u.id,
          author: author,
          date: backend.dateNow,
          time: backend.timeNow,
          kind: kind,
          text: text,
          status: 'new',
          statusLabel: 'Отправлено мастеру',
          timeline: [FaultStep(time: backend.timeNow, title: 'Сообщение отправлено', who: author)],
        );
        _db.faultReports.insert(0, f);
        backend.pushHistory(u.id, status: 'warn', title: 'Сообщение о неисправности', text: text.isEmpty ? kind : text, who: author);
        backend.pushNotification('master', kind: 'bad', title: 'Оператор сообщил о неисправности', text: '${u.code} · ${kind.toLowerCase()}', target: '/master/shift');
        return f;
      });

  @override
  Future<List<AppNotification>> notifications(String roleKey) =>
      backend.read(() => List<AppNotification>.unmodifiable(_db.notifications[roleKey] ?? const <AppNotification>[]));

  @override
  Future<void> markNotificationsRead(String roleKey) => backend.write([KvDomain.notifications], () {
        final List<AppNotification>? list = _db.notifications[roleKey];
        if (list == null) {
          return;
        }
        for (int i = 0; i < list.length; i++) {
          final AppNotification n = list[i];
          list[i] = AppNotification(id: n.id, time: n.time, kind: n.kind, title: n.title, text: n.text, target: n.target, read: true);
        }
      });

  @override
  Future<List<PlanItem>> plan() => backend.read(() => List<PlanItem>.unmodifiable(_db.plan));

  PlanItem _replace(String id, PlanItem Function(PlanItem) f) {
    final int i = _db.plan.indexWhere((PlanItem p) => p.id == id);
    if (i < 0) {
      throw const KvApiException(KvFailure.notFound, 'Работа не найдена');
    }
    return _db.plan[i] = f(_db.plan[i]);
  }

  @override
  Future<PlanItem> movePlanItem(String id, {required String date, required String time}) =>
      backend.write([KvDomain.plan], () => _replace(id, (PlanItem p) => p.copyWith(date: date, time: time)));

  @override
  Future<PlanItem> assignPlanItem(String id, String who) =>
      backend.write([KvDomain.plan], () => _replace(id, (PlanItem p) => p.copyWith(who: who, status: 'planned')));
}
