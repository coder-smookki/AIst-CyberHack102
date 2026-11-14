import 'local_pack.dart';
import 'local_search.dart';

/// Фраза о решении инженера в конце советов по ремонту, правилам и состояниям.
const String kDecisionLine = 'Решение принимает инженер.';

/// Системная инструкция модели; совпадает с той, на которой модель дообучена.
const String kSystemPrompt =
    'Ты помощник приложения «КСТ Визор» на телефоне инженера, работаешь без интернета. Отвечай по-русски, коротко '
    'и только по справке из вопроса. Ссылки на экраны бери из справки и пиши как [[подпись|путь]]. Не придумывай '
    'номера деталей, числа и пороги. Отсутствие найденных дефектов не означает исправность. Советы по ремонту '
    'и неисправностям заканчивай фразой «Решение принимает инженер.». На вопросы не о приложении и оборудовании '
    'вежливо отказывай.';

/// Часть ответа: текст или ссылка-переход.
class AnswerLink {
  /// Создаёт ссылку.
  const AnswerLink(this.label, this.path);

  /// Подпись чипа.
  final String label;

  /// Путь go_router.
  final String path;

  /// Вид ссылки по пути: card, chart, history, document, rule, scanner или screen.
  String get kind {
    if (path.contains('/charts')) {
      return 'chart';
    }
    if (path.contains('history')) {
      return 'history';
    }
    if (path.contains('/rule/')) {
      return 'rule';
    }
    if (path.contains('doc')) {
      return 'document';
    }
    if (path.contains('/card/')) {
      return 'card';
    }
    return 'screen';
  }
}

/// Разобранный ответ: чистый текст для показа и проверенные ссылки.
class ParsedAnswer {
  /// Создаёт ответ.
  const ParsedAnswer(this.text, this.links);

  /// Текст без разметки ссылок.
  final String text;

  /// Ссылки, пути которых есть среди экранов приложения.
  final List<AnswerLink> links;
}

final RegExp _token = RegExp(r'\[\[([^\[\]|]{1,80})\|(/[^\[\]\s|]{1,160})\]\]');

/// Проверяет путь ссылки по шаблонам экранов набора знаний: «{unit}» - идентификатор агрегата.
class LinkValidator {
  /// Строит проверку по экранам [screens] и известным агрегатам [unitIds].
  LinkValidator(List<PackScreen> screens, Iterable<String> unitIds) : _units = unitIds.toSet() {
    for (final PackScreen s in screens) {
      final String path = s.path.split('?').first;
      if (!path.startsWith('/')) {
        continue;
      }
      final String re = RegExp.escape(path)
          .replaceAll(RegExp.escape('{unit}'), '([A-Za-z0-9-]+)')
          .replaceAll(RegExp(r'\\\{[a-z_]+\\\}'), '[A-Za-z0-9-]+');
      _patterns.add(RegExp('^$re\$'));
    }
  }

  final Set<String> _units;
  final List<RegExp> _patterns = <RegExp>[];

  /// Путь ведёт на известный экран и известный агрегат.
  bool valid(String path) {
    final Uri? uri = Uri.tryParse(path);
    if (uri == null) {
      return false;
    }
    final String unit = uri.queryParameters['unit'] ?? '';
    if (unit.isNotEmpty && !_units.contains(unit)) {
      return false;
    }
    for (final RegExp p in _patterns) {
      final RegExpMatch? m = p.firstMatch(uri.path);
      if (m != null) {
        if (m.groupCount >= 1 && m.group(1) != null && !_units.contains(m.group(1))) {
          return false;
        }
        return true;
      }
    }
    return false;
  }
}

/// Разбирает ответ модели: ссылки [[подпись|путь]] уходят в чипы (если путь проверен), подпись остаётся в тексте
/// только у непроверенных ссылок; незаконченная ссылка в конце потока скрывается.
ParsedAnswer parseAnswer(String raw, LinkValidator validator, {bool streaming = false}) {
  String s = raw.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').replaceAll('<|im_end|>', '');
  if (streaming) {
    final int open = s.lastIndexOf('[[');
    if (open >= 0 && !s.substring(open).contains(']]')) {
      s = s.substring(0, open);
    }
    if (s.endsWith('[')) {
      s = s.substring(0, s.length - 1);
    }
  }
  final List<AnswerLink> links = <AnswerLink>[];
  final Set<String> seen = <String>{};
  final String text = s.replaceAllMapped(_token, (Match m) {
    final String label = m.group(1)!.trim();
    final String path = m.group(2)!.trim();
    if (validator.valid(path)) {
      if (seen.add(path)) {
        links.add(AnswerLink(label, path));
      }
      return '';
    }
    return label;
  });
  final String clean = text
      .split('\n')
      .map((String l) => l.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trimRight())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .replaceAll(RegExp(r'^(Ссылки|Перейти|Экраны):?\s*$', multiLine: true), '')
      .trim();
  return ParsedAnswer(clean, links);
}

/// Контекст экрана, из которого задан вопрос.
class AskContext {
  /// Создаёт контекст.
  const AskContext({this.screen, this.unitId});

  /// Заголовок открытого экрана: «Карточка агрегата».
  final String? screen;

  /// Агрегат открытого экрана: AMS-1.
  final String? unitId;
}

