import '../../api_exception.dart';
import '../../models/equipment.dart';
import '../../models/inspection.dart';
import '../../models/workflow.dart';
import '../../repositories/change_feed.dart';
import '../../repositories/inspection_repository.dart';
import '../mock_backend.dart';
import '../mock_db.dart';

/// Диагностика, осмотры и находки демонстрационного сервера.
class MockInspectionRepository implements InspectionRepository {
  /// Создаёт репозиторий поверх [backend].
  MockInspectionRepository(this.backend);

  /// Демонстрационный сервер.
  final MockBackend backend;

  MockDb get _db => backend.db;

  static const List<KvDomain> _all = [KvDomain.inspections, KvDomain.findings, KvDomain.equipment, KvDomain.notifications, KvDomain.workflow];

  Finding _finding(String id) =>
      _db.findings.where((Finding f) => f.id == id).firstOrNull ?? (throw const KvApiException(KvFailure.notFound, 'Находка не найдена'));

  Inspection _inspection(String id) =>
      _db.inspections.where((Inspection i) => i.id == id).firstOrNull ?? (throw const KvApiException(KvFailure.notFound, 'Осмотр не найден'));

  Finding _put(Finding f) {
    final int i = _db.findings.indexWhere((Finding x) => x.id == f.id);
    _db.findings[i] = f;
    return f;
  }

  void _putInspection(Inspection x) => _db.inspections[_db.inspections.indexWhere((Inspection i) => i.id == x.id)] = x;

  @override
  Future<List<RuleDef>> rules() => backend.read(() => List<RuleDef>.unmodifiable(_db.rules));

  @override
  Future<RuleDef> rule(String id) => backend.read(
        () => _db.rules.where((RuleDef r) => r.id == id).firstOrNull ?? (throw const KvApiException(KvFailure.notFound, 'Правило не найдено')),
      );

  @override
  Future<Map<int, String>> severityLabels() => backend.read(() => Map<int, String>.unmodifiable(_db.severityLabels));

  @override
  Future<List<DiagnosisResult>> diagnosis(String unitId) =>
      backend.read(() => List<DiagnosisResult>.unmodifiable(_db.diagnostics[backend.unitOf(unitId).id] ?? const <DiagnosisResult>[]));

  @override
  Future<List<RouteStep>> route(String unitId) => backend.read(() => List<RouteStep>.unmodifiable(_route(backend.unitOf(unitId))));

  /// Маршрут агрегата: заданный в демонстрационных данных или построенный по состоянию узлов.
  List<RouteStep> _route(Equipment u) => _db.routes[u.id] ?? _routeOfNodes(u);

  /// Маршрут по состоянию узлов: прошлые находки, отклонения датчиков, ресурс на исходе, плановые.
  List<RouteStep> _routeOfNodes(Equipment u) {
    final List<RouteStep> steps = [];
    int n = 0;
    String why(EquipmentNode node) => node.status == 'bad'
        ? 'finding'
        : node.status == 'warn'
            ? 'sensor'
            : (node.norm != null && (node.hours ?? 0) / node.norm! >= 0.8)
                ? 'resource'
                : 'routine';
    final List<EquipmentNode> ordered = [...u.nodes]..sort((EquipmentNode a, EquipmentNode b) => _rank(why(a)).compareTo(_rank(why(b))));
    for (final EquipmentNode node in ordered) {
      n += 1;
      final String w = why(node);
      steps.add(RouteStep(
        n: n,
        nodeId: node.id,
        name: node.name,
        why: w,
        reason: switch (w) {
          'finding' => 'Находка прошлого осмотра',
          'sensor' => 'Отклонение показаний',
          'resource' => 'Ресурс ${node.hours?.round()} из ${node.norm?.round()} ч',
          _ => 'Плановый осмотр',
        },
      ));
    }
    return steps;
  }

  static int _rank(String why) => const ['finding', 'sensor', 'resource', 'routine'].indexOf(why);

