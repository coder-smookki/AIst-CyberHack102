import 'dart:convert';

/// Ссылка на экран приложения: подпись и путь go_router.
class PackLink {
  /// Создаёт ссылку с подписью [label] и путём [path].
  const PackLink(this.label, this.path);

  /// Из записи набора знаний.
  factory PackLink.fromJson(Map<String, dynamic> j) => PackLink('${j['label'] ?? ''}', '${j['path'] ?? ''}');

  /// Подпись чипа.
  final String label;

  /// Путь экрана; может содержать «{unit}» - подставляется текущий агрегат.
  final String path;

  /// Ссылка в разметке ответа: [[подпись|путь]].
  String get token => '[[$label|$path]]';

  @override
  bool operator ==(Object other) => other is PackLink && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// Агрегат из набора знаний: идентификатор маршрутов, название, модель и написания для поиска.
class PackUnit {
  /// Создаёт агрегат.
  const PackUnit({required this.id, required this.name, required this.model, required this.aliases});

  /// Из записи набора знаний.
  factory PackUnit.fromJson(Map<String, dynamic> j) => PackUnit(
        id: '${j['id']}',
        name: '${j['name'] ?? j['id']}',
        model: '${j['model'] ?? ''}',
        aliases: <String>[for (final Object? a in (j['aliases'] as List<Object?>? ?? const <Object?>[])) '$a'.toLowerCase()],
      );

  /// Идентификатор в путях: AMS-1.
  final String id;

  /// Название: «АМС-1».
  final String name;

  /// Модель: «AMS PCP 60S12/3».
  final String model;

  /// Написания в вопросах: «амс-1», «амс 1».
  final List<String> aliases;
}

/// Фрагмент справки, по которому идёт поиск: самодостаточный текст, ключевые слова и ссылки.
class PackChunk {
  /// Создаёт фрагмент.
  const PackChunk({
    required this.id,
    required this.kind,
    required this.title,
    required this.text,
    required this.keywords,
    required this.links,
    this.unit,
    this.units = const <String>[],
  });

  /// Из записи набора знаний.
  factory PackChunk.fromJson(Map<String, dynamic> j) => PackChunk(
        id: '${j['id']}',
        kind: '${j['kind'] ?? ''}',
        title: '${j['title'] ?? ''}',
        text: '${j['text'] ?? ''}',
        keywords: <String>[for (final Object? k in (j['keywords'] as List<Object?>? ?? const <Object?>[])) '$k'],
        links: <PackLink>[
          for (final Object? l in (j['links'] as List<Object?>? ?? const <Object?>[]))
            if (l is Map<String, dynamic>) PackLink.fromJson(l),
        ],
        unit: j['unit'] == null || '${j['unit']}'.isEmpty || '${j['unit']}' == 'null' ? null : '${j['unit']}',
        units: <String>[for (final Object? u in (j['units'] as List<Object?>? ?? const <Object?>[])) '$u'],
      );

  /// Идентификатор: «ts.vibration.ams».
  final String id;

  /// Вид: troubleshooting, screen, rule, status, maintenance, howto, unit, role, safety.
  final String kind;

  /// Заголовок.
  final String title;

  /// Текст справки.
  final String text;

  /// Ключевые слова и синонимы.
  final List<String> keywords;

  /// Ссылки на экраны.
  final List<PackLink> links;

  /// Агрегат, к которому относится фрагмент; null - общий.
  final String? unit;

  /// Агрегаты, к которым относится фрагмент уровня модели; пусто - ко всем.
  final List<String> units;

  /// Агрегат для ссылок фрагмента: агрегат вопроса, если фрагмент к нему относится, иначе первый из [units].
  String? unitFor(String? asked) {
    if (unit != null) {
      return unit;
    }
    if (asked != null && (units.isEmpty || units.contains(asked))) {
      return asked;
    }
    return units.isEmpty ? null : units.first;
  }

  /// Фрагмент про неисправность, правило или состояние: ответ заканчивается фразой об инженере.
  bool get needsDecisionLine => kind == 'troubleshooting' || kind == 'rule' || kind == 'status' || kind == 'maintenance';
}

/// Шаблон экрана: путь с «{unit}» и заголовок; по шаблонам проверяются ссылки из ответа модели.
class PackScreen {
  /// Создаёт шаблон.
  const PackScreen({required this.id, required this.title, required this.path, required this.needsUnit});

  /// Из записи набора знаний.
  factory PackScreen.fromJson(Map<String, dynamic> j) => PackScreen(
        id: '${j['id']}',
        title: '${j['title'] ?? ''}',
        path: '${j['path'] ?? ''}',
        needsUnit: j['needs_unit'] == true,
      );

  /// Идентификатор.
  final String id;

  /// Заголовок экрана.
  final String title;

  /// Путь с подстановкой «{unit}».
  final String path;

  /// Экрану нужен агрегат.
  final bool needsUnit;
}

/// Набор знаний помощника: агрегаты, экраны и фрагменты справки, собранные из кода, правил и документов.
class LocalPack {
  /// Создаёт набор.
  const LocalPack({required this.units, required this.screens, required this.chunks, required this.safety});

  /// Разбирает JSON набора знаний.
  factory LocalPack.parse(String source) {
    final Map<String, dynamic> j = jsonDecode(source) as Map<String, dynamic>;
    List<Map<String, dynamic>> list(String key) =>
        <Map<String, dynamic>>[for (final Object? e in (j[key] as List<Object?>? ?? const <Object?>[])) if (e is Map<String, dynamic>) e];
    return LocalPack(
      units: list('units').map(PackUnit.fromJson).toList(),
      screens: list('screens').map(PackScreen.fromJson).toList(),
      chunks: list('chunks').map(PackChunk.fromJson).toList(),
      safety: <String>[for (final Object? s in (j['safety'] as List<Object?>? ?? const <Object?>[])) '$s'],
    );
  }

  /// Агрегаты.
  final List<PackUnit> units;

  /// Экраны.
  final List<PackScreen> screens;

  /// Фрагменты справки.
  final List<PackChunk> chunks;

  /// Формулировки безопасности.
  final List<String> safety;

  /// Агрегат по идентификатору; null - нет такого.
  PackUnit? unit(String? id) {
    if (id == null) {
      return null;
    }
    for (final PackUnit u in units) {
      if (u.id == id) {
        return u;
      }
    }
    return null;
  }
}
