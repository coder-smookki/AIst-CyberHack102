/// Числовой тип ядра под другим именем: внутри [KvFormat] имя num занято методом.
typedef KvNumber = num;

/// Форматирование чисел, дат и текста по правилам дизайна (KV.num и KV.typo в js/core.js).
abstract final class KvFormat {
  /// Неразрывный пробел.
  static const String nbsp = ' ';

  static final RegExp _thousands = RegExp(r'\B(?=(\d{3})+(?!\d))');
  static final RegExp _unit = RegExp(
    r'(\d) (?=(°C|мм/с|бар|ч|А|g|%|дн|МБ|КБ|ГБ|мин|сут|с|мс|кВт|м³/ч|об/мин)(?![а-яА-ЯёЁa-zA-Z]))',
  );
  static final RegExp _digitGroups = RegExp(r'(\d) (\d{3})(?!\d)');
  static final RegExp _initials = RegExp(r'([А-ЯЁ]\.) (?=[А-ЯЁ])');
  static final RegExp _ids = RegExp(r'([A-Za-zА-ЯЁ]{1,4})-(\d+)');

  /// Число по-русски: `num(3.1, 1)` - «3,1», `num(19190)` - «19 190» с неразрывным пробелом.
  ///
  /// Без [digits] целые печатаются без дробной части, а дробные меньше 10 - с одним знаком.
  static String num(KvNumber? value, [int? digits]) {
    if (value == null) {
      return '';
    }
    final int d = digits ?? (value.abs() < 10 && value % 1 != 0 ? 1 : 0);
    final List<String> parts = value.toStringAsFixed(d).split('.');
    final String whole = parts[0].replaceAll(_thousands, nbsp);
    return parts.length > 1 ? '$whole,${parts[1]}' : whole;
  }

  /// Число с единицей через неразрывный пробел: «78 °C», «3,1 мм/с».
  static String withUnit(KvNumber? value, String unit, [int? digits]) => '${num(value, digits)}$nbsp$unit';

  /// Типографская обработка строки: неразрывный пробел перед единицами, внутри разрядов и после инициалов;
  /// номера вида F-1043, АМС-2, ТО-2 не переносятся по дефису.
  static String typo(String text) => text
      .replaceAllMapped(_unit, (Match m) => '${m[1]}$nbsp')
      .replaceAllMapped(_digitGroups, (Match m) => '${m[1]}$nbsp${m[2]}')
      .replaceAllMapped(_initials, (Match m) => '${m[1]}$nbsp')
      .replaceAllMapped(_ids, (Match m) => '${m[1]}-⁠${m[2]}');

  /// Дата «14.11.2026».
  static String date(DateTime at) => '${_two(at.day)}.${_two(at.month)}.${at.year}';

  /// Дата без года «14.11».
  static String dayMonth(DateTime at) => '${_two(at.day)}.${_two(at.month)}';

  /// Время «09:41».
  static String time(DateTime at) => '${_two(at.hour)}:${_two(at.minute)}';

  /// Русское склонение по числу: plural(4, 'попытка', 'попытки', 'попыток') - «попытки».
  static String plural(int n, String one, String few, String many) {
    final int m10 = n.abs() % 10;
    final int m100 = n.abs() % 100;
    if (m10 == 1 && m100 != 11) {
      return one;
    }
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) {
      return few;
    }
    return many;
  }

  /// Время строки состояния «9:41».
  static String statusTime(DateTime at) => '${at.hour}:${_two(at.minute)}';

  static String _two(int v) => v < 10 ? '0$v' : '$v';
}
