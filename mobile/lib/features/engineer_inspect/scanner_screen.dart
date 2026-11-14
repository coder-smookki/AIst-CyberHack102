import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/engineer_inspect_routes.dart';
import '../../app/routes/engineer_service_routes.dart';
import '../../core/kv.dart';
import '../../data/providers.dart';
import 'inspect_actions.dart';
import 'inspect_catalog.dart';
import 'inspect_providers.dart';
import 'live/live_scanner_screen.dart';
import 'widgets/inspect_camera.dart';
import 'works_sheet.dart';

/// Вид кадра основного сканера: лёгкое увеличение, насос поднят над панелью (MAIN_VIEW прототипа).
const KvCamView kScannerView = KvCamView(k: 1.2, cx: 0.47, cy: 0.6);

/// Вид рамки распознавания по коду модели.
KvArKind arKindOf(String kind) => switch (kind) {
      'defect' => KvArKind.defect,
      'gauge' => KvArKind.gauge,
      _ => KvArKind.part,
    };

/// Рамка распознавания как прямоугольник в процентах кадра.
({double x, double y, double w, double h}) detRect(Detection d) => (x: d.x, y: d.y, w: d.w, h: d.h);

/// Сканер, агрегат распознан (scanner): живое видео с рамками узлов, признаков дефектов и манометра, панель
/// с агрегатом, покрытием обхода и кнопками «Карточка» и «Завершить».
class ScannerScreen extends ConsumerWidget {
  /// Создаёт сканер агрегата [unitId].
  const ScannerScreen({super.key, this.unitId = kInspectDefaultUnit, this.nameplateFirst = false, this.via, this.aim});

  /// Агрегат, распознанный по шильдику.
  final String unitId;

  /// Агрегат не выбран (центральная кнопка «Сканер»): на настоящем сервере сначала читается шильдик.
  final bool nameplateFirst;

  /// Как выбран агрегат: «nameplate» - по шильдику; null - вручную (из карточки или списка).
  final String? via;

