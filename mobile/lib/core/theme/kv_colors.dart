import 'package:flutter/material.dart';

import 'kv_tokens.dart';

/// Цвета и тени дизайна для светлой и тёмной темы (css/app.css, :root и [data-theme="dark"]).
///
/// Экраны берут цвета только отсюда: `context.kv.brand`, `context.kv.text2` и так далее.
@immutable
class KvColors extends ThemeExtension<KvColors> {
  /// Создаёт набор цветов; готовые наборы - [KvColors.light] и [KvColors.dark].
  const KvColors({
    required this.brightness,
    required this.brand,
    required this.brandHover,
    required this.brandDeep,
    required this.brandNavy,
    required this.brandSteel,
    required this.tint,
    required this.tint2,
    required this.onBrand,
    required this.btnPrimary,
    required this.btnPrimaryPress,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.text,
    required this.text2,
    required this.text3,
    required this.border,
    required this.divider,
    required this.ok,
    required this.okBg,
    required this.warn,
    required this.warnBg,
    required this.warnText,
    required this.bad,
    required this.badBg,
    required this.unk,
    required this.unkBg,
    required this.info,
    required this.infoBg,
    required this.chartOk,
    required this.chartWarn,
    required this.chartAlarm,
    required this.chartGrid,
    required this.chartAxis,
    required this.scrim,
    required this.snackBg,
    required this.snackText,
    required this.snackAction,
    required this.press,
    required this.tabBar,
    required this.tabBarBorder,
    required this.shadow1,
    required this.shadow2,
    required this.shadowTab,
    required this.shadowSheet,
    required this.heroOverlay,
  });

  /// Яркость темы.
  final Brightness brightness;

  /// Основной синий: кнопки, ссылки, активные элементы.
  final Color brand;

  /// Синий наведения и нажатия.
  final Color brandHover;

  /// Тёмный синий: подложка героя.
  final Color brandDeep;

  /// Дополнительный синий.
  final Color brandNavy;

  /// Дополнительный стальной синий.
  final Color brandSteel;

  /// Светло-синяя подложка, кружок активной вкладки.
  final Color tint;

  /// Более мягкая подложка.
  final Color tint2;

  /// Текст на синем.
  final Color onBrand;

  /// Фон основной кнопки.
  final Color btnPrimary;

  /// Фон основной кнопки при нажатии.
  final Color btnPrimaryPress;

  /// Фон экрана.
  final Color bg;

  /// Поверхность карточек.
  final Color surface;

  /// Поля на карточках, дорожки сегментов.
  final Color surface2;

  /// Дорожки прогресса, выключенные переключатели.
  final Color surface3;

  /// Основной текст.
  final Color text;

  /// Второстепенный текст.
  final Color text2;

  /// Третичный текст и плейсхолдеры.
  final Color text3;

  /// Рамки полей и вторичных кнопок.
  final Color border;

  /// Разделители строк.
  final Color divider;

  /// Норма.
  final Color ok;

  /// Подложка нормы.
  final Color okBg;

  /// Внимание.
  final Color warn;

  /// Подложка внимания.
  final Color warnBg;

  /// Текст внимания на светлой подложке.
  final Color warnText;

  /// Авария и критично.
  final Color bad;

  /// Подложка аварии.
  final Color badBg;

  /// Нет данных.
  final Color unk;

  /// Подложка «нет данных».
  final Color unkBg;

  /// Информационный синий.
  final Color info;

  /// Подложка информационного синего.
  final Color infoBg;

  /// График в норме.
  final Color chartOk;

  /// График выше уставки предупреждения.
  final Color chartWarn;

  /// График выше аварийной уставки.
  final Color chartAlarm;

  /// Сетка графика.
  final Color chartGrid;

  /// Подписи осей графика.
  final Color chartAxis;

  /// Затемнение под листом и диалогом.
  final Color scrim;

  /// Фон уведомления снизу.
  final Color snackBg;

  /// Текст уведомления снизу.
  final Color snackText;

