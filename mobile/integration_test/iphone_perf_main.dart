import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kst_vizor/app/router.dart';
import 'package:kst_vizor/app/state/app_state.dart';
import 'package:kst_vizor/core/widgets/kv_button.dart';
import 'package:kst_vizor/main.dart' as app;

/// Замер плавности на телефоне: обычный запуск приложения (настоящие кадры по vsync), вход инженера, прокрутка и
/// переходы без касаний, в конце выход; время сборки и отрисовки кадров по этапам пишется в tmp/kv_perf/frames.log.
final Directory _out = Directory('${Directory.systemTemp.path}/kv_perf');

/// Кадры текущего этапа.
final List<ui.FrameTiming> _frames = <ui.FrameTiming>[];

/// Строка отчёта.
void _log(String line) {
  _out.createSync(recursive: true);
  File('${_out.path}/frames.log').writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append, flush: true);
}

/// Перцентиль [q] миллисекунд.
double _pct(List<double> v, double q) {
  if (v.isEmpty) {
    return 0;
  }
  final List<double> s = List<double>.of(v)..sort();
  return s[((s.length - 1) * q).round()];
}

/// Ждёт [ms] миллисекунд, затем подводит итог по кадрам этапа [name].
Future<void> _measure(String name, Future<void> Function() body) async {
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  _frames.clear();
  await body();
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  final List<double> b = _frames.map((ui.FrameTiming f) => f.buildDuration.inMicroseconds / 1000).toList();
  final List<double> r = _frames.map((ui.FrameTiming f) => f.rasterDuration.inMicroseconds / 1000).toList();
  String f(double x) => x.toStringAsFixed(1);
  _log('KV_FRAMES $name: кадров ${_frames.length}; сборка p50 ${f(_pct(b, .5))} p90 ${f(_pct(b, .9))} max ${f(_pct(b, 1))}; '
      'отрисовка p50 ${f(_pct(r, .5))} p90 ${f(_pct(r, .9))} max ${f(_pct(r, 1))}; '
      '>8.3 мс: сборка ${b.where((double x) => x > 8.3).length}, отрисовка ${r.where((double x) => x > 8.3).length}; '
      '>16.7 мс: сборка ${b.where((double x) => x > 16.7).length}, отрисовка ${r.where((double x) => x > 16.7).length}');
}

/// Все элементы дерева.
List<Element> _elements() {
  final List<Element> all = <Element>[];
  void visit(Element e) {
    all.add(e);
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return all;
}

/// Текущий путь.
String _path() {
  final BuildContext? ctx = kvRootNavigatorKey.currentContext;
  return ctx == null ? '' : GoRouter.of(ctx).routerDelegate.currentConfiguration.uri.path;
}

/// Ждёт условия [ok] не дольше [s] секунд.
Future<bool> _until(bool Function() ok, [int s = 30]) async {
  final DateTime end = DateTime.now().add(Duration(seconds: s));
  while (DateTime.now().isBefore(end)) {
    if (ok()) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return ok();
}

/// Прокрутка самого длинного видимого списка вниз и вверх анимацией, как быстрый жест.
Future<void> _scroll() async {
  ScrollPosition? best;
  for (final Element e in _elements()) {
    if (e is StatefulElement && e.state is ScrollableState) {
      final ScrollPosition p = (e.state as ScrollableState).position;
      if (p.hasContentDimensions && p.axis == Axis.vertical && (best == null || p.maxScrollExtent > best.maxScrollExtent)) {
        best = p;
      }
    }
  }
  if (best == null || best.maxScrollExtent <= 0) {
    return;
  }
  for (int i = 0; i < 2; i++) {
    await best.animateTo(best.maxScrollExtent, duration: const Duration(milliseconds: 900), curve: Curves.easeOut);
    await best.animateTo(0, duration: const Duration(milliseconds: 900), curve: Curves.easeOut);
  }
}

/// Переход на путь [path].
Future<void> _go(String path, {bool push = false}) async {
  final GoRouter r = GoRouter.of(kvRootNavigatorKey.currentContext!);
  if (push) {
    unawaited(r.push(path));
  } else {
    r.go(path);
  }
  await Future<void>.delayed(const Duration(milliseconds: 2500));
}

/// Запуск замера.
Future<void> main() async {
  await app.main();
  SchedulerBinding.instance.addTimingsCallback(_frames.addAll);
  if (_out.existsSync()) {
    _out.deleteSync(recursive: true);
  }
  _log('KV_STEP старт, ${ui.PlatformDispatcher.instance.views.first.display.refreshRate.toStringAsFixed(0)} Гц');
  try {
    await _until(() => _path() == '/login' || _path().startsWith('/engineer') || _path().startsWith('/master') || _path().startsWith('/operator'));
    if (_path().startsWith('/master') || _path().startsWith('/operator')) {
      await ProviderScope.containerOf(kvRootNavigatorKey.currentContext!, listen: false).read(sessionProvider.notifier).logout();
      kvRootNavigatorKey.currentContext!.go('/login');
      await _until(() => _path() == '/login');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (_path() == '/login') {
      final List<EditableText> fields = _elements().map((Element e) => e.widget).whereType<EditableText>().toList();
      fields[0].controller.text = 'engineer@kst.demo';
      fields[1].controller.text = 'demo12345';
      final KvButton login = _elements().map((Element e) => e.widget).whereType<KvButton>().firstWhere((KvButton b) => b.label == 'Войти');
      await _measure('вход инженера', () async {
        login.onPressed!();
        await _until(() => _path().startsWith('/engineer'));
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      });
    }
    _log('KV_STEP путь ${_path()}');
    await _measure('объекты: покой 6 с (опрос сервера)', () => Future<void>.delayed(const Duration(seconds: 6)));
    await _measure('объекты: прокрутка', _scroll);
    await _measure('открытие карточки Н-101', () => _go('/engineer/objects/card/N-101', push: true));
    await _measure('карточка: прокрутка', _scroll);
    await _measure('карточка: покой 6 с', () => Future<void>.delayed(const Duration(seconds: 6)));
    await _measure('вкладка история', () => _go('/engineer/history'));
    await _measure('история: прокрутка', _scroll);
    await _measure('вкладка ассистент', () => _go('/engineer/assistant'));
    await _measure('вкладка профиль', () => _go('/engineer/profile'));
    await _measure('вкладка объекты', () => _go('/engineer/objects'));
    await _measure('живой сканер Н-101: 10 с', () async {
      await _go('/engineer/scanner?unit=N-101', push: true);
      await Future<void>.delayed(const Duration(milliseconds: 7500));
    });
    await _measure('возврат к объектам', () => _go('/engineer/objects'));
    await ProviderScope.containerOf(kvRootNavigatorKey.currentContext!, listen: false).read(sessionProvider.notifier).logout();
    kvRootNavigatorKey.currentContext!.go('/login');
    await _until(() => _path() == '/login');
    _log('KV_STEP выход, путь ${_path()}');
    _log('KV_DONE');
  } catch (e, s) {
    _log('KV_FAIL $e $s');
  }
}