  /// Узел, на который инженер собирается навести камеру (из блока «Сначала проверьте»); null - по маршруту.
  final String? aim;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(serverModeProvider)) {
      if (via == 'nameplate' || via == 'manual' || via == 'qr') {
        return LiveScannerScreen(unitId: unitId, byNameplate: via == 'nameplate', byQr: via == 'qr', aim: aim);
      }
      return LiveScanSearchScreen(expected: nameplateFirst ? null : unitId, aim: aim);
    }
    final KvColors c = context.kv;
    final Equipment? unit = ref.watch(unitProvider(unitId)).value;
    final List<Detection> found = ref.watch(detectionsProvider(unitId)).value ?? const <Detection>[];
    final List<RouteStep> route = ref.watch(routeProvider(unitId)).value ?? const <RouteStep>[];
    final List<Detection> ordered = [...found]..sort((Detection a, Detection b) => _rank(a.kind).compareTo(_rank(b.kind)));
    final int defects = found.where((Detection d) => d.kind == 'defect').length;
    final RouteStep? next = route.next;
    final RouteStep? aimed = route.where((RouteStep r) => r.nodeId == aim && (r.result == null || r.result == 'next')).firstOrNull;
    final List<KvArBoxData> boxes = [
      for (final Detection d in ordered)
        arBoxOf(
          kScannerView,
          detRect(d),
          kind: arKindOf(d.kind),
          label: d.kind == 'gauge' ? gaugeValueOf(d.label) : d.label,
          position: d.kind == 'gauge' ? KvArLabelPosition.aboveRight : (kArLabelPositions[d.label] ?? KvArLabelPosition.above),
          icon: d.kind == 'gauge' ? KvIcons.gauge : null,
          semanticLabel: d.label,
          onTap: _tapOf(context, d),
        ),
    ];
    return ArCameraScreen(
      stage: KvArStage(view: kScannerView, boxes: boxes),
      top: ArTopBar(pill: 'Анализ видео · 24 кадр/с', onBack: () => context.kvBack(EngineerInspectPaths.objects)),
      panel: ArPanel(
        children: [
          ArPanelTitle(
            title: unit == null ? ' ' : '${unit.code} · ${unit.modelShort}',
            caption: unit == null ? ' ' : 'По шильдику · № ${unit.serial}',
            chip: defects == 0 ? null : KvChip('$defects ${KvFormat.plural(defects, 'признак', 'признака', 'признаков')}', status: KvStatus.bad),
            chipLabel: 'Признаки дефектов',
            onChip: () => context.kvPush(EngineerInspectPaths.scanDefectFor(unitId)),
          ),
          NextNodeCard(
            done: route.checked,
            total: route.length,
            title: aimed != null
                ? aimHint(aimed.name)
                : (next == null ? 'Все узлы осмотрены' : 'Далее: ${nodeShortName(next.name)}'),
            subtitle: 'Осмотрено ${route.checked} из ${route.length} узлов',
            onTap: () => context.kvPush(EngineerInspectPaths.routeFor(unitId)),
          ),
          Row(
            children: [
              Expanded(
                child: KvButton('Карточка', kind: KvButtonKind.secondary, onPressed: () => context.kvPush(EngineerInspectPaths.card(unitId))),
              ),
              const SizedBox(width: KvSpace.s3),
              Expanded(child: KvButton('Работы', kind: KvButtonKind.secondary, onPressed: () => showWorksSheet(context, unitId))),
              const SizedBox(width: KvSpace.s3),
              Expanded(child: KvButton('Завершить', onPressed: () => _finish(context, route))),
            ],
          ),
        ],
      ),
      lightHome: c.isDark,
    );
  }

  static int _rank(String kind) => switch (kind) {
        'part' => 0,
        'defect' => 1,
        _ => 2,
      };

  /// Касание рамки: признак для подтверждения - крупный план, признак только камеры - разбор правила, манометр - чтение шкалы.
  VoidCallback? _tapOf(BuildContext context, Detection d) {
    if (d.kind == 'gauge') {
      return () => context.kvPush(EngineerInspectPaths.scanGaugeFor(unitId));
    }
    final DefectClass? cls = kDefectClasses[d.label];
    if (d.kind != 'defect' || cls == null) {
      return null;
    }
    if (cls.closeUp) {
      return () => context.kvPush(EngineerInspectPaths.scanDefectFor(unitId, d.label));
    }
    return () => context.kvPush(EngineerInspectPaths.rule(cls.ruleId, unitId));
  }

  /// Диалог «Завершить осмотр?» (b-scan-finish): продолжить обход или перейти к итогу.
  void _finish(BuildContext context, List<RouteStep> route) {
    final BuildContext screen = context;
    showKvDialog<void>(
      context,
      builder: (BuildContext dialog) => KvDialog(
        icon: KvIcons.clipboard,
        title: 'Завершить осмотр?',
        text: 'Осмотрено ${route.checked} из ${route.length} узлов. Непросмотренные узлы попадут в отчёт с отметкой «не осмотрено».',
        actions: [
          KvButton('Продолжить', kind: KvButtonKind.secondary, onPressed: () => Navigator.of(dialog).pop()),
          KvButton(
            'Завершить',
            onPressed: () {
              Navigator.of(dialog).pop();
              screen.kvPush(EngineerServicePaths.cSummary);
            },
          ),
        ],
      ),
    );
  }
}

/// Подсказка сканера для узла из блока «Сначала проверьте».
String aimHint(String node) => 'Наведите камеру на: $node';

/// Поиск шильдика (b-scan-search): рамка наведения с бегущей линией, подсказки и кнопки QR-кода, условий съёмки и ввода номера.
class ScanSearchScreen extends ConsumerWidget {
  /// Создаёт экран.
  const ScanSearchScreen({super.key});