  /// Действие в уведомлении снизу.
  final Color snackAction;

  /// Подсветка при нажатии.
  final Color press;

  /// Фон плавающей панели вкладок.
  final Color tabBar;

  /// Тонкая внутренняя рамка панели вкладок (только тёмная тема).
  final Color? tabBarBorder;

  /// Тень карточек (--shadow-1).
  final List<BoxShadow> shadow1;

  /// Тень всплывающих элементов (--shadow-2).
  final List<BoxShadow> shadow2;

  /// Тень панели вкладок (--shadow-tab).
  final List<BoxShadow> shadowTab;

  /// Тень листа снизу (--shadow-sheet).
  final List<BoxShadow> shadowSheet;

  /// Синее наложение на фото героя (--hero-overlay).
  final Gradient heroOverlay;

  /// Цвета AR-рамки детали: одинаковы в обеих темах, потому что лежат на видео.
  Color get arPart => const Color(0xFF2F8CFF);

  /// Цвет AR-рамки дефекта.
  Color get arDefect => const Color(0xFFE5483D);

  /// Цвет AR-рамки манометра.
  Color get arGauge => const Color(0xFF23A169);

  /// Стеклянная подложка поверх видео.
  Color get arGlass => const Color(0x9E0A1422);

  /// Текст поверх видео.
  Color get arText => const Color(0xFFFFFFFF);

