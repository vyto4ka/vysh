import 'package:flutter/material.dart';

import '../../app/settings/terminal_font.dart';
import '../../infra/platform/desktop_env.dart';

/// Предустановленные акцентные цвета (seed для Material You);
/// названия - AppStrings.accentNames в том же порядке.
const seedPresets = <int>[
  0xFF6750A4, // фиалка
  0xFF0061A4, // океан
  0xFF006A6A, // бирюза
  0xFF2E7D5B, // мята
  0xFF5B6300, // лайм
  0xFF8B5000, // янтарь
  0xFFB3261E, // коралл
  0xFF9C4068, // сакура
  0xFF5F6368, // графит
];

/// Цвета меток хостов.
const hostColors = <int>[
  0xFF6750A4,
  0xFF0061A4,
  0xFF006A6A,
  0xFF2E7D5B,
  0xFF8B5000,
  0xFFB3261E,
  0xFF9C4068,
  0xFF5F6368,
];

ThemeData buildTheme({
  required Color seed,
  required Brightness brightness,
  bool compact = false,
  Map<String, Color>? roles,
}) {
  // Схема из одного цвета (как Material You), поверх - готовые роли из дотов.
  final scheme = applyRoles(
    ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
    roles,
  );
  final radius = BorderRadius.circular(16);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: radius),
      clipBehavior: Clip.antiAlias,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      groupAlignment: -1,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size.square(compact ? 40 : 48)),
        iconSize: const WidgetStatePropertyAll(20),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
    ),
    // Уведомление компактное и по центру, а не полоса на всю ширину окна.
    // На телефоне ширина экрана меньше 420 - там обычная плашка.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: DesktopEnv.isMobile ? null : 420,
    ),
    // Меню: скруглённый контейнер с внутренним отступом,
    // пункты - «пилюли» с тональной подсветкой при наведении.
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(3),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(220, 48)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
          ),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return Colors.transparent;
          if (states.contains(WidgetState.pressed)) {
            return scheme.secondaryContainer.withValues(alpha: 0.85);
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return scheme.secondaryContainer;
          }
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return scheme.onSurface.withValues(alpha: 0.38);
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return scheme.onSecondaryContainer;
          }
          return scheme.onSurface;
        }),
        iconColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return scheme.onSurface.withValues(alpha: 0.38);
          }
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return scheme.onSecondaryContainer;
          }
          return scheme.onSurfaceVariant;
        }),
        // Без лишнего «серого» слоя поверх - подсветку даёт backgroundColor.
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
  );
}

/// Моноширинный шрифт интерфейса (пути, адреса): шрифт терминала по
/// умолчанию, без выбора пользователя. Терминал - см. [TerminalFont].
TextStyle monoStyle(BuildContext context, {double size = 13, Color? color}) =>
    TextStyle(
      fontFamily: TerminalFont.defaultFamily,
      fontFamilyFallback: TerminalFont.fallbackOf(''),
      fontSize: size,
      height: 1.35,
      color: color,
    );

/// Накладывает готовые роли M3 на сгенерированную схему.
ColorScheme applyRoles(ColorScheme s, Map<String, Color>? r) {
  if (r == null || r.isEmpty) return s;
  Color? c(String k) => r[k.toLowerCase()];
  return s.copyWith(
    primary: c('primary'),
    onPrimary: c('onPrimary'),
    primaryContainer: c('primaryContainer'),
    onPrimaryContainer: c('onPrimaryContainer'),
    secondary: c('secondary'),
    onSecondary: c('onSecondary'),
    secondaryContainer: c('secondaryContainer'),
    onSecondaryContainer: c('onSecondaryContainer'),
    tertiary: c('tertiary'),
    onTertiary: c('onTertiary'),
    tertiaryContainer: c('tertiaryContainer'),
    onTertiaryContainer: c('onTertiaryContainer'),
    error: c('error'),
    onError: c('onError'),
    errorContainer: c('errorContainer'),
    onErrorContainer: c('onErrorContainer'),
    surface: c('surface') ?? c('background'),
    onSurface: c('onSurface') ?? c('onBackground'),
    surfaceDim: c('surfaceDim'),
    surfaceBright: c('surfaceBright'),
    surfaceContainerLowest: c('surfaceContainerLowest'),
    surfaceContainerLow: c('surfaceContainerLow'),
    surfaceContainer: c('surfaceContainer'),
    surfaceContainerHigh: c('surfaceContainerHigh'),
    surfaceContainerHighest: c('surfaceContainerHighest'),
    onSurfaceVariant: c('onSurfaceVariant'),
    outline: c('outline'),
    outlineVariant: c('outlineVariant'),
    inverseSurface: c('inverseSurface'),
    onInverseSurface: c('inverseOnSurface') ?? c('onInverseSurface'),
    inversePrimary: c('inversePrimary'),
    surfaceTint: c('surfaceTint'),
  );
}
