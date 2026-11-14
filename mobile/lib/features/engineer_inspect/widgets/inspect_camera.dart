import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/kv.dart';

/// Экран живого видео (.b-cam): кадр на весь экран под строкой состояния, верхняя панель камеры, панель снизу
/// и слои поверх видео. Значки строки состояния светлые; индикатор «домой» светлый, если нет белой панели.
class ArCameraScreen extends StatelessWidget {
  /// Создаёт экран камеры.
  const ArCameraScreen({super.key, required this.stage, required this.top, this.panel, this.layers = const <Widget>[], this.lightHome});

  /// Видео с рамками: обычно [KvArStage] в [RepaintBoundary].
  final Widget stage;

  /// Верхняя панель камеры: [ArTopBar].
  final Widget top;

  /// Белая панель снизу: [ArPanel].
  final Widget? panel;

  /// Подсказки и кнопки поверх видео.
  final List<Widget> layers;

  /// Светлый индикатор «домой»; по умолчанию - когда нет белой панели или в тёмной теме.
  final bool? lightHome;

  @override
  Widget build(BuildContext context) {
    final double topInset = MediaQuery.paddingOf(context).top;
    return KvScreen(
      immersive: true,
      lightStatusBar: true,
      lightHome: lightHome ?? (panel == null || context.kv.isDark),
      stagger: KvStagger.none,
      body: Stack(
        children: [
          Positioned.fill(child: RepaintBoundary(child: stage)),
          ...layers,
          Positioned(left: KvSpace.gutter, right: KvSpace.gutter, top: topInset, child: top),
          if (panel != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: KvLayout.maxContent), child: panel)),
            ),
        ],
      ),
    );
  }
}

/// Верхняя панель камеры (.b-ar-top): «закрыть» или «назад», стеклянная плашка состояния и фонарик.
class ArTopBar extends StatefulWidget {
  /// Создаёт панель.
  const ArTopBar({
    super.key,
    required this.pill,
    required this.onBack,
    this.backIcon = KvIcons.close,
    this.spinning = false,
    this.waiting = false,
    this.flashOn = false,
    this.onFlash,
  });

  /// Текст плашки: «Анализ видео · 24 кадр/с».
  final String pill;

  /// Закрыть камеру или вернуться.
  final VoidCallback onBack;

  /// Значок левой кнопки: закрыть или назад.
  final KvIcons backIcon;

  /// Спиннер вместо точки «в эфире».
  final bool spinning;

  /// Жёлтая точка ожидания.
  final bool waiting;

  /// Фонарик включён при открытии.
  final bool flashOn;

  /// Фонарик переключён: включить или выключить подсветку камеры.
  final ValueChanged<bool>? onFlash;

  @override
  State<ArTopBar> createState() => _ArTopBarState();
}

class _ArTopBarState extends State<ArTopBar> {
  late bool _flash = widget.flashOn;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        KvRoundButton(
          icon: widget.backIcon,
          iconSize: 22,
          variant: KvRoundVariant.glass,
          semanticLabel: widget.backIcon == KvIcons.close ? 'Закрыть' : 'Назад',
          onPressed: widget.onBack,
        ),
        const SizedBox(width: KvSpace.s2),
        Expanded(child: Center(child: KvArPill(text: widget.pill, spinning: widget.spinning, waiting: widget.waiting))),
        const SizedBox(width: KvSpace.s2),
        KvRoundButton(
          icon: KvIcons.flash,
          iconSize: 22,
          variant: KvRoundVariant.glass,
          active: _flash,
          semanticLabel: 'Фонарик',
          onPressed: () {
            setState(() => _flash = !_flash);
            widget.onFlash?.call(_flash);
          },
        ),
      ],
    );
  }
}

/// Белая панель поверх видео (.b-panel): ручка и блоки с промежутком 12, поля 20 и место под индикатор «домой».
class ArPanel extends StatelessWidget {
  /// Создаёт панель с блоками [children].
  const ArPanel({super.key, required this.children});

  /// Блоки панели.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final double bottom = math.max(KvLayout.homeIndicator, MediaQuery.viewPaddingOf(context).bottom);
    return Container(
      padding: EdgeInsets.fromLTRB(KvSpace.s5, 10, KvSpace.s5, bottom),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(KvRadius.sheet)),
        boxShadow: c.shadowSheet,
      ),
      child: DefaultTextStyle(
        style: context.kvText.base,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(width: 38, height: 5, decoration: BoxDecoration(color: c.surface3, borderRadius: BorderRadius.circular(3))),
            ),
            for (final Widget w in children) ...[const SizedBox(height: KvSpace.s3), w],
          ],
        ),
      ),
    );
  }
}

/// Заголовок панели камеры (.b-ptitle): агрегат и чип признаков, ниже - как распознан.
class ArPanelTitle extends StatelessWidget {
  /// Создаёт заголовок.
  const ArPanelTitle({super.key, required this.title, required this.caption, this.chip, this.onChip, this.chipLabel});

  /// «Н-101 · Wilo IL 65/160».
  final String title;

  /// «По шильдику · № 2786107-0142».
  final String caption;

  /// Чип справа.
  final Widget? chip;

  /// Касание чипа.
  final VoidCallback? onChip;

