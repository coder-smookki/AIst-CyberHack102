import '../../models/inspection.dart';
import '../mock_db.dart';

/// Дополнения демонстрационных данных раздела «Инженер: осмотр» поверх истории 14.11.2026.
///
/// Вызывается после seedStory и seedBase: маршруты осмотра, разборы правил, привязка рамок камеры к агрегатам,
/// время срабатывания R08 и пик вибрации по журналу датчика.
void seedEngineerInspect(MockDb db) {
  _detections(db);
  _routes(db);
  _ruleChecks(db);
  _firedAt(db, 'N-101', 'R08', '08:12');
  db.sensorPeaks['N-101/vib1x'] = (value: 4.8, label: '10.11');
}

/// Рамки кадра camera.jpg: насос Н-101 крупным планом и лужа под АМС-2 у пола.
void _detections(MockDb db) {
  final List<Detection> tagged = [
    for (final Detection d in db.detections)
      Detection(kind: d.kind, label: d.label, x: d.x, y: d.y, w: d.w, h: d.h, unitId: d.label == 'Лужа под агрегатом' ? 'AMS-2' : 'N-101'),
  ];
  db.detections
    ..clear()
    ..addAll(tagged);
}

/// Маршруты осмотра (ROUTE прототипа): Н-101 в середине обхода, АМС-1 и АМС-2 - перед обходом.
void _routes(MockDb db) {
  db.routes['N-101'] = const [
    RouteStep(
      n: 1,
      nodeId: 'motor_bearings',
      name: 'Подшипники двигателя',
      why: 'sensor',
      reason: 'Датчики · R08: 3,1 мм/с, 78 °C',
      result: 'warn',
      note: 'Шум со стороны привода',
    ),
    RouteStep(
      n: 2,
      nodeId: 'seal',
      name: 'Торцевое уплотнение',
      why: 'sensor',
      reason: 'Датчики · R01: вибрация и нагрев растут',
      result: 'bad',
      note: 'Капли у вала · признак дефекта',
    ),
    RouteStep(
      n: 3,
      nodeId: 'frame',
      name: 'Анкерные болты и рама',
      why: 'finding',
      reason: 'Прошлая находка F-1036 · 4,8 мм/с 10.11',
      result: 'ok',
      note: 'Ослабления не выявлено',
    ),
    RouteStep(
      n: 4,
      nodeId: 'terminal_box',
      name: 'Клеммная коробка',
      why: 'resource',
      reason: 'Ресурс · ТО-2 через 10 ч',
      result: 'warn',
      note: 'Потемнение изоляции',
    ),
    RouteStep(n: 5, nodeId: 'coupling', name: 'Кожух муфты', why: 'routine', reason: 'Регламент · R06', result: 'ok', note: 'На месте'),
    RouteStep(
      n: 6,
      nodeId: 'gauge',
      name: 'Манометр на нагнетании',
      why: 'routine',
      reason: 'Регламент · R05: сверка с датчиком',
      result: 'next',
    ),
    RouteStep(n: 7, nodeId: 'flanges', name: 'Фланцевые соединения', why: 'routine', reason: 'Регламент ТО-1'),
    RouteStep(n: 8, nodeId: 'casing', name: 'Корпус насоса', why: 'routine', reason: 'Регламент ТО-1'),
    RouteStep(n: 9, nodeId: 'motor', name: 'Электродвигатель снаружи', why: 'routine', reason: 'Регламент · крышка вентилятора'),
  ];
  db.routes['AMS-1'] = const [
    RouteStep(
      n: 1,
      nodeId: 'frame',
      name: 'Рама и анкерные болты',
      why: 'finding',
      reason: 'Прошлая находка F-1031 · коррозия рамы',
      result: 'next',
    ),
    RouteStep(n: 2, nodeId: 'unit', name: 'Агрегат в целом', why: 'resource', reason: 'Ресурс · ТО через 1 200 ч'),
    RouteStep(n: 3, nodeId: 'seal', name: 'Торцевое уплотнение', why: 'routine', reason: 'Регламент · R01'),
    RouteStep(n: 4, nodeId: 'gearbox', name: 'Редуктор', why: 'routine', reason: 'Регламент · уровень масла'),
    RouteStep(n: 5, nodeId: 'motor', name: 'Электродвигатель', why: 'routine', reason: 'Регламент · нагрев и шум'),
    RouteStep(n: 6, nodeId: 'coupling', name: 'Кожух муфты', why: 'routine', reason: 'Регламент · R06'),
    RouteStep(n: 7, nodeId: 'gauge', name: 'Манометр на нагнетании', why: 'routine', reason: 'Регламент · R05: сверка с датчиком'),
    RouteStep(n: 8, nodeId: 'flanges', name: 'Фланцевые соединения', why: 'routine', reason: 'Регламент ТО'),
    RouteStep(n: 9, nodeId: 'terminal_box', name: 'Клеммная коробка', why: 'routine', reason: 'Регламент ТО'),
  ];
  db.routes['AMS-2'] = const [
    RouteStep(n: 1, nodeId: 'seal', name: 'Торцевое уплотнение', why: 'finding', reason: 'Находка F-1041 · течь у вала', result: 'next'),
    RouteStep(n: 2, nodeId: 'motor', name: 'Обмотки двигателя', why: 'sensor', reason: 'Датчики · S05: обмотка 112 °C'),
    RouteStep(n: 3, nodeId: 'unit', name: 'Агрегат в целом', why: 'resource', reason: 'Ресурс · 10 650 из 11 000 ч'),
    RouteStep(n: 4, nodeId: 'frame', name: 'Рама и анкерные болты', why: 'routine', reason: 'Регламент ТО'),
    RouteStep(n: 5, nodeId: 'gearbox', name: 'Редуктор', why: 'routine', reason: 'Регламент · уровень масла'),
    RouteStep(n: 6, nodeId: 'coupling', name: 'Кожух муфты', why: 'routine', reason: 'Регламент · R06'),
    RouteStep(n: 7, nodeId: 'gauge', name: 'Манометр на нагнетании', why: 'routine', reason: 'Регламент · R05: сверка с датчиком'),
    RouteStep(n: 8, nodeId: 'flanges', name: 'Фланцевые соединения', why: 'routine', reason: 'Регламент ТО'),
    RouteStep(n: 9, nodeId: 'terminal_box', name: 'Клеммная коробка', why: 'routine', reason: 'Регламент ТО'),
  ];
}

