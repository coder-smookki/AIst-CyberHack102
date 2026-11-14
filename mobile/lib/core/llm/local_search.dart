import 'dart:math' as math;

import 'local_pack.dart';

/// Окончания русских слов, отрезаемые при сведении слова к основе (от длинных к коротким).
const List<String> _endings = <String>[
  'иями', 'ями', 'ами', 'ией', 'иям', 'ием', 'ого', 'его', 'ому', 'ему', 'ыми', 'ими', 'ость', 'ости', 'остью',
  'ться', 'тся', 'ешь', 'ует', 'уют', 'ает', 'яет', 'ают', 'яют', 'ишь', 'ить', 'ать', 'ять', 'еть', 'ут', 'ют',
  'ит', 'ят', 'ат', 'ет', 'ем', 'им', 'ым', 'ой', 'ей', 'ий', 'ый', 'ая', 'яя', 'ое', 'ее', 'ие', 'ые', 'ам',
  'ям', 'ах', 'ях', 'ов', 'ев', 'ом', 'ую', 'юю', 'ия', 'ья', 'ье', 'ью', 'ии', 'а', 'я', 'о', 'е', 'и', 'ы', 'у',
  'ю', 'ь', 'й',
];

/// Номер правила в вопросе: R08, р8, S-01, v1.
final RegExp _ruleId = RegExp(r'(?<![a-zа-я0-9])([rрsv])-?(\d{1,2})(?![a-zа-я0-9])');

/// Служебные слова, не влияющие на поиск.
const Set<String> _stop = <String>{
  'и', 'в', 'во', 'на', 'с', 'со', 'к', 'ко', 'по', 'о', 'об', 'от', 'до', 'за', 'из', 'у', 'не', 'ни', 'а', 'но',
  'же', 'ли', 'бы', 'то', 'это', 'как', 'что', 'где', 'мне', 'меня', 'я', 'ты', 'вы', 'мы', 'он', 'она', 'оно',
  'они', 'его', 'её', 'ее', 'их', 'там', 'тут', 'здесь', 'есть', 'для', 'при', 'или', 'так', 'уже', 'ещё', 'еще',
  'можно', 'нужно', 'надо', 'какой', 'какая', 'какие', 'какое', 'который', 'пожалуйста', 'подскажи', 'скажи',
  'расскажи', 'покажи', 'такое', 'такой', 'вот', 'этот', 'эта', 'эти', 'него', 'нее', 'неё', 'кто',
};

/// Сводит слово к основе: нижний регистр, «ё» как «е», отрезанное окончание; основа не короче трёх букв.
String stemWord(String word) {
  final String w = word.toLowerCase().replaceAll('ё', 'е');
  if (w.length <= 3 || !RegExp(r'^[а-я]+$').hasMatch(w)) {
    return w;
  }
  for (final String e in _endings) {
    if (w.endsWith(e) && w.length - e.length >= 3) {
      return w.substring(0, w.length - e.length);
    }
  }
  return w;
}

/// Разбивает текст на основы слов без служебных слов; цифры и латиница сохраняются.
List<String> tokenize(String text) {
  final String t = text.toLowerCase().replaceAll('ё', 'е');
  final List<String> out = <String>[];
  for (final RegExpMatch m in RegExp(r'[a-zа-я0-9]+').allMatches(t)) {
    final String w = m.group(0)!;
    if (_stop.contains(w)) {
      continue;
    }
    out.add(stemWord(w));
  }
  return out;
}

/// Найденный фрагмент с оценкой.
class SearchHit {
  /// Создаёт результат.
  const SearchHit(this.chunk, this.score);

  /// Фрагмент.
  final PackChunk chunk;

  /// Оценка BM25 с поправкой на агрегат.
  final double score;
}

/// Результат поиска: агрегат вопроса (или контекста) и лучшие фрагменты.
class SearchResult {
  /// Создаёт результат.
  const SearchResult({required this.unit, required this.hits, required this.unitFromQuestion, required this.pack});

  /// Набор знаний, по которому шёл поиск.
  final LocalPack pack;

  /// Тот же результат с [n] лучшими фрагментами: слабым телефонам в запрос идёт меньше справки.
  SearchResult top(int n) => SearchResult(unit: unit, hits: hits.take(n).toList(), unitFromQuestion: unitFromQuestion, pack: pack);

  /// Агрегат для ссылок фрагмента [c].
  PackUnit? unitFor(PackChunk c) => pack.unit(c.unitFor(unit?.id));

  /// Агрегат, о котором вопрос; null - не определён.
  final PackUnit? unit;

  /// Агрегат назван в самом вопросе, а не взят из контекста экрана.
  final bool unitFromQuestion;

  /// Фрагменты по убыванию оценки.
  final List<SearchHit> hits;

  /// Есть уверенное совпадение.
  bool get found => hits.isNotEmpty;
}