  @override
  Future<List<RouteStep>> markRouteStep(String unitId, String nodeId, {required String result, String note = ''}) =>
      backend.write([KvDomain.inspections], () {
        final Equipment u = backend.unitOf(unitId);
        final List<RouteStep> steps = [
          for (final RouteStep s in _route(u))
            s.nodeId == nodeId
                ? RouteStep(n: s.n, nodeId: s.nodeId, name: s.name, why: s.why, reason: s.reason, result: result, note: note)
                : (s.result == 'next' ? RouteStep(n: s.n, nodeId: s.nodeId, name: s.name, why: s.why, reason: s.reason) : s),
        ];
        final int next = steps.indexWhere((RouteStep s) => s.result == null);
        if (next >= 0) {
          final RouteStep s = steps[next];
          steps[next] = RouteStep(n: s.n, nodeId: s.nodeId, name: s.name, why: s.why, reason: s.reason, result: 'next');
        }
        _db.routes[u.id] = steps;
        if (nodeId == 'gauge') {
          _gaugeRead(u.id, note);
        }
        return List<RouteStep>.unmodifiable(steps);
      });

  /// Показание манометра считано: правило R05 получает данные для сверки с датчиком.
  void _gaugeRead(String unitId, String note) {
    final String key = '$unitId/R05';
    final RuleCheck? old = _db.ruleChecks[key];
    if (old == null) {
      return;
    }
    _db.ruleChecks[key] = RuleCheck(
      ruleId: old.ruleId,
      unitId: old.unitId,
      verdict: 'Признаков не выявлено',
      count: 'Расхождение манометра и датчика в пределах 15 %',
      conditions: [
        for (final RuleCondition c in old.conditions)
          c.state == 'missing'
              ? RuleCondition(source: c.source, label: c.label, what: c.what, state: 'not', value: 'Манометр ${note.isEmpty ? 'считан' : note} · кадр ${backend.timeNow}')
              : c,
      ],
      frameLabel: old.frameLabel,
      frameTime: backend.timeNow,
      chartKey: old.chartKey,
    );
  }

  @override
  Future<RuleCheck> ruleCheck(String unitId, String ruleId) => backend.read(() {
        final Equipment u = backend.unitOf(unitId);
        final RuleCheck? seeded = _db.ruleChecks['${u.id}/$ruleId'];
        if (seeded != null) {
          return seeded;
        }
        final DiagnosisResult? fired = (_db.diagnostics[u.id] ?? const <DiagnosisResult>[]).where((DiagnosisResult d) => d.ruleId == ruleId).firstOrNull;
        if (fired == null) {
          return RuleCheck(ruleId: ruleId, unitId: u.id, verdict: 'Признаков не выявлено', count: 'Условия правила не выполнены');
        }
        final int met = fired.evidence.where((Evidence e) => e.met).length;
        return RuleCheck(
          ruleId: ruleId,
          unitId: u.id,
          verdict: fired.result == 'match' ? 'Признаки возможного дефекта' : 'Рекомендуется проверка',
          count: 'Выполнено $met из ${fired.evidence.length} условий',
          conditions: [
            for (final Evidence e in fired.evidence)
              RuleCondition(
                source: e.source,
                label: switch (e.source) {
                  'camera' => 'Камера',
                  'sensor' => 'Датчики',
                  'manual' => 'Отметка инженера',
                  _ => 'Данные',
                },
                state: e.met ? 'met' : 'not',
                value: e.text,
              ),
          ],
        );
      });

  @override
  Future<List<ChecklistItem>> checklist(String inspectionId) => backend.read(() => List<ChecklistItem>.unmodifiable(_db.checklist));

  @override
  Future<List<Detection>> detections(String unitId) => backend.read(() {
        final String id = backend.unitOf(unitId).id;
        return _db.detections.where((Detection d) => d.unitId.isEmpty || d.unitId == id).toList(growable: false);
      });

  @override
  Future<List<Inspection>> inspections({String? unitId}) => backend.read(
        () => _db.inspections.where((Inspection i) => unitId == null || i.unitId == backend.unitOf(unitId).id).toList(growable: false),
      );

  @override
  Future<Inspection> inspection(String id) => backend.read(() => _inspection(id));

  @override
  Future<InspectionSummary> summary(String inspectionId) => backend.read(
        () => _db.summaries[inspectionId] ?? (throw const KvApiException(KvFailure.notFound, 'Итог осмотра не найден')),
      );

  @override
  Future<List<HistoryEvent>> activity() => backend.read(() => List<HistoryEvent>.unmodifiable(_db.activity));

  @override
  Future<Inspection?> activeInspection(String unitId) => backend.read(
        () => _db.inspections.where((Inspection i) => i.unitId == backend.unitOf(unitId).id && i.status == 'draft').firstOrNull,
      );

