import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kst_vizor/app/router.dart';
import 'package:kst_vizor/app/state/app_state.dart';
import 'package:kst_vizor/core/kv.dart';
import 'package:kst_vizor/data/api/api_config.dart';
import 'package:kst_vizor/main.dart' as app;

/// Обход всех экранов всех ролей на телефоне в выпускной сборке: каждый маршрут роли открывается, ошибки и
/// экраны ошибки фиксируются, безопасные кнопки нажимаются по очереди, время кадров меряется по этапам.
/// Режим задаётся при сборке: --dart-define=KV_WALK=demo (встроенные данные) или server (только чтение).
const String _mode = String.fromEnvironment('KV_WALK', defaultValue: 'demo');

/// Сколько кнопок нажимать на экране (0 - только открыть экраны, для проверки раскладки на планшетах).
const int _maxButtons = int.fromEnvironment('KV_BUTTONS', defaultValue: 8);

/// Альбомная ориентация на планшете: --dart-define=KV_LAND=true или переменная окружения KV_LAND=1 (симулятор).
final bool _landscape = const bool.fromEnvironment('KV_LAND') || Platform.environment['KV_LAND'] == '1';

/// Папка отчёта в контейнере приложения.
final Directory _out = Directory('${Directory.systemTemp.path}/kv_walk');

/// Кадры текущего этапа.
final List<ui.FrameTiming> _frames = <ui.FrameTiming>[];

/// Ошибки Flutter текущего этапа.
final List<String> _errors = <String>[];

/// Номер снимка.
int _shot = 0;

/// Учётные записи ролей: демонстрационные и на сервере.
const Map<String, (String, String)> _accounts = <String, (String, String)>{
  'engineer': ('a.smirnov@kst-energo.ru', 'engineer@kst.demo'),
  'master': ('m.orlova@kst-energo.ru', 'master@kst.demo'),
  'operator': ('o.kuznetsova@kst-energo.ru', 'operator@kst.demo'),
  'admin': ('i.vlasov@kst-energo.ru', 'admin@kst.demo'),
  'sec': ('d.zakharov@kst-energo.ru', 'security@kst.demo'),
};

/// Подписи кнопок, которые обход не нажимает: выход, смена сервера, звонки, внешние приложения, удаление.
final RegExp _unsafe = RegExp(
  r'выйти|выход|сервер|демонстрац|подключ|позвонить|связаться|поделиться|скачать|удалить|заблокир|сбросить|'
  r'записать шум|микрофон|обновить систему|запустить обновление|резервн|восстанов|знакомство|завершить сеанс|'
  r'отозвать|сменить пароль|временный пароль',
  caseSensitive: false,
);

/// На настоящем сервере дополнительно не нажимаются кнопки, которые что-то записывают.
final RegExp _writes = RegExp(
  r'подтверд|это дефект|не дефект|сохран|отправ|назнач|создать|добав|записать|завершить|обслужил|заменил|'
  r'заметк|начать|принять|отклон|сообщить|в работу|закрыть находку|повторить осмотр|включить|выключить|применить',
  caseSensitive: false,
);

/// Строка отчёта.
void _log(String line) {
  _out.createSync(recursive: true);
  File('${_out.path}/walk.log').writeAsStringSync('${DateTime.now().toIso8601String().substring(11, 19)} $line\n', mode: FileMode.append, flush: true);
}

/// Маршрутизатор приложения.
GoRouter _router() => GoRouter.of(kvRootNavigatorKey.currentContext!);

/// Контейнер провайдеров приложения.
ProviderContainer _container() => ProviderScope.containerOf(kvRootNavigatorKey.currentContext!, listen: false);

/// Текущий путь.
String _path() {
  final BuildContext? c = kvRootNavigatorKey.currentContext;
  return c == null ? '' : GoRouter.of(c).routerDelegate.currentConfiguration.uri.toString();
}