  static const KvCamView _view = KvCamView(k: 1.9, cx: 0.33, cy: 0.43, ty: 0.43);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(serverModeProvider)) {
      return const LiveScanSearchScreen();
    }
    final KvColors c = context.kv;
    final Size size = MediaQuery.sizeOf(context);
    void found() => context.kvFade(EngineerInspectPaths.scanner);
    return ArCameraScreen(
      lightHome: true,
      stage: Stack(
        children: [
          const Positioned.fill(child: KvArStage(view: _view)),
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.7,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [c.arGlass, c.arGlass.withValues(alpha: 0), c.arGlass.withValues(alpha: 0), c.arGlass],
                      stops: const [0, 0.22, 0.62, 1],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      top: ArTopBar(pill: 'Ищу шильдик агрегата', spinning: true, onBack: () => context.kvBack(EngineerInspectPaths.objects)),
      layers: [
        Positioned(
          left: KvSpace.gutter,
          right: KvSpace.gutter,
          top: size.height * 0.22,
          child: const Center(child: ScanHintPill(icon: KvIcons.target, text: 'Наведите рамку на шильдик')),
        ),
        Positioned(
          left: size.width * 0.12,
          right: size.width * 0.12,
          top: size.height * 0.33,
          height: size.height * 0.2,
          child: KvPressable(onTap: found, highlight: false, semanticLabel: 'Шильдик в рамке', child: const ScanAimFrame()),
        ),
        Positioned(
          left: KvSpace.gutter,
          right: KvSpace.gutter,
          top: size.height * 0.57,
          child: IgnorePointer(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 290),
                child: Opacity(
                  opacity: 0.85,
                  child: Text(
                    'Номер и серийный номер считываются с заводской таблички. QR-код - дополнительный способ.',
                    textAlign: TextAlign.center,
                    style: context.kvText.caption.copyWith(color: c.arText, shadows: [Shadow(color: c.arGlass, offset: const Offset(0, 1), blurRadius: 3)]),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: KvSpace.gutter,
          right: KvSpace.gutter,
          bottom: 46,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ScanCamAction(icon: KvIcons.qr, label: 'QR-код', onTap: found),
              ScanCamAction(icon: KvIcons.sun, label: 'Условия', onTap: () => context.kvFade(EngineerInspectPaths.bScanPoor)),
              ScanCamAction(icon: KvIcons.hash, label: 'Ввести номер', onTap: () => context.kvPush(EngineerInspectPaths.search)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Стеклянная подсказка поверх видео (.b-cam-hint .ar-pill): значок 18 и текст.
class ScanHintPill extends StatelessWidget {
  /// Создаёт подсказку.
  const ScanHintPill({super.key, required this.icon, required this.text});

  /// Значок.
  final KvIcons icon;

  /// Текст.
  final String text;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return KvGlass(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.s4),
        decoration: BoxDecoration(color: c.arGlass, borderRadius: BorderRadius.circular(22)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KvIcon(icon, size: 18, color: c.arText),
            const SizedBox(width: KvSpace.s2),
            Text(text, maxLines: 1, softWrap: false, style: context.kvText.sm.copyWith(fontWeight: FontWeight.w500, color: c.arText, height: 1.2)),
          ],
        ),
      ),
    );
  }
}

/// Кнопка внизу экрана поиска шильдика (.b-cam-act): стеклянный круг 56 и подпись.
class ScanCamAction extends StatelessWidget {
  /// Создаёт кнопку.
  const ScanCamAction({super.key, required this.icon, required this.label, required this.onTap});

  /// Значок.
  final KvIcons icon;

  /// Подпись.
  final String label;

  /// Касание.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 72),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          KvRoundButton(icon: icon, size: 56, variant: KvRoundVariant.glass, semanticLabel: label, onPressed: onTap),
          const SizedBox(height: 6),
          Text(label, style: context.kvText.label.copyWith(color: c.arText, height: KvTextStyles.normalHeight(12))),
        ],
      ),
    );
  }
}

/// Рамка наведения (.ar-corners) с бегущей линией сканирования (.b-scanline, 2,4 с туда и обратно).
class ScanAimFrame extends StatefulWidget {
  /// Создаёт рамку.
  const ScanAimFrame({super.key});

  @override
  State<ScanAimFrame> createState() => _ScanAimFrameState();
}

