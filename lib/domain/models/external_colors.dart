import 'package:flutter/material.dart';

/// Цвета, пришедшие извне: акцент системы или файл дотов.
class ExternalColors {
  const ExternalColors({
    required this.seed,
    required this.source,
    this.path,
    this.roles = const {},
    this.ansi,
    this.terminalBackground,
    this.terminalForeground,
    this.brightness,
  });

  /// Основной цвет - из него строится вся схема Material You.
  final Color seed;

  /// Человекочитаемый источник: «Акцент Windows», «pywal», «caelestia»…
  final String source;

  /// Файл, из которого прочитано (для показа в настройках).
  final String? path;

  /// Готовые роли M3 по яркости (matugen, caelestia): перекрывают сгенерированные.
  final Map<Brightness, Map<String, Color>> roles;

  /// 16 цветов терминала (pywal, caelestia).
  final List<Color>? ansi;
  final Color? terminalBackground;
  final Color? terminalForeground;

  /// Режим, который задают доты (тёмный/светлый). null - не задают.
  final Brightness? brightness;

  bool sameAs(ExternalColors? o) =>
      o != null &&
      o.seed == seed &&
      o.source == source &&
      o.brightness == brightness &&
      o.terminalBackground == terminalBackground &&
      _listEq(o.ansi, ansi) &&
      _rolesEq(o.roles, roles);

  static bool _listEq(List<Color>? a, List<Color>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _rolesEq(Map<Brightness, Map<String, Color>> a, Map<Brightness, Map<String, Color>> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      final x = a[k]!, y = b[k];
      if (y == null || x.length != y.length) return false;
      for (final r in x.keys) {
        if (x[r] != y[r]) return false;
      }
    }
    return true;
  }
}

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
