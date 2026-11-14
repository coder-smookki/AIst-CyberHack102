import '../models/equipment.dart';
import '../models/inspection.dart';
import '../models/json.dart';

/// Перевод ответов цехового сервера в модели приложения. Поля дизайна, которых сервер не отдаёт
/// (обозначение «Н-101», короткая модель, ресурс), берутся из карточки-основы [base], если она есть.
abstract final class ApiMap {
  /// Ключ показания приложения по коду параметра сервера: vib_1x -> vib1x.
  static final Map<String, String> readingKeys = {for (final MapEntry<String, String> e in Reading.serverCodes.entries) e.value: e.key};

  /// Дата «14.11.2026» из момента ISO.
  static String date(String? iso) {
    final DateTime? t = iso == null ? null : DateTime.tryParse(iso);
    return t == null ? '' : '${_pad(t.day)}.${_pad(t.month)}.${t.year}';
  }

  /// Время «09:41» из момента ISO.
  static String time(String? iso) {
    final DateTime? t = iso == null ? null : DateTime.tryParse(iso);
    return t == null ? '' : '${_pad(t.hour)}:${_pad(t.minute)}';
  }

  static String _pad(int v) => v.toString().padLeft(2, '0');

  /// Длительность «26 мин» из секунд.
  static String duration(num? seconds) {
    if (seconds == null) {
      return '';
    }
    final int m = (seconds / 60).round();
    return m < 60 ? '$m мин' : '${m ~/ 60} ч ${m % 60} мин';
  }

  /// Знаков после запятой для параметра сервера.
  static int digitsOf(String code) => switch (code) {
        'rpm' || 'run_hours' => 0,
        'vib_1x' || 'vib_2x' || 'vib_hf' || 'vib_rms' || 'vib_axial' || 'press_in' || 'press_out' => 1,
        _ => 1,
      };

  /// Показания из ответа GET /equipment/{id}/telemetry; подписи берутся из показаний-основы [base].
  static Map<String, Reading> readings(Map<String, dynamic> j, [Map<String, Reading> base = const {}]) {
    final Map<String, Reading> out = {};
    for (final Map<String, dynamic> p in Json.list(j, 'parameters', (Map<String, dynamic> e) => e)) {
      final String code = Json.str(p, 'code');
      final String? key = readingKeys[code];
      if (key == null || p['value'] == null) {
        continue;
      }
      final Reading? b = base[key];
      out[key] = Reading(
        key: key,
        label: b?.label ?? Json.str(p, 'name'),
        short: b?.short ?? Json.str(p, 'name'),
        value: Json.number(p, 'value'),
        unit: Json.str(p, 'unit', b?.unit ?? ''),
        warn: Json.numOrNull(p, 'warn') ?? b?.warn,
        alarm: Json.numOrNull(p, 'alarm') ?? b?.alarm,
        digits: b?.digits ?? digitsOf(code),
      );
    }
    return out;
  }

  /// Тип оборудования по-русски: полное и короткое название по коду типа сервера.
  static const Map<String, (String, String)> kinds = {
    'inline_centrifugal_pump': ('Центробежный насос in-line', 'насос'),
    'progressive_cavity_pump': ('Винтовой насос', 'винтовой насос'),
    'control_cabinet': ('Шкаф управления', 'шкаф управления'),
    'power_transformer': ('Силовой трансформатор', 'трансформатор'),
  };

  /// Обозначение на станции по идентификатору сервера: N-101 - «Н-101», SHU-3 - «ШУ-3», TR-1 - «ТР-1».
  static String codeOf(String id) {
    const Map<String, String> prefixes = {'SHU': 'ШУ', 'AMS': 'АМС', 'TR': 'ТР', 'N': 'Н'};
    for (final MapEntry<String, String> e in prefixes.entries) {
      if (id.startsWith('${e.key}-')) {
        return '${e.value}${id.substring(e.key.length)}';
      }
    }
    return id;
  }

  /// Статус агрегата ok, warn, bad по диагнозу и уровню телеметрии.
  static String unitStatus(String? diagnosis, String? level) {
    if (diagnosis == 'defect' || level == 'alarm' || level == 'bad') {
      return 'bad';
    }
    if (diagnosis == 'check' || level == 'warn') {
      return 'warn';
    }
    return 'ok';
  }

