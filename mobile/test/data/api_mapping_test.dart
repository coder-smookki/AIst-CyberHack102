import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kst_vizor/data/api/api_client.dart';
import 'package:kst_vizor/data/api/api_config.dart';
import 'package:kst_vizor/data/api/api_mappers.dart';
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
}

/// Первая находка из ответа осмотра [s].
Map<String, dynamic> _firstFinding(String s) => (_j(s)['findings'] as List<dynamic>).first as Map<String, dynamic>;
