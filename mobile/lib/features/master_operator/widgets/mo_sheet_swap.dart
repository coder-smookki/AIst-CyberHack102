import 'package:flutter/widgets.dart';

import '../../../core/kv.dart';

/// Смена содержимого открытого листа (swapOverlay прототипа): новый лист проявляется со сдвигом 16 px
/// за 260 мс, прежний гаснет за 180 мс. Ключ [child] определяет, что содержимое сменилось.
class MoSheetSwap extends StatelessWidget {
  /// Создаёт смену листа с текущим содержимым [child].
  const MoSheetSwap({super.key, required this.child});

  /// Текущий лист: [KvSheet] с ключом состояния.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool reduce = context.kvReduceMotion;
    return AnimatedSwitcher(
      duration: reduce ? Duration.zero : const Duration(milliseconds: 260),
      reverseDuration: reduce ? Duration.zero : const Duration(milliseconds: 180),
      switchInCurve: KvMotion.ease,
      switchOutCurve: KvMotion.easeOut,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(alignment: Alignment.bottomCenter, children: [...previous, ?current]),
      transitionBuilder: (Widget c, Animation<double> a) {
        final bool incoming = c.key == child.key;
        if (!incoming) {
          return FadeTransition(opacity: a, child: c);
        }
        return FadeTransition(
          opacity: a,
          child: AnimatedBuilder(
            animation: a,
            builder: (BuildContext context, Widget? w) => Transform.translate(offset: Offset(0, 16 * (1 - a.value)), child: w),
            child: c,
          ),
        );
      },
      child: child,
    );
  }
}
