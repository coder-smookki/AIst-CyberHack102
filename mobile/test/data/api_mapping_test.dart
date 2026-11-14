import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kst_vizor/data/api/api_client.dart';
import 'package:kst_vizor/data/api/api_config.dart';
import 'package:kst_vizor/data/api/api_mappers.dart';
import 'package:kst_vizor/data/api/api_sound.dart';
import 'package:kst_vizor/data/api_exception.dart';
import 'package:kst_vizor/data/models/equipment.dart';
import 'package:kst_vizor/data/models/inspection.dart';

/// Ответы сервера в том виде, в каком их отдаёт server/ (сокращённо).
const String _telemetry = '''
{"equipment_id":"N-101","available":true,"level":"warn","parameters":[
 {"code":"rpm","name":"Частота вращения","unit":"об/мин","warn":null,"alarm":null,"value":2958.0},
 {"code":"vib_1x","name":"Амплитуда вибрации 1x","unit":"мм/с","warn":2.8,"alarm":4.5,"value":3.1},
 {"code":"temp_bearing","name":"Температура подшипника","unit":"°C","warn":75,"alarm":90,"value":78.0}]}''';

const String _series = '''
{"code":"vib_1x","name":"Амплитуда вибрации 1x","unit":"мм/с","warn":2.8,"alarm":4.5,
 "points":[{"t":"2026-11-10T08:00:00","v":0.84},{"t":"2026-11-10T09:00:00","v":3.2},{"t":"2026-11-10T10:00:00","v":0.85}]}''';

const String _diagnosis = '''
{"status":"check","findings":[{"rule_id":"R01","title":"Течь уплотнения","node_id":"seal","status":"check","severity":2,
 "diagnosis":"Возможная течь","recommendation":"Осмотреть","confidence":0.6,
 "evidence":[{"source":"camera","what":"Подтёк у вала","value":"уверенность 0,61","threshold":"от 0,25","met":true}],
 "missing":["наведите камеру на зону уплотнения вала"]}]}''';

const String _inspection = '''
{"id":5,"equipment_id":"N-101","user":{"id":1,"name":"Алексей Смирнов"},"started_at":"2026-11-14T09:30:00",
 "finished_at":"2026-11-14T09:56:00","status":"finished","summary":{"findings":2,"by_status":{"ok":1,"check":0,"defect":1},"duration_s":1560},
 "coverage":{"percent":71,"inspected":5,"total":7},
 "findings":[{"id":9,"node_code":"seal","node_name":"Торцевое уплотнение","source":"camera","rule_id":"R01","status":"defect",
  "severity":2,"title":"Подтёк у вала","evidence":[{"source":"camera","what":"Подтёк","value":"0,7","met":true}],"has_photo":true,
  "state":"open","created_at":"2026-11-14T09:40:00"},
  {"id":10,"node_code":"coupling","node_name":"Муфта","source":"manual","status":"ok","state":"resolved","created_at":"2026-11-14T09:45:00"}]}''';

