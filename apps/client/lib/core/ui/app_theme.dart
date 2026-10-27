import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

abstract final class AppSpacing {
  static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0, page = 24.0;
}

abstract final class AppRadius {
  static const small = 6.0, medium = 8.0, large = 10.0;
}

abstract final class AppMotion {
  static const hover = Duration(milliseconds: 120),
      transition = Duration(milliseconds: 180);
  static Duration duration(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : transition;
}

abstract final class AppBreakpoints {
  static const phone = 720.0, desktop = 1100.0, content = 1320.0;
}

abstract final class AppIconSize {
  static const small = 16.0, normal = 20.0, large = 28.0;
}

abstract final class Space {
  static const small = AppSpacing.sm,
      medium = AppSpacing.lg,
      large = AppSpacing.xl,
      page = AppSpacing.page,
      radius = AppRadius.large;
}

class AppDesignTokens extends ThemeExtension<AppDesignTokens> {
  const AppDesignTokens({
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.accent,
    required this.success,
    required this.warning,
    required this.danger,
  });
  final Color background,
      surface,
      surfaceElevated,
      border,
      textPrimary,
      textSecondary,
      accent,
      success,
      warning,
      danger;
  static const dark = AppDesignTokens(
    background: Color(0xFF101114),
    surface: Color(0xFF17191D),
    surfaceElevated: Color(0xFF1E2127),
    border: Color(0xFF343843),
    textPrimary: Color(0xFFF1F2F4),
    textSecondary: Color(0xFFA2A8B3),
    accent: Color(0xFF8196BE),
    success: Color(0xFFA4BEAC),
    warning: Color(0xFFD3BE95),
    danger: Color(0xFFD4959C),
  );
  static const light = AppDesignTokens(
    background: Color(0xFFF4F5F7),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFECEFF4),
    border: Color(0xFFD7DCE5),
    textPrimary: Color(0xFF1C2430),
    textSecondary: Color(0xFF5B6574),
    accent: Color(0xFF445E83),
    success: Color(0xFF456A52),
    warning: Color(0xFF7A602C),
    danger: Color(0xFF9F4653),
  );
  @override
  AppDesignTokens copyWith({
    Color? background,
    Color? surface,
    Color? surfaceElevated,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? accent,
    Color? success,
    Color? warning,
    Color? danger,
  }) => AppDesignTokens(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceElevated: surfaceElevated ?? this.surfaceElevated,
    border: border ?? this.border,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    accent: accent ?? this.accent,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
  );
  @override
  AppDesignTokens lerp(covariant AppDesignTokens? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppDesignTokens(
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      surfaceElevated: mix(surfaceElevated, other.surfaceElevated),
      border: mix(border, other.border),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      accent: mix(accent, other.accent),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
    );
  }
}

typedef DesignTokens = AppDesignTokens;

ThemeData appTheme(Brightness brightness, {bool compact = false}) {
  final t = brightness == Brightness.dark
      ? AppDesignTokens.dark
      : AppDesignTokens.light;
  final font = defaultTargetPlatform == TargetPlatform.windows
      ? 'Microsoft YaHei UI'
      : null;
  final scheme = ColorScheme.fromSeed(
    seedColor: t.accent,
    brightness: brightness,
    surface: t.surface,
    primary: t.accent,
    error: t.danger,
    onSurface: t.textPrimary,
    onSurfaceVariant: t.textSecondary,
    outline: t.border,
  );
  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.medium),
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: font,
  );
  return base.copyWith(
    scaffoldBackgroundColor: t.background,
    extensions: [t],
    textTheme: base.textTheme.apply(
      fontFamily: font,
      bodyColor: t.textPrimary,
      displayColor: t.textPrimary,
    ),
    dividerColor: t.border,
    visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
    listTileTheme: ListTileThemeData(
      dense: compact,
      minTileHeight: compact ? 48 : 56,
      contentPadding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
    ),
    dataTableTheme: DataTableThemeData(
      dataRowMinHeight: compact ? 40 : 48,
      dataRowMaxHeight: compact ? 48 : 56,
      headingRowHeight: compact ? 44 : 52,
      columnSpacing: compact ? 16 : 24,
    ),
    cardTheme: CardThemeData(
      color: t.surfaceElevated,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.large),
        side: BorderSide(color: t.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
        side: BorderSide(color: t.border),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.surface,
      contentPadding: EdgeInsets.all(compact ? 12 : 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.medium),
        borderSide: BorderSide(color: t.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.medium),
        borderSide: BorderSide(color: t.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.medium),
        borderSide: BorderSide(color: t.accent, width: 1.5),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: t.surface,
      indicatorColor: t.surfaceElevated,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: t.surface,
      indicatorColor: t.surfaceElevated,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.surfaceElevated,
      shape: shape,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: t.surfaceElevated,
      contentTextStyle: TextStyle(color: t.textPrimary),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
    ),
  );
}

/// Density changes spacing, not text legibility or minimum touch targets.
abstract final class AppDensity {
  static bool compact(BuildContext context) =>
      Theme.of(context).visualDensity == VisualDensity.compact;
  static double inset(BuildContext context) => compact(context) ? 12 : 16;
  static double gap(BuildContext context) => compact(context) ? 8 : 12;
  static double section(BuildContext context) => compact(context) ? 16 : 24;
}