  /// Подпись статуса агрегата.
  static String statusLabel(String status) => switch (status) {
        'bad' => 'Неисправность',
        'warn' => 'Внимание',
        'info' => 'На ремонте',
        _ => 'Норма',
      };

  /// Подпись режима работы.
  static String modeLabel(String mode) => switch (mode) {
        'running' => 'В работе',
        'reserve' => 'В резерве',
        'repair' => 'На ремонте',
        _ => 'Остановлен',
      };

  /// Карточка агрегата из ответа GET /equipment/{id} (или строки списка), показаний и диагноза.
  static Equipment equipment(
    Map<String, dynamic> j, {
    Equipment? base,
    Map<String, Reading>? readings,
    String? diagnosis,
    String? level,
    Resource? resource,
    NextMaintenance? nextTo,
  }) {
    final String id = Json.str(j, 'id');
    final String mode = Json.str(j, 'mode', base?.mode ?? 'running');
    final String status = unitStatus(diagnosis, level);
    final Map<String, Reading> values = readings ?? const <String, Reading>{};
    final Reading? vib = values['vib1x'];
    final Reading? bearing = values['tBearing'];
    final String summary = vib == null
        ? Json.str(j, 'location', base?.location ?? '')
        : [
            'Вибрация 1X ${vib.value.toStringAsFixed(vib.digits).replaceAll('.', ',')} ${vib.unit}',
            if (bearing != null) 'подшипник ${bearing.value.toStringAsFixed(0)} ${bearing.unit}',
          ].join(' · ');
    final Map<String, dynamic> last = Json.objOrNull(j, 'last_inspection') ?? const <String, dynamic>{};
    final String? lastAt = Json.strOrNull(j, 'last_inspection_at') ?? Json.strOrNull(last, 'started_at');
    return Equipment(
      id: id,
      code: base?.code ?? codeOf(id),
      name: Json.str(j, 'name', base?.name ?? id),
      kind: base?.kind ?? kinds[Json.str(j, 'type')]?.$1 ?? Json.str(j, 'type'),
      kindShort: base?.kindShort ?? kinds[Json.str(j, 'type')]?.$2 ?? 'оборудование',
      model: Json.str(j, 'model', base?.model ?? ''),
      modelShort: base?.modelShort ?? Json.str(j, 'model'),
      modelFull: base?.modelFull ?? Json.str(j, 'model'),
      manufacturer: Json.str(j, 'manufacturer', base?.manufacturer ?? ''),
      serial: Json.str(j, 'serial', base?.serial ?? ''),
      location: Json.str(j, 'location', base?.location ?? ''),
      commissioned: Json.str(j, 'commissioned', base?.commissioned ?? ''),
      status: status,
      statusLabel: statusLabel(status),
      mode: mode,
      modeLabel: modeLabel(mode),
      summary: summary,
      runHours: Json.number(j, 'run_hours', base?.runHours ?? 0),
      resource: resource ?? const Resource(label: 'Ресурс: недостаточно данных', used: 0, total: 0, left: 0, status: 'ok'),
      nextTo: nextTo ?? const NextMaintenance(code: '', inHours: 0, atHours: 0, date: ''),
      lastInspection: lastAt == null
          ? (base?.lastInspection ?? const LastInspection(date: '', time: '', who: '', id: ''))
          : LastInspection(
              date: date(lastAt),
              time: time(lastAt),
              who: base?.lastInspection.who ?? '',
              id: Json.str(last, 'id', base?.lastInspection.id ?? ''),
            ),
      specs: base?.specs ?? const <(String, String)>[],
      readings: values,
      maintenance: base?.maintenance ?? const <MaintenanceItem>[],
      nodes: base?.nodes ?? Json.list(j, 'nodes', EquipmentNode.fromJson),
      documents: base?.documents ?? const <EquipmentDocument>[],
      runByMonth: base?.runByMonth ?? const <MonthRun>[],
      openFindings: Json.integer(j, 'open_findings'),
    );
  }

