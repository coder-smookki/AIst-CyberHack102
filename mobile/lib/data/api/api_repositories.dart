import 'dart:async';

import '../api_exception.dart';
import '../models/auth.dart';
import '../models/equipment.dart';
import '../models/inspection.dart';
import '../models/json.dart';
import '../models/people.dart';
import '../models/workflow.dart';
import '../repositories/assistant_repository.dart';
import '../repositories/auth_repository.dart';
import '../repositories/change_feed.dart';
import '../repositories/equipment_repository.dart';
import '../repositories/inspection_repository.dart';
import '../repositories/report_repository.dart';
import '../repositories/telemetry_repository.dart';
import 'api_client.dart';
import 'api_feed.dart';
import 'api_mappers.dart';

/// Номер записи настоящего сервера (целое число); номера демонстрационных данных («INS-2209») сюда не подходят.
bool isServerId(String id) => int.tryParse(id) != null;

/// Вход на настоящем сервере. Сведения, которых сервер не хранит (должность, смена, сохранённая учётная запись,
/// контакты), остаются демонстрационными: параллельный вход в демонстрационный сервер даёт экранам других ролей контекст.
class ApiAuthRepository implements AuthRepository {
  /// Создаёт репозиторий.
  ApiAuthRepository(this.api, this.mock, this.feed);

  /// Клиент сервера.
  final ApiClient api;

  /// Демонстрационный вход для сведений дизайна.
  final AuthRepository mock;

  /// Поток изменений.
  final ApiFeed feed;

  AuthSession? _session;
  String? _password;

  AuthSession _merge(Map<String, dynamic> j, AuthSession? design) {
    final AppUser u = AppUser.fromJson(Json.obj(j, 'user'));
    final AppUser? d = design?.user;
    api
      ..accessToken = Json.str(j, 'access_token')
      ..refreshToken = Json.str(j, 'refresh_token');
    final AuthSession s = AuthSession(
      user: AppUser(
        id: u.id,
        email: u.email,
        name: u.name,
        roleCode: u.roleCode,
        roleTitle: u.roleTitle,
        permissions: u.permissions,
        mustChangePassword: u.mustChangePassword,
        title: d?.title ?? u.roleTitle,
        phone: d?.phone ?? '',
        shift: d?.shift ?? '',
      ),
      accessToken: api.accessToken!,
      refreshToken: api.refreshToken!,
      biometricsAllowed: Json.flag(j, 'biometrics_allowed', true),
    );
    _session = s;
    return s;
  }

  Future<AuthSession?> _design(String email, String password) async {
    try {
      return await mock.login(email, password);
    } on Object {
      return null;
    }
  }

  @override
  Future<AuthSession> login(String email, String password) async {
    final dynamic j = await api.postJson('/auth/login', {'email': email.trim(), 'password': password, 'device': 'КСТ Визор'}, false);
    _password = password;
    return _merge(j as Map<String, dynamic>, await _design(email, password));
  }

  @override
  Future<AuthSession> loginWithBiometrics(String refreshToken) async {
    final String token = api.refreshToken ?? refreshToken;
    final dynamic j = await api.postJson('/auth/refresh', {'refresh_token': token, 'biometric': true}, false);
    return _merge(j as Map<String, dynamic>, _session);
  }

  @override
  Future<AuthSession> changePassword(String newPassword, {String? currentPassword}) async {
    await api.postJson('/auth/password', {'current_password': currentPassword ?? _password ?? '', 'new_password': newPassword});
    _password = newPassword;
    final dynamic me = await api.getJson('/auth/me');
    final AuthSession? s = _session;
    if (s == null) {
      throw const KvApiException(KvFailure.invalidCredentials, 'Сеанс завершён - войдите заново');
    }
    final AppUser u = AppUser.fromJson(me as Map<String, dynamic>);
    _session = AuthSession(
      user: AppUser(
        id: u.id,
        email: u.email,
        name: u.name,
        roleCode: u.roleCode,
        roleTitle: u.roleTitle,
        permissions: u.permissions,
        mustChangePassword: u.mustChangePassword,
        title: s.user.title,
        phone: s.user.phone,
        shift: s.user.shift,
      ),
      accessToken: api.accessToken ?? s.accessToken,
      refreshToken: api.refreshToken ?? s.refreshToken,
      biometricsAllowed: s.biometricsAllowed,
    );
    return _session!;
  }

