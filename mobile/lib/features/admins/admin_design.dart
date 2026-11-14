import 'dart:math' as math;

import '../../core/kv.dart';
import '../../data/providers.dart';

/// Короткие названия источников данных на экранах администратора.
const Map<String, String> kAdmSourceShort = {
  'src-opc': 'Сервер ввода-вывода',
  'src-plc': 'ПЛК узла откачки',
  'src-vib': 'Шлюз вибродатчиков',
};

/// Короткое название источника [s].
String admSourceShort(DataSource s) => kAdmSourceShort[s.id] ?? s.name;

/// Значок источника: шлюз вибродатчиков - вибрация, остальные - разъём.
KvIcons admSourceIcon(DataSource s) => s.id == 'src-vib' ? KvIcons.vibrate : KvIcons.plug;

/// Детерминированный волнистый ряд прототипа (wave в 50_admins.js): [n] точек вокруг [base] с размахом [amp].
List<double> admWave(int n, double base, double amp, int seed, [double Function(int i, int n)? extra]) {
  final List<double> out = <double>[];
  int s = seed;
  for (int i = 0; i < n; i++) {
    s = (s * 9301 + 49297) % 233280;
    final double r = s / 233280 - 0.5;
    final double v = base + amp * r + math.sin(i / 2.6 + seed) * amp * 0.35 + (extra == null ? 0 : extra(i, n));
    out.add((v * 100).roundToDouble() / 100);
  }
  return out;
}

/// Загрузка процессора цехового сервера за сутки: пик во время резервного копирования, сейчас 23 %.
final List<double> kAdmCpu24 = () {
  final List<double> v = admWave(48, 19, 6, 7, (int i, int n) => i >= 34 && i <= 37 ? const [0.0, 28.0, 40.0, 22.0][i - 34] : 0);
  v[v.length - 1] = 23;
  return v;
}();

/// Отклик источников за последний час, мс.
final Map<String, List<double>> kAdmLatency = {
  'src-opc': admWave(30, 120, 14, 3),
  'src-plc': admWave(30, 40, 6, 5),
  'src-vib': admWave(30, 360, 80, 11, (int i, int n) => i > 19 ? math.pow((i - 19) / 10, 1.6) * 2050 : 0),
};

/// Сведения о модели распознавания, которых нет в ответе сервера: короткое имя, время кадра, ложные тревоги, классы.
class AdmModelInfo {
  /// Создаёт сведения.
  const AdmModelInfo({required this.short, required this.ms, required this.fp, required this.classes, this.isNew = const <String>[]});

  /// Короткое название.
  final String short;

  /// Время кадра: «42 мс».
  final String ms;

  /// Доля ложных тревог: «9 %».
  final String fp;

  /// Классы модели.
  final List<String> classes;

  /// Новые классы тестовой версии.
  final List<String> isNew;
}

const List<String> _detClasses = [
  'Электродвигатель',
  'Подшипниковый узел',
  'Муфта',
  'Кожух муфты',
  'Клеммная коробка',
  'Торцевое уплотнение',
  'Фланец',
  'Манометр',
  'Течь',
  'Коррозия',
  'Трещина',
  'Ослабленный болт',
  'Нет ограждения',
  'Повреждение кабеля',
];

/// Сведения о моделях по коду модели.
const Map<String, AdmModelInfo> kAdmModelInfo = {
  'm-det': AdmModelInfo(short: 'Детектор дефектов', ms: '42 мс', fp: '9 %', classes: _detClasses),
  'm-det-next': AdmModelInfo(
    short: 'Детектор дефектов',
    ms: '45 мс',
    fp: '7 %',
    classes: [..._detClasses, 'Подтёк масла', 'Ослабленная муфта'],
    isNew: ['Подтёк масла', 'Ослабленная муфта'],
  ),
  'm-gauge': AdmModelInfo(short: 'Чтение манометров', ms: '83 мс', fp: '2 %', classes: ['Стрелочный манометр']),
  'm-plate': AdmModelInfo(short: 'Шильдик и QR', ms: '125 мс', fp: '1 %', classes: ['Шильдик', 'QR-код']),
};

