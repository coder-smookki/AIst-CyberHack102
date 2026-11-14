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
import '../repositories/site_repository.dart';
import '../repositories/telemetry_repository.dart';
import '../repositories/workflow_repository.dart';
import 'api_client.dart';
import 'api_feed.dart';
import 'api_mappers.dart';
import 'bio_vault.dart';

/// Номер записи настоящего сервера (целое число); номера демонстрационных данных («INS-2209») сюда не подходят.
bool isServerId(String id) => int.tryParse(id) != null;

/// Вход на настоящем сервере. Сведения, которых сервер не хранит (должность, смена, сохранённая учётная запись,
/// контакты), остаются демонстрационными: параллельный вход в демонстрационный сервер даёт экранам других ролей контекст.
class ApiAuthRepository implements AuthRepository {
  /// Создаёт репозиторий; [vault] - хранилище входа по биометрии.
  ApiAuthRepository(this.api, this.mock, this.feed, [BioVault? vault]) : vault = vault ?? MemoryBioVault();

  /// Хранилище входа по биометрии.
  final BioVault vault;

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
    final BioAccount? saved = await vault.read();
    if (saved == null || saved.refreshToken.isEmpty) {
      throw const KvApiException(KvFailure.invalidCredentials, 'Вход по биометрии не включён - войдите с паролем');
    }
    final dynamic j;
    try {
      j = await api.postJson('/auth/refresh', {'refresh_token': saved.refreshToken, 'biometric': true}, false);
    } on KvApiException catch (e) {
      if (e.failure == KvFailure.network) {
        rethrow;
      }
      await vault.clear();
      throw KvApiException(e.failure, 'Вход по биометрии больше не действует: ${e.message}. Войдите с паролем.');
    }
    final AuthSession s = _merge(j as Map<String, dynamic>, _session);
    await vault.rotate(s.refreshToken);
    return s;
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
    await vault.clear();
    try {
      await mock.logout();
    } on Object {
      return;
    }
  }

  @override
  Future<LoginPreset?> scenarioLogin(String scenario) async => null;

  @override
  Future<SavedAccount?> savedAccount() => vault.account();

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
    Resource? resource;
    NextMaintenance? nextTo;
    try {
      final Map<String, dynamic> r = await api.getJson('/equipment/$id/resource') as Map<String, dynamic>;
      resource = ApiMap.resource(r);
      nextTo = ApiMap.nextMaintenance(r);
    } on KvApiException {
      resource = null;
    }
    return ApiMap.equipment(row, base: base, readings: readings ?? const <String, Reading>{}, diagnosis: diagnosis, level: level, resource: resource, nextTo: nextTo);
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
      return const <String, Reading>{};
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

  /// Учесть состояние обхода из ответа /ws/inspect: узлы, осмотренные камерой без признаков дефекта, отмечаются
  /// в маршруте как осмотренные. Узел с признаком ждёт решения инженера и сам дефектным не отмечается.
  void applyCoverage(String unitId, Map<String, dynamic> coverage) {
    final Map<String, ({String result, String note})> marks = _marks.putIfAbsent(unitId, () => {});
    final Map<String, dynamic> nodes = Json.obj(coverage, 'nodes');
    bool changed = false;
    nodes.forEach((String code, dynamic v) {
      if (v is! Map<String, dynamic> || !Json.flag(v, 'inspected')) {
        return;
      }
      if (Json.obj(v, 'defect_classes').isNotEmpty || marks.containsKey(code)) {
        return;
      }
      marks[code] = (result: 'ok', note: 'Осмотрено камерой');
      changed = true;
    });
    final int inspected = Json.integer(coverage, 'inspected');
    if (changed || _coverageSeen[unitId] != inspected) {
      _coverageSeen[unitId] = inspected;
      feed.notify(KvDomain.inspections);
    }
  }

  List<Map<String, dynamic>>? _rulesJson;

  Future<List<Map<String, dynamic>>> _rules() async =>
      _rulesJson ??= ((await api.getJson('/rules')) as List<dynamic>).whereType<Map<String, dynamic>>().toList();

  @override
  Future<List<RuleDef>> rules() async => [for (final Map<String, dynamic> r in await _rules()) ApiMap.rule(r)];

  @override
  Future<RuleDef> rule(String id) async {
    final Map<String, dynamic>? r = (await _rules()).where((Map<String, dynamic> e) => Json.str(e, 'id') == id).firstOrNull;
    if (r == null) {
      throw KvApiException(KvFailure.notFound, 'Правило $id не найдено');
    }
    return ApiMap.rule(r);
  }

  @override
  Future<Map<int, String>> severityLabels() async => {
        for (final Map<String, dynamic> r in await _rules())
          if (Json.integer(r, 'severity') > 0) Json.integer(r, 'severity'): Json.str(r, 'severity_title'),
      };

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
  Future<RuleCheck> ruleCheck(String unitId, String ruleId) async {
    final Inspection? active = await activeInspection(unitId);
    final Map<String, dynamic> j = await api.getJson(
      '/equipment/${Uri.encodeComponent(unitId)}/rules/${Uri.encodeComponent(ruleId)}',
      {if (active != null && isServerId(active.id)) 'inspection_id': active.id},
    ) as Map<String, dynamic>;
    return ApiMap.ruleCheck(j);
  }

  /// Как опознан агрегат следующего осмотра: nameplate, manual или qr (POST /inspections, identified_by).
  static final Map<String, String> identifiedBy = {};

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
    final Map<String, dynamic> j = await api.postJson('/inspections', {'equipment_id': unitId, 'identified_by': ?identifiedBy[unitId]}) as Map<String, dynamic>;
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

  @override
  Future<void> addWork(String inspectionId, String unitId, {required WorkKind kind, String? node, String? comment, String? maintenanceCode}) async {
    if (!isServerId(inspectionId)) {
      return mock.addWork(inspectionId, unitId, kind: kind, node: node, comment: comment, maintenanceCode: maintenanceCode);
    }
    final String text = (comment ?? '').trim();
    await api.postForm(
      '/inspections/$inspectionId/findings',
      fields: {
        'kind': kind.server,
        'node': ?node,
        if (text.isNotEmpty) 'comment': text,
        if (kind == WorkKind.maintenance) 'maintenance_code': ?maintenanceCode,
      },
    );
    if (node != null && kind != WorkKind.note) {
      _marks.putIfAbsent(unitId, () => {})[node] = (result: 'ok', note: kind.label);
    }
    feed
      ..notify(KvDomain.inspections)
      ..notify(KvDomain.findings)
      ..notify(KvDomain.equipment)
      ..notify(KvDomain.plan);
  }

  @override
  Future<List<MaintenanceKind>> maintenanceKinds(String unitId) async {
    final Map<String, dynamic> j = await api.getJson('/equipment/${Uri.encodeComponent(unitId)}/resource') as Map<String, dynamic>;
    return [
      for (final Map<String, dynamic> m in Json.list(j, 'maintenance', (Map<String, dynamic> e) => e))
        if (Json.str(m, 'code').isNotEmpty) (code: Json.str(m, 'code'), name: Json.str(m, 'name', Json.str(m, 'code'))),
    ];
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
    'noise_high',
    'noise_impulsive',
    'noise_tonal',
    'cavitation_noise',
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
    final Finding f = await _postFinding(inspectionId, fields);
    if (code != null) {
      _marks.putIfAbsent(ins.unitId, () => {})[code] = (result: severity >= 2 ? 'bad' : 'warn', note: comment ?? '');
    }
    return f;
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
  Future<List<Finding>> findings({String? status, String? unitId}) async {
    final List<dynamic> rows = await api.getJson('/inspections/findings', {'equipment_id': ?unitId}) as List<dynamic>;
    final List<Finding> all = [for (final Map<String, dynamic> r in rows.whereType<Map<String, dynamic>>()) ApiMap.finding(r)];
    return status == null ? all : all.where((Finding f) => f.status == status).toList();
  }

  @override
  Future<Finding> finding(String id) async {
    if (!isServerId(id)) {
      return mock.finding(id);
    }
    return ApiMap.finding(await api.getJson('/inspections/findings/$id') as Map<String, dynamic>);
  }

  Future<Finding> _state(String id, String state, String? comment) async =>
      ApiMap.finding(await api.postJson('/inspections/findings/$id/state', {'state': state, 'comment': ?comment}) as Map<String, dynamic>);

  Future<Finding> _decide(String id, List<String> states, String comment) async {
    Finding f = await finding(id);
    for (final String st in states) {
      f = await _state(id, st, comment);
    }
    feed
      ..notify(KvDomain.findings)
      ..notify(KvDomain.inspections);
    return f;
  }

  @override
  Future<Finding> confirmFinding(String id, {bool keepRunning = false, String? justification}) {
    if (!isServerId(id)) {
      return mock.confirmFinding(id, keepRunning: keepRunning, justification: justification);
    }
    final String note = [
      'Подтверждено мастером',
      if (keepRunning) 'агрегат оставлен в работе',
      if (justification != null && justification.isNotEmpty) justification,
    ].join('. ');
    return _decide(id, const ['in_work'], note);
  }

  @override
  Future<Finding> rejectFinding(String id, {required String reason, required String note}) {
    if (!isServerId(id)) {
      return mock.rejectFinding(id, reason: reason, note: note);
    }
    return _decide(id, const ['rejected'], [reason, if (note.isNotEmpty) note].join('. '));
  }

  @override
  Future<Finding> scheduleFinding(String id, {required String when}) {
    if (!isServerId(id)) {
      return mock.scheduleFinding(id, when: when);
    }
    return _decide(id, const ['in_work'], 'Запланировано: $when');
  }

  @override
  Future<Finding> commentFinding(String id, String text) async {
    if (!isServerId(id)) {
      return mock.commentFinding(id, text);
    }
    final Finding f = ApiMap.finding(await api.postJson('/inspections/findings/$id/comment', {'text': text}) as Map<String, dynamic>);
    feed.notify(KvDomain.findings);
    return f;
  }

  @override
  Future<Finding> reopenFinding(String id) async {
    if (!isServerId(id)) {
      return mock.reopenFinding(id);
    }
    throw const KvApiException(KvFailure.validation, 'Сервер не возвращает закрытые находки на подтверждение');
  }
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

/// Задания и уведомления с настоящего сервера (GET /tasks/my, /notifications). План ТО и сообщения о неисправностях
/// других ролей пока демонстрационные; в режиме сервера план пуст, чтобы не показывать вымышленные работы.
class ApiWorkflowRepository implements WorkflowRepository {
  /// Создаёт репозиторий.
  ApiWorkflowRepository(this.api, this.mock);

  /// Клиент сервера.
  final ApiClient api;

  /// Демонстрационные разделы других ролей.
  final WorkflowRepository mock;

  @override
  Future<List<InspectionTask>> tasks({String? assignee}) async {
    try {
      final List<dynamic> rows = await api.getJson('/tasks/my') as List<dynamic>;
      return [for (final Map<String, dynamic> r in rows.whereType<Map<String, dynamic>>()) InspectionTask.fromJson(r)];
    } on KvApiException catch (e) {
      if (e.failure == KvFailure.forbidden || e.failure == KvFailure.notFound) {
        return const <InspectionTask>[];
      }
      rethrow;
    }
  }

  @override
  Future<InspectionTask> task(String id) async {
    if (!isServerId(id)) {
      return mock.task(id);
    }
    return InspectionTask.fromJson(await api.getJson('/tasks/$id') as Map<String, dynamic>);
  }

  @override
  Future<InspectionTask> assignInspection({
    required String unitId,
    required String assignee,
    required String reason,
    required String due,
    String priority = 'normal',
    String? faultReportId,
  }) =>
      mock.assignInspection(unitId: unitId, assignee: assignee, reason: reason, due: due, priority: priority, faultReportId: faultReportId);

  Map<String, String>? _signs;

  Future<Map<String, String>> _signCodes() async => _signs ??= {
        for (final Map<String, dynamic> e in ((await api.getJson('/fault-reports/signs')) as List<dynamic>).whereType<Map<String, dynamic>>())
          Json.str(e, 'title'): Json.str(e, 'code'),
      };

  FaultReport _report(Map<String, dynamic> j) {
    final FaultReport r = FaultReport.fromJson(j);
    final String at = Json.str(j, 'created_at');
    return FaultReport(
      id: r.id,
      unitId: r.unitId,
      author: r.author,
      date: ApiMap.date(at),
      time: ApiMap.time(at),
      kind: r.kind,
      text: r.text,
      status: r.status,
      statusLabel: r.statusLabel,
    );
  }

  @override
  Future<List<String>> faultKinds() async => (await _signCodes()).keys.toList();

  @override
  Future<List<FaultReport>> faultReports({String? author}) async {
    List<dynamic> rows;
    try {
      rows = await api.getJson('/fault-reports') as List<dynamic>;
    } on KvApiException catch (e) {
      if (e.failure != KvFailure.forbidden) {
        rethrow;
      }
      rows = await api.getJson('/fault-reports/my') as List<dynamic>;
    }
    return [for (final Map<String, dynamic> r in rows.whereType<Map<String, dynamic>>()) _report(r)];
  }

  @override
  Future<FaultReport> faultReport(String id) async {
    if (!isServerId(id)) {
      return mock.faultReport(id);
    }
    return _report(await api.getJson('/fault-reports/$id') as Map<String, dynamic>);
  }

  @override
  Future<FaultReport> reportFault({required String unitId, required String kind, required String text, required String author}) async {
    final Map<String, String> codes = await _signCodes();
    final String code = codes[kind] ?? 'other';
    final Map<String, dynamic> j = await api.postJson('/fault-reports', {
      'equipment_id': unitId,
      'signs': [code],
      'comment': code == 'other' && text.trim().isEmpty ? kind : text,
    }) as Map<String, dynamic>;
    return _report(j);
  }

  @override
  Future<List<AppNotification>> notifications(String roleKey) async {
    try {
      final List<dynamic> rows = await api.getJson('/notifications') as List<dynamic>;
      return [
        for (final Map<String, dynamic> r in rows.whereType<Map<String, dynamic>>())
          AppNotification(
            id: Json.str(r, 'id'),
            time: '${ApiMap.date(Json.strOrNull(r, 'at'))} ${ApiMap.time(Json.strOrNull(r, 'at'))}'.trim(),
            kind: Json.str(r, 'kind'),
            title: Json.str(r, 'title'),
            text: Json.str(r, 'text'),
          ),
      ];
    } on KvApiException catch (e) {
      if (e.failure == KvFailure.forbidden) {
        return const <AppNotification>[];
      }
      rethrow;
    }
  }

  @override
  Future<void> markNotificationsRead(String roleKey) async {}

  @override
  Future<List<PlanItem>> plan() async => const <PlanItem>[];

  @override
  Future<PlanItem> movePlanItem(String id, {required String date, required String time}) => mock.movePlanItem(id, date: date, time: time);

  @override
  Future<PlanItem> assignPlanItem(String id, String who) => mock.assignPlanItem(id, who);
}

/// Площадка на настоящем сервере: имя сервера и его доступность; справочник сотрудников - демонстрационный.
class ApiSiteRepository implements SiteRepository {
  /// Создаёт репозиторий.
  ApiSiteRepository(this.api, this.mock);

  /// Клиент сервера.
  final ApiClient api;

  /// Справочник сотрудников других ролей.
  final SiteRepository mock;

  @override
  Future<Site> site() async {
    try {
      final Map<String, dynamic> j = await api.getJson('/site') as Map<String, dynamic>;
      return Site(
        name: Json.str(j, 'name'),
        shift: [Json.str(j, 'shift_title'), Json.str(j, 'shift')].where((String x) => x.isNotEmpty).join(' · '),
        shiftShort: 'смена ${Json.str(j, 'shift')}',
        server: Json.str(j, 'server_name'),
        wifi: '',
      );
    } on KvApiException catch (e) {
      if (e.failure != KvFailure.notFound) {
        rethrow;
      }
    }
    final String host = Uri.tryParse(api.baseUrl)?.host ?? api.baseUrl;
    final List<dynamic> rows = await api.getJson('/equipment') as List<dynamic>;
    final Set<String> places = {
      for (final Map<String, dynamic> r in rows.whereType<Map<String, dynamic>>()) Json.str(r, 'location').split(',').first.trim(),
    }..removeWhere((String p) => p.isEmpty);
    return Site(
      name: places.isEmpty ? host : places.join(', '),
      shift: '',
      shiftShort: host,
      server: host,
      wifi: '',
    );
  }

  @override
  Future<Map<String, Person>> people() => mock.people();

  @override
  Future<List<Person>> engineers() => mock.engineers();

  @override
  Future<int> ping() => api.ping();
}
