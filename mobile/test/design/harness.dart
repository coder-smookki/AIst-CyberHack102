import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kst_vizor/app/app.dart';
import 'package:kst_vizor/app/router.dart';
import 'package:kst_vizor/app/state/app_state.dart';
import 'package:kst_vizor/core/widgets/kv_overlays.dart';
import 'package:kst_vizor/data/mock/mock_backend.dart';
import 'package:kst_vizor/data/mock/repos/mock_auth_repository.dart';
import 'package:kst_vizor/data/providers.dart';
import 'package:path_parsing/path_parsing.dart';

import 'design_case.dart';

/// Размеры телефонов прототипа: ширина - высота в логических пикселях.
const Map<int, double> kPhoneHeights = {360: 780, 390: 844, 430: 932};

/// Размеры планшетов для проверки раскладки: ширина - высота в логических пикселях (1180 × 820 - альбомная).
const Map<int, double> kTabletHeights = {768: 1024, 820: 1180, 1024: 1366, 1180: 820};

/// Отступ строки состояния и индикатора «домой» в рамке iPhone прототипа.
const double kStatusInset = 54;

/// Нижний отступ рамки iPhone прототипа.
const double kHomeInset = 34;

/// Плотность пикселей снимков: 390 × 844 снимается в 780 × 1688, как снимки прототипа.
const double kShotDpr = 2;

bool _fontsLoaded = false;

/// Загружает Geologica из ресурсов, чтобы снимки рисовались фирменным шрифтом, а не тестовыми квадратами.
Future<void> loadKvFonts() async {
  if (_fontsLoaded) {
    return;
  }
  final FontLoader loader = FontLoader('Geologica');
  for (final String w in ['Light', 'Regular', 'Medium', 'SemiBold']) {
    final List<int> bytes = File('assets/fonts/Geologica-$w.ttf').readAsBytesSync();
    loader.addFont(Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(bytes))));
  }
  await loader.load();
  _fontsLoaded = true;
}

/// Итог снимка: путь к файлу и ошибки отрисовки.
class ShotResult {
  /// Создаёт итог.
  const ShotResult(this.path);

  /// Путь к снимку.
  final String path;
}

/// Снимает экран [c] в теме [theme] шириной [width]: открывает маршрут на демонстрационных данных
/// с остановленными часами, выполняет шаги, рисует строку состояния и индикатор «домой» как в прототипе
/// и записывает PNG в `build/design_shots/<тема>-<ширина>/<id>.png`.
///
/// Переполнение строк и колонок, исключения и отсутствие цели касания проваливают тест.
Future<ShotResult> shootCase(WidgetTester tester, DesignCase c, {required int width, required String theme}) async {
  debugDisableShadows = false;
  try {
    return await _shoot(tester, c, width: width, theme: theme);
  } finally {
    debugDisableShadows = true;
  }
}

Future<ShotResult> _shoot(WidgetTester tester, DesignCase c, {required int width, required String theme}) async {
  await loadKvFonts();
  final double height = kPhoneHeights[width] ?? kTabletHeights[width]!;
  tester.view.devicePixelRatio = kShotDpr;
  tester.view.physicalSize = Size(width * kShotDpr, height * kShotDpr);
  tester.view.padding = const FakeViewPadding(top: kStatusInset * kShotDpr, bottom: kHomeInset * kShotDpr);
  tester.view.viewPadding = const FakeViewPadding(top: kStatusInset * kShotDpr, bottom: kHomeInset * kShotDpr);
  addTearDown(tester.view.reset);
  addTearDown(hideKvTransients);

  final FixedClock clock = FixedClock(StoryClock.storyNow);
  final MockBackend backend = MockBackend(clock: clock, latency: MockLatency.none);
  c.setup?.call(backend);
  final ProviderContainer container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      mockBackendProvider.overrideWithValue(backend),
      settingsStoreProvider.overrideWithValue(MemorySettingsStore({'theme_mode': theme, 'onboarding_seen': true})),
    ],
    retry: (int count, Object error) => null,
  );
  addTearDown(container.dispose);
  final String? email = c.accountEmail;
  if (email != null) {
    container.read(sessionProvider.notifier).restore(MockAuthRepository(backend).demoSession(email));
  }
  final GoRouter router = container.read(routerProvider);
  router.go(c.route);

  final GlobalKey shotKey = GlobalKey();
  final ValueNotifier<(bool, bool)> chrome = ValueNotifier<(bool, bool)>((false, false));
  addTearDown(chrome.dispose);
  await tester.pumpWidget(
    RepaintBoundary(
      key: shotKey,
      child: UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              const Positioned.fill(child: KvApp()),
              Positioned.fill(child: IgnorePointer(child: _PhoneChrome(chrome: chrome, time: c.time, dark: theme == 'dark'))),
            ],
          ),
        ),
      ),
    ),
  );
  await pumpFor(tester, const Duration(milliseconds: 1600));
  await _precacheImages(tester);
  await pumpFor(tester, const Duration(milliseconds: 200));
  for (final DesignStep step in c.steps) {
    await step.run(tester, container);
  }
  await pumpFor(tester, const Duration(milliseconds: 1400));
  await _precacheImages(tester);
  await tester.pump(const Duration(milliseconds: 50));

  chrome.value = _systemChrome(tester, width, height);
  await tester.pump();

  final String dir = 'build/design_shots/$theme-$width';
  final String path = '$dir/${c.id}.png';
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    final ui.Image image = await boundary.toImage(pixelRatio: kShotDpr);
    final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(dir).createSync(recursive: true);
    File(path).writeAsBytesSync(png!.buffer.asUint8List());
  });
  return ShotResult(path);
}

