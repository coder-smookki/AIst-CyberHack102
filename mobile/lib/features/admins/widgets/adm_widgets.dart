import 'dart:async';
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/state/app_state.dart';
import '../../../core/kv.dart';
import '../../../data/providers.dart';

/// Типографская обработка строки, как KV.typo прототипа: единицы и номера не отрываются от чисел.
String ty(String s) => KvFormat.typo(s);

/// Узкий экран (контейнерный запрос прототипа max-width: 370px).
bool admNarrow(BuildContext context) => MediaQuery.sizeOf(context).width <= 370;

/// Верх карточки (.e-top): значок, заголовок с подписью и шеврон или свой виджет справа.
class AdmTop extends StatelessWidget {
  /// Создаёт верх карточки.
  const AdmTop({super.key, required this.icon, this.status, required this.title, required this.subtitle, this.trailing});

  /// Значок.
  final KvIcons icon;

  /// Тон значка.
  final KvStatus? status;

  /// Заголовок.
  final String title;

  /// Подпись.
  final String subtitle;

  /// Виджет справа; по умолчанию шеврон.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    return Row(
      children: [
        KvRowIcon(icon: icon, status: status),
        const SizedBox(width: KvSpace.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: t.h2.copyWith(height: 1.3)),
              const SizedBox(height: 2),
              Text(ty(subtitle), style: t.caption.copyWith(height: 1.35)),
            ],
          ),
        ),
        const SizedBox(width: KvSpace.s3),
        trailing ?? KvIcon(KvIcons.chevronRight, size: 20, color: context.kv.text3),
      ],
    );
  }
}

/// Счётчик загрузки (.e-meter): подпись, процент, тонкая полоса и пояснение.
class AdmMeter extends StatelessWidget {
  /// Создаёт счётчик.
  const AdmMeter({super.key, required this.label, required this.pct, this.extra});

  /// Подпись.
  final String label;

  /// Процент.
  final int pct;

  /// Пояснение под полосой.
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    final KvStatus? st = pct >= 90 ? KvStatus.bad : (pct >= 75 ? KvStatus.warn : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: t.label),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('$pct', style: t.numS),
            const SizedBox(width: 3),
            Text('%', style: t.unit),
          ],
        ),
        const SizedBox(height: 6),
        KvProgress(value: pct / 100, status: st, thin: true),
        if (extra != null) ...[const SizedBox(height: 6), Text(ty(extra!), style: t.micro)],
      ],
    );
  }
}

/// Сетка из колонок одинаковой ширины с промежутком [gap] (grid прототипа).
class AdmGrid extends StatelessWidget {
  /// Создаёт сетку.
  const AdmGrid({super.key, required this.children, this.columns = 2, this.gap = KvSpace.s3, this.rowGap});

  /// Ячейки.
  final List<Widget> children;

  /// Колонок.
  final int columns;

  /// Промежуток между колонками.
  final double gap;

  /// Промежуток между строками; по умолчанию как между колонками.
  final double? rowGap;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = [];
    for (int i = 0; i < children.length; i += columns) {
      if (i > 0) {
        rows.add(SizedBox(height: rowGap ?? gap));
      }
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int k = 0; k < columns; k++) ...[
                if (k > 0) SizedBox(width: gap),
                Expanded(child: i + k < children.length ? children[i + k] : const SizedBox.shrink()),
              ],
            ],
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: rows);
  }
}

/// Ряд колонок под чертой (.e-meters, .e-kpis): отступ [top] сверху, черта и ещё [top] до содержимого.
class AdmDividedRow extends StatelessWidget {
  /// Создаёт ряд.
  const AdmDividedRow({super.key, required this.children, required this.gap, required this.top, this.divider = true});

  /// Колонки.
  final List<Widget> children;

  /// Промежуток между колонками.
  final double gap;

  /// Отступ над чертой и под ней.
  final double top;

  /// Рисовать черту.
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(width: gap), Expanded(child: children[i])],
      ],
    );
    if (!divider) {
      return row;
    }
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.kv.divider)),
        ),
        child: Padding(
          padding: EdgeInsets.only(top: top + 1),
          child: row,
        ),
      ),
    );
  }
}

/// Показатель в ряду карточки (.e-kpi): значение с точкой статуса и подпись.
class AdmKpi extends StatelessWidget {
  /// Создаёт показатель.
  const AdmKpi({super.key, required this.value, required this.label, this.dot, this.warn = false});