/// Сведения о модели [m]; для неизвестной - по её названию.
AdmModelInfo admModelInfo(RecognitionModel m) =>
    kAdmModelInfo[m.id] ?? AdmModelInfo(short: m.name, ms: '-', fp: '-', classes: const <String>[]);

/// Значок модели.
KvIcons admModelIcon(RecognitionModel m) => switch (m.id) {
  'm-gauge' => KvIcons.gauge,
  'm-plate' => KvIcons.qr,
  _ => KvIcons.target,
};

/// Название главной метрики модели: «Полнота дефектов».
String admMetricLabel(RecognitionModel m) => m.metric.replaceFirst(RegExp(r'\s[0-9±].*$'), '');

/// Значение главной метрики модели: «0,94».
String admMetricValue(RecognitionModel m) => m.metric.replaceFirst(RegExp(r'^[^0-9±]+'), '');

/// Версия без пометки «beta»: «3.3».
String admShortVersion(String version) => version.split(' ').first;

/// Имена ключей показаний в тегах.
const Map<String, String> kAdmTagKey = {
  'vib1x': 'vib_1x',
  'vib2x': 'vib_2x',
  'vibHf': 'vib_hf',
  'tBearing': 't_bearing',
  'tWinding': 't_winding',
  'pressOut': 'p_out',
  'pressIn': 'p_in',
  'current': 'i_motor',
  'unbalance': 'i_unbal',
  'flow': 'flow',
};

/// Узлы OPC UA показаний Н-101.
const Map<String, String> _opcNode = {
  'vib1x': 'VIB1X',
  'vib2x': 'VIB2X',
  'vibHf': 'VIBHF',
  'tBearing': 'TBRG',
  'tWinding': 'TWND',
  'pressOut': 'POUT',
  'pressIn': 'PIN',
  'current': 'IMOT',
  'unbalance': 'IUNB',
  'flow': 'FLOW',
};

/// Регистры Modbus показаний АМС-1 и АМС-2.
const Map<String, Map<String, int>> _amsRegister = {
  'AMS-1': {'pressOut': 5, 'current': 7, 'vib1x': 9, 'vib2x': 10, 'vibHf': 11, 'tBearing': 13, 'tWinding': 15},
  'AMS-2': {'pressOut': 17, 'current': 19, 'tWinding': 21, 'vib1x': 23, 'vib2x': 24, 'vibHf': 25, 'tBearing': 27},
};

/// Агрегаты, теги которых настраивает администратор.
const List<String> kAdmTagUnits = ['N-101', 'AMS-1', 'AMS-2'];

/// Тег показания на экране привязки: ключ, адрес, источник, значение и статус.
class AdmTag {
  /// Создаёт тег.
  const AdmTag({
    required this.key,
    required this.name,
    required this.label,
    required this.value,
    required this.digits,
    required this.eu,
    required this.warn,
    required this.alarm,
    required this.status,
    required this.sourceId,
    required this.addr,
    required this.tag,
    required this.unit,
  });

  /// Ключ показания: vib1x.
  final String key;

  /// Имя ключа в теге: vib_1x.
  final String name;

  /// Название показания.
  final String label;

  /// Значение; null - тег добавлен, показание ещё не приходило.
  final double? value;

  /// Знаков после запятой.
  final int digits;

  /// Единица.
  final String eu;

  /// Уставка «внимание».
  final double? warn;

  /// Уставка «авария».
  final double? alarm;

  /// Статус: ok, warn, bad, unk.
  final String status;

  /// Источник.
  final String sourceId;

  /// Узел OPC UA или регистр.
  final String addr;

  /// Полное имя тега на сервере.
  final String tag;

  /// Агрегат.
  final Equipment unit;
}

