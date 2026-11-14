import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Раскладка «фото сверху, лист снизу» (вход и похожие экраны): лист по высоте содержимого прижат к низу,
/// фото занимает остальное и уходит под скруглённый верх листа на [overlap] пикселей (margin-top: -28px прототипа).
///
/// Высота - не меньше [minHeight]; если содержимое не помещается (открыта клавиатура), фото сжимается до
/// [heroMinHeight], а раскладка становится выше и прокручивается.
class KvHeroSheetLayout extends MultiChildRenderObjectWidget {
  /// Создаёт раскладку из [hero] и [sheet].
  KvHeroSheetLayout({super.key, required Widget hero, required Widget sheet, required this.minHeight, this.heroMinHeight = 260, this.overlap = 28})
      : super(children: [hero, sheet]);

  /// Наименьшая высота раскладки (обычно высота экрана).
  final double minHeight;

  /// Наименьшая видимая высота фото.
  final double heroMinHeight;

  /// На сколько фото уходит под лист.
  final double overlap;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderKvHeroSheet(minHeight, heroMinHeight, overlap);

  @override
  void updateRenderObject(BuildContext context, RenderKvHeroSheet renderObject) {
    renderObject
      ..minHeight = minHeight
      ..heroMinHeight = heroMinHeight
      ..overlap = overlap;
  }
}

class _HeroSheetParentData extends ContainerBoxParentData<RenderBox> {}

/// Объект отрисовки [KvHeroSheetLayout].
class RenderKvHeroSheet extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _HeroSheetParentData>, RenderBoxContainerDefaultsMixin<RenderBox, _HeroSheetParentData> {
  /// Создаёт объект отрисовки.
  RenderKvHeroSheet(this._minHeight, this._heroMinHeight, this._overlap);

  double _minHeight;
  double _heroMinHeight;
  double _overlap;

  /// Наименьшая высота раскладки.
  set minHeight(double v) {
    if (v != _minHeight) {
      _minHeight = v;
      markNeedsLayout();
    }
  }

  /// Наименьшая высота фото.
  set heroMinHeight(double v) {
    if (v != _heroMinHeight) {
      _heroMinHeight = v;
      markNeedsLayout();
    }
  }

  /// Насколько фото уходит под лист.
  set overlap(double v) {
    if (v != _overlap) {
      _overlap = v;
      markNeedsLayout();
    }
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _HeroSheetParentData) {
      child.parentData = _HeroSheetParentData();
    }
  }

  @override
  void performLayout() {
    final RenderBox hero = firstChild!;
    final RenderBox sheet = childAfter(hero)!;
    final double w = constraints.maxWidth;
    sheet.layout(BoxConstraints.tightFor(width: w), parentUsesSize: true);
    final double sh = sheet.size.height;
    final double total = constraints.constrainHeight(math.max(_minHeight, _heroMinHeight - _overlap + sh));
    final double heroH = total - sh + _overlap;
    hero.layout(BoxConstraints.tight(Size(w, heroH)));
    (hero.parentData! as _HeroSheetParentData).offset = Offset.zero;
    (sheet.parentData! as _HeroSheetParentData).offset = Offset(0, total - sh);
    size = Size(w, total);
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);
}