  /// Значение.
  final String value;

  /// Подпись.
  final String label;

  /// Точка статуса перед значением.
  final KvStatus? dot;

  /// Жёлтый текст значения.
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dot != null) ...[KvDot(status: dot!), const SizedBox(width: 6)],
            Flexible(
              child: Text(
                ty(value),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: t.body.copyWith(
                  fontWeight: FontWeight.w500,
                  height: KvTextStyles.normalHeight(15),
                  color: warn ? c.warnText : c.text,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: t.label.copyWith(fontWeight: FontWeight.w400, height: KvTextStyles.normalHeight(12)),
        ),
      ],
    );
  }
}

/// Крупное значение с пояснением (.e-big-row): «23 %» и «Загрузка процессора».
class AdmBigNum extends StatelessWidget {
  /// Создаёт строку.
  const AdmBigNum({super.key, required this.value, required this.unit, this.warn = false, required this.title, required this.text});

  /// Значение.
  final String value;

  /// Единица.
  final String unit;

  /// Жёлтый цвет.
  final bool warn;

  /// Заголовок пояснения.
  final String title;

  /// Текст пояснения.
  final String text;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final Color color = warn ? c.warnText : c.brand;
    final double size = admNarrow(context) ? 38 : 44;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                maxLines: 1,
                softWrap: false,
                style: t.numXl.copyWith(fontSize: size, letterSpacing: -0.02 * size, color: color),
              ),
              const SizedBox(width: 6),
              Text(unit, maxLines: 1, softWrap: false, style: t.numXl.copyWith(fontSize: 22, letterSpacing: 0, color: color)),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: t.sm.copyWith(fontWeight: FontWeight.w500, height: 1.35, color: c.text),
                ),
                Text(ty(text), style: t.caption.copyWith(height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Итог действия (.e-done): зелёный круг с галочкой, заголовок, текст и плитки с цифрами.
class AdmDone extends StatelessWidget {
  /// Создаёт итог.
  const AdmDone({super.key, required this.title, required this.text, this.stats = const <(String, String)>[], this.icon = KvIcons.check});

  /// Заголовок.
  final String title;

  /// Текст.
  final String text;

  /// Плитки «значение - подпись».
  final List<(String, String)> stats;

  /// Значок в круге.
  final KvIcons icon;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Padding(
      padding: const EdgeInsets.only(top: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 112,
            height: 112,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.okBg, shape: BoxShape.circle),
            child: Container(
              width: 80,
              height: 80,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.ok, shape: BoxShape.circle),
              child: KvIcon(icon, size: 40, color: c.onBrand),
            ),
          ),
          const SizedBox(height: 14 + 8),
          Text(title, textAlign: TextAlign.center, style: t.title.copyWith(height: 1.2)),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(
              ty(text),
              textAlign: TextAlign.center,
              style: t.sm.copyWith(color: c.text2, height: 1.45),
            ),
          ),
          if (stats.isNotEmpty) ...[
            const SizedBox(height: 8 + 12),
            AdmGrid(
              gap: 8,
              children: [
                for (final (String v, String l) in stats)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    decoration: BoxDecoration(color: c.surface2, borderRadius: BorderRadius.circular(KvRadius.sm)),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          ty(v),
                          maxLines: 1,
                          softWrap: false,
                          style: t.h2.copyWith(color: c.brand, height: KvTextStyles.normalHeight(17)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l,
                          style: t.label.copyWith(fontWeight: FontWeight.w400, height: KvTextStyles.normalHeight(12)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Временный пароль в пунктирной рамке (.e-pwd) с кнопкой копирования.
class AdmPassword extends StatelessWidget {
  /// Создаёт поле пароля.
  const AdmPassword(this.password, {super.key});

  /// Пароль.
  final String password;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    return CustomPaint(
      painter: _DashedBox(color: c.border, fill: c.surface2, radius: KvRadius.field),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(19, 7, 7, 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                password,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: TextStyle(
                  fontFamily: KvTextStyles.kvFontFamily,
                  fontSize: admNarrow(context) ? 21 : 24,
                  fontWeight: FontWeight.w500,
                  letterSpacing: (admNarrow(context) ? 21 : 24) * 0.06,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: c.text,
                  height: KvTextStyles.normalHeight(24),
                ),
              ),
            ),
            const SizedBox(width: 8),
            KvRoundButton(
              icon: KvIcons.copy,
              iconSize: 22,
              variant: KvRoundVariant.ghost,
              semanticLabel: 'Копировать',
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: password)));
                showKvToast(
                  context,
                  title: 'Пароль скопирован',
                  text: 'Буфер очистится через 60 с',
                  kind: KvToastKind.ok,
                  icon: KvIcons.copy,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Рамка из пунктира 1 px со скруглением и заливкой (border: 1px dashed).
class _DashedBox extends CustomPainter {
  _DashedBox({required this.color, required this.fill, required this.radius});

  final Color color;
  final Color fill;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final RRect r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    canvas.drawRRect(r, Paint()..color = fill);
    final Path border = Path()..addRRect(r.deflate(0.5));
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final PathMetric m in border.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 3), stroke);
        d += 6;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBox old) => old.color != color || old.fill != fill || old.radius != radius;
}

/// Строка выбора одного варианта (.e-opt): значок, заголовок, подпись и круглая отметка справа.
class AdmRadioRow extends StatelessWidget {
  /// Создаёт строку.
  const AdmRadioRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconStatus,
    required this.selected,
    required this.onTap,
  });

  /// Заголовок.
  final String title;

  /// Подпись.
  final String? subtitle;

  /// Значок.
  final KvIcons? icon;

  /// Тон значка.
  final KvStatus? iconStatus;

  /// Выбрана.
  final bool selected;

  /// Выбор.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Duration d = context.kvReduceMotion ? Duration.zero : KvMotion.std;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: KvRow(
        title: title,
        titleWidget: AnimatedDefaultTextStyle(
          duration: d,
          style: context.kvText.bodyM.copyWith(height: 1.3, color: selected ? c.brand : c.text),
          child: Text(title),
        ),
        subtitle: subtitle == null ? null : ty(subtitle!),
        icon: icon,
        iconStatus: iconStatus,
        chevron: false,
        onTap: onTap,
        trailing: AnimatedContainer(
          duration: KvMotion.fast,
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: selected ? c.brand : c.surface3, width: 2),
          ),
          child: AnimatedScale(
            scale: selected ? 1 : 0,
            duration: d,
            curve: KvMotion.ease,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: c.brand, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}

/// Подзаголовок внутри листа (.e-sub).
class AdmSub extends StatelessWidget {
  /// Создаёт подзаголовок.
  const AdmSub(this.text, {super.key});

  /// Текст.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(text, style: context.kvText.label.copyWith(height: KvTextStyles.normalHeight(12))),
    );
  }
}

