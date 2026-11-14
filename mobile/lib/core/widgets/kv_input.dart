import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../icons/kv_icon.dart';
import '../theme/kv_theme.dart';
import 'kv_pressable.dart';

/// Поле ввода (.field): подпись, рамка 52 px со скруглением 14, значок слева, кнопка справа, синее кольцо фокуса.
///
/// Для пароля [obscure] включает точки и кнопку «глаз». Ошибки входа показываются уведомлением сверху,
/// поэтому [error] только подкрашивает рамку.
class KvField extends StatefulWidget {
  /// Создаёт поле.
  const KvField({
    super.key,
    this.label,
    this.placeholder,
    this.controller,
    this.focusNode,
    this.lead,
    this.end,
    this.onEnd,
    this.obscure = false,
    this.reveal = true,
    this.error = false,
    this.help,
    this.area = false,
    this.enabled = true,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.readOnly = false,
    this.onTap,
    this.fieldKey,
    this.height,
  });

  /// Высота однострочного поля вместо стандартных 52 (поле поиска - 48).
  final double? height;

  /// Подпись над полем.
  final String? label;

  /// Подсказка в пустом поле.
  final String? placeholder;

  /// Контроллер текста.
  final TextEditingController? controller;

  /// Узел фокуса.
  final FocusNode? focusNode;

  /// Значок слева.
  final KvIcons? lead;

  /// Значок кнопки справа (не для пароля).
  final KvIcons? end;

  /// Действие кнопки справа.
  final VoidCallback? onEnd;

  /// Поле пароля с кнопкой «глаз».
  final bool obscure;

  /// Показывать кнопку «глаз» у поля пароля; false - только точки (вход в состоянии проверки).
  final bool reveal;

  /// Красная рамка.
  final bool error;

  /// Пояснение под полем.
  final String? help;

  /// Многострочное поле от 96 px.
  final bool area;

  /// Поле доступно.
  final bool enabled;

  /// Тип клавиатуры.
  final TextInputType? keyboardType;

  /// Кнопка действия клавиатуры.
  final TextInputAction? textInputAction;

  /// Подсказки автозаполнения.
  final Iterable<String>? autofillHints;

  /// Изменение текста.
  final ValueChanged<String>? onChanged;

  /// Отправка с клавиатуры.
  final ValueChanged<String>? onSubmitted;

  /// Фокус при открытии.
  final bool autofocus;

  /// Только чтение (поле-кнопка).
  final bool readOnly;

  /// Касание поля только для чтения.
  final VoidCallback? onTap;

  /// Ключ самого поля ввода для тестов.
  final Key? fieldKey;

  @override
  State<KvField> createState() => _KvFieldState();
}

class _KvFieldState extends State<KvField> {
  FocusNode? _ownFocus;
  bool _revealed = false;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(KvField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _ownFocus)?.removeListener(_onFocus);
      _focus.addListener(_onFocus);
    }
  }

  void _onFocus() => setState(() {});

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _ownFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    final bool focused = _focus.hasFocus;
    final Color borderColor = widget.error ? c.bad : (focused ? c.brand : c.border);
    final double borderWidth = widget.error || focused ? 1.5 : 1;
    final TextStyle input = t.body.copyWith(height: widget.area ? 1.42 : 1.25);
    final Widget? endButton = widget.obscure && !widget.reveal
        ? null
        : widget.obscure
        ? _FieldButton(
            icon: _revealed ? KvIcons.eyeOff : KvIcons.eye,
            label: _revealed ? 'Скрыть пароль' : 'Показать пароль',
            onTap: () => setState(() => _revealed = !_revealed),
          )
        : widget.end != null
            ? _FieldButton(icon: widget.end!, label: '', onTap: widget.onEnd)
            : null;
    final Widget box = AnimatedContainer(
      duration: KvMotion.std,
      curve: KvMotion.ease,
      constraints: BoxConstraints(minHeight: widget.area ? 96 : (widget.height ?? 52)),
      height: widget.area ? null : (widget.height ?? 52),
      padding: widget.area
          ? const EdgeInsets.symmetric(horizontal: KvSpace.s4, vertical: 14)
          : EdgeInsets.only(left: KvSpace.s4, right: endButton == null ? KvSpace.s4 : 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(KvRadius.field),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: focused && !widget.error ? [BoxShadow(color: c.tint2, spreadRadius: 4)] : const <BoxShadow>[],
      ),
      child: Row(
        crossAxisAlignment: widget.area ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          if (widget.lead != null) ...[
            KvIcon(widget.lead!, size: 20, color: c.text3),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: TextField(
              key: widget.fieldKey,
              controller: widget.controller,
              focusNode: _focus,
              style: input.copyWith(color: c.text),
              cursorColor: c.brand,
              obscureText: widget.obscure && !_revealed,
              keyboardType: widget.keyboardType ?? (widget.area ? TextInputType.multiline : TextInputType.text),
              textInputAction: widget.textInputAction,
              autofillHints: widget.autofillHints,
              maxLines: widget.area ? null : 1,
              minLines: widget.area ? 3 : null,
              autofocus: widget.autofocus,
              readOnly: widget.readOnly,
              enabled: widget.enabled,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              onTap: widget.readOnly ? widget.onTap : null,
              autocorrect: false,
              enableSuggestions: !widget.obscure,
              decoration: InputDecoration.collapsed(hintText: widget.placeholder, hintStyle: input.copyWith(color: c.text3)),
            ),
          ),
          ?endButton,
        ],
      ),
    );
    final Widget field = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.enabled && !widget.readOnly ? _focus.requestFocus : widget.onTap,
      child: box,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!, style: t.sm.copyWith(fontWeight: FontWeight.w500, height: KvTextStyles.normalHeight(14))),
          const SizedBox(height: 6),
        ],
        Opacity(opacity: widget.enabled ? 1 : 0.55, child: field),
        if (widget.help != null) ...[
          const SizedBox(height: 6),
          Text(widget.help!, style: t.label.copyWith(fontWeight: FontWeight.w400)),
        ],
      ],
    );
  }

}