  @override
  Future<Inspection> start(String unitId) => backend.write([KvDomain.inspections], () {
        final String id = backend.unitOf(unitId).id;
        final Inspection? open = _db.inspections.where((Inspection i) => i.unitId == id && i.status == 'draft').firstOrNull;
        if (open != null) {
          return open;
        }
        final Inspection created = Inspection(
          id: _db.nextId('INS-', 2209),
          unitId: id,
          date: backend.dateNow,
          time: backend.timeNow,
          duration: '0 мин',
          who: backend.currentUserName,
          status: 'draft',
          defects: 0,
          checks: 0,
          note: 'Идёт сейчас',
        );
        _db.inspections.insert(0, created);
        return created;
      });

  @override
  Future<Finding> addFinding(
    String inspectionId, {
    required String node,
    required String title,
    required String ruleId,
    required int severity,
    String? comment,
    List<String> evidence = const <String>[],
  }) =>
      backend.write(_all, () {
        final Inspection ins = _inspection(inspectionId);
        final Equipment u = backend.unitOf(ins.unitId);
        final RuleDef? rule = _db.rules.where((RuleDef r) => r.id == ruleId).firstOrNull;
        final Finding f = Finding(
          id: _db.nextId('F-', 1043),
          unitId: u.id,
          title: title,
          ruleId: ruleId,
          severity: severity,
          status: 'new',
          source: 'Осмотр ${ins.id}',
          date: backend.dateNow,
          time: backend.timeNow,
          author: backend.currentUserName,
          node: node,
          evidence: evidence,
          recommendation: rule?.recommendation ?? '',
          comment: comment,
        );
        _db.findings.insert(0, f);
        _putInspection(ins.copyWith(defects: ins.defects + 1, findingIds: [...ins.findingIds, f.id]));
        backend.putUnit(u.copyWith(openFindings: u.openFindings + 1));
        backend.pushHistory(u.id, status: severity >= 3 ? 'bad' : 'warn', title: 'Находка: ${title.toLowerCase()}', text: 'Осмотр ${ins.id} · правило $ruleId');
        backend.pushNotification('master', kind: 'bad', title: 'Новая находка ждёт подтверждения', text: '${u.code} · ${title.toLowerCase()} · $ruleId', target: '/master/findings');
        return f;
      });

  @override
  Future<void> addWork(String inspectionId, String unitId, {required WorkKind kind, String? node, String? comment, String? maintenanceCode}) =>
      backend.write(const [KvDomain.inspections, KvDomain.equipment], () {
        _inspection(inspectionId);
        final Equipment u = backend.unitOf(unitId);
        final String what = switch (kind) {
          WorkKind.maintenance => 'Обслуживание${maintenanceCode == null ? '' : ' $maintenanceCode'}',
          WorkKind.replacement => 'Замена узла',
          WorkKind.note => 'Заметка',
        };
        final String text = (comment ?? '').trim();
        backend.pushHistory(u.id, status: 'info', title: node == null ? what : '$what: $node', text: text.isEmpty ? 'Осмотр $inspectionId' : text);
      });

  @override
  Future<List<MaintenanceKind>> maintenanceKinds(String unitId) => backend.read(
        () => [for (final MaintenanceItem m in backend.unitOf(unitId).maintenance) (code: m.code, name: m.code)],
      );

  @override
  Future<void> dismissDetection(String inspectionId, String label) => backend.write([KvDomain.inspections], () {
        _inspection(inspectionId);
        backend.pushSysLog('info', 'Модели', 'Отметка «не дефект»: $label, кадр сохранён для проверки модели');
      });