/// Пояснение мелким шрифтом (.t-caption).
class AdmCaption extends StatelessWidget {
  /// Создаёт пояснение.
  const AdmCaption(this.text, {super.key, this.top = 0});

  /// Текст.
  final String text;

  /// Отступ сверху (.mt-s).
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Text(ty(text), style: context.kvText.caption),
    );
  }
}

/// Плашка с полужирной первой строкой (KV.note с html «<b>...</b><br>...»).
class AdmBoldNote extends StatelessWidget {
  /// Создаёт плашку.
  const AdmBoldNote({super.key, required this.bold, required this.text, this.tone, this.icon = KvIcons.info, this.onTap});

  /// Полужирная первая строка.
  final String bold;

  /// Текст под ней.
  final String text;

  /// Тон.
  final KvStatus? tone;

  /// Значок.
  final KvIcons icon;

  /// Касание.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return KvNote(
      tone: tone,
      icon: icon,
      onTap: onTap,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: ty(bold),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const TextSpan(text: '\n'),
            TextSpan(text: ty(text)),
          ],
        ),
      ),
    );
  }
}

/// Кнопка, которая показывает загрузку, пока идёт [work] (не меньше [wait]), затем вызывает [onDone].
///
/// Ошибка сервера показывается уведомлением сверху, кнопка снова доступна.
class AdmBusyButton extends StatefulWidget {
  /// Создаёт кнопку.
  const AdmBusyButton(
    this.label, {
    super.key,
    this.work,
    this.onDone,
    this.kind = KvButtonKind.primary,
    this.icon,
    this.small = false,
    this.expand,
    this.wait = KvMotion.wait,
  });

  /// Текст кнопки.
  final String label;

  /// Запрос к серверу.
  final Future<void> Function()? work;

  /// Действие после запроса.
  final VoidCallback? onDone;