class _FieldButton extends StatelessWidget {
  const _FieldButton({required this.icon, required this.label, required this.onTap});

  final KvIcons icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return KvPressable(
      onTap: onTap,
      immediate: true,
      highlight: false,
      semanticLabel: label.isEmpty ? null : label,
      child: SizedBox(
        width: KvLayout.touch,
        height: KvLayout.touch,
        child: Center(child: KvIcon(icon, size: 22, color: context.kv.text2)),
      ),
    );
  }
}

/// Строка поиска-кнопка (.search): открывает экран поиска.
class KvSearchPill extends StatelessWidget {
  /// Создаёт строку поиска с подсказкой [placeholder].
  const KvSearchPill(this.placeholder, {super.key, required this.onTap});

  /// Подсказка.
  final String placeholder;

  /// Касание.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final BorderRadius radius = BorderRadius.circular(KvRadius.field);
    return KvPressable(
      onTap: onTap,
      borderRadius: radius,
      semanticLabel: placeholder,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: KvSpace.s4),
        decoration: BoxDecoration(color: c.surface, borderRadius: radius, boxShadow: c.shadow1),
        child: Row(
          children: [
            KvIcon(KvIcons.search, size: 20, color: c.text3),
            const SizedBox(width: 10),
            Expanded(
              child: Text(placeholder, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.kvText.body.copyWith(color: c.text3, height: 1.25)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Сегментированный переключатель (.seg): синяя плашка плавно переезжает к выбранному пункту за 300 мс.
///
/// [animateFrom] - индекс, с которого плашка начинает движение при первом показе (переход между
/// экранами-вкладками карточки: шапка стоит, плашка едет, меняется только тело экрана).
class KvSegment extends StatelessWidget {
  /// Создаёт переключатель.
  const KvSegment({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
    this.onBackground = false,
    this.tall = false,
    this.animateFrom,
  });

  /// Подписи пунктов.
  final List<String> items;

  /// Выбранный пункт.
  final int index;

  /// Выбор пункта.
  final ValueChanged<int> onChanged;

  /// Белая дорожка с тенью на фоне экрана (.on-bg) вместо серой на карточке.
  final bool onBackground;

  /// Высокие пункты 48 вместо 44.
  final bool tall;

  /// С какого пункта плашка едет при первом показе.
  final int? animateFrom;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final TextStyle label = context.kvText.sm.copyWith(fontWeight: FontWeight.w500, height: 1.2);
    final double h = tall ? 48 : 44;
    final Duration d = context.kvReduceMotion ? Duration.zero : KvMotion.nav;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: onBackground ? c.surface : c.surface2,
        borderRadius: BorderRadius.circular(KvRadius.btn),
        boxShadow: onBackground ? c.shadow1 : null,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double w = box.maxWidth / items.length;
          return SizedBox(
            height: h,
            child: Stack(
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: (animateFrom ?? index).toDouble(), end: index.toDouble()),
                  duration: d,
                  curve: KvMotion.ease,
                  builder: (BuildContext context, double v, Widget? child) => Positioned(left: v * w, top: 0, bottom: 0, width: w, child: child!),
                  child: DecoratedBox(decoration: BoxDecoration(color: c.btnPrimary, borderRadius: BorderRadius.circular(13))),
                ),
                Row(
                  children: [
                    for (int i = 0; i < items.length; i++)
                      Expanded(
                        child: KvPressable(
                          onTap: i == index ? null : () => onChanged(i),
                          immediate: true,
                          highlight: false,
                          semanticLabel: items[i],
                          child: SizedBox(
                            height: h,
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: KvMotion.std,
                                style: label.copyWith(color: i == index ? c.onBrand : c.text2),
                                child: Text(items[i], maxLines: 1, softWrap: false, overflow: TextOverflow.fade),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Переключатель (.toggle): дорожка 52 × 32 в области 44 px, белый бегунок 26 px.
class KvToggle extends StatelessWidget {
  /// Создаёт переключатель.
  const KvToggle({super.key, required this.value, required this.onChanged, this.semanticLabel});

  /// Включён.
  final bool value;

  /// Смена состояния; null - неактивен.
  final ValueChanged<bool>? onChanged;

  /// Подпись для диктора.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final Duration d = context.kvReduceMotion ? Duration.zero : KvMotion.std;
    return Semantics(
      toggled: value,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onChanged!(!value);
              },
        child: SizedBox(
          width: 52,
          height: 44,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 6,
                height: 32,
                child: AnimatedContainer(
                  duration: d,
                  curve: KvMotion.ease,
                  decoration: BoxDecoration(color: value ? c.btnPrimary : c.surface3, borderRadius: BorderRadius.circular(16)),
                ),
              ),
              AnimatedPositioned(
                duration: d,
                curve: KvMotion.ease,
                top: 9,
                left: value ? 23 : 3,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFFFFF),
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Color(0x38000000), offset: Offset(0, 2), blurRadius: 3.6)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
