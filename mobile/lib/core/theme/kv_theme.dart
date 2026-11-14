import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kv_colors.dart';
import 'kv_typography.dart';

export 'kv_colors.dart';
export 'kv_tokens.dart';
export 'kv_typography.dart';

/// Темы приложения: Material 3, связанный с токенами дизайна, и расширения [KvColors] и [KvTextStyles].
abstract final class KvTheme {
  /// Светлая тема.
  static final ThemeData light = _build(KvColors.light);

  /// Тёмная тема.
  static final ThemeData dark = _build(KvColors.dark);

  static ThemeData _build(KvColors c) {
    final KvTextStyles t = KvTextStyles.of(c);
    final ColorScheme scheme = ColorScheme(
      brightness: c.brightness,
      primary: c.btnPrimary,
      onPrimary: c.onBrand,
      primaryContainer: c.tint,
      onPrimaryContainer: c.brand,
      secondary: c.brand,
      onSecondary: c.onBrand,
      secondaryContainer: c.tint2,
      onSecondaryContainer: c.brand,
      tertiary: c.ok,
      onTertiary: c.onBrand,
      error: c.bad,
      onError: c.onBrand,
      errorContainer: c.badBg,
      onErrorContainer: c.bad,
      surface: c.surface,
      onSurface: c.text,
      onSurfaceVariant: c.text2,
      surfaceContainerLowest: c.surface,
      surfaceContainerLow: c.bg,
      surfaceContainer: c.surface2,
      surfaceContainerHigh: c.surface2,
      surfaceContainerHighest: c.surface3,
      outline: c.border,
      outlineVariant: c.divider,
      shadow: const Color(0xFF000000),
      scrim: c.scrim,
      inverseSurface: c.snackBg,
      onInverseSurface: c.snackText,
      inversePrimary: c.snackAction,
    );
    final TextTheme textTheme = TextTheme(
      displayLarge: t.numXl,
      displayMedium: t.numL,
      displaySmall: t.numM,
      headlineLarge: t.title,
      headlineMedium: t.title,
      headlineSmall: t.hdr,
      titleLarge: t.hdr,
      titleMedium: t.h2,
      titleSmall: t.bodyM,
      bodyLarge: t.body,
      bodyMedium: t.base,
      bodySmall: t.caption,
      labelLarge: t.btn,
      labelMedium: t.label,
      labelSmall: t.micro,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: c.brightness,
      colorScheme: scheme,
      fontFamily: KvTextStyles.kvFontFamily,
      textTheme: textTheme,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      hoverColor: Colors.transparent,
      focusColor: c.press,
      dividerColor: c.divider,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.brand,
        selectionColor: c.brand.withValues(alpha: 0.24),
        selectionHandleColor: c.brand,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        foregroundColor: c.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        systemOverlayStyle: c.isDark ? KvSystemUi.lightIcons : KvSystemUi.darkIcons,
      ),
      extensions: <ThemeExtension<dynamic>>[c, t],
    );
  }
}

/// Стили системных панелей: прозрачные, меняется только цвет значков строки состояния и навигации.
abstract final class KvSystemUi {
  /// Светлые значки: экраны поверх фото, камеры и тёмная тема.
  static const SystemUiOverlayStyle lightIcons = SystemUiOverlayStyle(
    statusBarColor: Color(0x00000000),
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Color(0x00000000),
    systemNavigationBarDividerColor: Color(0x00000000),
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );

  /// Тёмные значки: светлые экраны.
  static const SystemUiOverlayStyle darkIcons = SystemUiOverlayStyle(
    statusBarColor: Color(0x00000000),
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Color(0x00000000),
    systemNavigationBarDividerColor: Color(0x00000000),
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );

  /// Стиль панелей: [lightStatus] - светлые значки сверху, [lightHome] - светлый индикатор и значки снизу.
  static SystemUiOverlayStyle of({required bool lightStatus, required bool lightHome}) {
    final SystemUiOverlayStyle top = lightStatus ? lightIcons : darkIcons;
    return top.copyWith(systemNavigationBarIconBrightness: lightHome ? Brightness.light : Brightness.dark);
  }
}

/// Быстрый доступ к токенам дизайна из виджетов.
extension KvThemeContext on BuildContext {
  /// Цвета и тени текущей темы.
  KvColors get kv => Theme.of(this).extension<KvColors>()!;

  /// Шкала шрифта текущей темы.
  KvTextStyles get kvText => Theme.of(this).extension<KvTextStyles>()!;

  /// Анимации отключены системой (уменьшение движения).
  bool get kvReduceMotion => MediaQuery.maybeDisableAnimationsOf(this) ?? false;
}
