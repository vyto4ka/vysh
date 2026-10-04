import 'package:flutter/material.dart';
import 'package:xterm2/xterm.dart';

import '../../domain/models/external_colors.dart';

/// Тема терминала из текущей M3-схемы: фон/текст/курсор - от акцента
/// приложения, 16 ANSI-цветов - сбалансированная палитра под тёмную/светлую тему.
TerminalTheme terminalThemeFor(ColorScheme scheme, [ExternalColors? ext]) {
  final dark = scheme.brightness == Brightness.dark;
  // Палитра из дотов (pywal, caelestia) - только если доты того же режима.
  final fromDots = ext?.ansi != null && (ext!.brightness == null || ext.brightness == scheme.brightness);
  final p = fromDots ? ext.ansi! : (dark ? _darkAnsi : _lightAnsi);
  return TerminalTheme(
    cursor: scheme.primary,
    selection: scheme.primary.withValues(alpha: 0.32),
    foreground: (fromDots ? ext.terminalForeground : null) ?? scheme.onSurface,
    background: terminalBackgroundFor(scheme, ext),
    black: p[0],
    red: p[1],
    green: p[2],
    yellow: p[3],
    blue: p[4],
    magenta: p[5],
    cyan: p[6],
    white: p[7],
    brightBlack: p[8],
    brightRed: p[9],
    brightGreen: p[10],
    brightYellow: p[11],
    brightBlue: p[12],
    brightMagenta: p[13],
    brightCyan: p[14],
    brightWhite: p[15],
    searchHitBackground: scheme.tertiaryContainer,
    searchHitBackgroundCurrent: scheme.tertiary,
    searchHitForeground: scheme.onTertiaryContainer,
  );
}

// Палитры в духе Catppuccin Mocha / Latte.
const _darkAnsi = <Color>[
  Color(0xFF45475A), Color(0xFFF38BA8), Color(0xFFA6E3A1), Color(0xFFF9E2AF),
  Color(0xFF89B4FA), Color(0xFFF5C2E7), Color(0xFF94E2D5), Color(0xFFBAC2DE),
  Color(0xFF585B70), Color(0xFFF7A1B8), Color(0xFFB9EBB5), Color(0xFFFBE9C3),
  Color(0xFFA3C4FB), Color(0xFFF8D2EE), Color(0xFFAEEADF), Color(0xFFCDD6F4),
];

const _lightAnsi = <Color>[
  Color(0xFF5C5F77), Color(0xFFD20F39), Color(0xFF40A02B), Color(0xFFDF8E1D),
  Color(0xFF1E66F5), Color(0xFFEA76CB), Color(0xFF179299), Color(0xFFACB0BE),
  Color(0xFF6C6F85), Color(0xFFDE293E), Color(0xFF49AF3D), Color(0xFFEEA02D),
  Color(0xFF456EED), Color(0xFFFE85D8), Color(0xFF2D9FA8), Color(0xFFBCC0CC),
];

/// Фон терминала: из дотов (если режим совпадает) или самый тёмный/светлый слой темы.
Color terminalBackgroundFor(ColorScheme scheme, [ExternalColors? ext]) {
  final match = ext != null && (ext.brightness == null || ext.brightness == scheme.brightness);
  return (match ? ext.terminalBackground : null) ?? scheme.surfaceContainerLowest;
}
