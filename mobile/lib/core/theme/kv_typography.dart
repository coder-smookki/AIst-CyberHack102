import 'package:flutter/material.dart';

import 'kv_colors.dart';

/// Шкала шрифта дизайна (классы .t-* и переменные --fs-* в css/app.css), шрифт Geologica из ресурсов.
///
/// Интерлиньяж распределяется поровну сверху и снизу, как в CSS; межбуквенные интервалы переведены из em в пиксели.
@immutable
class KvTextStyles extends ThemeExtension<KvTextStyles> {
  /// Собирает стили с цветами темы [c].
  factory KvTextStyles.of(KvColors c) {
    TextStyle s(double size, FontWeight weight, Color color, {double? height, double spacing = 0}) => TextStyle(
          fontFamily: kvFontFamily,
          fontSize: size,
          fontWeight: weight,
          height: height,
          letterSpacing: spacing,
          color: color,
          leadingDistribution: TextLeadingDistribution.even,
        );
    return KvTextStyles._(
      numXl: s(44, FontWeight.w300, c.text, height: 1, spacing: -0.88),
      numL: s(36, FontWeight.w300, c.text, height: 1, spacing: -0.72),
      numM: s(28, FontWeight.w400, c.text, height: 1.05, spacing: -0.28),
      numS: s(22, FontWeight.w400, c.text, height: 1.1),
      unit: s(13, FontWeight.w400, c.text2),
      title: s(22, FontWeight.w600, c.text, height: 1.2),
      hdr: s(18, FontWeight.w600, c.text, height: 1.25),
      h2: s(17, FontWeight.w600, c.text, height: 1.3),
      body: s(15, FontWeight.w400, c.text, height: 1.42),
      bodyM: s(15, FontWeight.w500, c.text, height: 1.38),
      sm: s(14, FontWeight.w400, c.text, height: 1.4),
      caption: s(13, FontWeight.w400, c.text2, height: 1.38),
      label: s(12, FontWeight.w500, c.text2, height: 1.33),
      micro: s(11, FontWeight.w500, c.text3, height: 1.3),
      btn: s(16, FontWeight.w600, c.text, height: 1),
      base: s(15, FontWeight.w400, c.text),
    );
  }

  const KvTextStyles._({
    required this.numXl,
    required this.numL,
    required this.numM,
    required this.numS,
    required this.unit,
    required this.title,
    required this.hdr,
    required this.h2,
    required this.body,
    required this.bodyM,
    required this.sm,
    required this.caption,
    required this.label,
    required this.micro,
    required this.btn,
    required this.base,
  });

  /// Семейство шрифта приложения.
  static const String kvFontFamily = 'Geologica';

  /// Множитель высоты строки, равный CSS line-height: normal для Geologica в браузере прототипа:
  /// верхний и нижний выносные элементы (0,975 и 0,275 кегля) округляются до пикселя по отдельности.
  static double normalHeight(double fontSize) => ((fontSize * 0.975).roundToDouble() + (fontSize * 0.275).roundToDouble()) / fontSize;

  /// Крупная тонкая цифра 44 (ресурс в часах).
  final TextStyle numXl;

  /// Цифра 36 (KPI).
  final TextStyle numL;

  /// Цифра 28 (плитки показаний).
  final TextStyle numM;

  /// Цифра 22.
  final TextStyle numS;

  /// Единица измерения рядом с цифрой.
  final TextStyle unit;

  /// Заголовок 22 (корневые экраны, лист входа).
  final TextStyle title;

  /// Заголовок шапки 18.
  final TextStyle hdr;

  /// Заголовок карточки 17.
  final TextStyle h2;

  /// Основной текст 15.
  final TextStyle body;

  /// Основной текст 15, средний.
  final TextStyle bodyM;

  /// Текст 14.
  final TextStyle sm;

  /// Подпись 13, второстепенный цвет.
  final TextStyle caption;

  /// Метка 12, средний, второстепенный цвет.
  final TextStyle label;

  /// Мелкая метка 11, третичный цвет.
  final TextStyle micro;

  /// Текст кнопки 16.
  final TextStyle btn;

  /// Базовый стиль экрана: 15, обычный интерлиньяж шрифта.
  final TextStyle base;

  @override
  KvTextStyles copyWith() => this;

  @override
  KvTextStyles lerp(covariant KvTextStyles? other, double t) {
    if (other == null) {
      return this;
    }
    TextStyle l(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return KvTextStyles._(
      numXl: l(numXl, other.numXl),
      numL: l(numL, other.numL),
      numM: l(numM, other.numM),
      numS: l(numS, other.numS),
      unit: l(unit, other.unit),
      title: l(title, other.title),
      hdr: l(hdr, other.hdr),
      h2: l(h2, other.h2),
      body: l(body, other.body),
      bodyM: l(bodyM, other.bodyM),
      sm: l(sm, other.sm),
      caption: l(caption, other.caption),
      label: l(label, other.label),
      micro: l(micro, other.micro),
      btn: l(btn, other.btn),
      base: l(base, other.base),
    );
  }
}
