import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'kv_page.dart';

/// Переходы экранов по правилам прототипа.
extension KvNavigation on BuildContext {
  /// Назад (data-back): закрыть верхний экран, а если закрывать нечего - перейти на [fallback] с анимацией возврата.
  void kvBack(String fallback) {
    if (canPop()) {
      pop();
    } else {
      go(fallback, extra: const KvNavExtra(transition: KvTransition.fade));
    }
  }

  /// Вперёд (push): новый экран въезжает справа.
  Future<T?> kvPush<T extends Object?>(String path, {Object? data}) => push<T>(path, extra: KvNavExtra(transition: KvTransition.push, data: data));

  /// Снизу вверх (up): сканер и полноэкранные формы.
  Future<T?> kvUp<T extends Object?>(String path, {Object? data}) => push<T>(path, extra: KvNavExtra(transition: KvTransition.up, data: data));

  /// Замена экрана наплывом (fade): после входа, после завершения сценария.
  void kvFade(String path, {Object? data}) => go(path, extra: KvNavExtra(transition: KvTransition.fade, data: data));

  /// Смена пункта сегмента (seg): шапка стоит, плашка едет с пункта [fromSegment].
  void kvSeg(String path, {required int fromSegment}) =>
      replace(path, extra: KvNavExtra(transition: KvTransition.seg, fromSegment: fromSegment));
}
