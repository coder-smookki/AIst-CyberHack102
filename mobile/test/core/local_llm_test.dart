import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/core/llm/local_answer.dart';
import 'package:kst_vizor/core/llm/local_pack.dart';
import 'package:kst_vizor/core/llm/local_search.dart';

/// Небольшой набор знаний для проверки поиска и разбора ссылок.
final LocalPack _pack = LocalPack.parse(jsonEncode(<String, Object?>{
  'units': <Object?>[
    <String, Object?>{'id': 'AMS-1', 'name': 'АМС-1', 'model': 'AMS PCP 60S12/3', 'aliases': <String>['амс-1', 'амс 1']},
    <String, Object?>{'id': 'N-101', 'name': 'Н-101', 'model': 'Wilo CronoLine IL 65/160', 'aliases': <String>['н-101']},
  ],
  'screens': <Object?>[
    <String, Object?>{'id': 'card', 'title': 'Карточка агрегата', 'path': '/engineer/objects/card/{unit}', 'needs_unit': true},
    <String, Object?>{'id': 'charts', 'title': 'Графики', 'path': '/engineer/objects/card/{unit}/charts', 'needs_unit': true},
    <String, Object?>{'id': 'scanner', 'title': 'Сканер', 'path': '/engineer/scanner', 'needs_unit': false},
    <String, Object?>{'id': 'rule', 'title': 'Правило', 'path': '/engineer/rule/{rule}', 'needs_unit': false},
  ],
  'chunks': <Object?>[
    <String, Object?>{
      'id': 'ts.vibration',
      'kind': 'troubleshooting',
      'title': 'Повышенная вибрация',
      'text': 'Порог 1x: внимание > 2.8, авария > 4.5 мм/с. Причины: износ подшипников, расцентровка муфты.',
      'keywords': <String>['вибрирует', 'трясёт', 'вибрация'],
      'links': <Object?>[
        <String, Object?>{'label': 'Графики {unit}', 'path': '/engineer/objects/card/{unit}/charts'},
      ],
    },
    <String, Object?>{
      'id': 'howto.inspection',
      'kind': 'howto',
      'title': 'Как начать осмотр',
      'text': 'Откройте сканер и наведите камеру на табличку агрегата.',
      'keywords': <String>['осмотр', 'начать', 'обход'],
      'links': <Object?>[
        <String, Object?>{'label': 'Сканер', 'path': '/engineer/scanner'},
      ],
    },
    <String, Object?>{
      'id': 'unit.ams1',
      'kind': 'unit',
      'title': 'АМС-1',
      'text': 'Винтовой насосный агрегат.',
      'keywords': <String>['винтовой'],
      'links': <Object?>[],
      'unit': 'AMS-1',
    },
  ],
  'safety': <String>['Решение принимает инженер.'],
}));

void main() {
  final LinkValidator validator = LinkValidator(_pack.screens, _pack.units.map((PackUnit u) => u.id));

  group('разбор ссылок', () {
    test('проверенная ссылка уходит в чип, текст очищается', () {
      final ParsedAnswer a = parseAnswer('Откройте графики. [[Графики АМС-1|/engineer/objects/card/AMS-1/charts]]', validator);
      expect(a.text, 'Откройте графики.');
      expect(a.links.single.path, '/engineer/objects/card/AMS-1/charts');
      expect(a.links.single.kind, 'chart');
    });

    test('выдуманный путь или агрегат не становится ссылкой, подпись остаётся текстом', () {
      final ParsedAnswer a = parseAnswer('См. [[Секрет|/engineer/secret]] и [[Карточка|/engineer/objects/card/X-9]]', validator);
      expect(a.links, isEmpty);
      expect(a.text, 'См. Секрет и Карточка');
    });

    test('незаконченная ссылка в потоке скрыта, повтор пути убран', () {
      final ParsedAnswer a = parseAnswer('Шаг 1. [[Сканер|/engineer/scanner]] [[Сканер|/engineer/scanner]] [[Граф', validator, streaming: true);
      expect(a.text, 'Шаг 1.');
      expect(a.links.length, 1);
    });

    test('путь с параметрами и шаблоном правила', () {
      expect(validator.valid('/engineer/rule/R08'), isTrue);
      expect(validator.valid('/engineer/scanner?unit=AMS-1'), isTrue);
      expect(validator.valid('/engineer/scanner?unit=ZZZ'), isFalse);
    });

    test('блок рассуждений и служебные токены убираются', () {
      expect(parseAnswer('<think>\nx\n</think>\n\nГотово.<|im_end|>', validator).text, 'Готово.');
    });
  });

  group('поиск по справке', () {
    final LocalSearch search = LocalSearch(_pack, minScore: 0.5);

    test('основа слова: разные формы находят одно', () {
      expect(stemWord('вибрация'), stemWord('вибрации'));
      expect(tokenize('Как начать осмотр?'), <String>[stemWord('начать'), 'осмотр']);
    });

    test('вопрос о неисправности находит фрагмент и агрегат из вопроса', () {
      final SearchResult r = search.search('АМС-1 сильно вибрирует, что делать?');
      expect(r.hits.first.chunk.id, 'ts.vibration');
      expect(r.unit?.id, 'AMS-1');
      expect(r.unitFromQuestion, isTrue);
    });

    test('агрегат берётся из контекста экрана, если не назван', () {
      final SearchResult r = search.search('трясёт агрегат', contextUnit: 'N-101');
      expect(r.unit?.id, 'N-101');
      expect(r.unitFromQuestion, isFalse);
    });

    test('вопрос не по теме ничего не находит', () {
      expect(search.search('Какая погода в Уфе?').found, isFalse);
    });

    test('запрос модели содержит справку со ссылками на агрегат', () {
      final SearchResult r = search.search('АМС-1 вибрирует');
      final String msg = buildUserMessage('АМС-1 вибрирует', r, const AskContext(screen: 'Карточка агрегата'));
      expect(msg, contains('Агрегат: АМС-1 (AMS PCP 60S12/3)'));
      expect(msg, contains('[[Графики АМС-1|/engineer/objects/card/AMS-1/charts]]'));
      expect(buildPrompt(msg), endsWith('<|im_start|>assistant\n<think>\n\n</think>\n\n'));
    });

    test('ответ без модели: текст справки, ссылки и фраза об инженере', () {
      final ParsedAnswer a = fallbackAnswer(search.search('АМС-1 вибрирует'));
      expect(a.text, contains('4.5 мм/с'));
      expect(a.text, endsWith(kDecisionLine));
      expect(a.links.single.path, '/engineer/objects/card/AMS-1/charts');
      expect(fallbackAnswer(search.search('рецепт борща')).links, isEmpty);
    });

    test('краткий ответ модели дополняется текстом справки, полный - нет', () {
      final SearchResult r = search.search('АМС-1 вибрирует');
      expect(withReference('Проверьте муфту.', r), contains('Из справки: Порог 1x'));
      const String full = 'Порог 1x: внимание > 2.8, авария > 4.5 мм/с. Причины: износ подшипников, расцентровка муфты.';
      expect(withReference(full, r), full);
    });

    test('проверка чисел: значение не из справки отмечается', () {
      expect(unsupportedNumbers('Авария выше 7.1 мм/с', 'авария > 4.5 мм/с'), <String>{'7.1'});
      expect(unsupportedNumbers('Авария выше 4,5 мм/с, шаг 2', 'авария > 4.5 мм/с'), isEmpty);
    });
  });
}
