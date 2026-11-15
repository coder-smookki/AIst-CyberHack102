import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kst_vizor/app/router.dart';
import 'package:kst_vizor/core/widgets/kv_pressable.dart';
import 'package:kst_vizor/core/widgets/kv_tabbar.dart';
import 'package:kst_vizor/features/engineer_service/assistant/local_assistant.dart';
import 'package:kst_vizor/features/master_operator/operator/op_blocks.dart';
import 'package:kst_vizor/main.dart' as app;

/// Папка отчёта в контейнере приложения (tmp/kv_itest): журнал шагов и снимки, их забирает devicectl.
final Directory _out = Directory('${Directory.systemTemp.path}/kv_itest');

/// Строка журнала: в консоль и в файл отчёта.
void _log(String line) {
  debugPrint(line);
  try {
    _out.createSync(recursive: true);
    File('${_out.path}/steps.log').writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

/// Кадры текущего этапа: время сборки и отрисовки по данным движка.
final List<ui.FrameTiming> _frames = <ui.FrameTiming>[];

/// Название текущего этапа замера кадров.
String _phaseName = 'запуск';

/// Перцентиль [q] списка миллисекунд.
double _pct(List<double> v, double q) {
  if (v.isEmpty) {
    return 0;
  }
  final List<double> s = List<double>.of(v)..sort();
  return s[((s.length - 1) * q).round()];
}

/// Итог по кадрам прошлого этапа в журнал и начало этапа [name].
void _phase(String name) {
  final List<double> build = _frames.map((ui.FrameTiming f) => f.buildDuration.inMicroseconds / 1000).toList();
  final List<double> raster = _frames.map((ui.FrameTiming f) => f.rasterDuration.inMicroseconds / 1000).toList();
  if (_frames.isNotEmpty) {
    String f(double x) => x.toStringAsFixed(1);
    _log(
      'KV_FRAMES $_phaseName: кадров ${_frames.length}; сборка p50 ${f(_pct(build, .5))} p90 ${f(_pct(build, .9))} max ${f(_pct(build, 1))}; '
      'отрисовка p50 ${f(_pct(raster, .5))} p90 ${f(_pct(raster, .9))} max ${f(_pct(raster, 1))}; '
      'сборка>8.3 ${build.where((double x) => x > 8.3).length}, отрисовка>8.3 ${raster.where((double x) => x > 8.3).length}, '
      'сборка>16.7 ${build.where((double x) => x > 16.7).length}, отрисовка>16.7 ${raster.where((double x) => x > 16.7).length}',
    );
  }
  _frames.clear();
  _phaseName = name;
}

/// Прокрутка главного списка экрана рывком вверх и обратно, как пальцем.
Future<void> _flingList(WidgetTester tester) async {
  final Finder scroll = find.byType(Scrollable);
  if (scroll.evaluate().isEmpty) {
    return;
  }
  for (int i = 0; i < 2; i++) {
    await tester.fling(scroll.first, const Offset(0, -500), 2500, warnIfMissed: false);
    await _wait(tester, 1200);
    await tester.fling(scroll.first, const Offset(0, 500), 2500, warnIfMissed: false);
    await _wait(tester, 1200);
  }
}

/// Привязка интеграционного теста.
late final IntegrationTestWidgetsFlutterBinding _binding;

/// Номер следующего снимка.
int _shot = 0;

/// Текст без неразрывных пробелов и регистра.
String _norm(String s) => s.replaceAll('\u00a0', ' ').replaceAll('\u202f', ' ').toLowerCase().trim();

/// Текст [s] на экране без учёта регистра и неразрывных пробелов (подписи разделов могут быть прописными).
Finder _text(String s) => find.byWidgetPredicate((Widget w) {
  final String? v = w is Text ? (w.data ?? w.textSpan?.toPlainText()) : (w is RichText ? w.text.toPlainText() : null);
  return v != null && _norm(v) == _norm(s);
});

/// Нажимаемый элемент с подписью для диктора [label].
Finder _press(String label) => find.byWidgetPredicate((Widget w) => w is KvPressable && w.semanticLabel != null && _norm(w.semanticLabel!) == _norm(label));

/// Карточка агрегата Н-101 в списке объектов (буква Н кириллицей или латиницей).
Finder _unitCard() => find.byWidgetPredicate((Widget w) => w is KvPressable && RegExp(r'^[НH]-101$').hasMatch(w.semanticLabel ?? ''));

/// Текущий путь маршрутизатора.
String _path() {
  final BuildContext? ctx = kvRootNavigatorKey.currentContext;
  if (ctx == null) {
    return '';
  }
  return GoRouter.of(ctx).routerDelegate.currentConfiguration.uri.path;
}

/// Контейнер провайдеров запущенного приложения.
ProviderContainer _container() => ProviderScope.containerOf(kvRootNavigatorKey.currentContext!, listen: false);

/// Кадры по 100 мс в течение [ms] миллисекунд.
Future<void> _wait(WidgetTester tester, [int ms = 800]) async {
  for (int i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Ждёт, пока [ok] станет истинным, не дольше [seconds] секунд.
Future<bool> _until(WidgetTester tester, bool Function() ok, {int seconds = 25}) async {
  final DateTime end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    if (ok()) {
      return true;
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
  return ok();
}

/// Ждёт появления [finder]; падает с понятным сообщением, если не дождался.
Future<void> _expectSoon(WidgetTester tester, Finder finder, String what, {int seconds = 25}) async {
  final bool ok = await _until(tester, () => finder.evaluate().isNotEmpty, seconds: seconds);
  expect(ok, isTrue, reason: 'не появилось: $what (путь ${_path()})');
}

/// Снимок экрана средствами integration_test: файл сохраняет драйвер на компьютере.
Future<void> _snap(WidgetTester tester, String name) async {
  await tester.pump();
  _shot++;
  final String id = '${_shot.toString().padLeft(2, '0')}_$name';
  try {
    final List<int> bytes = await _binding.takeScreenshot(id);
    _out.createSync(recursive: true);
    File('${_out.path}/$id.png').writeAsBytesSync(bytes, flush: true);
    _log('KV_SHOT $id');
  } catch (e) {
    _log('KV_SHOT_FAIL $id: $e');
  }
  await _wait(tester, 300);
}

/// Касание первого найденного виджета [finder] с ожиданием отклика.
Future<void> _tap(WidgetTester tester, Finder finder, String what, {int ms = 1200}) async {
  await _expectSoon(tester, finder, what);
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder.first, warnIfMissed: false);
  await _wait(tester, ms);
}

/// Касание вкладки нижней панели с подписью [label].
Future<void> _tab(WidgetTester tester, String label) async {
  final Finder f = find.descendant(of: find.byType(KvTabBar), matching: _press(label));
  await _tap(tester, f, 'вкладка «$label»', ms: 1500);
}

/// Прокрутка главного списка экрана, пока [finder] не попадёт в дерево, затем показ на экране.
Future<void> _scrollTo(WidgetTester tester, Finder finder, String what) async {
  for (int i = 0; i < 12 && finder.evaluate().isEmpty; i++) {
    final Finder scroll = find.byType(Scrollable);
    if (scroll.evaluate().isEmpty) {
      break;
    }
    await tester.drag(scroll.first, const Offset(0, -300), warnIfMissed: false);
    await _wait(tester, 400);
  }
  await _expectSoon(tester, finder, what, seconds: 5);
  await tester.ensureVisible(finder.first);
  await _wait(tester, 400);
}

/// Текст [value] прямо в контроллер поля [field]: на устройстве ввод через тестовую клавиатуру ненадёжен.
void _fill(WidgetTester tester, Finder field, String value) {
  final Finder editable = find.descendant(of: field, matching: find.byType(EditableText));
  expect(editable, findsOneWidget, reason: 'нет поля ввода $field');
  tester.widget<EditableText>(editable).controller.text = value;
}

/// Вход с почтой [email]: экран знакомства пропускается, предложение Face ID отклоняется.
Future<void> _login(WidgetTester tester, String email, String prefix) async {
  final Finder emailField = find.byKey(const ValueKey<String>('login-email'));
  bool atLogin = false;
  for (final DateTime end = DateTime.now().add(const Duration(seconds: 30)); DateTime.now().isBefore(end);) {
    if (emailField.evaluate().isNotEmpty) {
      atLogin = true;
      break;
    }
    if (_text('Пропустить').evaluate().isNotEmpty) {
      _log('KV_STEP знакомство при первом запуске: «Пропустить»');
      await tester.tap(_text('Пропустить').first, warnIfMissed: false);
      await _wait(tester, 1500);
    } else {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }
  expect(atLogin, isTrue, reason: 'нет экрана входа (путь ${_path()})');
  _fill(tester, emailField, email);
  _fill(tester, find.byKey(const ValueKey<String>('login-password')), 'demo12345');
  await tester.pump();
  FocusManager.instance.primaryFocus?.unfocus();
  await _wait(tester, 500);
  await tester.tap(_text('Войти').first, warnIfMissed: false);
  bool home = false;
  for (final DateTime end = DateTime.now().add(const Duration(seconds: 40)); DateTime.now().isBefore(end);) {
    if (_path().startsWith(prefix)) {
      home = true;
      break;
    }
    if (_text('Не сейчас').evaluate().isNotEmpty) {
      _log('KV_STEP предложение Face ID показано, ответ «Не сейчас»');
      await tester.tap(_text('Не сейчас').first, warnIfMissed: false);
      await _wait(tester, 1000);
    } else {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }
  expect(home, isTrue, reason: 'вход $email не открыл $prefix (путь ${_path()})');
  await _wait(tester, 2000);
  _log('KV_STEP вход $email -> ${_path()}');
}

/// Выход через вкладку «Профиль»: кнопка «Выйти из учётной записи» и подтверждение «Выйти».
Future<void> _logout(WidgetTester tester) async {
  await _tab(tester, 'Профиль');
  await _scrollTo(tester, _text('Выйти из учётной записи'), 'кнопка выхода');
  await tester.tap(_text('Выйти из учётной записи').first, warnIfMissed: false);
  await _wait(tester, 1000);
  await _tap(tester, _text('Выйти'), 'подтверждение выхода', ms: 1500);
  final bool out = await _until(tester, () => _path() == '/login', seconds: 20);
  expect(out, isTrue, reason: 'после выхода путь ${_path()}');
  _log('KV_STEP выход -> ${_path()}');
}

void main() {
  _binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iPhone: инженер, мастер и оператор на настоящем сервере', (WidgetTester tester) async {
    try {
      await _run(tester);
      _log('KV_DONE все шаги пройдены');
    } catch (e) {
      _log('KV_FAIL $e (путь ${_path()})');
      await _snap(tester, 'fail');
      rethrow;
    }
  });
}

/// Сценарий проверки: инженер, мастер, оператор; в конце приложение на экране входа.
Future<void> _run(WidgetTester tester) async {
  if (_out.existsSync()) {
    _out.deleteSync(recursive: true);
  }
  _log('KV_STEP старт теста');
  await app.main();
  await _wait(tester, 3000);
  if (_path().startsWith('/engineer') || _path().startsWith('/master') || _path().startsWith('/operator')) {
    await _logout(tester);
  }
  await _snap(tester, 'login');

  await _login(tester, 'engineer@kst.demo', '/engineer');
  await _expectSoon(tester, _unitCard(), 'агрегат Н-101 в объектах');
  await _snap(tester, 'engineer_objects');
  _log('KV_STEP объекты инженера: Н-101 есть');
  _phase('прокрутка объектов инженера');
  await _flingList(tester);
  _phase('открытие карточки Н-101');

  await _tap(tester, _unitCard(), 'карточка Н-101', ms: 2500);
  await _expectSoon(tester, _text('Сначала проверьте'), '«Сначала проверьте»');
  _phase('прокрутка карточки Н-101');
  await _flingList(tester);
  _phase('карточка: поиск разделов');
  await _scrollTo(tester, _text('Сначала проверьте'), '«Сначала проверьте»');
  await _snap(tester, 'card_first_checks');
  await _scrollTo(tester, _text('Паспорт агрегата'), 'раздел «Паспорт агрегата»');
  await _snap(tester, 'card_passport');
  _log('KV_STEP карточка Н-101: «Сначала проверьте» и «Паспорт агрегата» есть (путь ${_path()})');

  final NavigatorState nav = Navigator.of(kvRootNavigatorKey.currentContext!);
  for (int i = 0; i < 3 && find.byType(KvTabBar).evaluate().isEmpty; i++) {
    await nav.maybePop();
    await _wait(tester, 1000);
  }
  _phase('ассистент');
  await _tab(tester, 'Ассистент');
  await _expectSoon(tester, _press('Ближайшие ТО'), 'подсказки ассистента');
  await _snap(tester, 'assistant');
  await _tap(tester, _press('Ближайшие ТО'), 'подсказка «Ближайшие ТО»', ms: 500);
  final bool answered = await _until(tester, () {
    final LocalAssistantState s = _container().read(localAssistantProvider);
    return !s.busy && s.dialog.length >= 2 && !s.dialog.last.fromUser && s.dialog.last.text.trim().isNotEmpty;
  }, seconds: 90);
  final LocalAssistantState s = _container().read(localAssistantProvider);
  expect(answered, isTrue, reason: 'ассистент не ответил: ${s.dialog.length} сообщений, busy=${s.busy}');
  await _wait(tester, 1000);
  await _snap(tester, 'assistant_answer');
  final String answer = s.dialog.last.text.replaceAll('\n', ' ');
  _log('KV_STEP ассистент ответил (${s.model.name}, ссылок ${s.dialog.last.links.length}): ${answer.length > 160 ? answer.substring(0, 160) : answer}');

  _phase('выход и вход мастера');
  await _logout(tester);

  await _login(tester, 'master@kst.demo', '/master');
  _phase('мастер: смена');
  await _flingList(tester);
  _phase('мастер: находки и план ТО');
  await _snap(tester, 'master_shift');
  await _tab(tester, 'Находки');
  await _expectSoon(tester, _text('Находки'), 'экран «Находки»');
  expect(_path(), '/master/findings');
  await _wait(tester, 1500);
  await _snap(tester, 'master_findings');
  _log('KV_STEP мастер: «Находки» открыты');
  await _tab(tester, 'План ТО');
  await _expectSoon(tester, _text('План ТО'), 'экран «План ТО»');
  expect(_path(), '/master/plan');
  await _wait(tester, 1500);
  await _snap(tester, 'master_plan');
  _log('KV_STEP мастер: «План ТО» открыт');
  _phase('мастер: прокрутка плана ТО');
  await _flingList(tester);
  _phase('выход мастера и вход оператора');
  await _logout(tester);

  await _login(tester, 'operator@kst.demo', '/operator');
  await _expectSoon(tester, find.byType(OpUnitCard), 'агрегаты оператора');
  await _wait(tester, 1500);
  _phase('оператор: агрегаты, 12 с с опросом сервера');
  await _wait(tester, 12000);
  _phase('оператор: прокрутка агрегатов');
  await _flingList(tester);
  _phase('оператор: подсчёт агрегатов');
  await _snap(tester, 'operator_objects');
  final Set<String> codes = <String>{};
  for (int i = 0; i < 8; i++) {
    codes.addAll(tester.widgetList<OpUnitCard>(find.byType(OpUnitCard, skipOffstage: false)).map((OpUnitCard c) => c.unit.code));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -250), warnIfMissed: false);
    await _wait(tester, 300);
  }
  _log('KV_STEP оператор: агрегаты ${codes.toList()..sort()}');
  expect(codes.length, 5, reason: 'агрегаты оператора: $codes');
  await _logout(tester);
  await _snap(tester, 'logged_out');
  _phase('конец');
}