/// Догружает все картинки экрана по-настоящему, чтобы фото и логотипы попали в снимок.
Future<void> _precacheImages(WidgetTester tester) async {
  final Set<ImageProvider> providers = {};
  for (final Element e in find.byType(Image).evaluate()) {
    providers.add((e.widget as Image).image);
  }
  for (final Element e in find.byType(DecoratedBox).evaluate()) {
    final Decoration d = (e.widget as DecoratedBox).decoration;
    if (d is BoxDecoration && d.image != null) {
      providers.add(d.image!.image);
    }
  }
  if (providers.isEmpty) {
    return;
  }
  final Element context = find.byType(KvApp).evaluate().first;
  await tester.runAsync(() async {
    for (final ImageProvider p in providers) {
      await precacheImage(p, context);
    }
  });
}

/// Цвет значков строки состояния и индикатора «домой» по аннотации экрана (AnnotatedRegion KvScreen).
(bool, bool) _systemChrome(WidgetTester tester, int width, double height) {
  final RenderView view = tester.binding.renderViews.first;
  final ContainerLayer? layer = view.debugLayer;
  if (layer == null) {
    return (false, false);
  }
  final SystemUiOverlayStyle? top = layer.find<SystemUiOverlayStyle>(Offset(width * kShotDpr / 2, kStatusInset * kShotDpr / 2));
  final SystemUiOverlayStyle? bottom = layer.find<SystemUiOverlayStyle>(Offset(width * kShotDpr / 2, height * kShotDpr - 1 - kHomeInset * kShotDpr / 2));
  final bool lightTop = top?.statusBarIconBrightness == Brightness.light;
  final bool lightHome = (bottom ?? top)?.systemNavigationBarIconBrightness == Brightness.light;
  return (lightTop, lightHome);
}

/// Строка состояния 9:41 и индикатор «домой» рамки iPhone прототипа (KV.statusbar, .home-ind).
class _PhoneChrome extends StatelessWidget {
  const _PhoneChrome({required this.chrome, required this.time, required this.dark});

  final ValueNotifier<(bool, bool)> chrome;
  final String time;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<(bool, bool)>(
      valueListenable: chrome,
      builder: (BuildContext context, (bool, bool) v, Widget? _) {
        final Color top = v.$1 ? const Color(0xFFFFFFFF) : (dark ? const Color(0xFFF2F5F9) : const Color(0xFF313132));
        final Color home = v.$2 ? const Color(0xFFFFFFFF) : (dark ? const Color(0xFFF2F5F9) : const Color(0xFF313132));
        return Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: kStatusInset,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(34, 6, 26, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      time,
                      style: TextStyle(fontFamily: 'Geologica', fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: -0.16, color: top),
                    ),
                    CustomPaint(size: const Size(18 + 6 + 16 + 6 + 27, 13), painter: _StatusIcons(top)),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Center(
                child: Container(
                  width: 134,
                  height: 5,
                  decoration: BoxDecoration(color: home.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(3)),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StatusIcons extends CustomPainter {
  _StatusIcons(this.color);

  final Color color;

  static Path _svg(String d) {
    final _Writer w = _Writer();
    writeSvgPathDataToPath(d, w);
    return w.path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Paint fill = Paint()..color = color;
    canvas.save();
    canvas.translate(0, 0.5);
    for (final (double x, double y, double h) in [(0.0, 8.0, 4.0), (5.0, 5.5, 6.5), (10.0, 3.0, 9.0), (15.0, 0.0, 12.0)]) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, 3, h), const Radius.circular(1)), fill);
    }
    canvas.translate(24, 0);
    canvas.drawPath(
      _svg('M8 2.3c2.3 0 4.4.9 6 2.4l1.2-1.3A10.3 10.3 0 0 0 8 .5 10.3 10.3 0 0 0 .8 3.4L2 4.7a8.6 8.6 0 0 1 6-2.4zm0 3.4c1.4 0 2.6.5 3.6 1.4l1.2-1.3A7 7 0 0 0 8 3.9a7 7 0 0 0-4.8 1.9l1.2 1.3c1-.9 2.2-1.4 3.6-1.4zm0 3.4c-.6 0-1.1.2-1.5.6L8 11.3l1.5-1.6c-.4-.4-.9-.6-1.5-.6z'),
      fill,
    );
    canvas.translate(22, -0.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(0.5, 0.5, 23, 12), const Radius.circular(3.8)),
      Paint()
        ..color = color.withValues(alpha: 0.38 * color.a)
        ..style = PaintingStyle.stroke,
    );
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(2, 2, 20, 9), const Radius.circular(2.5)), fill);
    canvas.drawPath(_svg('M25 4.5v4c.8-.3 1.4-1.1 1.4-2s-.6-1.7-1.4-2z'), Paint()..color = color.withValues(alpha: 0.45 * color.a));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StatusIcons oldDelegate) => oldDelegate.color != color;
}

class _Writer extends PathProxy {
  final Path path = Path();

  @override
  void close() => path.close();

  @override
  void cubicTo(double x1, double y1, double x2, double y2, double x3, double y3) => path.cubicTo(x1, y1, x2, y2, x3, y3);

  @override
  void lineTo(double x, double y) => path.lineTo(x, y);

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);
}
