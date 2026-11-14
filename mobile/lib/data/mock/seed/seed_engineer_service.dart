import '../../models/inspection.dart';
import '../../models/workflow.dart';
import '../mock_db.dart';

/// Дополнения демонстрационных данных раздела «Инженер: итоги и сервис» поверх истории 14.11.2026.
///
/// Вызывается после seedStory и seedBase: итоги осмотров INS-2209 и INS-2207 для экранов итога, отчёта и очереди
/// отправки, общая лента «Истории», лента уведомлений инженера, время назначения и указания заданий T-318 и T-317,
/// диалог ассистента в формулировках прототипа.
void seedEngineerService(MockDb db) {
  db.summaries.addAll(const {
    'INS-2209': InspectionSummary(
      inspectionId: 'INS-2209',
      unitId: 'N-101',
      date: '14.11.2026',
      start: '09:20',
      end: '09:34',
      duration: '14 мин',
      nodesChecked: 5,
      nodesTotal: 9,
      rulesFired: 6,
      cameraDefects: 2,
      photos: 6,
      sizeMb: 18.4,
      reportSizeMb: 1.2,
      reportPages: 2,
      sentAt: '09:35',
      reportAt: '09:35',
      findings: [
        SummaryFinding(
          ruleId: 'R01',
          title: 'Деградация уплотнения вала',
          severity: 'critical',
          sources: 'камера и датчики',
          evidence: [
            Evidence(source: 'camera', text: 'Камера: капли и влажное пятно у вала, 09:31'),
            Evidence(source: 'sensor', text: 'Вибрация 1X 3,1 мм/с, уставка 2,8 мм/с'),
            Evidence(source: 'sensor', text: 'Подшипник 78 °C, уставка 75 °C'),
          ],
          recommendation: 'Рекомендуется перевести насос в резерв и заменить уплотнение.',
          frame: 'Течь у вала',
        ),
        SummaryFinding(
          ruleId: 'R04',
          title: 'Плохой контакт в клеммной коробке',
          severity: 'check',
          sources: 'только камера, рекомендуется проверка',
          evidence: [
            Evidence(source: 'camera', text: 'Камера: потемнение изоляции у клемм, 09:30'),
            Evidence(source: 'sensor', text: 'Небаланс токов 2,1 %, порог 5 %'),
          ],
          recommendation: 'Признаки возможного дефекта, рекомендуется проверка по наряду.',
          frame: 'Следы перегрева клемм',
        ),
        SummaryFinding(
          ruleId: 'R08',
          title: 'Признаки износа подшипника',
          severity: 'planned',
          sources: 'датчики',
          relatedRules: ['S01', 'S04'],
          evidence: [
            Evidence(source: 'sensor', text: 'Вибрация 1X 2,4 → 3,1 мм/с за 3 сут'),
            Evidence(source: 'sensor', text: 'Подшипник 71 → 78 °C за 3 сут'),
            Evidence(source: 'sensor', text: 'Ток 9,8 А - в норме'),
          ],
          recommendation: 'Проверить смазку подшипникового узла, запланировать замену подшипника.',
        ),
      ],
      notes: [SummaryNote(title: 'шум подшипника', time: '09:28', length: '0:14', sentAt: '09:36')],
    ),
    'INS-2207': InspectionSummary(
      inspectionId: 'INS-2207',
      unitId: 'AMS-2',
      date: '14.11.2026',
      start: '06:53',
      end: '07:05',
      duration: '12 мин',
      nodesChecked: 4,
      nodesTotal: 4,
      rulesFired: 2,
      cameraDefects: 1,
      photos: 4,
      sizeMb: 12.1,
      sentAt: '07:06',
      findings: [
        SummaryFinding(
          ruleId: 'R01',
          title: 'Течь торцевого уплотнения, перегрев обмоток',
          severity: 'critical',
          sources: 'камера и датчики',
          evidence: [
            Evidence(source: 'camera', text: 'Камера: течь у вала, лужа под агрегатом'),
            Evidence(source: 'sensor', text: 'Обмотка 112 °C, аварийная уставка 110 °C'),
          ],
          frame: 'Лужа под агрегатом',
        ),
      ],
    ),
  });

  db.activity.addAll(const [
    HistoryEvent(date: '14.11.2026', time: '09:34', status: 'bad', title: 'Н-101 · осмотр', text: '2 дефекта, R01', who: 'Алексей Смирнов', unitId: 'N-101', kind: 'inspection', label: 'Дефект', target: '/engineer/c-report'),
    HistoryEvent(date: '14.11.2026', time: '08:12', status: 'warn', title: 'Н-101 · правило R08', text: 'вибрация 3,1 мм/с', who: 'Система', unitId: 'N-101', kind: 'rule', label: 'Внимание', target: '/engineer/objects/diagnostics'),
    HistoryEvent(date: '14.11.2026', time: '07:30', status: 'info', title: 'АМС-2 · ремонт назначен', text: 'на 15.11, 08:00', who: 'Марина Орлова', unitId: 'AMS-2', kind: 'plan', label: 'План', target: '/engineer/objects/card/AMS-2'),
    HistoryEvent(date: '14.11.2026', time: '07:05', status: 'bad', title: 'АМС-2 · осмотр', text: 'течь уплотнения', who: 'Алексей Смирнов', unitId: 'AMS-2', kind: 'inspection', label: 'Дефект', target: '/engineer/objects/card/AMS-2'),
    HistoryEvent(date: '14.11.2026', time: '06:44', status: 'bad', title: 'АМС-2 · остановка, S05', text: 'обмотка 112 °C', who: 'Система', unitId: 'AMS-2', kind: 'alarm', label: 'Авария', target: '/engineer/objects/card/AMS-2'),
    HistoryEvent(date: '13.11.2026', time: '16:40', status: 'warn', title: 'Н-101 · плановый осмотр', text: 'шум подшипника', who: 'Алексей Смирнов', unitId: 'N-101', kind: 'inspection', label: 'Внимание', target: '/engineer/objects/card/N-101/history'),
    HistoryEvent(date: '12.11.2026', time: '10:20', status: 'ok', title: 'АМС-1 · плановый осмотр', text: 'замечание снято', who: 'Елена Титова', unitId: 'AMS-1', kind: 'inspection', label: 'Закрыто', target: '/engineer/objects/card/AMS-1'),
    HistoryEvent(date: '12.11.2026', time: '10:05', status: 'warn', title: 'Н-101 · подшипник 76 °C', text: 'правило S04', who: 'Система', unitId: 'N-101', kind: 'reading', label: 'Внимание', target: '/engineer/objects/card/N-101/charts'),
    HistoryEvent(date: '10.11.2026', time: '11:30', status: 'unk', title: 'Н-101 · осмотр после тревоги', text: 'дефектов не выявлено', who: 'Алексей Смирнов', unitId: 'N-101', kind: 'inspection', label: 'Без находок', target: '/engineer/objects/card/N-101/history'),
    HistoryEvent(date: '10.11.2026', time: '08:20', status: 'bad', title: 'Н-101 · вибрация 4,8 мм/с', text: 'уставка 4,5 мм/с', who: 'Система', unitId: 'N-101', kind: 'alarm', label: 'Авария', target: '/engineer/objects/card/N-101/charts'),
    HistoryEvent(date: '28.10.2026', time: '14:10', status: 'unk', title: 'АМС-1 · плановый осмотр', text: 'отклонений не выявлено', who: 'Елена Титова', unitId: 'AMS-1', kind: 'inspection', label: 'Без находок', target: '/engineer/objects/card/AMS-1'),
    HistoryEvent(date: '28.10.2026', time: '14:35', status: 'unk', title: 'АМС-2 · плановый осмотр', text: 'отклонений не выявлено', who: 'Елена Титова', unitId: 'AMS-2', kind: 'inspection', label: 'Без находок', target: '/engineer/objects/card/AMS-2'),
  ]);

  db.notifications['engineer'] = [
    const AppNotification(id: 'n-e1', time: '09:12', kind: 'info', title: 'Новое задание от мастера', text: 'Н-101 · осмотр по R08 до 10:00', target: '/engineer/task/T-318'),
    const AppNotification(id: 'n-e2', time: '08:12', kind: 'warn', title: 'Н-101: сработало правило R08', text: 'Вибрация 1X 3,1 мм/с · подшипник 78 °C', target: '/engineer/objects/diagnostics'),
    const AppNotification(id: 'n-e3', time: '08:00', kind: 'warn', title: 'Н-101: ТО-2 через 10 ч', text: 'Наработка 19 190 из 19 200 ч · план 15.11, 10:00', target: '/engineer/objects/card/N-101'),
    const AppNotification(id: 'n-e4', time: '09:35', kind: 'ok', title: 'Синхронизация завершена', text: 'INS-2209 на сервере цеха', target: '/engineer/c-queue-ok', read: true),
    const AppNotification(id: 'n-e5', time: '06:52', kind: 'info', title: 'Задание: осмотр АМС-2', text: 'Течь под агрегатом · О. Кузнецова', target: '/engineer/task/T-317', read: true),
    const AppNotification(id: 'n-e6', time: '06:44', kind: 'bad', title: 'АМС-2: тревога S05, остановка', text: 'Обмотка 112 °C, аварийная уставка 110 °C', target: '/engineer/objects/card/AMS-2', read: true),
  ];

  const Map<String, (String, String)> taskDetails = {
    'T-318': ('09:12', 'Осмотреть подшипниковый узел и зону уплотнения вала, проверить смазку и шум со стороны привода.'),
    'T-317': ('06:52', 'Осмотреть агрегат по сообщению оператора: место течи, уплотнение вала, нагрев двигателя.'),
  };
  for (int i = 0; i < db.tasks.length; i++) {
    final (String, String)? d = taskDetails[db.tasks[i].id];
    if (d != null) {
      db.tasks[i] = db.tasks[i].copyWith(assignedAt: d.$1, instructions: d.$2);
    }
  }

  db.assistantDialog
    ..clear()
    ..addAll(const [
      AssistantMessage(fromUser: true, text: 'Почему растёт вибрация Н-101?', time: '09:38'),
      AssistantMessage(
        fromUser: false,
        time: '09:38',
        text: 'Вибрация 1X выросла с 2,4 до 3,1 мм/с за 3 суток, подшипник - с 71 до 78 °C, ток в норме. '
            'Это признаки возможного износа подшипника, рекомендуется проверка смазки.',
        refs: ['R08'],
        links: [
          AssistantLink(title: 'Правило R08 · диагностика', deeplink: '/engineer/objects/diagnostics', kind: 'rule'),
          AssistantLink(title: 'График вибрации 1X', deeplink: '/engineer/objects/card/N-101/charts', kind: 'chart'),
        ],
        source: 'По данным датчиков и истории Н-101',
      ),
    ]);
}