/// Подставляет агрегат [unit] в ссылку; без агрегата убирает параметр «unit={unit}», а ссылку с агрегатом в пути
/// пропускает.
PackLink? bindLink(PackLink l, PackUnit? unit) {
  if (!l.path.contains('{unit}')) {
    return l;
  }
  if (unit != null) {
    return PackLink(l.label.replaceAll('{unit}', unit.name), l.path.replaceAll('{unit}', unit.id));
  }
  String path = l.path.replaceAll(RegExp(r'[?&]unit=\{unit\}'), '');
  if (path.contains('{unit}')) {
    return null;
  }
  if (!path.contains('?') && path.contains('&')) {
    path = path.replaceFirst('&', '?');
  }
  return PackLink(l.label.replaceAll(RegExp(r'\s*[·-]?\s*\{unit\}'), '').trim(), path);
}

/// Текст пользовательского сообщения для модели: экран, агрегат, справка с ссылками и вопрос.
String buildUserMessage(String question, SearchResult found, AskContext ctx) {
  final StringBuffer b = StringBuffer();
  if (ctx.screen != null && ctx.screen!.isNotEmpty) {
    b.writeln('Экран: ${ctx.screen}');
  }
  final PackUnit? u = found.unit;
  if (u != null) {
    b.writeln('Агрегат: ${u.name}${u.model.isEmpty ? '' : ' (${u.model})'}');
  }
  if (found.hits.isEmpty) {
    b.writeln('Справка: ничего не найдено.');
  } else {
    b.writeln('Справка:');
    int i = 1;
    for (final SearchHit h in found.hits) {
      final List<String> links = <String>[
        for (final PackLink l in h.chunk.links)
          if (bindLink(l, found.unitFor(h.chunk)) case final PackLink bound) bound.token,
      ];
      b.writeln('[$i] ${h.chunk.title}: ${h.chunk.text}${links.isEmpty ? '' : ' Ссылки: ${links.join(' ')}'}');
      i++;
    }
  }
  b.write('Вопрос: ${question.trim()}');
  return b.toString();
}

/// Полный запрос в формате ChatML; [thinkPrefix] - пустой блок рассуждений, как у моделей с режимом размышления.
String buildPrompt(String userMessage, {bool thinkPrefix = true}) {
  final StringBuffer b = StringBuffer()
    ..write('<|im_start|>system\n$kSystemPrompt<|im_end|>\n')
    ..write('<|im_start|>user\n$userMessage<|im_end|>\n')
    ..write('<|im_start|>assistant\n');
  if (thinkPrefix) {
    b.write('<think>\n\n</think>\n\n');
  }
  return b.toString();
}

/// Числа в тексте (с запятой или точкой), для проверки, что модель не придумала значения.
Set<String> numbersIn(String text) => <String>{
      for (final RegExpMatch m in RegExp(r'\d+(?:[.,]\d+)?').allMatches(text)) m.group(0)!.replaceAll(',', '.'),
    };

/// Числа ответа, которых нет ни в вопросе, ни в справке: признак выдуманных значений.
Set<String> unsupportedNumbers(String answer, String prompt) {
  final Set<String> known = numbersIn(prompt);
  return <String>{
    for (final String n in numbersIn(answer))
      if (!known.contains(n) && !RegExp(r'^[1-9]$').hasMatch(n)) n,
  };
}

/// Ответ без модели: лучший фрагмент справки целиком, второй - заголовком, ссылки из обоих и фраза об инженере.
ParsedAnswer fallbackAnswer(SearchResult found, {String? question}) {
  if (found.hits.isEmpty) {
    return const ParsedAnswer(
      'Я помогаю только с приложением «КСТ Визор» и оборудованием, а в справке на устройстве ответа на этот вопрос '
      'нет. Спросите про экран приложения, агрегат, правило, состояние или неисправность: например, «как начать '
      'осмотр» или «АМС-1 греется подшипник».',
      <AnswerLink>[],
    );
  }
  final SearchHit top = found.hits.first;
  final StringBuffer b = StringBuffer(top.chunk.text.trim());
  if (found.hits.length > 1) {
    b.write('\n\nСм. также: ${found.hits.skip(1).map((SearchHit h) => h.chunk.title).join('; ')}.');
  }
  if (found.hits.any((SearchHit h) => h.chunk.needsDecisionLine) && !b.toString().contains(kDecisionLine)) {
    b.write('\n\n$kDecisionLine');
  }
  final List<AnswerLink> links = <AnswerLink>[];
  final Set<String> seen = <String>{};
  for (final SearchHit h in found.hits) {
    for (final PackLink l in h.chunk.links) {
      final PackLink? bound = bindLink(l, found.unitFor(h.chunk));
      if (bound != null && seen.add(bound.path) && links.length < 5) {
        links.add(AnswerLink(bound.label, bound.path));
      }
    }
  }
  return ParsedAnswer(b.toString(), links);
}

/// Доля основ слов фрагмента [reference], которые есть в ответе [answer].
double coverage(String answer, String reference) {
  final Set<String> ref = tokenize(reference).where((String w) => w.length > 3).toSet();
  if (ref.isEmpty) {
    return 1;
  }
  final Set<String> got = tokenize(answer).toSet();
  return ref.where(got.contains).length / ref.length;
}

/// Ответ модели, дополненный текстом лучшего фрагмента справки, если модель пересказала его слишком кратко:
/// так инженер не теряет причины, проверки и меры безопасности из источника.
String withReference(String answer, SearchResult found) {
  if (found.hits.isEmpty) {
    return answer;
  }
  final String top = found.hits.first.chunk.text.trim();
  if (coverage(answer, top) >= 0.6) {
    return answer;
  }
  return '$answer\n\nИз справки: $top';
}
