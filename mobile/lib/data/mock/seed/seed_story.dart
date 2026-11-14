import '../../models/admin.dart';
import '../../models/equipment.dart';
import '../../models/inspection.dart';
import '../../models/people.dart';
import '../../models/workflow.dart';
import '../mock_db.dart';

/// История 14.11.2026 из прототипа (js/data.js): площадка, люди, агрегаты, правила, находки, задания,
/// сообщения, план, журналы и настройки. Файл собран из прототипа; правки истории вносятся в прототип и переносятся.
void seedStory(MockDb db) {
  db.site = const Site(name: 'Насосная станция № 2', shift: 'Смена А · 08:00-20:00', shiftShort: 'смена 08:00-20:00', server: 'КСТ-СРВ-02', wifi: 'KST-NS2-Field');
  db.people.addAll(const {
    'engineer': Person(id: 'u-101', name: 'Алексей Смирнов', roleCode: 'engineer', roleLabel: 'Инженер', title: 'Инженер-диагност', email: 'a.smirnov@kst-energo.ru', phone: '+7 912 405-18-22', shift: 'Смена А · 08:00-20:00'),
    'master': Person(id: 'u-102', name: 'Марина Орлова', roleCode: 'master', roleLabel: 'Мастер', title: 'Мастер участка', email: 'm.orlova@kst-energo.ru', phone: '+7 912 405-11-07', shift: 'Смена А · 08:00-20:00'),
    'operator': Person(id: 'u-103', name: 'Ольга Кузнецова', roleCode: 'operator', roleLabel: 'Оператор', title: 'Оператор насосной станции', email: 'o.kuznetsova@kst-energo.ru', phone: '+7 912 405-20-31', shift: 'Смена А · 08:00-20:00'),
    'admin': Person(id: 'u-104', name: 'Игорь Власов', roleCode: 'admin', roleLabel: 'Админ', title: 'Администратор системы', email: 'i.vlasov@kst-energo.ru', phone: '+7 912 405-02-44', shift: '5/2 · 09:00-18:00'),
    'sec': Person(id: 'u-105', name: 'Дмитрий Захаров', roleCode: 'security_admin', roleLabel: 'Админ ИБ', title: 'Администратор информационной безопасности', email: 'd.zakharov@kst-energo.ru', phone: '+7 912 405-03-19', shift: '5/2 · 09:00-18:00'),
  });
  db.users.addAll(const [
    AdminUser(id: 'u-101', name: 'Алексей Смирнов', roleCode: 'engineer', roleLabel: 'Инженер', email: 'a.smirnov@kst-energo.ru', status: 'active', lastLogin: '14.11 08:02', biometrics: true, activeSessions: 1),
    AdminUser(id: 'u-102', name: 'Марина Орлова', roleCode: 'master', roleLabel: 'Мастер', email: 'm.orlova@kst-energo.ru', status: 'active', lastLogin: '14.11 07:55', biometrics: true, activeSessions: 1),
    AdminUser(id: 'u-103', name: 'Ольга Кузнецова', roleCode: 'operator', roleLabel: 'Оператор', email: 'o.kuznetsova@kst-energo.ru', status: 'active', lastLogin: '14.11 06:31', activeSessions: 1),
    AdminUser(id: 'u-104', name: 'Игорь Власов', roleCode: 'admin', roleLabel: 'Админ', email: 'i.vlasov@kst-energo.ru', status: 'active', lastLogin: '13.11 17:40'),
    AdminUser(id: 'u-105', name: 'Дмитрий Захаров', roleCode: 'security_admin', roleLabel: 'Админ ИБ', email: 'd.zakharov@kst-energo.ru', status: 'active', lastLogin: '14.11 09:10', biometrics: true, activeSessions: 1),
    AdminUser(id: 'u-106', name: 'Елена Титова', roleCode: 'engineer', roleLabel: 'Инженер', email: 'e.titova@kst-energo.ru', status: 'active', lastLogin: '13.11 19:48', biometrics: true),
    AdminUser(id: 'u-107', name: 'Николай Гусев', roleCode: 'master', roleLabel: 'Мастер', email: 'n.gusev@kst-energo.ru', status: 'active', lastLogin: '13.11 20:05'),
    AdminUser(id: 'u-108', name: 'Анна Лебедева', roleCode: 'operator', roleLabel: 'Оператор', email: 'a.lebedeva@kst-energo.ru', status: 'active', lastLogin: '13.11 20:02'),
    AdminUser(id: 'u-109', name: 'Сергей Белов', roleCode: 'engineer', roleLabel: 'Инженер', email: 's.belov@kst-energo.ru', status: 'active', lastLogin: '14.11 08:15', activeSessions: 1),
    AdminUser(id: 'u-110', name: 'Павел Ершов', roleCode: 'engineer', roleLabel: 'Инженер', email: 'p.ershov@kst-energo.ru', status: 'temp', lastLogin: 'ещё не входил', tempPassword: 'Kv7-pT92-xR', tempUntil: '15.11 09:08'),
    AdminUser(id: 'u-111', name: 'Виктор Панов', roleCode: 'operator', roleLabel: 'Оператор', email: 'v.panov@kst-energo.ru', status: 'blocked', lastLogin: '01.11 19:58', blockReason: 'Перевод на другой участок', blockedAt: '02.11.2026, 10:15'),
  ]);
  db.thresholds.addAll({
    'vib1x': (warn: 2.8, alarm: 4.5, unit: 'мм/с', label: 'Вибрация 1X'),
    'vib2x': (warn: 1.8, alarm: 3.0, unit: 'мм/с', label: 'Вибрация 2X'),
    'vibHf': (warn: 2.5, alarm: 5.0, unit: 'g', label: 'ВЧ шум'),
    'tBearing': (warn: 75.0, alarm: 90.0, unit: '°C', label: 'Подшипник'),
    'tWinding': (warn: 90.0, alarm: 110.0, unit: '°C', label: 'Обмотка'),
  });
  db.units.addAll(const [
    Equipment(
      id: 'N-101', code: 'Н-101', name: 'Насос Н-101', kind: 'Центробежный насос in-line', kindShort: 'насос',
      model: 'Wilo CronoLine-IL 65/160', modelShort: 'Wilo IL 65/160', modelFull: 'IL 65/160-5,5/2', manufacturer: 'Wilo', serial: '2786107-0142',
      location: 'Насосная станция, зал 2', commissioned: '15.03.2021', status: 'warn', statusLabel: 'Внимание', mode: 'running', modeLabel: 'В работе',
      summary: 'Вибрация 1X 3,1 мм/с · подшипник 78 °C', runHours: 19190.0,
      resource: Resource(label: 'Ресурс подшипников', used: 19190.0, total: 20000.0, left: 810.0, status: 'warn'),
      nextTo: NextMaintenance(code: 'ТО-2', inHours: 10.0, atHours: 19200.0, date: '15.11.2026'),
      lastInspection: LastInspection(date: '13.11.2026', time: '16:40', who: 'Алексей Смирнов', id: 'INS-2205'),
      specs: [('Мощность', '5,5 кВт'), ('Частота вращения', '2900 об/мин'), ('Подача', '47 м³/ч'), ('Напор', '31,7 м'), ('Макс. давление', '16 бар'), ('Номинальный ток', '11,0 А'), ('Класс изоляции', 'F'), ('Защита', 'IP 55')],
      readings: {
        'vib1x': Reading(key: 'vib1x', label: 'Вибрация 1X', short: 'Вибрация 1X', value: 3.1, unit: 'мм/с', warn: 2.8, alarm: 4.5),
        'vib2x': Reading(key: 'vib2x', label: 'Вибрация 2X', short: 'Вибрация 2X', value: 1.2, unit: 'мм/с', warn: 1.8, alarm: 3.0),
        'vibHf': Reading(key: 'vibHf', label: 'ВЧ шум вибрации', short: 'ВЧ шум', value: 1.9, unit: 'g', warn: 2.5, alarm: 5.0),
        'tBearing': Reading(key: 'tBearing', label: 'Температура подшипника', short: 'Подшипник', value: 78.0, unit: '°C', warn: 75.0, alarm: 90.0, digits: 0),
        'tWinding': Reading(key: 'tWinding', label: 'Температура обмоток', short: 'Обмотка', value: 84.0, unit: '°C', warn: 90.0, alarm: 110.0, digits: 0),
        'pressOut': Reading(key: 'pressOut', label: 'Давление нагнетания', short: 'Давление', value: 4.6, unit: 'бар'),
        'pressIn': Reading(key: 'pressIn', label: 'Давление на входе', short: 'Вход', value: 1.5, unit: 'бар'),
        'current': Reading(key: 'current', label: 'Ток двигателя', short: 'Ток', value: 9.8, unit: 'А'),
        'unbalance': Reading(key: 'unbalance', label: 'Небаланс токов', short: 'Небаланс', value: 2.1, unit: '%', warn: 5.0),
        'flow': Reading(key: 'flow', label: 'Расход', short: 'Расход', value: 45.0, unit: 'м³/ч', digits: 0),
      },
      maintenance: [
        MaintenanceItem(code: 'ТО-1', interval: 4000.0, lastAt: 15200.0, lastDate: '28.05.2026', nextAt: 19200.0, inHours: 10.0, work: 'Контроль уплотнений, нагрева, шума, вибрации, затяжка фланцев'),
        MaintenanceItem(code: 'ТО-2', interval: 8000.0, lastAt: 11200.0, lastDate: '04.11.2025', nextAt: 19200.0, inHours: 10.0, work: 'Объём ТО-1, зазор муфты, уплотнительные кольца, чистка крышки вентилятора и клеммной коробки'),
        MaintenanceItem(code: 'Ревизия', interval: 16000.0, lastAt: 6000.0, lastDate: '11.10.2022', nextAt: 22000.0, inHours: 2810.0, work: 'Разборка, замена торцевого уплотнения, проверка вала и рабочего колеса'),
      ],
      nodes: [
        EquipmentNode(id: 'motor', name: 'Электродвигатель', hours: 19190.0, status: 'ok'),
        EquipmentNode(id: 'motor_bearings', name: 'Подшипники двигателя', hours: 19190.0, norm: 20000.0, status: 'warn'),
        EquipmentNode(id: 'terminal_box', name: 'Клеммная коробка', hours: 19190.0, status: 'warn'),
        EquipmentNode(id: 'coupling', name: 'Муфта и кожух муфты', hours: 19190.0, status: 'ok'),
        EquipmentNode(id: 'seal', name: 'Торцевое уплотнение', hours: 13190.0, norm: 15000.0, status: 'bad'),
        EquipmentNode(id: 'casing', name: 'Корпус насоса и рабочее колесо', hours: 19190.0, status: 'ok'),
        EquipmentNode(id: 'flanges', name: 'Фланцевые соединения', hours: 19190.0, status: 'ok'),
        EquipmentNode(id: 'gauge', name: 'Манометр на нагнетании', status: 'ok'),
      ],
      documents: [EquipmentDocument(name: 'Паспорт насоса IL 65/160', type: 'PDF', size: '2,4 МБ'), EquipmentDocument(name: 'Руководство по эксплуатации Wilo CronoLine-IL', type: 'PDF', size: '6,1 МБ'), EquipmentDocument(name: 'Регламент ТО насосов in-line', type: 'PDF', size: '0,8 МБ')],
      runByMonth: [MonthRun(label: 'Июн', value: 698.0), MonthRun(label: 'Июл', value: 721.0), MonthRun(label: 'Авг', value: 734.0), MonthRun(label: 'Сен', value: 702.0), MonthRun(label: 'Окт', value: 731.0), MonthRun(label: 'Ноя', value: 302.0, highlight: true)],
      openFindings: 2,
    ),
    Equipment(
      id: 'AMS-1', code: 'АМС-1', name: 'Агрегат насосный винтовой № 1', kind: 'Винтовой насос', kindShort: 'винтовой насос',
      model: 'AMS PCP60S12/3', modelShort: 'AMS PCP60S12/3', modelFull: 'PCP60S12/3 01 Ex B1 HNBR DTS', manufacturer: 'AMS', serial: '21031004-1',
      location: 'Узел откачки, площадка 1', commissioned: '20.07.2023', status: 'ok', statusLabel: 'Норма', mode: 'running', modeLabel: 'В работе',
      summary: 'Отклонений не выявлено · осмотр 12.11', runHours: 9800.0,
      resource: Resource(label: 'Наработка до ТО агрегата', used: 9800.0, total: 11000.0, left: 1200.0, status: 'ok'),
      nextTo: NextMaintenance(code: 'ТО по наработке', inHours: 1200.0, atHours: 11000.0, date: '28.12.2026'),
      lastInspection: LastInspection(date: '12.11.2026', time: '10:20', who: 'Елена Титова', id: 'INS-2198'),
      specs: [('Мощность', '11 кВт'), ('Частота вращения двигателя', '1460 об/мин'), ('Частота вращения насоса', '260 об/мин'), ('Подача', '20 м³/ч'), ('Макс. давление', '10 бар'), ('Номинальный ток', '23,0 А'), ('Масса', '430 кг')],
      readings: {
        'vib1x': Reading(key: 'vib1x', label: 'Вибрация 1X', short: 'Вибрация 1X', value: 1.4, unit: 'мм/с', warn: 2.8, alarm: 4.5),
        'vib2x': Reading(key: 'vib2x', label: 'Вибрация 2X', short: 'Вибрация 2X', value: 0.7, unit: 'мм/с', warn: 1.8, alarm: 3.0),
        'vibHf': Reading(key: 'vibHf', label: 'ВЧ шум вибрации', short: 'ВЧ шум', value: 0.9, unit: 'g', warn: 2.5, alarm: 5.0),
        'tBearing': Reading(key: 'tBearing', label: 'Температура подшипника', short: 'Подшипник', value: 52.0, unit: '°C', warn: 75.0, alarm: 90.0, digits: 0),
        'tWinding': Reading(key: 'tWinding', label: 'Температура обмоток', short: 'Обмотка', value: 68.0, unit: '°C', warn: 90.0, alarm: 110.0, digits: 0),
        'pressOut': Reading(key: 'pressOut', label: 'Давление нагнетания', short: 'Давление', value: 6.2, unit: 'бар'),
        'current': Reading(key: 'current', label: 'Ток двигателя', short: 'Ток', value: 18.4, unit: 'А'),
      },
      maintenance: [
        MaintenanceItem(code: 'ТО по наработке', interval: 11000.0, lastAt: 0.0, lastDate: '20.07.2023', nextAt: 11000.0, inHours: 1200.0, work: 'Обслуживание агрегата по регламенту AMS'),
      ],
      nodes: [
        EquipmentNode(id: 'unit', name: 'Агрегат в целом', hours: 9800.0, norm: 11000.0, status: 'ok'),
        EquipmentNode(id: 'motor', name: 'Электродвигатель', hours: 9800.0, norm: 60000.0, status: 'ok'),
        EquipmentNode(id: 'gearbox', name: 'Редуктор', hours: 9800.0, status: 'ok'),
        EquipmentNode(id: 'seal', name: 'Торцевое уплотнение', hours: 6100.0, status: 'ok'),
        EquipmentNode(id: 'frame', name: 'Рама и анкерные болты', status: 'ok'),
      ],
      documents: [EquipmentDocument(name: 'Паспорт агрегата AMS PCP60S12/3', type: 'PDF', size: '3,2 МБ')],
      runByMonth: [MonthRun(label: 'Июн', value: 612.0), MonthRun(label: 'Июл', value: 655.0), MonthRun(label: 'Авг', value: 640.0), MonthRun(label: 'Сен', value: 618.0), MonthRun(label: 'Окт', value: 664.0), MonthRun(label: 'Ноя', value: 281.0, highlight: true)],
    ),
    Equipment(
      id: 'AMS-2', code: 'АМС-2', name: 'Агрегат насосный винтовой № 2', kind: 'Винтовой насос', kindShort: 'винтовой насос',
      model: 'AMS PCP60S12/3', modelShort: 'AMS PCP60S12/3', modelFull: 'PCP60S12/3 01 Ex B1 HNBR DTS', manufacturer: 'AMS', serial: '21031004-2',
      location: 'Узел откачки, площадка 1', commissioned: '20.07.2023', status: 'info', statusLabel: 'На ремонте', mode: 'repair', modeLabel: 'На ремонте',
      summary: 'Течь у вала · обмотка 112 °C', runHours: 10650.0,
      resource: Resource(label: 'Наработка до ТО агрегата', used: 10650.0, total: 11000.0, left: 350.0, status: 'warn'),
      nextTo: NextMaintenance(code: 'Ремонт уплотнения', inHours: 0.0, atHours: 10650.0, date: '15.11.2026'),
      lastInspection: LastInspection(date: '14.11.2026', time: '07:05', who: 'Алексей Смирнов', id: 'INS-2207'),
      specs: [('Мощность', '11 кВт'), ('Частота вращения двигателя', '1460 об/мин'), ('Частота вращения насоса', '260 об/мин'), ('Подача', '20 м³/ч'), ('Макс. давление', '10 бар'), ('Номинальный ток', '23,0 А'), ('Масса', '430 кг')],
      readings: {
        'vib1x': Reading(key: 'vib1x', label: 'Вибрация 1X', short: 'Вибрация 1X', value: 2.2, unit: 'мм/с', warn: 2.8, alarm: 4.5),
        'vib2x': Reading(key: 'vib2x', label: 'Вибрация 2X', short: 'Вибрация 2X', value: 0.9, unit: 'мм/с', warn: 1.8, alarm: 3.0),
        'vibHf': Reading(key: 'vibHf', label: 'ВЧ шум вибрации', short: 'ВЧ шум', value: 1.6, unit: 'g', warn: 2.5, alarm: 5.0),
        'tBearing': Reading(key: 'tBearing', label: 'Температура подшипника', short: 'Подшипник', value: 71.0, unit: '°C', warn: 75.0, alarm: 90.0, digits: 0),
        'tWinding': Reading(key: 'tWinding', label: 'Температура обмоток', short: 'Обмотка', value: 112.0, unit: '°C', warn: 90.0, alarm: 110.0, digits: 0),
        'pressOut': Reading(key: 'pressOut', label: 'Давление нагнетания', short: 'Давление', value: 0.0, unit: 'бар'),
        'current': Reading(key: 'current', label: 'Ток двигателя', short: 'Ток', value: 0.0, unit: 'А'),
      },
      maintenance: [
        MaintenanceItem(code: 'Ремонт уплотнения', inHours: 0.0, work: 'Замена торцевого уплотнения, проверка изоляции обмоток'),
      ],
      nodes: [
        EquipmentNode(id: 'unit', name: 'Агрегат в целом', hours: 10650.0, norm: 11000.0, status: 'warn'),
        EquipmentNode(id: 'motor', name: 'Электродвигатель', hours: 10650.0, norm: 60000.0, status: 'bad'),
        EquipmentNode(id: 'seal', name: 'Торцевое уплотнение', hours: 7400.0, status: 'bad'),
        EquipmentNode(id: 'frame', name: 'Рама и анкерные болты', status: 'ok'),
      ],
      documents: [EquipmentDocument(name: 'Паспорт агрегата AMS PCP60S12/3', type: 'PDF', size: '3,2 МБ')],
      runByMonth: [MonthRun(label: 'Июн', value: 640.0), MonthRun(label: 'Июл', value: 668.0), MonthRun(label: 'Авг', value: 652.0), MonthRun(label: 'Сен', value: 671.0), MonthRun(label: 'Окт', value: 690.0), MonthRun(label: 'Ноя', value: 302.0, highlight: true)],
      openFindings: 1, stoppedAt: '14.11.2026 06:44', stopNote: 'Значения на момент остановки 06:44',
    ),
  ]);
  db.severityLabels.addAll(const {1: 'наблюдение и проверка', 2: 'устранить в плановом порядке', 3: 'критично: остановка или запрет эксплуатации'});
  db.rules.addAll(const [
    RuleDef(id: 'R01', title: 'Деградация уплотнения вала', camera: 'Влажное пятно, капли, блеск жидкости у вала', sensor: 'Рост вибрации и температуры подшипникового узла', status: 'defect', severity: 3, recommendation: 'Перевести насос в резерв. Осмотреть зону уплотнения вала и точку контроля смазки подшипника, заменить уплотнение.'),
    RuleDef(id: 'R02', title: 'Ослабление крепления к фундаменту', camera: 'Коррозия рамы, отсутствует или выступает анкерный болт', sensor: 'Рост низкочастотной вибрации (1-я гармоника)', status: 'defect', severity: 2, recommendation: 'Проверить и затянуть анкерные болты нормированным моментом, затем проверить соосность валов.'),
    RuleDef(id: 'R03', title: 'Потеря свойств смазки или её нехватка', camera: 'Масло в смотровом стекле тёмное, мутное или ниже отметки MIN', sensor: 'Температура подшипника выше нормы на 10-15 °C', status: 'defect', severity: 2, recommendation: 'Заменить масло и промыть узел в течение 48 часов. Тип и объём масла - по карточке узла.'),
    RuleDef(id: 'R04', title: 'Плохой контакт в клеммной коробке', camera: 'Окисление, потемнение изоляции, следы перегрева на клеммной коробке', sensor: 'Небаланс токов по фазам более 5 % или локальный нагрев', status: 'defect', severity: 3, recommendation: 'Обесточить двигатель и протянуть клеммы, зачистить контакты. Работы выполнять по наряду с проверкой отсутствия напряжения.'),
    RuleDef(id: 'R05', title: 'Расхождение манометра и датчика давления', camera: 'Показание стрелочного манометра (чтение шкалы)', sensor: 'Значение электронного датчика отличается более чем на 15 %', status: 'defect', severity: 2, recommendation: 'Выполнить поверку датчика давления или продувку импульсной линии. До выяснения причины ориентироваться на манометр.'),
    RuleDef(id: 'R06', title: 'Кожух муфты отсутствует, разрушен или смещён', camera: 'Кожух муфты отсутствует, разрушен или смещён', sensor: 'Не требуются', status: 'defect', severity: 3, recommendation: 'Эксплуатация запрещена. Остановить агрегат и установить кожух муфты в штатное положение.'),
    RuleDef(id: 'R07', title: 'Кавитация, подтверждённая на месте и по датчикам', camera: 'Нестабильность потока (при наличии признаков)', sensor: 'Падение давления на входе, рост высокочастотной вибрации', status: 'defect', severity: 3, recommendation: 'Проверить уровень в ёмкости и фильтры на всасывании, полностью открыть задвижку на всасе. Не допускать длительной работы в этом режиме.'),
    RuleDef(id: 'R08', title: 'Проблема смазки или износ подшипников', camera: 'Не требуется', sensor: 'Вибрация и температура растут, ток в норме', status: 'defect', severity: 2, recommendation: 'Проверить смазку подшипникового узла, запланировать замену подшипника.'),
    RuleDef(id: 'R09', title: 'Расцентровка валов', camera: 'Не требуется', sensor: 'Высокая осевая вибрация на муфте, температура в норме, ток слегка повышен', status: 'defect', severity: 2, recommendation: 'Проверить и скорректировать соосность валов насоса и двигателя, проверить состояние муфты.'),
    RuleDef(id: 'R10', title: 'Износ проточной части', camera: 'Не требуется', sensor: 'КПД упал на 15 %, вибрация и температура в норме', status: 'defect', severity: 2, recommendation: 'Запланировать ремонт проточной части, заказать запасные части.'),
    RuleDef(id: 'R11', title: 'Достигнут межремонтный интервал', camera: 'Не требуется', sensor: 'Наработка достигла 4000 / 8000 / 16000 моточасов', status: 'check', severity: 2, recommendation: 'Провести обслуживание по регламенту.'),
    RuleDef(id: 'R12', title: 'Кавитация по данным датчиков', camera: 'Не требуется', sensor: 'Рост широкополосной вибрации, падение давления на входе', status: 'defect', severity: 2, recommendation: 'Проверить уровень в ёмкости и фильтры на всасывании, полностью открыть задвижку на всасе.'),
    RuleDef(id: 'S01', title: 'Дисбаланс ротора по уставке заказчика', camera: 'Не требуется', sensor: 'Амплитуда 1x выше 2.8 мм/с - предупреждение, выше 4.5 мм/с - тревога', status: 'check', severity: 1, recommendation: 'Запланировать проверку балансировки рабочего колеса, осмотреть колесо на налипание и эрозию.'),
    RuleDef(id: 'S02', title: 'Нарушение центровки по уставке заказчика', camera: 'Не требуется', sensor: 'Амплитуда 2x выше 1.8 мм/с - предупреждение, выше 3.0 мм/с - тревога', status: 'check', severity: 1, recommendation: 'Запланировать проверку центровки валов и затяжки крепежа.'),
    RuleDef(id: 'S03', title: 'Износ подшипника или шум по уставке заказчика', camera: 'Не требуется', sensor: 'ВЧ шум выше 2.5 g - предупреждение, выше 5.0 g - тревога', status: 'check', severity: 1, recommendation: 'Проверить смазку и шум подшипников; проверить давление на входе, чтобы исключить кавитацию.'),
    RuleDef(id: 'S04', title: 'Перегрев подшипника по уставке заказчика', camera: 'Не требуется', sensor: 'Температура подшипника выше 75 °C - предупреждение, выше 90 °C - тревога', status: 'check', severity: 1, recommendation: 'Проверить смазку и охлаждение подшипникового узла.'),
    RuleDef(id: 'S05', title: 'Перегрев обмоток двигателя по уставке заказчика', camera: 'Не требуется', sensor: 'Температура обмоток выше 90 °C - предупреждение, выше 110 °C - тревога', status: 'check', severity: 1, recommendation: 'Проверить нагрузку двигателя, чистоту крыльчатки и кожуха вентилятора.'),
    RuleDef(id: 'V01', title: 'Визуальный признак возможного дефекта', camera: 'Любой дефектный признак, не входящий в правила с датчиками', sensor: 'Не требуются', status: 'defect', severity: 2, recommendation: 'Осмотреть узел, подтвердить или снять замечание и зафиксировать результат осмотра.'),
  ]);
  db.diagnostics.addAll(const {
    'N-101': [
      DiagnosisResult(ruleId: 'R01', status: 'bad', result: 'match', title: 'Деградация уплотнения вала', text: 'Признаки возможного дефекта: течь у вала подтверждается ростом вибрации и температуры подшипникового узла.', evidence: [Evidence(source: 'camera', text: 'Капли и влажное пятно у вала, кадр 09:31'), Evidence(source: 'sensor', text: 'Вибрация 1X 3,1 мм/с, растёт 3 сут'), Evidence(source: 'sensor', text: 'Подшипник 78 °C, уставка 75 °C')]),
      DiagnosisResult(ruleId: 'R04', status: 'warn', result: 'camera', title: 'Плохой контакт в клеммной коробке', text: 'Следы перегрева на клеммной коробке. Небаланс токов 2,1 % - ниже 5 %, датчики признак не подтверждают. Рекомендуется проверка.', evidence: [Evidence(source: 'camera', text: 'Потемнение изоляции у клемм, кадр 09:30'), Evidence(source: 'sensor', text: 'Небаланс токов 2,1 %, порог 5 %')]),
      DiagnosisResult(ruleId: 'R08', status: 'warn', result: 'match', title: 'Проблема смазки или износ подшипников', text: 'Вибрация и температура растут при токе в норме. Ресурс подшипников 19 190 из 20 000 ч.', evidence: [Evidence(source: 'sensor', text: 'Вибрация 1X 2,4 → 3,1 мм/с за 3 сут'), Evidence(source: 'sensor', text: 'Подшипник 71 → 78 °C за 3 сут'), Evidence(source: 'sensor', text: 'Ток 9,8 А при номинале 11,0 А')]),
      DiagnosisResult(ruleId: 'S01', status: 'warn', result: 'warn', title: 'Дисбаланс ротора по уставке заказчика', text: 'Вибрация 1X 3,1 мм/с, уставка предупреждения 2,8 мм/с.', evidence: [Evidence(source: 'sensor', text: '10.11 кратко 4,8 мм/с при аварийной уставке 4,5')]),
      DiagnosisResult(ruleId: 'S04', status: 'warn', result: 'warn', title: 'Перегрев подшипника по уставке заказчика', text: '78 °C, уставка 75 °C.', evidence: [Evidence(source: 'sensor', text: 'Выше уставки с 12.11 10:05')]),
      DiagnosisResult(ruleId: 'R11', status: 'warn', result: 'match', title: 'Достигнут межремонтный интервал', text: 'До ТО-1 и ТО-2 осталось 10 ч наработки (19 190 из 19 200 ч).', evidence: [Evidence(source: 'data', text: 'Последнее ТО-2 на 11 200 ч')]),
    ],
  });
  db.checklist.addAll(const [
    ChecklistItem(id: 'seal', label: 'Зона уплотнения вала', state: 'bad', note: 'Капли у вала'),
    ChecklistItem(id: 'terminal', label: 'Клеммная коробка', state: 'warn', note: 'Потемнение изоляции'),
    ChecklistItem(id: 'coupling', label: 'Кожух муфты на месте', state: 'ok'),
    ChecklistItem(id: 'gauge', label: 'Манометр читается', state: 'ok', note: '4,6 бар, датчик 4,6 бар'),
    ChecklistItem(id: 'anchor', label: 'Анкерные болты', state: 'ok'),
    ChecklistItem(id: 'noise', label: 'Посторонний шум', state: 'warn', note: 'Шум подшипника со стороны привода'),
  ]);
  db.detections.addAll(const [
    Detection(kind: 'part', label: 'Электродвигатель', x: 28.0, y: 31.0, w: 28.0, h: 20.0),
    Detection(kind: 'defect', label: 'Следы перегрева клемм', x: 31.0, y: 35.0, w: 12.0, h: 10.0),
    Detection(kind: 'part', label: 'Кожух муфты', x: 33.0, y: 50.0, w: 22.0, h: 7.0),
    Detection(kind: 'part', label: 'Корпус насоса', x: 30.0, y: 56.0, w: 34.0, h: 15.0),
    Detection(kind: 'defect', label: 'Течь у вала', x: 31.0, y: 57.0, w: 11.0, h: 11.0),
    Detection(kind: 'gauge', label: 'Манометр · 4,6 бар', x: 70.0, y: 55.0, w: 11.0, h: 6.0),
    Detection(kind: 'defect', label: 'Лужа под агрегатом', x: 13.0, y: 77.3, w: 30.0, h: 7.0),
  ]);
  db.findings.addAll(const [
    Finding(id: 'F-1043', unitId: 'N-101', title: 'Деградация уплотнения вала', ruleId: 'R01', severity: 3, status: 'new', source: 'Осмотр INS-2209', date: '14.11.2026', time: '09:34', author: 'Алексей Смирнов', node: 'Торцевое уплотнение', evidence: ['Камера: капли и влажное пятно у вала', 'Вибрация 1X 3,1 мм/с, уставка 2,8', 'Подшипник 78 °C, уставка 75'], recommendation: 'Перевести насос в резерв. Осмотреть зону уплотнения вала и точку контроля смазки подшипника, заменить уплотнение.'),
    Finding(id: 'F-1042', unitId: 'N-101', title: 'Признаки износа подшипника двигателя', ruleId: 'R08', severity: 2, status: 'new', source: 'Правило R08, датчики', date: '14.11.2026', time: '08:12', author: 'Система', node: 'Подшипники двигателя', evidence: ['Вибрация 1X 2,4 → 3,1 мм/с за 3 сут', 'Подшипник 71 → 78 °C за 3 сут', 'Ток 9,8 А - в норме'], recommendation: 'Проверить смазку подшипникового узла, запланировать замену подшипника.'),
    Finding(id: 'F-1041', unitId: 'AMS-2', title: 'Течь торцевого уплотнения, перегрев обмоток', ruleId: 'R01', severity: 3, status: 'planned', source: 'Осмотр INS-2207', date: '14.11.2026', time: '07:05', author: 'Алексей Смирнов', node: 'Торцевое уплотнение', evidence: ['Камера: течь у вала, лужа под агрегатом', 'Обмотка 112 °C, аварийная уставка 110', 'Сообщение оператора 06:40'], recommendation: 'Заменить торцевое уплотнение, проверить изоляцию обмоток.', confirmedBy: 'Марина Орлова', confirmedAt: '07:30', planned: 'Ремонт уплотнения 15.11, 08:00'),
    Finding(id: 'F-1036', unitId: 'N-101', title: 'Кратковременное превышение вибрации 1X', ruleId: 'S01', severity: 1, status: 'confirmed', source: 'Правило S01, датчики', date: '10.11.2026', time: '08:20', author: 'Система', node: 'Корпус насоса и рабочее колесо', evidence: ['Вибрация 1X 4,8 мм/с, 40 мин', 'Аварийная уставка 4,5 мм/с'], recommendation: 'Запланировать проверку балансировки рабочего колеса.', confirmedBy: 'Марина Орлова', confirmedAt: '10.11 12:10'),
    Finding(id: 'F-1031', unitId: 'AMS-1', title: 'Коррозия рамы у анкерного болта', ruleId: 'V01', severity: 2, status: 'closed', source: 'Осмотр INS-2198', date: '12.11.2026', time: '10:20', author: 'Елена Титова', node: 'Рама и анкерные болты', evidence: ['Камера: рыжий налёт у болта'], recommendation: 'Осмотреть узел, подтвердить или снять замечание.', closedBy: 'Марина Орлова', closedNote: 'Поверхностная коррозия, болт затянут. Замечание снято.'),
  ]);
  db.inspections.addAll(const [
    Inspection(id: 'INS-2209', unitId: 'N-101', date: '14.11.2026', time: '09:20', duration: '14 мин', who: 'Алексей Смирнов', status: 'draft', defects: 2, checks: 6, note: 'Идёт сейчас', findingIds: ['F-1043']),
    Inspection(id: 'INS-2207', unitId: 'AMS-2', date: '14.11.2026', time: '06:58', duration: '12 мин', who: 'Алексей Смирнов', status: 'done', defects: 1, checks: 5, note: 'По сообщению оператора', findingIds: ['F-1041']),
    Inspection(id: 'INS-2205', unitId: 'N-101', date: '13.11.2026', time: '16:40', duration: '9 мин', who: 'Алексей Смирнов', status: 'done', defects: 0, checks: 6, note: 'Внешних дефектов не выявлено, отмечен шум подшипника'),
    Inspection(id: 'INS-2198', unitId: 'AMS-1', date: '12.11.2026', time: '10:20', duration: '11 мин', who: 'Елена Титова', status: 'done', defects: 1, checks: 5, note: 'Замечание снято мастером', findingIds: ['F-1031']),
    Inspection(id: 'INS-2190', unitId: 'N-101', date: '10.11.2026', time: '11:30', duration: '16 мин', who: 'Алексей Смирнов', status: 'done', defects: 0, checks: 6, note: 'Осмотр после тревоги, ослабления крепления не выявлено'),
  ]);
  db.tasks.addAll(const [
    InspectionTask(id: 'T-318', unitId: 'N-101', title: 'Осмотр по срабатыванию правила R08', due: '14.11, 10:00', from: 'Марина Орлова', to: 'Алексей Смирнов', status: 'progress', statusLabel: 'Выполняется', reason: 'Вибрация 1X 3,1 мм/с и подшипник 78 °C выше уставок', priority: 'urgent'),
    InspectionTask(id: 'T-317', unitId: 'AMS-2', title: 'Осмотр по сообщению оператора', due: '14.11, 07:00', from: 'Марина Орлова', to: 'Алексей Смирнов', status: 'done', statusLabel: 'Выполнено', reason: 'Течь под агрегатом, повышенный шум', faultReportId: 'S-077'),
    InspectionTask(id: 'T-319', unitId: 'AMS-1', title: 'Плановый обход', due: '14.11, 14:00', from: 'Марина Орлова', to: 'Елена Титова', status: 'new', statusLabel: 'Назначено', reason: 'Ежесменный обход узла откачки'),
  ]);
  db.faultReports.addAll(const [
    FaultReport(id: 'S-077', unitId: 'AMS-2', author: 'Ольга Кузнецова', date: '14.11.2026', time: '06:40', kind: 'Течь', text: 'Течь под агрегатом, повышенный шум', status: 'repair', statusLabel: 'На ремонте', timeline: [FaultStep(time: '06:40', title: 'Сообщение отправлено', who: 'Ольга Кузнецова'), FaultStep(time: '06:52', title: 'Мастер назначил осмотр', who: 'Марина Орлова → Алексей Смирнов'), FaultStep(time: '07:05', title: 'Дефект зафиксирован', who: 'Течь торцевого уплотнения, обмотка 112 °C'), FaultStep(time: '07:30', title: 'Находка подтверждена, ремонт 15.11', who: 'Марина Орлова')]),
    FaultReport(id: 'S-071', unitId: 'N-101', author: 'Анна Лебедева', date: '09.11.2026', time: '22:15', kind: 'Шум', text: 'Посторонний шум со стороны двигателя', status: 'closed', statusLabel: 'Проверено'),
  ]);
  db.faultKinds.addAll(const ['Течь', 'Шум или стук', 'Вибрация', 'Нагрев', 'Запах гари', 'Другое']);
  db.plan.addAll(const [
    PlanItem(id: 'P-501', unitId: 'AMS-2', work: 'Ремонт торцевого уплотнения', date: '15.11.2026', time: '08:00', who: 'Алексей Смирнов', status: 'planned', basis: 'Находка F-1041'),
    PlanItem(id: 'P-502', unitId: 'N-101', work: 'ТО-2 (с объёмом ТО-1)', date: '15.11.2026', time: '10:00', who: 'Елена Титова', status: 'planned', basis: 'R11: 19 200 ч наработки'),
    PlanItem(id: 'P-503', unitId: 'N-101', work: 'Замена подшипников двигателя', date: '19.12.2026', time: '09:00', who: 'не назначен', status: 'draft', basis: 'Ресурс 19 190 из 20 000 ч'),
    PlanItem(id: 'P-504', unitId: 'AMS-1', work: 'ТО по наработке 11 000 ч', date: '28.12.2026', time: '09:00', who: 'не назначен', status: 'draft', basis: 'Наработка 9 800 из 11 000 ч'),
    PlanItem(id: 'P-505', unitId: 'N-101', work: 'Ревизия', date: '05.05.2027', time: '09:00', who: 'не назначен', status: 'draft', basis: '22 000 ч наработки'),
  ]);
  db.history.addAll(const {
    'N-101': [
      HistoryEvent(date: '14.11.2026', time: '09:34', status: 'bad', title: 'Находка: деградация уплотнения вала', text: 'Осмотр INS-2209 · правило R01', who: 'Алексей Смирнов'),
      HistoryEvent(date: '14.11.2026', time: '08:12', status: 'warn', title: 'Вибрация 1X выше уставки', text: '3,1 мм/с, уставка 2,8 мм/с · правило S01', who: 'Система'),
      HistoryEvent(date: '13.11.2026', time: '16:40', status: 'info', title: 'Плановый осмотр', text: 'Внешних дефектов не выявлено, отмечен шум подшипника', who: 'Алексей Смирнов'),
      HistoryEvent(date: '12.11.2026', time: '10:05', status: 'warn', title: 'Температура подшипника 76 °C', text: 'Уставка 75 °C · правило S04', who: 'Система'),
      HistoryEvent(date: '10.11.2026', time: '11:30', status: 'info', title: 'Осмотр после тревоги', text: 'Ослабления крепления не выявлено. Рекомендуется контроль вибрации', who: 'Алексей Смирнов'),
      HistoryEvent(date: '10.11.2026', time: '08:20', status: 'bad', title: 'Вибрация 1X выше аварийной уставки', text: '4,8 мм/с, уставка 4,5 мм/с · 40 мин', who: 'Система'),
      HistoryEvent(date: '02.11.2026', time: '09:00', status: 'ok', title: 'Отчёт за октябрь', text: 'PDF и Excel сформированы', who: 'Марина Орлова'),
      HistoryEvent(date: '28.05.2026', time: '10:00', status: 'ok', title: 'ТО-1 выполнено', text: 'Наработка 15 200 ч', who: 'Елена Титова'),
    ],
    'AMS-1': [
      HistoryEvent(date: '12.11.2026', time: '10:20', status: 'info', title: 'Плановый осмотр', text: 'Коррозия рамы у болта, замечание снято мастером', who: 'Елена Титова'),
      HistoryEvent(date: '01.11.2026', time: '09:00', status: 'ok', title: 'Отчёт за октябрь', text: 'PDF и Excel сформированы', who: 'Марина Орлова'),
    ],
    'AMS-2': [
      HistoryEvent(date: '14.11.2026', time: '07:30', status: 'info', title: 'Ремонт запланирован', text: 'Замена уплотнения 15.11, 08:00', who: 'Марина Орлова'),
      HistoryEvent(date: '14.11.2026', time: '07:05', status: 'bad', title: 'Находка: течь торцевого уплотнения', text: 'Осмотр INS-2207 · правило R01', who: 'Алексей Смирнов'),
      HistoryEvent(date: '14.11.2026', time: '06:44', status: 'bad', title: 'Аварийная остановка', text: 'Обмотка 112 °C, уставка 110 °C · правило S05', who: 'Система'),
      HistoryEvent(date: '14.11.2026', time: '06:40', status: 'warn', title: 'Сообщение о неисправности', text: 'Течь под агрегатом, повышенный шум', who: 'Ольга Кузнецова'),
    ],
  });
  db.notifications.addAll({
    'engineer': [
      const AppNotification(id: 'n1', time: '09:12', kind: 'info', title: 'Новое задание от мастера', text: 'Н-101 · осмотр по срабатыванию правила R08 до 10:00', target: '/engineer/objects/card/N-101'),
      const AppNotification(id: 'n2', time: '08:12', kind: 'warn', title: 'Н-101: вибрация 1X выше уставки', text: '3,1 мм/с, уставка 2,8 мм/с', target: '/engineer/objects/card/N-101'),
      const AppNotification(id: 'n3', time: '06:52', kind: 'bad', title: 'АМС-2: осмотр по сообщению оператора', text: 'Течь под агрегатом, повышенный шум', target: '/engineer/objects/card/AMS-2'),
    ],
    'master': [
      const AppNotification(id: 'm1', time: '09:34', kind: 'bad', title: 'Новая находка ждёт подтверждения', text: 'Н-101 · деградация уплотнения вала · R01', target: '/master/findings'),
      const AppNotification(id: 'm2', time: '08:12', kind: 'warn', title: 'Н-101: сработало правило R08', text: 'Вибрация и температура подшипника растут', target: '/master/findings'),
      const AppNotification(id: 'm3', time: '06:40', kind: 'bad', title: 'Оператор сообщил о неисправности', text: 'АМС-2 · течь под агрегатом', target: '/master/findings'),
    ],
    'operator': [
      const AppNotification(id: 'o1', time: '07:30', kind: 'info', title: 'АМС-2 на ремонте', text: 'Ремонт уплотнения 15.11, 08:00', target: '/operator/objects'),
      const AppNotification(id: 'o2', time: '06:52', kind: 'ok', title: 'Сообщение принято мастером', text: 'Осмотр назначен инженеру', target: '/operator/history'),
    ],
    'admin': [
      const AppNotification(id: 'a1', time: '09:05', kind: 'warn', title: 'Задержка опроса Modbus', text: 'Шлюз вибродатчиков Н-101 · 2,4 с', target: '/admin/sources'),
      const AppNotification(id: 'a2', time: '03:00', kind: 'ok', title: 'Резервная копия создана', text: '1,8 ГБ · 03:00-03:07', target: '/admin/system'),
    ],
    'sec': [
      const AppNotification(id: 's1', time: '09:10', kind: 'warn', title: '3 неудачных входа подряд', text: 'v.panov@kst-energo.ru · учётная запись заблокирована', target: '/sec/log'),
      const AppNotification(id: 's2', time: 'вчера', kind: 'info', title: 'Временный пароль истекает', text: 'Павел Ершов · до 15.11, 09:08', target: '/sec/users'),
    ],
  });
  db.assistantSuggestions.addAll(const ['Почему растёт вибрация Н-101?', 'Порядок замены торцевого уплотнения', 'Что входит в ТО-2?', 'Сравнить Н-101 за неделю']);
  db.assistantDialog.addAll(const [
    AssistantMessage(fromUser: true, text: 'Почему растёт вибрация Н-101?'),
    AssistantMessage(fromUser: false, text: 'Вибрация 1X выросла с 2,4 до 3,1 мм/с за 3 суток, температура подшипника - с 71 до 78 °C, ток в норме (9,8 А). Такое сочетание соответствует правилу R08: признаки проблемы смазки или износа подшипников. Ресурс подшипников - 19 190 из 20 000 ч. Рекомендуется проверка смазки подшипникового узла.', refs: ['R08', 'Паспорт IL 65/160, с. 34']),
  ]);
  db.server = const ServerStatus(name: 'Цеховой сервер КСТ-СРВ-02', ip: '10.20.4.15', version: '1.4.2', uptime: '18 сут 6 ч', cpu: 23, ram: 41, disk: 58, clients: 7, wifi: 'KST-NS2-Field', lastBackup: '14.11.2026 03:00', backupSize: '1,8 ГБ', updateAvailable: '1.5.0', updateSize: '214 МБ', updateNotes: 'Новая модель чтения манометров, ускорение отчётов Excel');
  db.sources.addAll(const [
    DataSource(id: 'src-opc', name: 'Сервер ввода-вывода', proto: 'OPC UA', addr: 'opc.tcp://10.20.1.8:4840', status: 'ok', statusLabel: 'Подключено', tags: 46, poll: '1 с', latency: '120 мс', security: 'Basic256Sha256, подпись и шифрование'),
    DataSource(id: 'src-plc', name: 'ПЛК узла откачки АМС', proto: 'Modbus TCP', addr: '10.20.1.9:502', status: 'ok', statusLabel: 'Подключено', tags: 18, poll: '1 с', latency: '40 мс', security: 'Сегмент АСУ ТП, только чтение'),
    DataSource(id: 'src-vib', name: 'Шлюз вибродатчиков Н-101', proto: 'Modbus RTU → TCP', addr: '10.20.1.12:502', status: 'warn', statusLabel: 'Задержка 2,4 с', tags: 8, poll: '2 с', latency: '2,4 с', security: 'Только чтение'),
  ]);
  db.tags.addAll(const [
    TagBinding(tag: 'NS2.N101.VIB_1X', unitId: 'N-101', param: 'Вибрация 1X', eu: 'мм/с', value: '3,1', sourceId: 'src-vib', addr: '40011'),
    TagBinding(tag: 'NS2.N101.VIB_2X', unitId: 'N-101', param: 'Вибрация 2X', eu: 'мм/с', value: '1,2', sourceId: 'src-vib', addr: '40012'),
    TagBinding(tag: 'NS2.N101.VIB_HF', unitId: 'N-101', param: 'ВЧ шум вибрации', eu: 'g', value: '1,9', sourceId: 'src-vib', addr: '40013'),
    TagBinding(tag: 'NS2.N101.T_BRG', unitId: 'N-101', param: 'Температура подшипника', eu: '°C', value: '78', sourceId: 'src-opc', addr: 'ns=2;s=N101.TBRG'),
    TagBinding(tag: 'NS2.N101.T_WND', unitId: 'N-101', param: 'Температура обмоток', eu: '°C', value: '84', sourceId: 'src-opc', addr: 'ns=2;s=N101.TWND'),
    TagBinding(tag: 'NS2.N101.P_OUT', unitId: 'N-101', param: 'Давление нагнетания', eu: 'бар', value: '4,6', sourceId: 'src-opc', addr: 'ns=2;s=N101.POUT'),
    TagBinding(tag: 'NS2.AMS2.T_WND', unitId: 'AMS-2', param: 'Температура обмоток', eu: '°C', value: '112', sourceId: 'src-plc', addr: '30021'),
    TagBinding(tag: 'NS2.AMS1.P_OUT', unitId: 'AMS-1', param: 'Давление нагнетания', eu: 'бар', value: '6,2', sourceId: 'src-plc', addr: '30005'),
  ]);
  db.models.addAll(const [
    RecognitionModel(id: 'm-det', name: 'Узлы и внешние дефекты', version: '3.2', date: '02.11.2026', status: 'active', metric: 'Полнота дефектов 0,94', classes: 14, fps: '24 кадр/с', size: '48 МБ'),
    RecognitionModel(id: 'm-gauge', name: 'Чтение стрелочных манометров', version: '1.4', date: '20.10.2026', status: 'active', metric: 'Погрешность ±0,1 бар', classes: 1, fps: '12 кадр/с', size: '9 МБ'),
    RecognitionModel(id: 'm-plate', name: 'Распознавание шильдика', version: '2.1', date: '15.09.2026', status: 'active', metric: 'Точность 0,98', classes: 1, fps: '8 кадр/с', size: '22 МБ'),
    RecognitionModel(id: 'm-det-next', name: 'Узлы и внешние дефекты', version: '3.3 beta', date: '12.11.2026', status: 'test', metric: 'Полнота дефектов 0,96', classes: 16, fps: '22 кадр/с', size: '51 МБ'),
  ]);
  db.syslog.addAll(const [
    SysLogEntry(time: '09:05', level: 'warn', source: 'Опрос', text: 'Шлюз вибродатчиков Н-101: задержка ответа 2,4 с'),
    SysLogEntry(time: '08:12', level: 'info', source: 'Правила', text: 'Сработало R08 для Н-101, уведомлены 2 пользователя'),
    SysLogEntry(time: '06:44', level: 'bad', source: 'Правила', text: 'S05 тревога: АМС-2 обмотка 112 °C'),
    SysLogEntry(time: '03:07', level: 'ok', source: 'Резерв', text: 'Резервная копия 1,8 ГБ создана'),
    SysLogEntry(time: '03:00', level: 'info', source: 'Резерв', text: 'Запуск резервного копирования по расписанию'),
    SysLogEntry(time: '00:00', level: 'info', source: 'Отчёты', text: 'Суточный отчёт сформирован'),
  ]);
  db.backups.addAll(const [
    Backup(date: '14.11.2026', time: '03:00', size: '1,8 ГБ', kind: 'По расписанию', status: 'ok'),
    Backup(date: '13.11.2026', time: '03:00', size: '1,8 ГБ', kind: 'По расписанию', status: 'ok'),
    Backup(date: '12.11.2026', time: '15:20', size: '1,7 ГБ', kind: 'Перед обновлением моделей', status: 'ok'),
  ]);
  db.permissions.addAll(const [
    Permission(key: 'view', label: 'Просмотр состояния и показаний', group: 'Оборудование'),
    Permission(key: 'report_fault', label: 'Сообщение о неисправности', group: 'Оборудование'),
    Permission(key: 'inspect', label: 'Осмотр со сканером', group: 'Осмотры'),
    Permission(key: 'findings', label: 'Фиксация находок', group: 'Осмотры'),
    Permission(key: 'diagnostics', label: 'Диагностика и история', group: 'Осмотры'),
    Permission(key: 'assistant', label: 'Ассистент', group: 'Осмотры'),
    Permission(key: 'confirm', label: 'Подтверждение и закрытие находок', group: 'Управление'),
    Permission(key: 'plan', label: 'Планирование ТО', group: 'Управление'),
    Permission(key: 'mode', label: 'Смена режима агрегата', group: 'Управление'),
    Permission(key: 'reports_own', label: 'Свои отчёты PDF и Excel', group: 'Отчёты'),
    Permission(key: 'reports_all', label: 'Отчёты смены и участка', group: 'Отчёты'),
    Permission(key: 'system', label: 'Цеховой сервер, обновления, резерв', group: 'Система'),
    Permission(key: 'sources', label: 'Источники данных и теги', group: 'Система'),
    Permission(key: 'models', label: 'Модели распознавания', group: 'Система'),
    Permission(key: 'syslog', label: 'Системный журнал', group: 'Система'),
    Permission(key: 'users', label: 'Учётные записи', group: 'Безопасность'),
    Permission(key: 'roles', label: 'Роли и права', group: 'Безопасность'),
    Permission(key: 'policy', label: 'Политика безопасности', group: 'Безопасность'),
    Permission(key: 'seclog', label: 'Журнал безопасности', group: 'Безопасность'),
  ]);
  db.roles.addAll(const [
    Role(id: 'engineer', name: 'Инженер', users: 4, system: true, permissions: ['view', 'inspect', 'findings', 'diagnostics', 'assistant', 'reports_own']),
    Role(id: 'master', name: 'Мастер', users: 2, system: true, permissions: ['view', 'inspect', 'findings', 'diagnostics', 'assistant', 'reports_own', 'confirm', 'plan', 'mode', 'reports_all']),
    Role(id: 'operator', name: 'Оператор', users: 3, system: true, permissions: ['view', 'report_fault', 'assistant']),
    Role(id: 'admin', name: 'Админ', users: 1, system: true, permissions: ['system', 'sources', 'models', 'syslog']),
    Role(id: 'security_admin', name: 'Админ ИБ', users: 1, system: true, permissions: ['users', 'roles', 'policy', 'seclog']),
  ]);
  db.seniorRoleTemplate = const Role(id: 'senior', name: 'Старший инженер', users: 0, system: false, permissions: ['view', 'inspect', 'findings', 'diagnostics', 'assistant', 'reports_own', 'confirm', 'reports_all']);
  db.seniorRoleAssignee = 'Елена Титова';
  db.policy = const SecurityPolicy(pwdMin: 10, pwdClasses: 'буквы, цифры и символ', pwdExpireDays: 90, lockAfter: 5, lockMinutes: 30, sessionHours: 12, idleMinutes: 15, biometrics: true, tempPwdHours: 24, twoFactorAdmins: true);
  db.seclog.addAll(const [
    SecLogEntry(time: '09:10', level: 'warn', who: 'v.panov@kst-energo.ru', text: '3 неудачных входа подряд с 10.20.4.77'),
    SecLogEntry(time: '09:08', level: 'info', who: 'Дмитрий Захаров', text: 'Создана учётная запись p.ershov@kst-energo.ru, роль Инженер'),
    SecLogEntry(time: '08:02', level: 'ok', who: 'Алексей Смирнов', text: 'Вход по биометрии, устройство KV-T14'),
    SecLogEntry(time: '07:55', level: 'ok', who: 'Марина Орлова', text: 'Вход по паролю'),
    SecLogEntry(time: '02.11', level: 'bad', who: 'Дмитрий Захаров', text: 'Заблокирована учётная запись v.panov@kst-energo.ru'),
  ]);
  db.devices.addAll(const [
    Device(name: 'KV-T14 · Galaxy Tab Active5', who: 'Алексей Смирнов', last: '14.11 08:02'),
    Device(name: 'KV-P03 · Pixel 8', who: 'Марина Орлова', last: '14.11 07:55'),
  ]);
  db.settingsDefaults.addAll(const {
    'theme': 'light',
    'labels': true,
    'haptics': true,
    'sensitivity': 'Максимум',
    'biometrics': true,
    'reportPhotos': true,
    'cacheSize': '312 МБ',
    'appVersion': '1.4.2 (сборка 412)',
  });
}