  /// Ресурс узла с наибольшим расчётным износом из ответа GET /equipment/{id}/resource; null - данных нет.
  static Resource? resource(Map<String, dynamic> j) {
    Resource? best;
    double worst = -1;
    for (final Map<String, dynamic> n in Json.list(j, 'nodes', (Map<String, dynamic> e) => e)) {
      final Map<String, dynamic> calc = Json.obj(n, 'calculated');
      final double? used = Json.numOrNull(calc, 'used_percent');
      final double? total = Json.numOrNull(Json.obj(n, 'normative'), 'hours');
      final double? left = Json.numOrNull(calc, 'remaining_hours');
      if (used == null || total == null || left == null || used <= worst) {
        continue;
      }
      worst = used;
      best = Resource(
        label: 'Ресурс: ${Json.str(n, 'name').toLowerCase()}',
        used: total - left,
        total: total,
        left: left,
        status: used >= 100 ? 'bad' : (used >= 80 ? 'warn' : 'ok'),
      );
    }
    return best;
  }

  /// Ближайшее обслуживание по наработке из ответа GET /equipment/{id}/resource; null - данных нет.
  static NextMaintenance? nextMaintenance(Map<String, dynamic> j) {
    NextMaintenance? best;
    for (final Map<String, dynamic> m in Json.list(j, 'maintenance', (Map<String, dynamic> e) => e)) {
      final double? left = Json.numOrNull(m, 'remaining_hours');
      if (left == null || (best != null && left >= best.inHours)) {
        continue;
      }
      best = NextMaintenance(
        code: Json.str(m, 'name', Json.str(m, 'code')),
        inHours: left,
        atHours: Json.number(m, 'last_at_hours') + Json.number(m, 'interval_hours'),
        date: '',
      );
    }
    return best;
  }

  /// Правило из справочника GET /rules.
  static RuleDef rule(Map<String, dynamic> j) => RuleDef(
        id: Json.str(j, 'id'),
        title: Json.str(j, 'title'),
        camera: Json.str(Json.obj(j, 'camera'), 'text'),
        sensor: Json.str(Json.obj(j, 'sensor'), 'text'),
        status: Json.str(Json.obj(j, 'status'), 'status', 'check'),
        severity: Json.integer(j, 'severity', 1),
        recommendation: Json.str(j, 'recommendation'),
      );

  /// Разбор правила по агрегату из GET /equipment/{id}/rules/{rule_id}: условия плоским списком.
  static RuleCheck ruleCheck(Map<String, dynamic> j) {
    final List<Map<String, dynamic>> raw = Json.list(j, 'conditions', (Map<String, dynamic> e) => e);
    final List<RuleCondition> conditions = [
      for (final Map<String, dynamic> c in raw)
        RuleCondition(
          source: Json.str(c, 'source'),
          label: Json.str(c, 'source_title'),
          what: [Json.str(c, 'what'), Json.str(c, 'threshold')].where((String x) => x.isNotEmpty).join(' '),
          state: switch (Json.str(c, 'state')) {
            'met' => 'met',
            'unmet' => 'not',
            _ => 'missing',
          },
          value: Json.str(c, 'value'),
        ),
    ];
    final int met = conditions.where((RuleCondition c) => c.state == 'met').length;
    final String? param = raw.where((Map<String, dynamic> c) => Json.str(c, 'source') == 'sensor').map((Map<String, dynamic> c) => Json.str(c, 'param')).firstOrNull;
    return RuleCheck(
      ruleId: Json.str(j, 'rule_id'),
      unitId: Json.str(j, 'equipment_id'),
      verdict: Json.str(j, 'status_title'),
      count: 'Выполнено $met из ${conditions.length} условий',
      conditions: conditions,
      chartKey: param == null ? null : readingKeys[param],
    );
  }

  /// Часы ряда за период графика.
  static int hoursOf(TelemetryPeriod p) => switch (p) {
        TelemetryPeriod.hour => 6,
        TelemetryPeriod.day => 24,
        TelemetryPeriod.week => 168,
        TelemetryPeriod.month => 720,
      };