/// Поиск BM25 по фрагментам справки: поля заголовка, ключевых слов и текста с весами, поправка на агрегат.
class LocalSearch {
  /// Строит индекс по набору [pack].
  LocalSearch(this.pack, {this.minScore = 2.2}) {
    for (final PackChunk c in pack.chunks) {
      final Map<String, double> tf = <String, double>{};
      void add(String text, double w) {
        for (final String s in tokenize(text)) {
          tf[s] = (tf[s] ?? 0) + w;
        }
      }

      add(c.title, 2.5);
      add(c.keywords.join(' '), 2);
      add(c.text, 1);
      _tf.add(tf);
      final double len = tf.values.fold(0, (double a, double b) => a + b);
      _len.add(len);
      for (final String s in tf.keys) {
        _df[s] = (_df[s] ?? 0) + 1;
      }
    }
    _avg = _len.isEmpty ? 1 : _len.reduce((double a, double b) => a + b) / _len.length;
  }

  /// Набор знаний.
  final LocalPack pack;

  final List<Map<String, double>> _tf = <Map<String, double>>[];
  final List<double> _len = <double>[];
  final Map<String, int> _df = <String, int>{};
  double _avg = 1;

  /// Наименьшая оценка, при которой фрагмент считается найденным.
  final double minScore;

  /// Находит агрегат, названный в вопросе [question]; null - не назван.
  PackUnit? unitIn(String question) {
    final String q = ' ${question.toLowerCase().replaceAll('ё', 'е')} ';
    PackUnit? best;
    int bestLen = 0;
    for (final PackUnit u in pack.units) {
      for (final String a in <String>[...u.aliases, u.id.toLowerCase(), u.name.toLowerCase()]) {
        if (a.isEmpty) {
          continue;
        }
        final RegExp re = RegExp('(^|[^a-zа-я0-9])${RegExp.escape(a)}(?![a-zа-я0-9])');
        if (re.hasMatch(q) && a.length > bestLen) {
          best = u;
          bestLen = a.length;
        }
      }
    }
    return best;
  }

  /// Вопрос [question] без написаний агрегата [unit]: агрегат учитывается поправкой, а не словами поиска.
  static String withoutUnit(String question, PackUnit unit) {
    String q = question.toLowerCase().replaceAll('ё', 'е');
    final List<String> names = <String>[...unit.aliases, unit.id.toLowerCase(), unit.name.toLowerCase()]
      ..sort((String a, String b) => b.length.compareTo(a.length));
    for (final String a in names) {
      if (a.isNotEmpty) {
        q = q.replaceAll(RegExp('(^|[^a-zа-я0-9])${RegExp.escape(a)}(?![a-zа-я0-9])'), ' ');
      }
    }
    return q;
  }

  /// Ищет фрагменты по вопросу [question]; [contextUnit] - агрегат открытого экрана, [limit] - сколько вернуть.
  SearchResult search(String question, {String? contextUnit, int limit = 3}) {
    final PackUnit? named = unitIn(question);
    final PackUnit? unit = named ?? pack.unit(contextUnit);
    final List<String> q = tokenize(named == null ? question : withoutUnit(question, named));
    final String lower = question.toLowerCase();
    final Set<String> rules = <String>{
      for (final RegExpMatch m in _ruleId.allMatches(lower))
        '${m.group(1) == 'r' || m.group(1) == 'р' ? 'R' : m.group(1)!.toUpperCase()}${m.group(2)!.padLeft(2, '0')}',
    };
    final bool statusQuestion = RegExp('статус|означа|значит|цвет|рамк').hasMatch(lower);
    final int n = pack.chunks.length;
    final List<SearchHit> hits = <SearchHit>[];
    for (int i = 0; i < n; i++) {
      double score = 0;
      final Map<String, double> tf = _tf[i];
      for (final String s in q.toSet()) {
        final double f = tf[s] ?? 0;
        if (f == 0) {
          continue;
        }
        final int df = _df[s] ?? 0;
        final double idf = math.log(1 + (n - df + 0.5) / (df + 0.5));
        score += idf * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * _len[i] / _avg));
      }
      if (score <= 0) {
        continue;
      }
      final PackChunk c = pack.chunks[i];
      if (rules.isNotEmpty) {
        if (c.kind == 'rule' && rules.any(c.title.contains)) {
          score *= 3;
        }
      } else if (c.id.endsWith('.card')) {
        score *= 1.5;
      }
      if (c.kind == 'safety') {
        score *= 0.6;
      }
      if (c.kind == 'status' && statusQuestion) {
        score *= 1.6;
      }
      if (unit != null && c.unit != null) {
        score *= c.unit == unit.id ? 1.35 : 0.45;
      } else if (unit != null && c.units.isNotEmpty) {
        score *= c.units.contains(unit.id) ? 1.25 : 0.5;
      }
      hits.add(SearchHit(pack.chunks[i], score));
    }
    hits.sort((SearchHit a, SearchHit b) => b.score.compareTo(a.score));
    final List<SearchHit> top = <SearchHit>[
      for (final SearchHit h in hits.take(limit))
        if (h.score >= minScore && h.score >= hits.first.score * 0.45) h,
    ];
    if (top.isEmpty && named != null) {
      top.addAll(<SearchHit>[
        for (final PackChunk c in pack.chunks)
          if (c.kind == 'unit' && c.unit == named.id) SearchHit(c, minScore),
      ].take(2));
    }
    return SearchResult(unit: unit, hits: top, unitFromQuestion: named != null, pack: pack);
  }
}