/// Теги агрегата [unit]: все показания с адресами из привязок [bindings] или по схеме адресов станции.
List<AdmTag> admTagsOf(Equipment unit, List<TagBinding> bindings) {
  final Set<String> labels = unit.readings.values.map((Reading r) => r.label).toSet();
  return [
    for (final Reading r in unit.readings.values)
      () {
        final TagBinding? given = bindings.where((TagBinding t) => t.unitId == unit.id && t.param == r.label).firstOrNull;
        final bool n101 = unit.id == 'N-101';
        final String sourceId = n101 ? (r.key.startsWith('vib') ? 'src-vib' : 'src-opc') : 'src-plc';
        final String addr = given?.addr ?? (n101 ? 'ns=2;s=N101.${_opcNode[r.key]}' : '${30000 + (_amsRegister[unit.id]?[r.key] ?? 0)}');
        final bool unk = unit.mode == 'repair' && (r.key == 'pressOut' || r.key == 'current');
        return AdmTag(
          key: r.key,
          name: kAdmTagKey[r.key] ?? r.key,
          label: r.label,
          value: r.value,
          digits: r.digits,
          eu: r.unit,
          warn: r.warn,
          alarm: r.alarm,
          status: unk ? 'unk' : r.status,
          sourceId: given?.sourceId ?? sourceId,
          addr: addr,
          tag: given?.tag ?? 'NS2.${unit.id.replaceAll('-', '')}.${(kAdmTagKey[r.key] ?? r.key).toUpperCase()}',
          unit: unit,
        );
      }(),
    for (final TagBinding t in bindings.where((TagBinding t) => t.unitId == unit.id && !labels.contains(t.param)))
      AdmTag(
        key: t.tag.split('.').last.toLowerCase(),
        name: t.tag.split('.').last.toLowerCase(),
        label: t.param,
        value: double.tryParse(t.value.replaceAll(',', '.')),
        digits: 1,
        eu: t.eu,
        warn: null,
        alarm: null,
        status: 'unk',
        sourceId: t.sourceId,
        addr: t.addr,
        tag: t.tag,
        unit: unit,
      ),
  ];
}

/// Группа прав, как их назвал заказчик.
class AdmPermGroup {
  /// Создаёт группу.
  const AdmPermGroup(this.name, this.keys);

  /// Название.
  final String name;

  /// Коды прав.
  final List<String> keys;
}

/// Группы прав на экранах ролей.
const List<AdmPermGroup> kAdmPermGroups = [
  AdmPermGroup('Осмотр', ['inspect', 'diagnostics']),
  AdmPermGroup('Находки', ['findings', 'confirm']),
  AdmPermGroup('Оборудование', ['view', 'report_fault', 'mode', 'plan']),
  AdmPermGroup('Отчёты', ['reports_own', 'reports_all']),
  AdmPermGroup('Ассистент', ['assistant']),
  AdmPermGroup('Система', ['system', 'sources', 'models', 'syslog']),
  AdmPermGroup('Учётные записи', ['users', 'roles', 'policy', 'seclog']),
];

/// Значок роли по коду.
KvIcons admRoleIcon(String roleId) => switch (roleId) {
  'engineer' => KvIcons.wrench,
  'master' => KvIcons.clipboard,
  'operator' => KvIcons.gauge,
  'admin' => KvIcons.server,
  'security_admin' || 'sec' => KvIcons.shield,
  'senior' => KvIcons.star,
  _ => KvIcons.key,
};

/// «6 прав».
String admRights(int n) => '$n ${KvFormat.plural(n, 'право', 'права', 'прав')}';

/// «4 пользователя».
String admUsersWord(int n) => '$n ${KvFormat.plural(n, 'пользователь', 'пользователя', 'пользователей')}';

/// «8 тегов».
String admTagsWord(int n) => '$n ${KvFormat.plural(n, 'тег', 'тега', 'тегов')}';

/// Название права по коду.
String admPermLabel(List<Permission> perms, String key) => perms.where((Permission p) => p.key == key).firstOrNull?.label ?? key;

/// «Алексей Смирнов» - «А. Смирнов».
String admShortName(String name) {
  final List<String> p = name.split(' ');
  return p.length < 2 ? name : '${p[0].substring(0, 1)}. ${p[1]}';
}

/// Подпись и тон состояния учётной записи.
(String, KvStatus) admUserState(String status) => switch (status) {
  'temp' => ('Временный пароль', KvStatus.warn),
  'blocked' => ('Заблокирована', KvStatus.bad),
  _ => ('Активна', KvStatus.ok),
};

/// Учётная запись ещё ни разу не входила.
bool admNeverLoggedIn(AdminUser u) => u.lastLogin.isEmpty || u.lastLogin == 'ещё не входил';
