import 'package:flutter/material.dart';

import '../../domain/models/external_colors.dart';

/// Предустановленные акцентные цвета (seed для Material You).
const seedPresets = <(String, int)>[
  ('Фиалка', 0xFF6750A4),
  ('Океан', 0xFF0061A4),
  ('Бирюза', 0xFF006A6A),
  ('Мята', 0xFF2E7D5B),
  ('Лайм', 0xFF5B6300),
  ('Янтарь', 0xFF8B5000),
  ('Коралл', 0xFFB3261E),
  ('Сакура', 0xFF9C4068),
  ('Графит', 0xFF5F6368),
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
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, width: 420),
    // Меню M3 (Expressive): скруглённый контейнер с внутренним отступом,
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
        minimumSize: const WidgetStatePropertyAll(Size(220, 44)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0.1),
        ),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return Colors.transparent;
          if (states.contains(WidgetState.pressed)) {
            return scheme.secondaryContainer.withValues(alpha: 0.85);
          }
          if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) {
            return scheme.secondaryContainer;
          }
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return scheme.onSurface.withValues(alpha: 0.38);
          if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) {
            return scheme.onSecondaryContainer;
          }
          return scheme.onSurface;
        }),
        iconColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return scheme.onSurface.withValues(alpha: 0.38);
          if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) {
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

/// Моноширинный шрифт терминала. Nerd Font будет вшит позже.
const monoFontFamily = 'Cascadia Mono';
const monoFontFallback = <String>[
  'JetBrainsMono Nerd Font',
  'JetBrains Mono',
  'Consolas',
  'DejaVu Sans Mono',
  'Liberation Mono',
  'monospace',
];

TextStyle monoStyle(BuildContext context, {double size = 13, Color? color}) =>
    TextStyle(
      fontFamily: monoFontFamily,
      fontFamilyFallback: monoFontFallback,
      fontSize: size,
      height: 1.35,
      color: color,
    );