  @override
  Future<List<String>> passwordProblems(String password) => mock.passwordProblems(password);

  @override
  Future<void> logout() async {
    try {
      await api.postJson('/auth/logout');
    } on KvApiException {
      api.accessToken = null;
    }
    api
      ..accessToken = null
      ..lastFrame = null;
    _session = null;
    try {
      await mock.logout();
    } on Object {
      return;
    }
  }

  @override
  Future<LoginPreset?> scenarioLogin(String scenario) async => null;

  @override
  Future<SavedAccount?> savedAccount() => mock.savedAccount();

  @override
  Future<ConnectionInfo> connectionInfo() => mock.connectionInfo();

  @override
  Future<SupportContact> securityContact() => mock.securityContact();

  @override
  Future<BlockedAccount?> blockedAccount(String email) => mock.blockedAccount(email);

  @override
  Future<PasswordRules> passwordRules() => mock.passwordRules();

  @override
  Future<AuthSession> loginOffline(String email) => mock.loginOffline(email);

  @override
  Future<void> checkSession() async {
    try {
      await api.getJson('/auth/me');
    } on KvApiException catch (e) {
      if (e.failure == KvFailure.network) {
        return;
      }
      rethrow;
    }
  }
}

/// Оборудование с настоящего сервера; поля дизайна - из демонстрационной карточки того же агрегата.
class ApiEquipmentRepository implements EquipmentRepository {
  /// Создаёт репозиторий.
  ApiEquipmentRepository(this.api, this.mock, this.feed);

  /// Клиент сервера.
  final ApiClient api;

  /// Демонстрационные карточки-основы.
  final EquipmentRepository mock;

  /// Поток изменений.
  final ApiFeed feed;

  Future<Equipment?> _base(String id) async {
    try {
      return await mock.unit(id);
    } on Object {
      return null;
    }
  }

  Future<Equipment> _merge(Map<String, dynamic> row) async {
    final String id = Json.str(row, 'id');
    final Equipment? base = await _base(id);
    Map<String, Reading>? readings;
    String? level;
    String? diagnosis;
    if (Json.flag(row, 'telemetry', true)) {
      try {
        final Map<String, dynamic> t = await api.getJson('/equipment/$id/telemetry') as Map<String, dynamic>;
        if (Json.flag(t, 'available')) {
          readings = ApiMap.readings(t, base?.readings ?? const {});
          level = Json.strOrNull(t, 'level');
        }
      } on KvApiException {
        readings = null;
      }
    }
    try {
      final Map<String, dynamic> d = await api.getJson('/equipment/$id/diagnosis') as Map<String, dynamic>;
      diagnosis = Json.strOrNull(d, 'status');
    } on KvApiException {
      diagnosis = null;
    }
    return ApiMap.equipment(row, base: base, readings: readings, diagnosis: diagnosis, level: level);
  }

  @override
  Future<List<Equipment>> units() async {
    final List<dynamic> rows = await api.getJson('/equipment') as List<dynamic>;
    return Future.wait([for (final Map<String, dynamic> r in rows.whereType<Map<String, dynamic>>()) _merge(r)]);
  }

  @override
  Future<Equipment> unit(String id) async {
    String key = id;
    final Equipment? base = await _base(id);
    if (base != null) {
      key = base.id;
    }
    final Map<String, dynamic> row = await api.getJson('/equipment/${Uri.encodeComponent(key)}') as Map<String, dynamic>;
    return _merge(row);
  }