/// Разборы правил Н-101 (COND прототипа) и правило R05 без данных до чтения манометра.
void _ruleChecks(MockDb db) {
  const List<RuleCheck> checks = [
    RuleCheck(
      ruleId: 'R01',
      unitId: 'N-101',
      verdict: 'Признаки возможного дефекта',
      count: 'Выполнено 3 из 3 условий',
      conditions: [
        RuleCondition(source: 'camera', label: 'Камера', state: 'met', value: 'Капли и влажное пятно у вала · кадр 09:31'),
        RuleCondition(
          source: 'sensor',
          label: 'Датчики',
          state: 'met',
          value: 'Вибрация 1X 2,4 → 3,1 мм/с за 3 сут · подшипник 78 °C, уставка 75 °C',
        ),
        RuleCondition(
          source: 'manual',
          label: 'Отметка инженера',
          what: 'Зона уплотнения вала в чек-листе',
          state: 'met',
          value: '«Капли у вала» · А. Смирнов, 09:32',
        ),
      ],
      frameLabel: 'Течь у вала',
      frameTime: '09:31',
      chartKey: 'vib1x',
    ),
    RuleCheck(
      ruleId: 'R04',
      unitId: 'N-101',
      verdict: 'Рекомендуется проверка',
      count: 'Выполнено 1 из 2 условий · данных не хватает',
      conditions: [
        RuleCondition(source: 'camera', label: 'Камера', state: 'met', value: 'Потемнение изоляции у клемм · кадр 09:30'),
        RuleCondition(source: 'sensor', label: 'Датчики', state: 'not', value: 'Небаланс токов 2,1 % при пороге 5 % - не подтверждает'),
        RuleCondition(
          source: 'data',
          label: 'Нет данных',
          what: 'Локальный нагрев клеммной коробки',
          state: 'missing',
          value: 'Датчика температуры клемм нет. Можно дополнить ручным замером пирометром по наряду.',
        ),
      ],
      frameLabel: 'Следы перегрева клемм',
      frameTime: '09:30',
      chartKey: 'unbalance',
    ),
    RuleCheck(
      ruleId: 'R08',
      unitId: 'N-101',
      verdict: 'Признаки возможного дефекта',
      count: 'Выполнено 3 из 3 условий',
      conditions: [
        RuleCondition(source: 'sensor', label: 'Датчики', what: 'Вибрация растёт', state: 'met', value: '1X 2,4 → 3,1 мм/с за 3 сут'),
        RuleCondition(
          source: 'sensor',
          label: 'Датчики',
          what: 'Температура подшипника растёт',
          state: 'met',
          value: '71 → 78 °C за 3 сут',
        ),
        RuleCondition(source: 'sensor', label: 'Датчики', what: 'Ток в норме', state: 'met', value: '9,8 А при номинале 11,0 А'),
      ],
      chartKey: 'tBearing',
    ),
    RuleCheck(
      ruleId: 'S01',
      unitId: 'N-101',
      verdict: 'Выше уставки предупреждения',
      count: 'Выполнен 1 из 2 порогов',
      conditions: [
        RuleCondition(
          source: 'sensor',
          label: 'Предупреждение',
          what: 'Вибрация 1X выше 2,8 мм/с',
          state: 'met',
          value: 'Сейчас 3,1 мм/с · растёт с 12.11',
        ),
        RuleCondition(
          source: 'sensor',
          label: 'Тревога',
          what: 'Вибрация 1X выше 4,5 мм/с',
          state: 'not',
          value: 'Сейчас ниже · 10.11 кратко 4,8 мм/с',
        ),
      ],
      chartKey: 'vib1x',
    ),
    RuleCheck(
      ruleId: 'S04',
      unitId: 'N-101',
      verdict: 'Выше уставки предупреждения',
      count: 'Выполнен 1 из 2 порогов',
      conditions: [
        RuleCondition(
          source: 'sensor',
          label: 'Предупреждение',
          what: 'Подшипник выше 75 °C',
          state: 'met',
          value: 'Сейчас 78 °C · выше уставки с 12.11 10:05',
        ),
        RuleCondition(source: 'sensor', label: 'Тревога', what: 'Подшипник выше 90 °C', state: 'not', value: 'Сейчас ниже на 12 °C'),
      ],
      chartKey: 'tBearing',
    ),
    RuleCheck(
      ruleId: 'R11',
      unitId: 'N-101',
      verdict: 'Интервал наступит через 10 ч',
      count: 'Учитываются только моточасы',
      conditions: [
        RuleCondition(
          source: 'data',
          label: 'Наработка',
          what: 'ТО-1 и ТО-2 на 19 200 ч',
          state: 'soon',
          value: 'Сейчас 19 190 ч · осталось 10 ч',
        ),
        RuleCondition(
          source: 'data',
          label: 'История',
          what: 'Последнее ТО-2 на 11 200 ч',
          state: 'met',
          value: '04.11.2025 · интервал 8 000 ч',
        ),
      ],
    ),
    RuleCheck(
      ruleId: 'R01',
      unitId: 'AMS-2',
      verdict: 'Признаки возможного дефекта',
      count: 'Выполнено 2 из 2 условий',
      conditions: [
        RuleCondition(source: 'camera', label: 'Камера', state: 'met', value: 'Лужа под агрегатом, капли со стороны вала · кадр 07:04'),
        RuleCondition(source: 'sensor', label: 'Датчики', state: 'met', value: 'Обмотка 112 °C, аварийная уставка 110 °C'),
      ],
      frameLabel: 'Лужа под агрегатом',
      frameTime: '07:04',
      chartKey: 'tWinding',
    ),
    RuleCheck(
      ruleId: 'R05',
      unitId: 'N-101',
      verdict: 'Нет данных',
      count: 'Выполнено 0 из 2 условий · данных не хватает',
      conditions: [
        RuleCondition(source: 'camera', label: 'Камера', state: 'missing', value: 'манометр ещё не считан'),
        RuleCondition(source: 'sensor', label: 'Датчики', state: 'met', value: 'Датчик давления 4,6 бар'),
      ],
    ),
  ];
  for (final RuleCheck c in checks) {
    db.ruleChecks['${c.unitId}/${c.ruleId}'] = c;
  }
}

/// Время срабатывания правила [ruleId] агрегата [unitId] для подсказки «сработало правило … в …».
void _firedAt(MockDb db, String unitId, String ruleId, String time) {
  final List<DiagnosisResult>? list = db.diagnostics[unitId];
  if (list == null) {
    return;
  }
  db.diagnostics[unitId] = [
    for (final DiagnosisResult d in list)
      d.ruleId == ruleId
          ? DiagnosisResult(
              ruleId: d.ruleId,
              status: d.status,
              result: d.result,
              title: d.title,
              text: d.text,
              evidence: d.evidence,
              missing: d.missing,
              firedAt: time,
            )
          : d,
  ];
}
