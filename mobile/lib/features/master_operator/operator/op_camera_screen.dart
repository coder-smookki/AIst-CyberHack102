import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/navigation/kv_nav.dart';
import '../../../app/routes/master_operator_routes.dart';
import '../../../core/kv.dart';
import '../widgets/mo_frame.dart';
import 'op_blocks.dart';

/// Кадр к сообщению о неисправности: живое видео пола под АМС-2 с рамкой прицела на луже, подсветка
/// и затвор. Снимок возвращает на сообщение с приложенным кадром (результат true).
class OpCameraScreen extends StatefulWidget {
  /// Создаёт экран.
  const OpCameraScreen({super.key});

  /// Увеличенный вид на пол под АМС-2 (KV.cam.view(2.4, 0.3, 0.8, 0.45, 0.5)).
  static const KvCamView view = KvCamView(k: 2.4, cx: 0.3, cy: 0.8, tx: 0.45);

  /// Лужа под агрегатом в процентах кадра camera.jpg.
  static const Rect puddle = Rect.fromLTWH(13, 77.3, 30, 7);

  @override
  State<OpCameraScreen> createState() => _OpCameraScreenState();
}

class _OpCameraScreenState extends State<OpCameraScreen> {
  bool _flash = false;

  void _close() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(false);
    } else {
      context.kvBack(MasterOperatorPaths.opReport);
    }
  }

  void _shoot() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    } else {
      context.kvBack(MasterOperatorPaths.opReport);
    }
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final EdgeInsets pad = MediaQuery.paddingOf(context);
    final Rect pb = OpCameraScreen.view.map(OpCameraScreen.puddle);
    return KvScreen(
      immersive: true,
      lightStatusBar: true,
      lightHome: true,
      stagger: KvStagger.none,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double w = box.maxWidth;
          final double h = box.maxHeight;
          final double left = math.max(pb.left, 4) / 100 * w;
          final double right = math.max(100 - pb.left - pb.width, 4) / 100 * w;
          return Stack(
            children: [
              const Positioned.fill(
                child: RepaintBoundary(child: KvArStage(view: OpCameraScreen.view)),
              ),
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
              Positioned(
                left: left,
                right: right,
                top: pb.top / 100 * h - 12,
                height: pb.height / 100 * h + 24,
                child: const IgnorePointer(child: MoAimCorners()),
              ),
              Positioned(
                left: KvSpace.gutter,
                right: KvSpace.gutter,
                top: pad.top + 4,
                child: Row(
                  children: [
                    KvRoundButton(icon: KvIcons.close, variant: KvRoundVariant.glass, onPressed: _close, semanticLabel: 'Закрыть'),
                    const SizedBox(width: KvSpace.s2),
                    const Expanded(
                      child: Center(
                        child: OpGlassPill(icon: KvIcons.camera, text: 'АМС-2 · живое видео'),
                      ),
                    ),
                    const SizedBox(width: KvSpace.s2),
                    KvRoundButton(
                      icon: KvIcons.flash,
                      variant: KvRoundVariant.glass,
                      active: _flash,
                      onPressed: () => setState(() => _flash = !_flash),
                      semanticLabel: 'Подсветка',
                    ),
                  ],
                ),
              ),
              Positioned(
                left: KvSpace.gutter,
                right: KvSpace.gutter,
                top: pad.top + 60,
                child: const Center(
                  child: IgnorePointer(child: OpGlassPill(text: 'Наведите рамку на место неисправности')),
                ),
              ),
              Positioned(
                left: KvSpace.gutter,
                right: KvSpace.gutter,
                bottom: pad.bottom + 2,
                child: Center(child: _Shutter(onTap: _shoot)),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Затвор камеры (.d-shutter): белый круг 76 с кольцом стекла 4 и белым кольцом 7, значок камеры.
class _Shutter extends StatelessWidget {
  const _Shutter({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return KvPressable(
      onTap: onTap,
      shape: BoxShape.circle,
      semanticLabel: 'Снять кадр',
      child: Container(
        width: 76,
        height: 76,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.arText,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: c.arText, spreadRadius: 7),
            BoxShadow(color: Color.alphaBlend(c.arGlass, c.arText), spreadRadius: 4),
          ],
        ),
        child: KvIcon(KvIcons.camera, size: 28, color: c.brandDeep),
      ),
    );
  }
}