  /// Ряд из ответа GET /equipment/{id}/telemetry/{code}?hours=.
  static TelemetrySeries series(Map<String, dynamic> j, String unitId, String key, TelemetryPeriod period, {Reading? base}) {
    final List<Map<String, dynamic>> points = Json.list(j, 'points', (Map<String, dynamic> e) => e);
    final List<double> values = [for (final Map<String, dynamic> p in points) Json.number(p, 'v')];
    final bool long = period == TelemetryPeriod.week || period == TelemetryPeriod.month;
    final List<String> labels = [for (final Map<String, dynamic> p in points) long ? date(Json.str(p, 't')).substring(0, 5) : time(Json.str(p, 't'))];
    if (values.isEmpty) {
      values.add(base?.value ?? 0);
      labels.add('');
    }
    if (values.length == 1) {
      values.add(values.first);
      labels.add(labels.first);
    }
    int peak = 0;
    for (int i = 1; i < values.length; i++) {
      if (values[i] > values[peak]) {
        peak = i;
      }
    }
    final String peakIso = peak < points.length ? Json.str(points[peak], 't') : '';
    return TelemetrySeries(
      unitId: unitId,
      key: key,
      period: period,
      values: values,
      labels: labels,
      label: base?.label ?? Json.str(j, 'name'),
      unit: Json.str(j, 'unit', base?.unit ?? ''),
      digits: base?.digits ?? digitsOf(Json.str(j, 'code')),
      warn: Json.numOrNull(j, 'warn') ?? base?.warn,
      alarm: Json.numOrNull(j, 'alarm') ?? base?.alarm,
      peakValue: values[peak],
      peakLabel: peakIso.isEmpty ? '' : date(peakIso).substring(0, 5),
    );
  }

  /// Срабатывания правил из ответа GET /equipment/{id}/diagnosis.
  static List<DiagnosisResult> diagnosis(Map<String, dynamic> j) => [
        for (final Map<String, dynamic> f in Json.list(j, 'findings', (Map<String, dynamic> e) => e))
          DiagnosisResult(
            ruleId: Json.str(f, 'rule_id'),
            status: Json.str(f, 'status') == 'defect' ? 'bad' : 'warn',
            result: 'match',
            title: Json.str(f, 'title'),
            text: Json.str(f, 'diagnosis'),
            evidence: [
              for (final Map<String, dynamic> e in Json.list(f, 'evidence', (Map<String, dynamic> e) => e))
                Evidence(
                  source: Json.str(e, 'source'),
                  text: [Json.str(e, 'what'), Json.str(e, 'value')].where((String s) => s.isNotEmpty).join(': '),
                  met: Json.flag(e, 'met', true),
                ),
            ],
            missing: Json.strings(f, 'missing'),
          ),
      ];

  /// Осмотр из ответа /inspections.
  static Inspection inspection(Map<String, dynamic> j) {
    final Map<String, dynamic> s = Json.obj(j, 'summary');
    final Map<String, dynamic> by = Json.obj(s, 'by_status');
    final List<Map<String, dynamic>> findings = Json.list(j, 'findings', (Map<String, dynamic> e) => e);
    final bool done = Json.str(j, 'status') == 'finished';
    return Inspection(
      id: Json.str(j, 'id'),
      unitId: Json.str(j, 'equipment_id'),
      date: date(Json.strOrNull(j, 'started_at')),
      time: time(Json.strOrNull(j, 'started_at')),
      duration: duration(Json.numOrNull(s, 'duration_s')),
      who: Json.str(Json.obj(j, 'user'), 'name'),
      status: done ? 'done' : 'draft',
      defects: Json.integer(by, 'defect', findings.where((Map<String, dynamic> f) => Json.str(f, 'status') == 'defect').length),
      checks: Json.integer(by, 'check', findings.where((Map<String, dynamic> f) => Json.str(f, 'status') == 'check').length),
      note: done ? '' : 'Идёт сейчас',
      findingIds: [for (final Map<String, dynamic> f in findings) Json.str(f, 'id')],
    );
  }

  /// Находка из ответа сервера (finding_view).
  static Finding finding(Map<String, dynamic> j, {String author = ''}) {
    final String status = Json.str(j, 'status');
    return Finding(
      id: Json.str(j, 'id'),
      unitId: Json.str(j, 'equipment_id'),
      title: Json.str(j, 'title'),
      ruleId: Json.str(j, 'rule_id'),
      severity: Json.integer(j, 'severity', status == 'defect' ? 2 : 1),
      status: switch (Json.str(j, 'state')) {
        'in_work' => 'confirmed',
        'resolved' => 'closed',
        'rejected' => 'rejected',
        _ => 'new',
      },
      rejectReason: Json.strOrNull(j, 'reject_reason'),
      rejectedAt: Json.strOrNull(j, 'rejected_at') == null ? null : '${date(Json.strOrNull(j, 'rejected_at'))} ${time(Json.strOrNull(j, 'rejected_at'))}',
      source: Json.str(j, 'source'),
      date: date(Json.strOrNull(j, 'created_at')),
      time: time(Json.strOrNull(j, 'created_at')),
      author: Json.str(Json.obj(j, 'user'), 'name', author),
      node: Json.str(j, 'node_name', Json.str(j, 'node_code')),
      evidence: [for (final Map<String, dynamic> e in Json.list(j, 'evidence', (Map<String, dynamic> e) => e)) Json.str(e, 'what')],
      recommendation: Json.str(j, 'recommendation'),
      comment: Json.strOrNull(j, 'comment'),
    );
  }