  @override
  Future<List<Equipment>> search(String query) async {
    final String q = query.trim().toLowerCase();
    final List<Equipment> all = await units();
    final Set<String> mockIds = {
      for (final Equipment e in await mock.search(query).catchError((Object _) => const <Equipment>[])) e.id,
    };
    return all
        .where(
          (Equipment e) =>
              mockIds.contains(e.id) ||
              q.isEmpty ||
              [e.id, e.code, e.name, e.model, e.serial].any((String f) => f.toLowerCase().contains(q)),
        )
        .toList();
  }

  @override
  Future<Equipment?> bySerial(String serial) async {
    try {
      final Map<String, dynamic> row = await api.getJson('/equipment/by-serial/${Uri.encodeComponent(serial)}') as Map<String, dynamic>;
      return _merge(row);
    } on KvApiException catch (e) {
      if (e.failure == KvFailure.notFound) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<List<HistoryEvent>> history(String unitId) async {
    final Equipment? base = await _base(unitId);
    final String id = base?.id ?? unitId;
    final List<dynamic> items = await api.getJson('/equipment/${Uri.encodeComponent(id)}/history') as List<dynamic>;
    return ApiMap.history(items, id);
  }

  @override
  Future<Equipment> setMode(String unitId, String mode, {String? reason}) async {
    await api.postJson('/equipment/${Uri.encodeComponent(unitId)}/mode', {'mode': mode, 'reason': ?reason});
    feed.notify(KvDomain.equipment);
    return unit(unitId);
  }
}

/// Телеметрия с настоящего сервера; у агрегатов без датчиков - демонстрационные показания.
class ApiTelemetryRepository implements TelemetryRepository {
  /// Создаёт репозиторий.
  ApiTelemetryRepository(this.api, this.mock);

  /// Клиент сервера.
  final ApiClient api;

  /// Демонстрационная телеметрия: подписи и агрегаты без датчиков.
  final TelemetryRepository mock;

  /// Как часто обновлять живые показания.
  static const Duration poll = Duration(seconds: 3);

  Future<Map<String, Reading>> _base(String unitId) async {
    try {
      return await mock.readings(unitId);
    } on Object {
      return const <String, Reading>{};
    }
  }

  @override
  Future<Map<String, Reading>> readings(String unitId) async {
    final Map<String, Reading> base = await _base(unitId);
    final Map<String, dynamic> t = await api.getJson('/equipment/${Uri.encodeComponent(unitId)}/telemetry') as Map<String, dynamic>;
    if (!Json.flag(t, 'available')) {
      return base;
    }
    return ApiMap.readings(t, base);
  }

  @override
  Future<TelemetrySeries> series(String unitId, String key, TelemetryPeriod period) async {
    final String? code = Reading.serverCodes[key];
    final Map<String, Reading> base = await _base(unitId);
    if (code == null) {
      return mock.series(unitId, key, period);
    }
    try {
      final Map<String, dynamic> j = await api.getJson(
        '/equipment/${Uri.encodeComponent(unitId)}/telemetry/$code',
        {'hours': '${ApiMap.hoursOf(period)}'},
      ) as Map<String, dynamic>;
      return ApiMap.series(j, unitId, key, period, base: base[key]);
    } on KvApiException catch (e) {
      if (e.failure == KvFailure.notFound || e.failure == KvFailure.validation) {
        return mock.series(unitId, key, period);
      }
      rethrow;
    }
  }

  @override
  Stream<Map<String, Reading>> watchReadings(String unitId) async* {
    yield await readings(unitId);
    while (true) {
      await Future<void>.delayed(poll);
      try {
        yield await readings(unitId);
      } on KvApiException {
        continue;
      }
    }
  }
}

/// Осмотры, диагностика и маршрут с настоящего сервера. Справочник правил, разбор правил и решения мастера
/// по находкам пока остаются демонстрационными.
class ApiInspectionRepository implements InspectionRepository {
  /// Создаёт репозиторий.
  ApiInspectionRepository(this.api, this.mock, this.feed);

  /// Клиент сервера.
  final ApiClient api;

  /// Демонстрационные данные для разделов, которых нет на сервере.
  final InspectionRepository mock;

  /// Поток изменений.
  final ApiFeed feed;

  static final Map<String, Map<String, ({String result, String note})>> _marks = {};
  static final Map<String, Map<String, String>> _nodeCodes = {};
  static final Map<String, int> _coverageSeen = {};

  /// Учесть состояние обхода из ответа /ws/inspect: осмотренные камерой узлы отмечаются в маршруте.
  void applyCoverage(String unitId, Map<String, dynamic> coverage) {
    final Map<String, ({String result, String note})> marks = _marks.putIfAbsent(unitId, () => {});
    final Map<String, dynamic> nodes = Json.obj(coverage, 'nodes');
    bool changed = false;
    nodes.forEach((String code, dynamic v) {
      if (v is! Map<String, dynamic> || !Json.flag(v, 'inspected')) {
        return;
      }
      final bool defect = Json.obj(v, 'defect_classes').isNotEmpty;
      final String result = defect ? 'bad' : 'ok';
      final ({String result, String note})? old = marks[code];
      if (old == null || (old.result == 'ok' && result == 'bad')) {
        marks[code] = (result: result, note: defect ? 'Признак дефекта на видео' : 'Осмотрено камерой');
        changed = true;
      }
    });
    final int inspected = Json.integer(coverage, 'inspected');
    if (changed || _coverageSeen[unitId] != inspected) {
      _coverageSeen[unitId] = inspected;
      feed.notify(KvDomain.inspections);
    }
  }

  @override
  Future<List<RuleDef>> rules() => mock.rules();

  @override
  Future<RuleDef> rule(String id) => mock.rule(id);

  @override
  Future<Map<int, String>> severityLabels() => mock.severityLabels();

  @override
  Future<List<DiagnosisResult>> diagnosis(String unitId) async {
    final Inspection? active = await activeInspection(unitId);
    final Map<String, dynamic> j = await api.getJson(
      '/equipment/${Uri.encodeComponent(unitId)}/diagnosis',
      {if (active != null && isServerId(active.id)) 'inspection_id': active.id},
    ) as Map<String, dynamic>;
    return ApiMap.diagnosis(j);
  }

  @override
  Future<List<RouteStep>> route(String unitId) async {
    final List<dynamic> rows = await api.getJson('/equipment/${Uri.encodeComponent(unitId)}/route') as List<dynamic>;
    final Map<String, ({String result, String note})> marks = _marks[unitId] ?? const {};
    final Map<String, String> codes = _nodeCodes.putIfAbsent(unitId, () => {});
    final List<RouteStep> steps = [];
    bool nextSet = false;
    int i = 0;
    for (final Map<String, dynamic> r in rows.whereType<Map<String, dynamic>>()) {
      final RouteStep s = RouteStep.fromJson(r, i++);
      codes[s.name] = s.nodeId;
      final ({String result, String note})? m = marks[s.nodeId];
      String? result = m?.result;
      if (result == null && !nextSet) {
        result = 'next';
        nextSet = true;
      }
      steps.add(RouteStep(n: s.n, nodeId: s.nodeId, name: s.name, why: s.why, reason: s.reason, result: result, note: m?.note ?? ''));
    }
    return steps;
  }

  @override
  Future<List<RouteStep>> markRouteStep(String unitId, String nodeId, {required String result, String note = ''}) async {
    _marks.putIfAbsent(unitId, () => {})[nodeId] = (result: result, note: note);
    final Inspection? active = await activeInspection(unitId);
    if (active != null && isServerId(active.id)) {
      try {
        await api.postForm(
          '/inspections/${active.id}/findings',
          fields: {
            'kind': result == 'ok' ? 'checked' : 'defect',
            'node': nodeId,
            if (result != 'ok') 'severity': result == 'bad' ? '2' : '1',
            if (note.isNotEmpty) 'comment': note,
          },
        );
      } on KvApiException {
        feed.notify(KvDomain.inspections);
      }
    }
    feed.notify(KvDomain.inspections);
    return route(unitId);
  }

  @override
  Future<RuleCheck> ruleCheck(String unitId, String ruleId) => mock.ruleCheck(unitId, ruleId);

  @override
  Future<List<ChecklistItem>> checklist(String inspectionId) => mock.checklist(inspectionId);

  @override
  Future<List<Detection>> detections(String unitId) async => const <Detection>[];

  @override
  Future<List<Inspection>> inspections({String? unitId}) async {
    final List<dynamic> rows = await api.getJson('/inspections', {'equipment_id': ?unitId}) as List<dynamic>;
    return [for (final Map<String, dynamic> r in rows.whereType<Map<String, dynamic>>()) ApiMap.inspection(r)];
  }

  @override
  Future<Inspection> inspection(String id) async {
    if (!isServerId(id)) {
      return mock.inspection(id);
    }
    return ApiMap.inspection(await api.getJson('/inspections/$id') as Map<String, dynamic>);
  }

  @override
  Future<InspectionSummary> summary(String inspectionId) async {
    if (!isServerId(inspectionId)) {
      return mock.summary(inspectionId);
    }
    return ApiMap.summary(await api.getJson('/inspections/$inspectionId') as Map<String, dynamic>);
  }

  @override
  Future<List<HistoryEvent>> activity() async {
    final List<Inspection> all = await inspections();
    return [
      for (final Inspection i in all)
        HistoryEvent(
          date: i.date,
          time: i.time,
          status: i.defects > 0 ? 'bad' : (i.checks > 0 ? 'warn' : (i.status == 'draft' ? 'info' : 'ok')),
          title: i.status == 'draft' ? 'Осмотр идёт · ${i.unitId}' : 'Осмотр № ${i.id} · ${i.unitId}',
          text: [if (i.duration.isNotEmpty) i.duration, if (i.defects > 0) 'дефектов ${i.defects}', if (i.checks > 0) 'проверить ${i.checks}'].join(' · '),
          who: i.who,
          unitId: i.unitId,
          kind: 'inspection',
          label: i.id,
        ),
    ];
  }

  @override
  Future<Inspection?> activeInspection(String unitId) async {
    final List<dynamic> rows = await api.getJson('/inspections', {'equipment_id': unitId, 'status': 'active'}) as List<dynamic>;
    final Map<String, dynamic>? first = rows.whereType<Map<String, dynamic>>().firstOrNull;
    return first == null ? null : ApiMap.inspection(first);
  }

  @override
  Future<Inspection> start(String unitId) async {
    final Map<String, dynamic> j = await api.postJson('/inspections', {'equipment_id': unitId}) as Map<String, dynamic>;
    if (!Json.flag(j, 'resumed')) {
      _marks.remove(unitId);
    }
    feed.notify(KvDomain.inspections);
    return ApiMap.inspection(j);
  }

  Future<String?> _nodeCode(String unitId, String node) async {
    if (!_nodeCodes.containsKey(unitId)) {
      try {
        await route(unitId);
      } on KvApiException {
        return null;
      }
    }
    final Map<String, String> codes = _nodeCodes[unitId] ?? const {};
    if (codes.containsValue(node)) {
      return node;
    }
    if (codes.containsKey(node)) {
      return codes[node];
    }
    final String low = node.toLowerCase();
    for (final MapEntry<String, String> e in codes.entries) {
      if (e.key.toLowerCase().contains(low) || low.contains(e.key.toLowerCase().split(' ').first)) {
        return e.value;
      }
    }
    return null;
  }

  @override
  Future<Finding> addFinding(
    String inspectionId, {
    required String node,
    required String title,
    required String ruleId,
    required int severity,
    String? comment,
    List<String> evidence = const <String>[],
  }) async {
    if (!isServerId(inspectionId)) {
      return mock.addFinding(inspectionId, node: node, title: title, ruleId: ruleId, severity: severity, comment: comment, evidence: evidence);
    }
    final Inspection ins = await inspection(inspectionId);
    final String? code = await _nodeCode(ins.unitId, node);
    final bool fired = await _ruleFires(ins.unitId, inspectionId, ruleId, code);
    final Map<String, String> fields = {
      'kind': 'defect',
      'severity': '${severity.clamp(1, 3)}',
      'comment': [title, if (comment != null && comment.isNotEmpty) comment].join('. '),
      'node': ?code,
      if (fired) 'rule_id': ruleId,
    };
    return _postFinding(inspectionId, fields);
  }

  /// Признаки дефекта, которые сервер принимает в поле sign (data/rules.json, signs).
  static const Set<String> serverSigns = {
    'leak',
    'corrosion',
    'terminal_box_burnt',
    'coupling_no_guard',
    'coupling_guard_broken',
    'coupling_guard_shifted',
    'crack',
    'damage',
  };

  /// Находка со сканера по классу детектора [cls]: признак дефекта передаётся серверу как sign, узел - кодом.
  Future<Finding> addCameraFinding(String inspectionId, {required String cls, String? node, required int severity, String? comment}) async {
    final Inspection ins = await inspection(inspectionId);
    final String? code = node == null ? null : await _nodeCode(ins.unitId, node);
    final Map<String, String> fields = {
      'kind': 'defect',
      'severity': '${severity.clamp(1, 3)}',
      'comment': ?comment,
      'node': ?code,
      if (serverSigns.contains(cls)) 'sign': cls,
    };
    return _postFinding(inspectionId, fields);
  }

  /// Правило [ruleId] сейчас срабатывает в диагнозе осмотра (для узла [node], если он известен).
  Future<bool> _ruleFires(String unitId, String inspectionId, String ruleId, String? node) async {
    if (!RegExp(r'^[RSV]\d{2}$').hasMatch(ruleId)) {
      return false;
    }
    try {
      final Map<String, dynamic> j = await api.getJson(
        '/equipment/${Uri.encodeComponent(unitId)}/diagnosis',
        {'inspection_id': inspectionId},
      ) as Map<String, dynamic>;
      return Json.list(j, 'findings', (Map<String, dynamic> f) => f)
          .any((Map<String, dynamic> f) => Json.str(f, 'rule_id') == ruleId && (node == null || Json.str(f, 'node_id') == node));
    } on KvApiException {
      return false;
    }
  }

  Future<Finding> _postFinding(String inspectionId, Map<String, String> fields) async {
    dynamic j;
    for (final String drop in const ['', 'rule_id', 'sign', 'node']) {
      fields.remove(drop);
      try {
        j = await api.postForm('/inspections/$inspectionId/findings', fields: fields, frame: api.lastFrame);
        break;
      } on KvApiException catch (e) {
        if ((e.failure != KvFailure.validation && e.failure != KvFailure.notFound) || drop == 'node') {
          rethrow;
        }
      }
    }
    feed
      ..notify(KvDomain.inspections)
      ..notify(KvDomain.findings);
    return ApiMap.finding(j as Map<String, dynamic>);
  }

  @override
  Future<void> dismissDetection(String inspectionId, String label) async {
    if (!isServerId(inspectionId)) {
      return mock.dismissDetection(inspectionId, label);
    }
  }

  @override
  Future<Inspection> finish(String inspectionId) async {
    if (!isServerId(inspectionId)) {
      return mock.finish(inspectionId);
    }
    final Map<String, dynamic> j = await api.postJson('/inspections/$inspectionId/finish') as Map<String, dynamic>;
    final Inspection done = ApiMap.inspection(j);
    _marks.remove(done.unitId);
    feed
      ..notify(KvDomain.inspections)
      ..notify(KvDomain.findings)
      ..notify(KvDomain.equipment)
      ..notify(KvDomain.reports);
    return done;
  }

  @override
  Future<List<Finding>> findings({String? status, String? unitId}) => mock.findings(status: status, unitId: unitId);

  @override
  Future<Finding> finding(String id) async {
    if (!isServerId(id)) {
      return mock.finding(id);
    }
    return ApiMap.finding(await api.getJson('/inspections/findings/$id') as Map<String, dynamic>);
  }

  @override
  Future<Finding> confirmFinding(String id, {bool keepRunning = false, String? justification}) =>
      mock.confirmFinding(id, keepRunning: keepRunning, justification: justification);

  @override
  Future<Finding> rejectFinding(String id, {required String reason, required String note}) => mock.rejectFinding(id, reason: reason, note: note);

  @override
  Future<Finding> scheduleFinding(String id, {required String when}) => mock.scheduleFinding(id, when: when);

  @override
  Future<Finding> commentFinding(String id, String text) => mock.commentFinding(id, text);

  @override
  Future<Finding> reopenFinding(String id) => mock.reopenFinding(id);
}

/// Отчёты: отчёт по осмотру формирует настоящий сервер (PDF или Excel), остальные - демонстрационные.
class ApiReportRepository implements ReportRepository {
  /// Создаёт репозиторий.
  ApiReportRepository(this.api, this.mock, this.feed);

  /// Клиент сервера.
  final ApiClient api;

  /// Демонстрационные отчёты.
  final ReportRepository mock;

  /// Поток изменений.
  final ApiFeed feed;

  static final List<Report> _made = [];

  @override
  Future<List<Report>> reports() async => [..._made.reversed, ...await mock.reports()];

  @override
  Future<Report> unitReport(String unitId, String format) => mock.unitReport(unitId, format);

  /// Адрес файла отчёта по осмотру [inspectionId] на сервере.
  Uri reportUri(String inspectionId, String format) => api.uri('/inspections/$inspectionId/report.${format == 'xlsx' ? 'xlsx' : 'pdf'}');

  @override
  Future<Report> inspectionReport(String inspectionId, String format) async {
    if (!isServerId(inspectionId)) {
      return mock.inspectionReport(inspectionId, format);
    }
    final String ext = format == 'xlsx' ? 'xlsx' : 'pdf';
    final int bytes = (await api.getBytes('/inspections/$inspectionId/report.$ext')).length;
    final DateTime now = DateTime.now();
    final Report r = Report(
      id: 'R-$inspectionId-$ext',
      title: 'Отчёт по осмотру № $inspectionId',
      format: ext,
      createdAt: '${ApiMap.date(now.toIso8601String())} ${ApiMap.time(now.toIso8601String())}',
      size: bytes >= 1024 * 1024 ? '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} МБ' : '${(bytes / 1024).ceil()} КБ',
      inspectionId: inspectionId,
    );
    _made.add(r);
    feed.notify(KvDomain.reports);
    return r;
  }

  @override
  Future<Report> shiftReport(String date, String format) => mock.shiftReport(date, format);
}

/// Ассистент цехового сервера (POST /assistant/ask); подсказки вопросов - демонстрационные.
class ApiAssistantRepository implements AssistantRepository {
  /// Создаёт репозиторий.
  ApiAssistantRepository(this.api, this.mock, this.feed);

  /// Клиент сервера.
  final ApiClient api;

  /// Демонстрационный ассистент.
  final AssistantRepository mock;

  /// Поток изменений.
  final ApiFeed feed;

  static final List<AssistantMessage> _dialog = [];

  @override
  Future<List<String>> suggestions() => mock.suggestions();

  @override
  Future<List<AssistantMessage>> dialog() async => List<AssistantMessage>.unmodifiable(_dialog);

  @override
  Future<AssistantMessage> ask(String question, {String? unitId}) async {
    final String now = ApiMap.time(DateTime.now().toIso8601String());
    _dialog.add(AssistantMessage(fromUser: true, text: question, time: now));
    feed.notify(KvDomain.assistant);
    final Map<String, dynamic> j = await api.postJson('/assistant/ask', {'question': question, 'equipment_id': ?unitId}) as Map<String, dynamic>;
    final AssistantMessage a = AssistantMessage.fromAnswer(j);
    _dialog.add(a);
    feed.notify(KvDomain.assistant);
    return a;
  }
}