  @override
  Future<Inspection> finish(String inspectionId) => backend.write(_all, () {
        final Inspection ins = _inspection(inspectionId);
        final Equipment u = backend.unitOf(ins.unitId);
        final Inspection done = ins.copyWith(status: 'done', checks: _db.checklist.length, duration: ins.duration == '0 мин' ? '14 мин' : ins.duration, note: ins.defects == 0 ? 'Внешних дефектов не выявлено' : 'Находок: ${ins.defects}');
        _putInspection(done);
        for (int i = 0; i < _db.tasks.length; i++) {
          final InspectionTask t = _db.tasks[i];
          if (t.unitId == u.id && t.status != 'done' && t.to == ins.who) {
            _db.tasks[i] = t.copyWith(status: 'done', statusLabel: 'Выполнено');
            backend.pushNotification('master', kind: 'ok', title: 'Осмотр по заданию выполнен', text: '${ins.who} осмотрел ${u.code}', target: '/master/shift');
            if (t.faultReportId != null) {
              final int r = _db.faultReports.indexWhere((FaultReport f) => f.id == t.faultReportId);
              if (r >= 0) {
                final FaultReport fr = _db.faultReports[r];
                _db.faultReports[r] = fr.copyWith(
                  status: 'inspected',
                  statusLabel: 'Осмотр выполнен',
                  timeline: [...fr.timeline, FaultStep(time: backend.timeNow, title: 'Осмотр выполнен', who: ins.who)],
                );
                backend.pushNotification('operator', kind: 'ok', title: 'Осмотр по сообщению выполнен', text: '${u.code} · ${ins.who}', target: '/operator/history');
              }
            }
          }
        }
        backend.pushHistory(u.id, status: ins.defects > 0 ? 'warn' : 'info', title: 'Осмотр ${ins.id}', text: done.note);
        return done;
      });

  @override
  Future<List<Finding>> findings({String? status, String? unitId}) => backend.read(
        () => _db.findings
            .where((Finding f) => (status == null || f.status == status) && (unitId == null || f.unitId == backend.unitOf(unitId).id))
            .toList(growable: false),
      );

  @override
  Future<Finding> finding(String id) => backend.read(() => _finding(id));

  @override
  Future<Finding> confirmFinding(String id, {bool keepRunning = false, String? justification}) => backend.write(_all, () {
        final Finding f = _finding(id);
        final Equipment u = backend.unitOf(f.unitId);
        if (f.severity >= 3 && !keepRunning && u.mode == 'running') {
          backend.putUnit(u.copyWith(mode: 'reserve', modeLabel: 'В резерве'));
          backend.pushNotification('operator', kind: 'info', title: '${u.code} переведён в резерв', text: 'Решение мастера по находке ${f.id}', target: '/operator/objects');
        }
        backend.pushHistory(u.id, status: 'info', title: 'Находка ${f.id} подтверждена', text: keepRunning ? 'Оставлен в работе до ТО-2' : f.title);
        backend.pushNotification('engineer', kind: 'info', title: 'Находка ${f.id} подтверждена', text: '${u.code} · ${backend.currentUserName}', target: '/engineer/history');
        return _put(f.copyWith(
          status: 'confirmed',
          confirmedBy: backend.currentUserName,
          confirmedAt: backend.timeNow,
          keepRunning: keepRunning,
          masterComment: justification,
        ));
      });

  @override
  Future<Finding> rejectFinding(String id, {required String reason, required String note}) => backend.write(_all, () {
        final Finding f = _finding(id);
        final Equipment u = backend.unitOf(f.unitId);
        backend.putUnit(u.copyWith(openFindings: (u.openFindings - 1).clamp(0, 99)));
        backend.pushHistory(u.id, status: 'info', title: 'Находка ${f.id} отклонена', text: reason);
        return _put(f.copyWith(status: 'rejected', rejectReason: reason, closedNote: note, closedBy: backend.currentUserName, rejectedAt: backend.timeNow));
      });

  @override
  Future<Finding> scheduleFinding(String id, {required String when}) => backend.write([..._all, KvDomain.plan], () {
        final Finding f = _finding(id);
        final Equipment u = backend.unitOf(f.unitId);
        final List<String> parts = when.split(', ');
        _db.plan.add(PlanItem(
          id: _db.nextId('P-', 505),
          unitId: u.id,
          work: f.title,
          date: parts.first,
          time: parts.length > 1 ? parts[1] : '09:00',
          who: 'не назначен',
          status: 'planned',
          basis: 'Находка ${f.id}',
        ));
        return _put(f.copyWith(status: 'planned', planned: when));
      });

  @override
  Future<Finding> commentFinding(String id, String text) => backend.write([KvDomain.findings], () => _put(_finding(id).copyWith(masterComment: text)));

  @override
  Future<Finding> reopenFinding(String id) => backend.write(_all, () {
        final Finding f = _finding(id);
        final Equipment u = backend.unitOf(f.unitId);
        backend.putUnit(u.copyWith(openFindings: u.openFindings + 1));
        backend.pushHistory(u.id, status: 'info', title: 'Находка ${f.id} возвращена на подтверждение', text: f.title);
        return _put(f.copyWith(status: 'new'));
      });
}