Map<String, dynamic> _j(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  test('показания сервера переводятся в ключи приложения с уставками', () {
    final Map<String, Reading> r = ApiMap.readings(_j(_telemetry));
    expect(r.keys, containsAll(<String>['vib1x', 'tBearing']));
    expect(r.containsKey('rpm'), isFalse);
    expect(r['vib1x']!.value, 3.1);
    expect(r['vib1x']!.warn, 2.8);
    expect(r['vib1x']!.status, 'warn');
  });

  test('ряд телеметрии: значения, подписи и пик', () {
    final TelemetrySeries s = ApiMap.series(_j(_series), 'N-101', 'vib1x', TelemetryPeriod.day);
    expect(s.values, <double>[0.84, 3.2, 0.85]);
    expect(s.labels.first, '08:00');
    expect(s.peakValue, 3.2);
    expect(s.peakLabel, '10.11');
    expect(s.alarm, 4.5);
  });

  test('диагноз: правило, статус и основания', () {
    final List<DiagnosisResult> d = ApiMap.diagnosis(_j(_diagnosis));
    expect(d, hasLength(1));
    expect(d.single.ruleId, 'R01');
    expect(d.single.status, 'warn');
    expect(d.single.evidence.single.text, 'Подтёк у вала: уверенность 0,61');
    expect(d.single.missing.single, contains('уплотнения'));
  });

  test('осмотр и итог осмотра', () {
    final Inspection i = ApiMap.inspection(_j(_inspection));
    expect(i.id, '5');
    expect(i.status, 'done');
    expect(i.date, '14.11.2026');
    expect(i.time, '09:30');
    expect(i.duration, '26 мин');
    expect(i.defects, 1);
    expect(i.findingIds, <String>['9', '10']);
    final InspectionSummary s = ApiMap.summary(_j(_inspection));
    expect(s.nodesChecked, 5);
    expect(s.nodesTotal, 7);
    expect(s.findings.single.ruleId, 'R01');
    expect(s.photos, 1);
    expect(s.end, '09:56');
  });

  test('находка и карточка агрегата со статусом по диагнозу', () {
    final Finding f = ApiMap.finding(_firstFinding(_inspection));
    expect(f.id, '9');
    expect(f.node, 'Торцевое уплотнение');
    expect(f.status, 'new');
    final Equipment e = ApiMap.equipment(
      _j('{"id":"N-101","name":"Насос Н-101","model":"IL 65/160","serial":"2786107-0142","mode":"running","run_hours":19190.0}'),
      readings: ApiMap.readings(_j(_telemetry)),
      diagnosis: 'defect',
    );
    expect(e.status, 'bad');
    expect(e.modeLabel, 'В работе');
    expect(e.serial, '2786107-0142');
    expect(e.summary, contains('3,1'));
  });

  test('адрес сервера дополняется схемой и очищается', () {
    expect(normalizeServerUrl(' 192.168.1.152:8765/ '), 'http://192.168.1.152:8765');
    expect(normalizeServerUrl(''), kDefaultServerUrl);
  });

  test('клиент обновляет токен при 401 и переводит отказы в KvApiException', () async {
    int calls = 0;
    final ApiClient api = ApiClient(
      'http://srv',
      client: MockClient((http.Request req) async {
        if (req.url.path == '/auth/refresh') {
          return http.Response(jsonEncode({'access_token': 'new', 'refresh_token': 'r2'}), 200);
        }
        if (req.url.path == '/equipment') {
          calls++;
          return req.headers['authorization'] == 'Bearer new' ? http.Response('[]', 200) : http.Response.bytes(utf8.encode('{"detail":"Токен истёк"}'), 401);
        }
        return http.Response.bytes(utf8.encode(jsonEncode({'detail': 'Не найдено'})), 404);
      }),
    )
      ..accessToken = 'old'
      ..refreshToken = 'r1';
    expect(await api.getJson('/equipment'), isEmpty);
    expect(calls, 2);
    expect(api.refreshToken, 'r2');
    await expectLater(api.getJson('/x'), throwsA(isA<KvApiException>().having((KvApiException e) => e.failure, 'failure', KvFailure.notFound)));
    expect(api.ws('/ws/detect').toString(), 'ws://srv/ws/detect?token=new');
  });

  test('справочник правил GET /rules и разбор правила по агрегату', () {
    final RuleDef r = ApiMap.rule(_j('''
{"id":"R01","title":"Деградация уплотнения вала","camera":{"text":"Влажное пятно у вала","signs":[{"code":"leak","title":"Течь"}]},
 "sensor":{"text":"Рост вибрации и температуры","conditions":[]},"status":{"status":"defect","status_title":"Правило сработало"},
 "severity":3,"severity_title":"критично","recommendation":"Перевести насос в резерв."}'''));
    expect(r.id, 'R01');
    expect(r.camera, 'Влажное пятно у вала');
    expect(r.status, 'defect');
    expect(r.severity, 3);
    final RuleCheck c = ApiMap.ruleCheck(_j('''
{"equipment_id":"N-101","rule_id":"R01","status_title":"Недостаточно данных для проверки правила","conditions":[
 {"source":"camera","source_title":"Камера","what":"Течь у вала","threshold":">= 0.5","state":"unknown","value":"нет данных"},
 {"source":"sensor","source_title":"Датчики","param":"vib_hf","what":"ВЧ шум вибрации","threshold":"> 2.5 g","state":"unmet","value":"0.15 g"},
 {"source":"sensor","source_title":"Датчики","param":"temp_bearing","what":"Температура подшипника","threshold":"> 75 °C","state":"met","value":"78 °C"}]}'''));
    expect(c.verdict, 'Недостаточно данных для проверки правила');
    expect(c.count, 'Выполнено 1 из 3 условий');
    expect(c.conditions.map((RuleCondition x) => x.state), <String>['missing', 'not', 'met']);
    expect(c.conditions.first.label, 'Камера');
    expect(c.chartKey, 'vibHf');
  });

  test('отклонённая мастером находка', () {
    final Finding f = ApiMap.finding(_j('''
{"id":12,"equipment_id":"N-101","node_name":"Корпус","status":"defect","state":"rejected","reject_reason":"Блик на краске",
 "rejected_at":"2026-11-14T18:05:00","created_at":"2026-11-14T17:50:00","title":"Коррозия"}'''));
    expect(f.status, 'rejected');
    expect(f.rejectReason, 'Блик на краске');
    expect(f.rejectedAt, '14.11.2026 18:05');
  });

  test('разбор шума: уровень к норме, полосы, пики, спектр и признак-кандидат', () {
    final SoundResult r = SoundResult.fromJson(_j('''
{"id":7,"inspection_id":12,"duration_s":8.0,"level_dbfs":-21.5,"peak_dbfs":-3.2,"crest_factor":5.1,"kurtosis":6.3,
 "bands":[{"code":"low","title":"Низкие","from_hz":20,"to_hz":200,"share":0.4,"db":-25.0}],
 "shaft_hz":48.3,"peaks":[{"freq_hz":48.5,"prominence_db":12.0,"match":"1x","match_title":"1× оборотов"}],
 "spectrum":[{"f":20,"db":-60},{"f":50,"db":-35}],
 "baseline":{"dbfs":-29.9,"source":"recordings","recordings":3,"title":"по трём записям","delta_db":8.4},
 "candidates":[{"sign":"noise_high","title":"Повышенный шум","text":"Шум на 8 дБ выше нормы","value":"+8,4 дБ","confirm":{"kind":"defect","sign":"noise_high"}}],
 "normal":false,"note":"Кандидаты не записаны"}'''));
    expect(r.id, '7');
    expect(r.levelDb, -21.5);
    expect(r.deltaDb, 8.4);
    expect(r.bands.single.share, 0.4);
    expect(r.peaks.single.match, '1x');
    expect(r.spectrum, hasLength(2));
    expect(r.candidates.single.sign, 'noise_high');
    expect(r.candidates.single.explanation, 'Шум на 8 дБ выше нормы');
  });

  test('новые типы оборудования: русские названия и обозначения, без ресурса и показаний', () {
    final Equipment e = ApiMap.equipment(_j('{"id":"SHU-3","name":"Шкаф управления ШУ-3","type":"control_cabinet","model":"ШУ","serial":"2408-0317","mode":"running","run_hours":48200.0}'));
    expect(e.code, 'ШУ-3');
    expect(e.kind, 'Шкаф управления');
    expect(e.kindShort, 'шкаф управления');
    expect(e.readings, isEmpty);
    expect(e.resource.total, 0);
    expect(ApiMap.codeOf('TR-1'), 'ТР-1');
    expect(ApiMap.codeOf('N-101'), 'Н-101');
    expect(ApiMap.kinds['power_transformer']!.$1, 'Силовой трансформатор');
  });
}

/// Первая находка из ответа осмотра [s].
Map<String, dynamic> _firstFinding(String s) => (_j(s)['findings'] as List<dynamic>).first as Map<String, dynamic>;