  /// События истории из ответа GET /equipment/{id}/history.
  static List<HistoryEvent> history(List<dynamic> items, String unitId) {
    final List<HistoryEvent> out = [];
    for (final Map<String, dynamic> e in items.whereType<Map<String, dynamic>>()) {
      final String at = Json.str(e, 'at');
      final String who = Json.str(Json.obj(e, 'user'), 'name');
      if (Json.str(e, 'type') == 'inspection') {
        final Map<String, dynamic> by = Json.obj(Json.obj(e, 'summary'), 'by_status');
        final int defects = Json.integer(by, 'defect');
        final int checks = Json.integer(by, 'check');
        final bool active = Json.str(e, 'status') == 'active';
        out.add(
          HistoryEvent(
            date: date(at),
            time: time(at),
            status: defects > 0 ? 'bad' : (checks > 0 ? 'warn' : (active ? 'info' : 'ok')),
            title: active ? 'Осмотр идёт' : 'Осмотр № ${Json.str(e, 'id')}',
            text: [
              for (final Map<String, dynamic> f in Json.list(e, 'findings', (Map<String, dynamic> x) => x)) Json.str(f, 'title'),
            ].join(' · '),
            who: who,
            unitId: unitId,
            kind: 'inspection',
            label: Json.str(e, 'id'),
          ),
        );
      } else {
        out.add(
          HistoryEvent(
            date: date(at),
            time: time(at),
            status: 'info',
            title: switch (Json.str(e, 'kind')) {
              'replacement' => 'Замена: ${Json.str(e, 'node_name')}',
              'maintenance' => 'Обслуживание: ${Json.str(e, 'node_name')}',
              _ => 'Проверка: ${Json.str(e, 'node_name')}',
            },
            text: Json.str(e, 'comment'),
            who: who,
            unitId: unitId,
            kind: 'maintenance',
          ),
        );
      }
    }
    return out;
  }

  /// Итог осмотра из ответа GET /inspections/{id}.
  static InspectionSummary summary(Map<String, dynamic> j) {
    final Map<String, dynamic> cov = Json.obj(j, 'coverage');
    final List<Map<String, dynamic>> findings = Json.list(j, 'findings', (Map<String, dynamic> e) => e)
        .where((Map<String, dynamic> f) => Json.str(f, 'status') == 'defect' || Json.str(f, 'status') == 'check')
        .toList();
    final String start = Json.str(j, 'started_at');
    final String end = Json.str(j, 'finished_at');
    final Map<String, dynamic> s = Json.obj(j, 'summary');
    return InspectionSummary(
      inspectionId: Json.str(j, 'id'),
      unitId: Json.str(j, 'equipment_id'),
      date: date(start),
      start: time(start),
      end: end.isEmpty ? '' : time(end),
      duration: duration(Json.numOrNull(s, 'duration_s')),
      nodesChecked: Json.integer(cov, 'inspected'),
      nodesTotal: Json.integer(cov, 'total'),
      rulesFired: findings.map((Map<String, dynamic> f) => Json.str(f, 'rule_id')).where((String r) => r.isNotEmpty).toSet().length,
      cameraDefects: findings.where((Map<String, dynamic> f) => Json.str(f, 'source') == 'camera').length,
      photos: Json.list(j, 'findings', (Map<String, dynamic> e) => e).where((Map<String, dynamic> f) => Json.flag(f, 'has_photo')).length,
      sizeMb: 0,
      findings: [
        for (final Map<String, dynamic> f in findings)
          SummaryFinding(
            ruleId: Json.str(f, 'rule_id'),
            title: Json.str(f, 'title'),
            severity: Json.str(f, 'status') == 'defect' ? 'bad' : 'warn',
            sources: Json.str(f, 'source') == 'camera' ? 'Камера' : 'Инженер',
            evidence: Json.list(f, 'evidence', Evidence.fromJson),
            recommendation: Json.str(f, 'recommendation'),
          ),
      ],
    );
  }
}
