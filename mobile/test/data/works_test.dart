import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kst_vizor/data/api/api_client.dart';
import 'package:kst_vizor/data/api/api_feed.dart';
import 'package:kst_vizor/data/api/api_repositories.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/repos/mock_inspection_repository.dart';
import 'package:kst_vizor/data/repositories/change_feed.dart';
import 'package:kst_vizor/data/repositories/inspection_repository.dart';

/// Поля формы multipart из тела запроса: имя поля -> значение.
Map<String, String> _form(http.Request req) {
  final String body = utf8.decode(req.bodyBytes);
  final Map<String, String> out = {};
  for (final RegExpMatch m in RegExp(r'name="([^"]+)"(?:\r\n[^\r\n]+)*\r\n\r\n([^\r]*)\r\n').allMatches(body)) {
    out[m.group(1)!] = m.group(2)!;
  }
  return out;
}

void main() {
  late List<Map<String, String>> posted;
  late List<KvDomain> notified;
  late ApiInspectionRepository repo;
  late StreamSubscription<KvDomain> sub;

  setUp(() {
    posted = [];
    notified = [];
    final ApiClient api = ApiClient(
      'http://srv',
      client: MockClient((http.Request req) async {
        if (req.method == 'POST' && req.url.path == '/inspections/7/findings') {
          posted.add(_form(req));
          return http.Response.bytes(utf8.encode(jsonEncode({'id': 1, 'kind': _form(req)['kind']})), 201);
        }
        if (req.url.path == '/equipment/N-101/resource') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({
              'nodes': <dynamic>[],
              'maintenance': [
                {'code': 'TO-1', 'name': 'ТО-1', 'remaining_hours': 10},
                {'code': 'TR', 'name': 'Ревизия', 'remaining_hours': 900},
              ],
            })),
            200,
          );
        }
        return http.Response.bytes(utf8.encode('{"detail":"Не найдено"}'), 404);
      }),
    );
    final ApiFeed feed = ApiFeed();
    sub = feed.changes.listen(notified.add);
    repo = ApiInspectionRepository(api, MockInspectionRepository(MockBackend(latency: MockLatency.none)), feed);
  });

  tearDown(() => sub.cancel());

  test('замена узла уходит видом replacement с узлом и обновляет агрегат и ресурс', () async {
    await repo.addWork('7', 'N-101', kind: WorkKind.replacement, node: 'motor_bearings', comment: ' Подшипники SKF 6309 ');
    await Future<void>.delayed(Duration.zero);
    expect(posted, [
      {'kind': 'replacement', 'node': 'motor_bearings', 'comment': 'Подшипники SKF 6309'},
    ]);
    expect(notified, containsAll(<KvDomain>[KvDomain.inspections, KvDomain.equipment, KvDomain.plan]));
  });

  test('обслуживание передаёт вид по регламенту, заметка - без узла и без кода', () async {
    await repo.addWork('7', 'N-101', kind: WorkKind.maintenance, maintenanceCode: 'TO-1');
    await repo.addWork('7', 'N-101', kind: WorkKind.note, comment: 'Шум со стороны привода', maintenanceCode: 'TO-1');
    expect(posted, [
      {'kind': 'maintenance', 'maintenance_code': 'TO-1'},
      {'kind': 'note', 'comment': 'Шум со стороны привода'},
    ]);
  });

  test('виды обслуживания берутся из регламента агрегата на сервере', () async {
    final List<MaintenanceKind> kinds = await repo.maintenanceKinds('N-101');
    expect(kinds, [(code: 'TO-1', name: 'ТО-1'), (code: 'TR', name: 'Ревизия')]);
  });
}