/// Пауза [ms] миллисекунд.
Future<void> _pause(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// Ждёт условия [ok] не дольше [s] секунд.
Future<bool> _until(bool Function() ok, [int s = 20]) async {
  final DateTime end = DateTime.now().add(Duration(seconds: s));
  while (DateTime.now().isBefore(end)) {
    if (ok()) {
      return true;
    }
    await _pause(150);
  }
  return ok();
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

/// Отпечаток экрана: путь, число маршрутов навигатора и все тексты.
String _signature() {
  final StringBuffer b = StringBuffer(_path());
  for (final Element e in _elements()) {
    final Widget w = e.widget;
    if (w is Text) {
      b.write('|${w.data ?? w.textSpan?.toPlainText() ?? ''}');
    } else if (w is RichText) {
      b.write('|${w.text.toPlainText()}');
    } else if (w is Navigator) {
      b.write('|nav');
    }
  }
  return b.toString();
}

/// Экран ошибки Flutter в дереве.
bool _hasErrorWidget() => _elements().any((Element e) => e.widget is ErrorWidget);

/// Снимок экрана в PNG в папку отчёта.
Future<void> _snap(String name) async {
  try {
    final RenderView view = WidgetsBinding.instance.renderViews.first;
    final OffsetLayer layer = (view as dynamic).layer as OffsetLayer;
    final double dpr = view.flutterView.devicePixelRatio;
    final ui.Image image = await layer.toImage(Offset.zero & (view.size * dpr), pixelRatio: 1.5 / dpr);
    final dynamic data = await image.toByteData(format: ui.ImageByteFormat.png);
    _shot++;
    final String safe = name.replaceAll(RegExp(r'[^A-Za-z0-9а-яА-Я_-]+'), '_');
    File('${_out.path}/${_shot.toString().padLeft(3, '0')}_$safe.png').writeAsBytesSync(data.buffer.asUint8List() as List<int>, flush: true);
  } catch (e) {
    _log('SHOT_FAIL $name $e');
  }
}

/// Сводка кадров этапа: число, максимум сборки и отрисовки, кадры дольше 8,3 и 16,7 мс.
String _frameStats() {
  if (_frames.isEmpty) {
    return 'кадров 0';
  }
  final List<double> b = _frames.map((ui.FrameTiming f) => f.buildDuration.inMicroseconds / 1000).toList()..sort();
  final List<double> r = _frames.map((ui.FrameTiming f) => f.rasterDuration.inMicroseconds / 1000).toList()..sort();
  String f(double x) => x.toStringAsFixed(1);
  int over(List<double> v, double t) => v.where((double x) => x > t).length;
  return 'кадров ${_frames.length}, сборка p90 ${f(b[(b.length * .9).floor().clamp(0, b.length - 1)])} max ${f(b.last)}, '
      'отрисовка p90 ${f(r[(r.length * .9).floor().clamp(0, r.length - 1)])} max ${f(r.last)}, '
      '>8.3: ${over(b, 8.3)}/${over(r, 8.3)}, >16.7: ${over(b, 16.7)}/${over(r, 16.7)}';
}

/// Закрывает листы, диалоги и всплывающие сообщения над экраном.
Future<void> _closeOverlays() async {
  hideKvTransients();
  for (int i = 0; i < 4; i++) {
    final NavigatorState? nav = kvRootNavigatorKey.currentState;
    final Route<dynamic>? top = nav == null ? null : _topRoute(nav);
    if (top is PopupRoute) {
      nav!.pop();
      await _pause(350);
    } else {
      break;
    }
  }
}

/// Верхний маршрут навигатора.
Route<dynamic>? _topRoute(NavigatorState nav) {
  Route<dynamic>? top;
  nav.popUntil((Route<dynamic> r) {
    top = r;
    return true;
  });
  return top;
}

/// Подписи и действия кнопок на экране: кнопки, строки списков и нажимаемые карточки, кроме панели вкладок.
List<(String, VoidCallback)> _buttons() {
  final List<(String, VoidCallback)> out = <(String, VoidCallback)>[];
  final Set<String> seen = <String>{};
  for (final Element e in _elements()) {
    final Widget w = e.widget;
    String? label;
    VoidCallback? action;
    if (w is KvButton) {
      label = w.label;
      action = w.onPressed;
    } else if (w is KvRow) {
      label = w.title;
      action = w.onTap;
    } else if (w is KvPressable && w.semanticLabel != null) {
      if (e.findAncestorWidgetOfExactType<KvTabBar>() != null) {
        continue;
      }
      label = w.semanticLabel;
      action = w.onTap;
    }
    if (label == null || action == null || label.trim().isEmpty || !seen.add(label)) {
      continue;
    }
    if (_unsafe.hasMatch(label) || (_mode == 'server' && _writes.hasMatch(label))) {
      continue;
    }
    out.add((label, action));
  }
  return out;
}

/// Итоги обхода для таблицы.
final List<String> _table = <String>[];

/// Открывает экран [path] роли [role], проверяет ошибки, нажимает до [maxButtons] кнопок.
Future<void> _visit(String role, String path, {int maxButtons = _maxButtons}) async {
  await _closeOverlays();
  _errors.clear();
  _frames.clear();
  _router().go(path);
  await _pause(1400);
  final String opened = _path();
  final String firstFrames = _frameStats();
  final bool errWidget = _hasErrorWidget();
  await _snap('$role$path');
  final List<String> openErrors = List<String>.of(_errors);
  int pressed = 0;
  int responded = 0;
  final List<String> silent = <String>[];
  final List<String> pressErrors = <String>[];
  final List<String> reached = <String>[];
  final List<(String, VoidCallback)> buttons = _buttons();
  for (final (String label, VoidCallback _) in buttons.take(maxButtons)) {
    final (String, VoidCallback)? fresh = _buttons().where(((String, VoidCallback) b) => b.$1 == label).firstOrNull;
    if (fresh == null) {
      continue;
    }
    final String before = _signature();
    _errors.clear();
    try {
      fresh.$2();
    } catch (e) {
      pressErrors.add('$label: $e');
    }
    pressed++;
    await _pause(900);
    final String after = _signature();
    if (after != before) {
      responded++;
      final String now = _path();
      if (now != opened && !reached.contains(now)) {
        reached.add(now);
        if (_hasErrorWidget()) {
          pressErrors.add('$label -> $now: экран ошибки');
        }
      }
    } else {
      silent.add(label);
    }
    pressErrors.addAll(_errors.map((String x) => '$label: $x'));
    await _closeOverlays();
    if (_path() != opened) {
      _router().go(opened);
      await _pause(700);
    }
  }
  final bool ok = !errWidget && openErrors.isEmpty && pressErrors.isEmpty && opened.split('?').first == path.split('?').first;
  final String row = '${ok ? 'OK ' : 'ERR'} | $role | $path | открыт: $opened | кнопок ${buttons.length}, нажато $pressed, '
      'отклик $responded${silent.isEmpty ? '' : ' (без видимого отклика: ${silent.join(', ')})'}'
      '${reached.isEmpty ? '' : ' | переходы: ${reached.join(', ')}'}'
      '${errWidget ? ' | ЭКРАН ОШИБКИ' : ''}${openErrors.isEmpty ? '' : ' | ошибки при открытии: ${openErrors.join(' / ')}'}'
      '${pressErrors.isEmpty ? '' : ' | ошибки кнопок: ${pressErrors.join(' / ')}'} | первые кадры: $firstFrames';
  _table.add(row);
  _log('ROW $row');
}

/// Пути маршрутов приложения без параметров (кроме агрегата и правила, которые подставляются).
List<String> _routes() {
  final List<String> out = <String>[];
  void walk(List<RouteBase> routes, String parent) {
    for (final RouteBase r in routes) {
      String base = parent;
      if (r is GoRoute) {
        base = r.path.startsWith('/') ? r.path : '${parent == '/' ? '' : parent}/${r.path}';
        out.add(base);
      }
      walk(r.routes, base);
    }
  }

  walk(_router().configuration.routes, '');
  return out
      .map((String p) => p.replaceAll(':unitId', 'N-101').replaceAll(':ruleId', 'R04'))
      .where((String p) => !p.contains(':'))
      .toSet()
      .toList();
}

/// Вход учётной записью [email] через экран входа.
Future<void> _login(String email, String role) async {
  final ProviderContainer c = _container();
  if (c.read(sessionProvider) != null) {
    await c.read(sessionProvider.notifier).logout();
  }
  _router().go('/login');
  await _until(() => _path() == '/login');
  await _pause(800);
  final List<EditableText> fields = _elements().map((Element e) => e.widget).whereType<EditableText>().toList();
  fields[0].controller.text = email;
  fields[1].controller.text = 'demo12345';
  final KvButton login = _elements().map((Element e) => e.widget).whereType<KvButton>().firstWhere((KvButton b) => b.label == 'Войти');
  login.onPressed!();
  final bool ok = await _until(() {
    final Iterable<KvButton> later = _elements().map((Element e) => e.widget).whereType<KvButton>().where((KvButton b) => b.label == 'Не сейчас');
    if (later.isNotEmpty) {
      later.first.onPressed?.call();
    }
    return _path().startsWith('/$role') || (role == 'sec' && _path().startsWith('/sec'));
  }, 30);
  _log('LOGIN $email -> ${_path()} ${ok ? '' : 'НЕ ВОШЁЛ'}');
}

/// Запуск обхода.
Future<void> main() async {
  final void Function(FlutterErrorDetails)? original = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails d) {
    _errors.add(d.exceptionAsString().split('\n').first);
    original?.call(d);
  };
  await app.main();
  if (_landscape) {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }
  SchedulerBinding.instance.addTimingsCallback(_frames.addAll);
  if (_out.existsSync()) {
    _out.deleteSync(recursive: true);
  }
  await _until(() => kvRootNavigatorKey.currentContext != null && _path().isNotEmpty);
  final ProviderContainer c = _container();
  await c.read(apiConfigProvider.notifier).setDemo(_mode == 'demo');
  await c.read(deviceSettingsProvider.notifier).completeOnboarding();
  final Size size = WidgetsBinding.instance.renderViews.first.size;
  _log('START режим $_mode, экран ${size.width.round()}x${size.height.round()}');
  try {
    final List<String> all = _routes();
    _log('ROUTES ${all.length}');
    await _visit('none', '/guide');
    for (final MapEntry<String, (String, String)> a in _accounts.entries) {
      final String role = a.key;
      await _login(_mode == 'demo' ? a.value.$1 : a.value.$2, role);
      final List<String> mine = all.where((String p) => p.startsWith('/$role/') || p == '/$role').toList();
      if (role == 'engineer') {
        mine.add('/guide');
      }
      for (final String p in mine) {
        await _visit(role, p);
      }
    }
    final ProviderContainer c2 = _container();
    await c2.read(sessionProvider.notifier).logout();
    _router().go('/login');
    await _pause(1000);
    final int bad = _table.where((String r) => r.startsWith('ERR')).length;
    _log('DONE экранов ${_table.length}, с ошибками $bad');
  } catch (e, s) {
    _log('FAIL $e $s');
  } finally {
    await _container().read(apiConfigProvider.notifier).setDemo(false);
  }
}
