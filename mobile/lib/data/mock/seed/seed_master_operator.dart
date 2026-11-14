import '../../models/inspection.dart';
import '../../models/workflow.dart';
import '../mock_db.dart';

/// Дополнения демонстрационных данных раздела «Мастер и оператор» поверх истории 14.11.2026.
///
/// Вызывается после seedStory и seedBase. Добавляет то, что экраны мастера и оператора показывают из данных,
/// а история прототипа задаёт только текстом экранов: комментарии инженера и работы по находкам, просроченную поверку
/// манометра в плане ТО, ход работ по закрытому сообщению S-071, переходы уведомлений и прочитанные записи ленты.
/// Переходы уведомлений - пути приложения (MasterOperatorPaths).
void seedMasterOperator(MockDb db) {
  for (int i = 0; i < db.findings.length; i++) {
    final Finding f = db.findings[i];
    final String? comment = switch (f.id) {
      'F-1043' => 'Капли и влажное пятно у вала. Шум подшипника со стороны привода, по датчикам рост 3 сут.',
      'F-1041' => 'Течь торцевого уплотнения, лужа под агрегатом. Агрегат остановлен по S05.',
      _ => null,
    };
    if (comment != null) {
      db.findings[i] = f.copyWith(comment: comment);
    }
    if (f.id == 'F-1036') {
      db.findings[i] = f.copyWith(planned: 'Проверка балансировки при ТО-2');
    }
  }

  db.plan.insert(
    0,
    const PlanItem(
      id: 'P-499',
      unitId: 'N-101',
      work: 'Поверка манометра на нагнетании',
      date: '12.11.2026',
      time: '09:00',
      who: 'не назначен',
      status: 'overdue',
      basis: 'Межповерочный интервал 12 мес',
    ),
  );

  for (int i = 0; i < db.faultReports.length; i++) {
    final FaultReport r = db.faultReports[i];
    if (r.id == 'S-071') {
      db.faultReports[i] = r.copyWith(timeline: const [
        FaultStep(time: '09.11, 22:15', title: 'Сообщение отправлено', who: 'Анна Лебедева'),
        FaultStep(time: '09.11, 22:24', title: 'Мастер назначил осмотр', who: 'Николай Гусев → Елена Титова'),
        FaultStep(time: '09.11, 23:05', title: 'Осмотр выполнен', who: 'Внешних дефектов не выявлено, шум подшипника - под наблюдением'),
        FaultStep(time: '10.11, 07:50', title: 'Сообщение закрыто', who: 'Николай Гусев'),
      ]);
    }
  }

  const Map<String, String> targets = {
    'm1': '/master/findings/finding/F-1043',
    'm2': '/master/findings/finding/F-1042',
    'm3': '/master/shift/report/S-077',
    'o1': '/operator/objects/repair/AMS-2',
    'o2': '/operator/history/report/S-077',
  };
  const Set<String> read = {'m2', 'm3'};
  for (final String role in const ['master', 'operator']) {
    final List<AppNotification>? list = db.notifications[role];
    if (list == null) {
      continue;
    }
    for (int i = 0; i < list.length; i++) {
      final AppNotification n = list[i];
      list[i] = AppNotification(id: n.id, time: n.time, kind: n.kind, title: n.title, text: n.text, target: targets[n.id] ?? n.target, read: read.contains(n.id));
    }
  }
}
