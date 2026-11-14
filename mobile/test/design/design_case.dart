import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kst_vizor/core/icons/kv_icon.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/models/people.dart';

/// Снимок дизайна одного экрана прототипа: маршрут, роль сеанса и шаги до нужного состояния
/// (касание, открывающее лист, диалог или уведомление).
///
/// Пример: `DesignCase('card-menu', route: '/engineer/objects/card/N-101', role: KvRole.engineer, steps: [TapLabel('Ещё')])`.
class DesignCase {
  /// Создаёт снимок экрана [id] прототипа.
  const DesignCase(
    this.id, {
    required this.route,
    this.role,
    this.email,
    this.steps = const <DesignStep>[],
    this.time = '9:41',
    this.setup,
    this.skip,
  });

  /// Пропуск экрана-дубля доски с причиной: экран не снимается, но учтён в покрытии.
  const DesignCase.skip(this.id, {required String reason})
      : route = '',
        role = null,
        email = null,
        steps = const <DesignStep>[],
        time = '9:41',
        setup = null,
        skip = reason;

  /// Идентификатор экрана прототипа: имя файла снимка.
  final String id;

  /// Путь приложения.
  final String route;

  /// Роль сеанса; null - без входа (экраны входа).
  final KvRole? role;

  /// Почта учётной записи вместо стандартной для роли.
  final String? email;

  /// Шаги после открытия маршрута.
  final List<DesignStep> steps;

  /// Время в строке состояния снимка.
  final String time;

  /// Подготовка данных демонстрационного сервера до открытия экрана.
  final void Function(MockBackend backend)? setup;

  /// Причина пропуска или null.
  final String? skip;

  /// Почта стандартной учётной записи роли.
  String? get accountEmail => email ??
      switch (role) {
        null => null,
        KvRole.engineer => 'engineer@kst.demo',
        KvRole.master => 'master@kst.demo',
        KvRole.operator => 'operator@kst.demo',
        KvRole.admin => 'admin@kst.demo',
        KvRole.sec => 'security@kst.demo',
        KvRole.senior => 'e.titova@kst-energo.ru',
      };
}

/// Шаг подготовки снимка.
abstract class DesignStep {
  /// Базовый конструктор.
  const DesignStep();

  /// Выполнить шаг; [container] - провайдеры приложения.
  Future<void> run(WidgetTester tester, ProviderContainer container);
}

/// Касание виджета по точному тексту.
class TapText extends DesignStep {
  /// Создаёт шаг.
  const TapText(this.text, {this.index = 0});

  /// Текст.
  final String text;

  /// Какое совпадение по счёту.
  final int index;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) => tapFinder(tester, find.text(text).at(index), 'текст «$text»');
}

/// Касание по подписи для диктора (semanticLabel кнопок: «Назад», «Ещё», «Закрыть»).
class TapLabel extends DesignStep {
  /// Создаёт шаг.
  const TapLabel(this.label, {this.index = 0});

  /// Подпись.
  final String label;

  /// Какое совпадение по счёту.
  final int index;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) => tapFinder(tester, find.bySemanticsLabel(label).at(index), 'подпись «$label»');
}

/// Касание по ключу виджета.
class TapKey extends DesignStep {
  /// Создаёт шаг.
  const TapKey(this.key);

  /// Значение ключа.
  final String key;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) => tapFinder(tester, find.byKey(ValueKey<String>(key)), 'ключ $key');
}

/// Касание значка дизайна.
class TapIcon extends DesignStep {
  /// Создаёт шаг.
  const TapIcon(this.icon, {this.index = 0});

  /// Значок.
  final KvIcons icon;

  /// Какое совпадение по счёту.
  final int index;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) =>
      tapFinder(tester, find.byWidgetPredicate((Widget w) => w is KvIcon && w.icon == icon).at(index), 'значок ${icon.name}');
}

/// Ввод текста в поле по ключу.
class EnterText extends DesignStep {
  /// Создаёт шаг.
  const EnterText(this.key, this.text);

  /// Ключ поля.
  final String key;

  /// Текст.
  final String text;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) async {
    final Finder f = find.byKey(ValueKey<String>(key));
    expect(f, findsOneWidget, reason: 'Нет поля с ключом $key');
    await tester.enterText(f, text);
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Пауза для анимаций и таймеров.
class Wait extends DesignStep {
  /// Создаёт шаг.
  const Wait(this.duration);

  /// Длительность.
  final Duration duration;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) => pumpFor(tester, duration);
}

/// Произвольный шаг.
class Custom extends DesignStep {
  /// Создаёт шаг из функции [body].
  const Custom(this.body);

  /// Действие.
  final Future<void> Function(WidgetTester tester, ProviderContainer container) body;

  @override
  Future<void> run(WidgetTester tester, ProviderContainer container) => body(tester, container);
}

/// Касание найденного виджета с проверкой, что он один на экране, и ожиданием отклика.
Future<void> tapFinder(WidgetTester tester, Finder finder, String what) async {
  expect(finder, findsOneWidget, reason: 'Не найдена цель касания: $what');
  await tester.tap(finder, warnIfMissed: false);
  await pumpFor(tester, const Duration(milliseconds: 700));
}

/// Кадры каждые 50 мс в течение [d].
Future<void> pumpFor(WidgetTester tester, Duration d) async {
  final int n = (d.inMilliseconds / 50).ceil();
  for (int i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