  /// Вид кнопки.
  final KvButtonKind kind;

  /// Значок слева.
  final KvIcons? icon;

  /// Малая кнопка.
  final bool small;

  /// Растягивать на всю ширину.
  final bool? expand;

  /// Наименьшее время загрузки (data-wait прототипа).
  final Duration wait;

  @override
  State<AdmBusyButton> createState() => _AdmBusyButtonState();
}

class _AdmBusyButtonState extends State<AdmBusyButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    final Duration wait = context.kvReduceMotion ? Duration.zero : widget.wait;
    try {
      await Future.wait<void>([if (widget.work != null) widget.work!(), Future<void>.delayed(wait)]);
    } on KvApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showKvToast(context, title: 'Не удалось выполнить', text: e.message);
      }
      return;
    }
    if (mounted) {
      setState(() => _busy = false);
    }
    widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    return KvButton(
      widget.label,
      kind: widget.kind,
      icon: widget.icon,
      small: widget.small,
      expand: widget.expand,
      loading: _busy,
      onPressed: _run,
    );
  }
}

/// Кнопки диалога «Отмена» и действие (cancelOk прототипа): длинная подпись - столбиком, короткая - в ряд.
class AdmDialogActions extends StatelessWidget {
  /// Создаёт кнопки.
  const AdmDialogActions({
    super.key,
    required this.okText,
    this.work,
    this.onDone,
    this.kind = KvButtonKind.primary,
    this.wait = KvMotion.wait,
  });

  /// Подпись действия.
  final String okText;

  /// Запрос к серверу.
  final Future<void> Function()? work;

  /// Действие после запроса; диалог закрывает само.
  final VoidCallback? onDone;

  /// Вид кнопки действия.
  final KvButtonKind kind;

  /// Наименьшее время загрузки.
  final Duration wait;

  @override
  Widget build(BuildContext context) {
    final Widget ok = AdmBusyButton(okText, kind: kind, work: work, onDone: onDone, wait: wait);
    final Widget no = KvButton('Отмена', kind: KvButtonKind.secondary, onPressed: () => Navigator.of(context).pop());
    if (okText.length > 12) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ok,
          const SizedBox(height: KvSpace.s2),
          no,
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: no),
        const SizedBox(width: KvSpace.s3),
        Expanded(child: ok),
      ],
    );
  }
}

/// Переключатель со своим состоянием (data-toggle="switch" прототипа).
class AdmToggle extends StatefulWidget {
  /// Создаёт переключатель.
  const AdmToggle({super.key, required this.initial, this.onChanged, this.semanticLabel});

  /// Начальное положение.
  final bool initial;

  /// Сообщение о смене.
  final ValueChanged<bool>? onChanged;

  /// Подпись для диктора.
  final String? semanticLabel;

  @override
  State<AdmToggle> createState() => _AdmToggleState();
}

class _AdmToggleState extends State<AdmToggle> {
  late bool _on = widget.initial;

  @override
  void didUpdateWidget(AdmToggle old) {
    super.didUpdateWidget(old);
    if (old.initial != widget.initial) {
      _on = widget.initial;
    }
  }

  @override
  Widget build(BuildContext context) {
    return KvToggle(
      value: _on,
      semanticLabel: widget.semanticLabel,
      onChanged: (bool v) {
        setState(() => _on = v);
        widget.onChanged?.call(v);
      },
    );
  }
}

/// Сегменты со своим состоянием (data-toggle="seg" прототипа).
class AdmSegment extends StatefulWidget {
  /// Создаёт сегменты.
  const AdmSegment({super.key, required this.items, required this.initial, this.onBackground = false, this.onChanged});

  /// Подписи.
  final List<String> items;

  /// Выбранный пункт.
  final int initial;

  /// Белая дорожка с тенью.
  final bool onBackground;

  /// Сообщение о выборе.
  final ValueChanged<int>? onChanged;

  @override
  State<AdmSegment> createState() => _AdmSegmentState();
}

class _AdmSegmentState extends State<AdmSegment> {
  late int _i = widget.initial;

  @override
  Widget build(BuildContext context) {
    return KvSegment(
      items: widget.items,
      index: _i,
      onBackground: widget.onBackground,
      onChanged: (int i) {
        setState(() => _i = i);
        widget.onChanged?.call(i);
      },
    );
  }
}

