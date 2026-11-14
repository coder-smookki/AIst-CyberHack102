import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/core/kv.dart';
import 'package:kst_vizor/data/api/api_mappers.dart';
import 'package:kst_vizor/data/models/inspection.dart';
import 'package:kst_vizor/features/engineer_service/service_common.dart';

void main() {
  test('старый сервер без итога: null, экраны показывают итог как раньше', () {
    expect(InspectionVerdict.fromJson({'summary': {'findings': 0, 'duration_s': 60}}), isNull);
    expect(InspectionVerdict.fromJson({}), isNull);
    final InspectionSummary s = ApiMap.summary({'id': 3, 'equipment_id': 'N-101', 'summary': {'duration_s': 60}});
    expect(s.verdict, isNull);
  });

  test('неполный осмотр: название и узлы из summary', () {
    final InspectionSummary s = ApiMap.summary({
      'id': 5,
      'equipment_id': 'N-101',
      'summary': {
        'status': 'incomplete',
        'status_title': 'Осмотр неполный',
        'uninspected': [
          {'code': 'seal', 'name': 'Торцевое уплотнение'},
          {'code': 'gauge', 'name': 'Манометр на нагнетании'},
        ],
      },
    });
    final InspectionVerdict v = s.verdict!;
    expect(v.incomplete, isTrue);
    expect(v.title, 'Осмотр неполный');
    expect(v.uninspected.map((UninspectedNode n) => n.code), ['seal', 'gauge']);
    expect(v.uninspectedText, 'Торцевое уплотнение, Манометр на нагнетании');
  });

  test('дефект побеждает, но неосмотренные узлы всё равно перечислены', () {
    final InspectionVerdict v = InspectionVerdict.fromJson({
      'summary': {
        'status': 'defect',
        'status_title': 'Обнаружен дефект',
        'uninspected': [
          {'code': 'coupling', 'name': 'Муфта'},
        ],
      },
    })!;
    expect(v.status, 'defect');
    expect(v.incomplete, isTrue);
    expect(InspectionVerdictBlock.tone(v), KvStatus.bad);
  });

  test('данные отчёта: overall и uninspected верхнего уровня; повреждённые элементы пропускаются', () {
    final InspectionVerdict v = InspectionVerdict.fromJson({
      'overall': {'status': 'incomplete', 'title': 'Осмотр неполный'},
      'uninspected': [
        {'code': 'motor', 'name': ''},
        'Фланцы',
        42,
        null,
        {'name': 7},
      ],
    })!;
    expect(v.title, 'Осмотр неполный');
    expect(v.uninspected, [(code: 'motor', name: 'motor'), (code: 'Фланцы', name: 'Фланцы')]);
    expect(InspectionVerdictBlock.tone(v), KvStatus.warn);
  });

  test('статус incomplete без названия получает русское название', () {
    final InspectionVerdict v = InspectionVerdict.fromJson({'summary': {'status': 'incomplete', 'uninspected': 'не список'}})!;
    expect(v.title, 'Осмотр неполный');
    expect(v.uninspected, isEmpty);
  });

  testWidgets('блок итога: чип и список неосмотренных узлов', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: KvTheme.light,
        home: const Scaffold(
          body: InspectionVerdictBlock(
            verdict: InspectionVerdict(status: 'incomplete', title: 'Осмотр неполный', uninspected: [(code: 'seal', name: 'Торцевое уплотнение')]),
          ),
        ),
      ),
    );
    expect(find.text('Осмотр неполный'), findsOneWidget);
    expect(find.textContaining('Не осмотрены: Торцевое уплотнение'), findsOneWidget);
  });
}