  /// Подпись чипа для диктора.
  final String? chipLabel;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    Widget? end = chip;
    if (end != null && onChip != null) {
      end = Transform.translate(
        offset: const Offset(4, 0),
        child: KvPressable(
          onTap: onChip,
          highlight: false,
          semanticLabel: chipLabel,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: end),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: t.h2)),
            if (end != null) ...[const SizedBox(width: KvSpace.s2), end],
          ],
        ),
        Text(KvFormat.typo(caption), style: t.caption),
      ],
    );
  }
}

/// Строка основания (.b-ev-line): значок 16 и текст 13.
@immutable
class EvidenceLine {
  /// Создаёт строку.
  const EvidenceLine(this.icon, this.text);

  /// Значок источника.
  final KvIcons icon;

  /// Текст.
  final String text;
}

/// Серый блок оснований (.b-ev): необязательная подпись «Основания» и строки со значками.
class EvidenceBox extends StatelessWidget {
  /// Создаёт блок.
  const EvidenceBox({super.key, required this.lines, this.label});

  /// Строки.
  final List<EvidenceLine> lines;

  /// Подпись над строками.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final TextStyle line = t.caption.copyWith(color: c.text, height: 1.38);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(KvRadius.sm)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (label != null) Text(label!, style: t.label),
          for (int i = 0; i < lines.length; i++) ...[
            if (i > 0 || label != null) const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 1), child: KvIcon(lines[i].icon, size: 16, color: c.text3)),
                const SizedBox(width: KvSpace.s2),
                Expanded(child: Text(KvFormat.typo(lines[i].text), style: line)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Плашка «Далее» на панели сканера (.b-next): кольцо покрытия, следующий узел и шеврон.
class NextNodeCard extends StatelessWidget {
  /// Создаёт плашку.
  const NextNodeCard({super.key, required this.done, required this.total, required this.title, required this.subtitle, required this.onTap});

  /// Осмотрено узлов.
  final int done;

  /// Всего узлов.
  final int total;

  /// «Далее: манометр».
  final String title;

  /// «Осмотрено 5 из 9 узлов».
  final String subtitle;

  /// Открыть маршрут.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final BorderRadius radius = BorderRadius.circular(KvRadius.card);
    return KvPressable(
      onTap: onTap,
      borderRadius: radius,
      pressedScale: 0.985,
      semanticLabel: title,
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: c.tint2, borderRadius: radius),
        child: Row(
          children: [
            KvRingGauge(done: done, total: total),
            const SizedBox(width: KvSpace.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: t.sm.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: t.caption),
                ],
              ),
            ),
            const SizedBox(width: KvSpace.s3),
            KvIcon(KvIcons.chevronRight, size: 20, color: c.text3),
          ],
        ),
      ),
    );
  }
}

/// Врезка кадра с видео (.b-frame): увеличенный участок кадра с рамкой, метка времени и кнопка «переснять».
class CamFrame extends StatelessWidget {
  /// Создаёт врезку.
  const CamFrame({super.key, required this.view, required this.aspectRatio, this.boxes = const <KvArBoxData>[], this.tag, this.onRetake});

  /// Участок кадра.
  final KvCamView view;

  /// Отношение ширины к высоте врезки.
  final double aspectRatio;

  /// Рамки в процентах врезки.
  final List<KvArBoxData> boxes;

  /// Метка: «Кадр с видео · 09:31».
  final String? tag;

  /// «Переснять»: стеклянная кнопка в правом нижнем углу.
  final VoidCallback? onRetake;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(KvRadius.card),
        child: Stack(
          children: [
            Positioned.fill(child: RepaintBoundary(child: KvArStage(view: view, boxes: boxes, boxRadius: 10, glow: false))),
            if (tag != null)
              Positioned(
                left: 10,
                top: 10,
                child: KvGlass(
                  blur: 8,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    height: 28,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(color: c.arGlass, borderRadius: BorderRadius.circular(14)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        KvIcon(KvIcons.camera, size: 14, color: c.arText),
                        const SizedBox(width: 6),
                        Text(tag!, maxLines: 1, softWrap: false, style: context.kvText.label.copyWith(color: c.arText, height: 1.2)),
                      ],
                    ),
                  ),
                ),
              ),
            if (onRetake != null)
              Positioned(
                right: 8,
                bottom: 8,
                child: KvRoundButton(icon: KvIcons.refresh, iconSize: 20, variant: KvRoundVariant.glass, semanticLabel: 'Переснять', onPressed: onRetake),
              ),
          ],
        ),
      ),
    );
  }
}

/// Разметка рамок кадра камеры: перевод рамки распознавания в проценты области вида [view].
KvArBoxData arBoxOf(
  KvCamView view,
  ({double x, double y, double w, double h}) d, {
  KvArKind kind = KvArKind.part,
  VoidCallback? onTap,
  String? label,
  KvArLabelPosition position = KvArLabelPosition.above,
  KvIcons? icon,
  String? semanticLabel,
}) =>
    KvArBoxData(
      view.map(Rect.fromLTWH(d.x, d.y, d.w, d.h)),
      kind: kind,
      onTap: onTap,
      label: label,
      labelPosition: position,
      labelIcon: icon,
      semanticLabel: semanticLabel,
    );