/// Фильтры-чипы со своим выбором одного пункта.
class AdmFilterChips extends StatefulWidget {
  /// Создаёт фильтры.
  const AdmFilterChips({super.key, required this.items, this.initial = 0, this.onSelected});

  /// Пункты.
  final List<KvFilterItem> items;

  /// Выбранный пункт.
  final int initial;

  /// Сообщение о выборе.
  final ValueChanged<int>? onSelected;

  @override
  State<AdmFilterChips> createState() => _AdmFilterChipsState();
}

class _AdmFilterChipsState extends State<AdmFilterChips> {
  late int _i = widget.initial;

  @override
  Widget build(BuildContext context) {
    return KvFilterChips(
      items: widget.items,
      selected: _i,
      onSelected: (int i) {
        setState(() => _i = i);
        widget.onSelected?.call(i);
      },
    );
  }
}

/// Чипы, переносящиеся на новую строку (.e-chips): высота 30, промежуток 6.
class AdmChips extends StatelessWidget {
  /// Создаёт ряд чипов.
  const AdmChips({super.key, required this.chips});

  /// Чипы: подпись, тон и точка.
  final List<(String, KvStatus?, bool)> chips;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (String label, KvStatus? status, bool dot) in chips)
          SizedBox(
            height: 30,
            child: KvChip(label, status: status, dot: dot),
          ),
      ],
    );
  }
}

/// Карточка профиля (.e-prof): аватар, имя, должность, почта и роль.
class AdmProfileCard extends StatelessWidget {
  /// Создаёт карточку.
  const AdmProfileCard({super.key, required this.person, required this.roleLabel});

  /// Сотрудник.
  final Person person;

  /// Название роли.
  final String roleLabel;

  @override
  Widget build(BuildContext context) {
    final KvTextStyles t = context.kvText;
    return KvCard(
      child: Row(
        children: [
          KvAvatar(person.name, size: KvAvatarSize.large),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  person.name,
                  style: t.body.copyWith(fontWeight: FontWeight.w500, height: KvTextStyles.normalHeight(15)),
                ),
                const SizedBox(height: 3),
                Text(person.title, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13))),
                const SizedBox(height: 3),
                Text(person.email, style: t.caption.copyWith(height: KvTextStyles.normalHeight(13))),
                const SizedBox(height: 3 + 8),
                KvChip('Роль «$roleLabel»', status: KvStatus.info, dot: false),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Карточка «Оформление»: тема приложения, сохраняется на устройстве.
class AdmThemeCard extends ConsumerWidget {
  /// Создаёт карточку.
  const AdmThemeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeMode mode = ref.watch(deviceSettingsProvider.select((DeviceSettings s) => s.themeMode));
    final int index = switch (mode) {
      ThemeMode.light => 0,
      ThemeMode.dark => 1,
      ThemeMode.system => 2,
    };
    return KvCard(
      title: 'Оформление',
      child: KvSegment(
        items: const ['Светлая', 'Тёмная', 'Как в системе'],
        index: index,
        onChanged: (int i) =>
            ref.read(deviceSettingsProvider.notifier).setThemeMode(const [ThemeMode.light, ThemeMode.dark, ThemeMode.system][i]),
      ),
    );
  }
}

/// Закрывает лист или диалог [overlay] и, когда он ушёл, выполняет [then].
void admCloseThen(BuildContext overlay, VoidCallback then) {
  Navigator.of(overlay).pop();
  then();
}

/// Строки «ключ - значение» прямо в листе (KV.kvs вне карточки): каждая строка - отдельный блок листа
/// с промежутком 12, у второй и следующих черта сверху.
List<Widget> admLooseKeyValues(BuildContext context, List<(String, String)> pairs) => [
  for (int i = 0; i < pairs.length; i++)
    if (i == 0)
      KvKeyValues([pairs[i]])
    else
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.kv.divider)),
        ),
        child: Padding(padding: const EdgeInsets.only(top: 1), child: KvKeyValues([pairs[i]])),
      ),
];

/// Заголовок строки списка, который может переноситься: строка 19 px вместо округлённых движком 20 px,
/// чтобы две строки занимали 38 px, как 2 × 19,5 px в браузере прототипа.
Widget admWrapTitle(BuildContext context, String text, {Color? color}) =>
    Text(text, style: context.kvText.bodyM.copyWith(height: 1.29, color: color ?? context.kv.text));
