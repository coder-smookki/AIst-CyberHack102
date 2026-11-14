import '../../models/admin.dart';
import '../mock_db.dart';

/// Дополнения демонстрационных данных раздела «Админ и Админ ИБ» поверх истории 14.11.2026.
///
/// Вызывается после seedStory и seedBase. Приводит данные разделов «Админ» и «Админ ИБ» к прототипу:
/// политика безопасности как на сервере (пароль от 10 символов с буквами и цифрами, 10 ошибок за 5 минут,
/// сеанс 720 ч), полный системный журнал и журнал безопасности с подробностями, все устройства смены
/// с версиями приложения и открытые сеансы со способом входа.
void seedAdmins(MockDb db) {
  db.policy = const SecurityPolicy(
    pwdMin: 10,
    pwdClasses: 'буквы и цифры',
    pwdExpireDays: 0,
    lockAfter: 10,
    lockMinutes: 5,
    sessionHours: 720,
    idleMinutes: 0,
    biometrics: true,
    tempPwdHours: 24,
    twoFactorAdmins: false,
  );

  db.syslog
    ..clear()
    ..addAll(const [
      SysLogEntry(
        time: '09:34',
        level: 'info',
        source: 'Осмотры',
        text: 'Сохранён осмотр INS-2209 · Н-101',
        details: [('Инженер', 'Алексей Смирнов'), ('Устройство', 'KV-T14'), ('Находки', 'F-1043, R01')],
      ),
      SysLogEntry(
        time: '09:20',
        level: 'info',
        source: 'Сканер',
        text: 'Н-101 опознан по шильдику',
        details: [('Модель', 'Шильдик и QR 2.1'), ('Уверенность', '0,99'), ('Устройство', 'KV-T14')],
      ),
      SysLogEntry(
        time: '09:05',
        level: 'warn',
        source: 'Опрос',
        text: 'Шлюз вибродатчиков Н-101: задержка ответа 2,4 с',
        details: [('Источник', 'Modbus 10.20.1.12:502'), ('Норма', 'до 1 с'), ('Тегов затронуто', '8')],
        ref: 'source:src-vib',
      ),
      SysLogEntry(
        time: '08:12',
        level: 'info',
        source: 'Правила',
        text: 'Сработало R08 для Н-101, уведомлены 2 пользователя',
        details: [('Агрегат', 'Н-101'), ('Условие', 'вибрация 3,1 мм/с и подшипник 78 °C'), ('Уведомлены', 'А. Смирнов, М. Орлова')],
        ref: 'source:src-opc',
      ),
      SysLogEntry(
        time: '07:30',
        level: 'info',
        source: 'Режимы',
        text: 'АМС-2 переведён в режим «На ремонте»',
        details: [('Кто', 'Марина Орлова'), ('Основание', 'F-1041, ремонт 15.11 08:00')],
      ),
      SysLogEntry(
        time: '06:44',
        level: 'bad',
        source: 'Правила',
        text: 'S05 тревога: АМС-2 обмотка 112 °C',
        details: [('Агрегат', 'АМС-2'), ('Уставка', '110 °C'), ('Действие', 'агрегат остановлен')],
        ref: 'tags:AMS-2',
      ),
      SysLogEntry(
        time: '03:07',
        level: 'ok',
        source: 'Резерв',
        text: 'Резервная копия 1,8 ГБ создана',
        details: [('Длительность', '7 мин'), ('Хранится копий', '14')],
        ref: 'maint',
      ),
      SysLogEntry(time: '03:00', level: 'info', source: 'Резерв', text: 'Запуск резервного копирования по расписанию', details: [('Расписание', 'ежедневно 03:00')]),
      SysLogEntry(time: '00:00', level: 'info', source: 'Отчёты', text: 'Суточный отчёт сформирован', details: [('Форматы', 'PDF и Excel'), ('Агрегатов', '3')]),
    ]);

  db.seclog
    ..clear()
    ..addAll(const [
      SecLogEntry(
        time: '09:10',
        level: 'warn',
        who: 'v.panov@kst-energo.ru',
        text: '3 неудачных входа подряд с 10.20.4.77',
        kind: 'fail',
        title: '3 неудачных входа',
        details: [('Учётная запись', 'v.panov@kst-energo.ru'), ('Адрес', '10.20.4.77 · KV-T11'), ('Попыток', '3 за 40 с'), ('Результат', 'отказ: заблокирована с 02.11')],
        userId: 'u-111',
      ),
      SecLogEntry(
        time: '09:10',
        level: 'ok',
        who: 'Дмитрий Захаров',
        text: 'Вход по биометрии, устройство KV-P05',
        kind: 'login',
        title: 'Вход по биометрии',
        details: [('Устройство', 'KV-P05 · Pixel 8'), ('Способ', 'биометрия')],
        userId: 'u-105',
      ),
      SecLogEntry(
        time: '09:08',
        level: 'info',
        who: 'Дмитрий Захаров',
        text: 'Создана учётная запись p.ershov@kst-energo.ru, роль Инженер',
        kind: 'change',
        title: 'Создана учётная запись',
        details: [('Кто изменил', 'Дмитрий Захаров'), ('Учётная запись', 'p.ershov@kst-energo.ru'), ('Роль', 'нет → Инженер'), ('Пароль', 'временный до 15.11, 09:08')],
        userId: 'u-110',
      ),
      SecLogEntry(
        time: '08:02',
        level: 'ok',
        who: 'Алексей Смирнов',
        text: 'Вход по биометрии, устройство KV-T14',
        kind: 'login',
        title: 'Вход по биометрии',
        details: [('Устройство', 'KV-T14 · Galaxy Tab Active5'), ('Способ', 'биометрия')],
        userId: 'u-101',
      ),
      SecLogEntry(
        time: '07:55',
        level: 'ok',
        who: 'Марина Орлова',
        text: 'Вход по паролю',
        kind: 'login',
        title: 'Вход по паролю',
        details: [('Устройство', 'KV-P03 · Pixel 8'), ('Способ', 'пароль')],
        userId: 'u-102',
      ),
      SecLogEntry(
        time: '06:31',
        level: 'ok',
        who: 'Ольга Кузнецова',
        text: 'Вход по паролю',
        kind: 'login',
        title: 'Вход по паролю',
        details: [('Устройство', 'KV-T09 · Galaxy Tab Active5'), ('Способ', 'пароль')],
        userId: 'u-103',
      ),
      SecLogEntry(
        time: '02.11',
        level: 'bad',
        who: 'Дмитрий Захаров',
        text: 'Заблокирована учётная запись v.panov@kst-energo.ru',
        kind: 'block',
        title: 'Блокировка входа',
        details: [('Кто изменил', 'Дмитрий Захаров'), ('Учётная запись', 'v.panov@kst-energo.ru'), ('Статус', 'активна → заблокирована'), ('Причина', 'Перевод на другой участок')],
        userId: 'u-111',
      ),
    ]);

  db.devices
    ..clear()
    ..addAll(const [
      Device(name: 'KV-T14 · Galaxy Tab Active5', who: 'А. Смирнов', last: '14.11 08:02', version: '1.4.2'),
      Device(name: 'KV-P03 · Pixel 8', who: 'М. Орлова', last: '14.11 07:55', version: '1.4.2'),
      Device(name: 'KV-T09 · Galaxy Tab Active5', who: 'О. Кузнецова', last: '14.11 06:31', version: '1.4.2'),
      Device(name: 'KV-P05 · Pixel 8', who: 'Д. Захаров', last: '14.11 09:10', version: '1.4.2'),
      Device(name: 'KV-P01 · Pixel 8', who: 'И. Власов', last: '13.11 17:40', version: '1.4.2'),
      Device(name: 'KV-T11 · Galaxy Tab Active5', who: 'Общий, смена Б', last: '13.11 20:05', version: '1.4.1'),
      Device(name: 'KV-T12 · Galaxy XCover7', who: 'Общий, смена Б', last: '13.11 20:02', version: '1.4.1'),
    ]);

  db.sessions
    ..clear()
    ..addAll(const [
      UserSession(id: 'KV-T14', userId: 'u-101', device: 'KV-T14 · Galaxy Tab Active5', since: '08:02', method: 'Биометрия'),
      UserSession(id: 'KV-P03', userId: 'u-102', device: 'KV-P03 · Pixel 8', since: '07:55', method: 'Пароль'),
      UserSession(id: 'KV-T07', userId: 'u-109', device: 'KV-T07 · Galaxy Tab Active5', since: '08:15', method: 'Пароль'),
      UserSession(id: 'KV-T09', userId: 'u-103', device: 'KV-T09 · Galaxy Tab Active5', since: '06:31', method: 'Пароль'),
      UserSession(id: 'KV-P05', userId: 'u-105', device: 'KV-P05 · Pixel 8', since: '09:10', method: 'Биометрия'),
    ]);
}