class _ScanAimFrameState extends State<ScanAimFrame> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.kvReduceMotion) {
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Animation<double> t = CurvedAnimation(parent: _c, curve: Curves.easeInOut);
    return RepaintBoundary(
      child: CustomPaint(
        painter: _CornersPainter(c.arText),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) => AnimatedBuilder(
            animation: t,
            builder: (BuildContext context, Widget? line) => Stack(
              children: [
                Positioned(
                  left: box.maxWidth * 0.06,
                  right: box.maxWidth * 0.06,
                  top: box.maxHeight * (0.12 + 0.76 * t.value),
                  height: 2,
                  child: line!,
                ),
              ],
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: LinearGradient(colors: [c.arPart.withValues(alpha: 0), c.arPart, c.arPart.withValues(alpha: 0)]),
                boxShadow: [kvCssShadow(0, 0, 12, c.arPart)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Уголки рамки наведения: скруглённая белая рамка 3 px, видны только углы 28 × 28.
class _CornersPainter extends CustomPainter {
  _CornersPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double k = 28;
    final RRect frame = RRect.fromRectAndRadius((Offset.zero & size).deflate(1.5), const Radius.circular(16.5));
    final Paint p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (final Offset o in [Offset.zero, Offset(size.width - k, 0), Offset(0, size.height - k), Offset(size.width - k, size.height - k)]) {
      canvas.save();
      canvas.clipRect(o & const Size(k, k));
      canvas.drawRRect(frame, p);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_CornersPainter oldDelegate) => oldDelegate.color != color;
}

/// Плохие условия съёмки (b-scan-poor): затемнённое видео и стеклянная карточка «Мало света» с показателями и фонариком.
class ScanPoorScreen extends StatelessWidget {
  /// Создаёт экран.
  const ScanPoorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final double top = MediaQuery.paddingOf(context).top;
    return ArCameraScreen(
      lightHome: true,
      stage: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 1.5, sigmaY: 1.5),
        child: ColorFiltered(colorFilter: ColorFilter.matrix(_dim(0.32, 0.6)), child: const KvArStage(view: kScannerView)),
      ),
      top: ArTopBar(pill: 'Распознавание на паузе', waiting: true, onBack: () => context.kvBack(EngineerInspectPaths.objects)),
      layers: [
        Positioned(
          left: KvSpace.gutter,
          right: KvSpace.gutter,
          top: top + 78,
          child: KvGlass(
            blur: 14,
            borderRadius: BorderRadius.circular(KvRadius.lg),
            child: Container(
              padding: const EdgeInsets.all(KvSpace.s5),
              decoration: BoxDecoration(color: c.arGlass, borderRadius: BorderRadius.circular(KvRadius.lg)),
              child: DefaultTextStyle(
                style: t.base.copyWith(color: c.arText),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 52,
                        height: 52,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: c.warn, shape: BoxShape.circle),
                        child: KvIcon(KvIcons.sun, size: 28, color: c.arText),
                      ),
                    ),
                    const SizedBox(height: KvSpace.s3),
                    Text('Мало света', style: t.hdr.copyWith(color: c.arText)),
                    const SizedBox(height: KvSpace.s3),
                    Opacity(
                      opacity: 0.85,
                      child: Text('Признаки дефектов могут быть пропущены. Включите фонарик или подойдите ближе.', style: t.sm.copyWith(color: c.arText)),
                    ),
                    const SizedBox(height: KvSpace.s3),
                    const _Quality(status: KvStatus.bad, label: 'Освещённость', value: 'низкая'),
                    const SizedBox(height: KvSpace.s2),
                    const _Quality(status: KvStatus.warn, label: 'Расстояние 2,4 м', value: 'нужно до 1,5 м'),
                    const SizedBox(height: KvSpace.s2),
                    const _Quality(status: KvStatus.ok, label: 'Блики', value: 'не обнаружены'),
                    const SizedBox(height: KvSpace.s3),
                    KvButton('Включить фонарик', icon: KvIcons.flash, wait: true, onPressed: () => context.kvFade(EngineerInspectPaths.scanner)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Матрица яркости [b] и насыщенности [s] (filter: brightness() saturate()).
  static List<double> _dim(double b, double s) {
    const double r = 0.2126;
    const double g = 0.7152;
    const double bl = 0.0722;
    return [
      (r + (1 - r) * s) * b, (g - g * s) * b, (bl - bl * s) * b, 0, 0,
      (r - r * s) * b, (g + (1 - g) * s) * b, (bl - bl * s) * b, 0, 0,
      (r - r * s) * b, (g - g * s) * b, (bl + (1 - bl) * s) * b, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }
}

/// Показатель условий съёмки (.b-q): точка, название и значение.
class _Quality extends StatelessWidget {
  const _Quality({required this.status, required this.label, required this.value});

  final KvStatus status;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 28),
      child: Row(
        children: [
          KvDot(status: status),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: t.sm.copyWith(color: c.arText, height: KvTextStyles.normalHeight(14)))),
          const SizedBox(width: 10),
          Opacity(
            opacity: 0.75,
            child: Text(value, maxLines: 1, softWrap: false, style: t.caption.copyWith(color: c.arText, height: KvTextStyles.normalHeight(13))),
          ),
        ],
      ),
    );
  }
}