  /// Светлая тема.
  static final KvColors light = KvColors(
    brightness: Brightness.light,
    brand: const Color(0xFF135AA6),
    brandHover: const Color(0xFF1787FF),
    brandDeep: const Color(0xFF0D3F75),
    brandNavy: const Color(0xFF27348B),
    brandSteel: const Color(0xFF1E5170),
    tint: const Color(0xFFDEE6F1),
    tint2: const Color(0xFFEBF1F9),
    onBrand: const Color(0xFFFFFFFF),
    btnPrimary: const Color(0xFF135AA6),
    btnPrimaryPress: const Color(0xFF0D4C8E),
    bg: const Color(0xFFF4F5F8),
    surface: const Color(0xFFFFFFFF),
    surface2: const Color(0xFFF1F3F7),
    surface3: const Color(0xFFE8EBF0),
    text: const Color(0xFF313132),
    text2: const Color(0xFF6B7280),
    text3: const Color(0xFF9AA1AC),
    border: const Color(0xFFD5D9DE),
    divider: const Color(0xFFECEEF2),
    ok: const Color(0xFF1E8E5A),
    okBg: const Color(0xFFE6F5EE),
    warn: const Color(0xFFE39A0C),
    warnBg: const Color(0xFFFFF4DC),
    warnText: const Color(0xFFA86A00),
    bad: const Color(0xFFD93B30),
    badBg: const Color(0xFFFDEAE8),
    unk: const Color(0xFF8A94A0),
    unkBg: const Color(0xFFEEF0F3),
    info: const Color(0xFF135AA6),
    infoBg: const Color(0xFFDEE6F1),
    chartOk: const Color(0xFF2F7FE0),
    chartWarn: const Color(0xFFE39A0C),
    chartAlarm: const Color(0xFFD93B30),
    chartGrid: const Color(0xFFE6E9EE),
    chartAxis: const Color(0xFF9AA1AC),
    scrim: const Color(0x700C1626),
    snackBg: const Color(0xFF1E2A3B),
    snackText: const Color(0xFFF2F5F9),
    snackAction: const Color(0xFF8CC0FF),
    press: const Color(0x14135AA6),
    tabBar: const Color(0xFFFFFFFF),
    tabBarBorder: null,
    shadow1: [
      kvCssShadow(0, 1, 2, const Color(0x0A122646)),
      kvCssShadow(0, 2, 10, const Color(0x0A122646)),
    ],
    shadow2: [
      kvCssShadow(0, 2, 6, const Color(0x0F122646)),
      kvCssShadow(0, 10, 28, const Color(0x17122646)),
    ],
    shadowTab: [
      kvCssShadow(0, 10, 34, const Color(0x29122C5A)),
      kvCssShadow(0, 2, 6, const Color(0x0F122C5A)),
    ],
    shadowSheet: [kvCssShadow(0, -8, 40, const Color(0x290C1626))],
    heroOverlay: const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0x8C08224A), Color(0x8C0D3F75), Color(0xEB082042)],
      stops: [0, 0.45, 1],
    ),
  );

  /// Тёмная тема.
  static final KvColors dark = KvColors(
    brightness: Brightness.dark,
    brand: const Color(0xFF4D9BFF),
    brandHover: const Color(0xFF79B4FF),
    brandDeep: const Color(0xFF2C7BE5),
    brandNavy: const Color(0xFF6C7BE0),
    brandSteel: const Color(0xFF5D93B5),
    tint: const Color(0xFF18355A),
    tint2: const Color(0xFF142B48),
    onBrand: const Color(0xFFFFFFFF),
    btnPrimary: const Color(0xFF2C7BE5),
    btnPrimaryPress: const Color(0xFF2468C4),
    bg: const Color(0xFF0B1626),
    surface: const Color(0xFF12233A),
    surface2: const Color(0xFF1A2F4B),
    surface3: const Color(0xFF223A5A),
    text: const Color(0xFFF2F5F9),
    text2: const Color(0xFFA9B6C6),
    text3: const Color(0xFF73859C),
    border: const Color(0xFF2A3F5C),
    divider: const Color(0xFF1E3350),
    ok: const Color(0xFF3DBE84),
    okBg: const Color(0xFF123A2D),
    warn: const Color(0xFFF2AE3A),
    warnBg: const Color(0x24F0AA3C),
    warnText: const Color(0xFFF5C36B),
    bad: const Color(0xFFF2655C),
    badBg: const Color(0xFF401D21),
    unk: const Color(0xFF9AA6B4),
    unkBg: const Color(0xFF1E2D42),
    info: const Color(0xFF4D9BFF),
    infoBg: const Color(0xFF18355A),
    chartOk: const Color(0xFF4D9BFF),
    chartWarn: const Color(0xFFF2AE3A),
    chartAlarm: const Color(0xFFF2655C),
    chartGrid: const Color(0xFF1F3451),
    chartAxis: const Color(0xFF73859C),
    scrim: const Color(0x9E020810),
    snackBg: const Color(0xFFE9EEF5),
    snackText: const Color(0xFF12233A),
    snackAction: const Color(0xFF135AA6),
    press: const Color(0x1A78AFFF),
    tabBar: const Color(0xFF1A2F4B),
    tabBarBorder: const Color(0x12FFFFFF),
    shadow1: [kvCssShadow(0, 1, 2, const Color(0x40000000))],
    shadow2: [kvCssShadow(0, 4, 22, const Color(0x59000000))],
    shadowTab: [
      kvCssShadow(0, 8, 24, const Color(0x80000000)),
      kvCssShadow(0, 2, 6, const Color(0x59000000)),
    ],
    shadowSheet: [kvCssShadow(0, -8, 40, const Color(0x73000000))],
    heroOverlay: const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0x99041022), Color(0x99082446), Color(0xF2051224)],
      stops: [0, 0.45, 1],
    ),
  );

  /// Тёмная тема или нет.
  bool get isDark => brightness == Brightness.dark;

  /// Цвет статуса: ok, warn, bad, info, unk.
  Color status(KvStatus status) => switch (status) {
        KvStatus.ok => ok,
        KvStatus.warn => warn,
        KvStatus.bad => bad,
        KvStatus.info => brand,
        KvStatus.unk => unk,
      };

  /// Подложка статуса.
  Color statusBg(KvStatus status) => switch (status) {
        KvStatus.ok => okBg,
        KvStatus.warn => warnBg,
        KvStatus.bad => badBg,
        KvStatus.info => infoBg,
        KvStatus.unk => unkBg,
      };

  /// Цвет текста статуса на его подложке (у «внимания» текст темнее значка).
  Color statusText(KvStatus status) => switch (status) {
        KvStatus.ok => ok,
        KvStatus.warn => warnText,
        KvStatus.bad => bad,
        KvStatus.info => brand,
        KvStatus.unk => text2,
      };

  @override
  KvColors copyWith() => this;

  @override
  KvColors lerp(covariant KvColors? other, double t) {
    if (other == null) {
      return this;
    }
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    List<BoxShadow> s(List<BoxShadow> a, List<BoxShadow> b) => BoxShadow.lerpList(a, b, t)!;
    return KvColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      brand: c(brand, other.brand),
      brandHover: c(brandHover, other.brandHover),
      brandDeep: c(brandDeep, other.brandDeep),
      brandNavy: c(brandNavy, other.brandNavy),
      brandSteel: c(brandSteel, other.brandSteel),
      tint: c(tint, other.tint),
      tint2: c(tint2, other.tint2),
      onBrand: c(onBrand, other.onBrand),
      btnPrimary: c(btnPrimary, other.btnPrimary),
      btnPrimaryPress: c(btnPrimaryPress, other.btnPrimaryPress),
      bg: c(bg, other.bg),
      surface: c(surface, other.surface),
      surface2: c(surface2, other.surface2),
      surface3: c(surface3, other.surface3),
      text: c(text, other.text),
      text2: c(text2, other.text2),
      text3: c(text3, other.text3),
      border: c(border, other.border),
      divider: c(divider, other.divider),
      ok: c(ok, other.ok),
      okBg: c(okBg, other.okBg),
      warn: c(warn, other.warn),
      warnBg: c(warnBg, other.warnBg),
      warnText: c(warnText, other.warnText),
      bad: c(bad, other.bad),
      badBg: c(badBg, other.badBg),
      unk: c(unk, other.unk),
      unkBg: c(unkBg, other.unkBg),
      info: c(info, other.info),
      infoBg: c(infoBg, other.infoBg),
      chartOk: c(chartOk, other.chartOk),
      chartWarn: c(chartWarn, other.chartWarn),
      chartAlarm: c(chartAlarm, other.chartAlarm),
      chartGrid: c(chartGrid, other.chartGrid),
      chartAxis: c(chartAxis, other.chartAxis),
      scrim: c(scrim, other.scrim),
      snackBg: c(snackBg, other.snackBg),
      snackText: c(snackText, other.snackText),
      snackAction: c(snackAction, other.snackAction),
      press: c(press, other.press),
      tabBar: c(tabBar, other.tabBar),
      tabBarBorder: Color.lerp(tabBarBorder, other.tabBarBorder, t),
      shadow1: s(shadow1, other.shadow1),
      shadow2: s(shadow2, other.shadow2),
      shadowTab: s(shadowTab, other.shadowTab),
      shadowSheet: s(shadowSheet, other.shadowSheet),
      heroOverlay: Gradient.lerp(heroOverlay, other.heroOverlay, t)!,
    );
  }
}

/// Статусы дизайна: норма, внимание, авария, информация (на ремонте), нет данных.
enum KvStatus {
  /// Норма.
  ok,

  /// Внимание.
  warn,

  /// Авария, критично.
  bad,

  /// Информация, на ремонте.
  info,

  /// Нет данных.
  unk;

  /// Статус по строке данных: 'ok', 'warn', 'bad', 'info', иначе «нет данных».
  static KvStatus parse(String? value) => switch (value) {
        'ok' => KvStatus.ok,
        'warn' => KvStatus.warn,
        'bad' => KvStatus.bad,
        'info' => KvStatus.info,
        _ => KvStatus.unk,
      };

  /// Статус значения относительно уставок, как KV.statusOf: выше аварийной - bad, выше предупреждения - warn.
  static KvStatus ofValue(double value, double? warn, double? alarm) {
    if (alarm != null && value > alarm) {
      return KvStatus.bad;
    }
    if (warn != null && value > warn) {
      return KvStatus.warn;
    }
    return KvStatus.ok;
  }
}
