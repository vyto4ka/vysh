import 'dart:ui';

import 'external_colors.dart';

/// Палитры Catppuccin (https://catppuccin.com/palette).
class CatppuccinFlavor {
  const CatppuccinFlavor(this.id, this.name, this.dark, this.c);

  final String id;
  final String name;
  final bool dark;

  /// Цвета по именам из официальной палитры.
  final Map<String, int> c;

  Color operator [](String key) => Color(c[key]!);
}

/// Акценты в порядке, как на сайте Catppuccin.
const catppuccinAccents = [
  'rosewater', 'flamingo', 'pink', 'mauve', 'red', 'maroon', 'peach',
  'yellow', 'green', 'teal', 'sky', 'sapphire', 'blue', 'lavender',
];

const catppuccinFlavors = [
  CatppuccinFlavor('latte', 'Latte', false, {
    'rosewater': 0xFFDC8A78, 'flamingo': 0xFFDD7878, 'pink': 0xFFEA76CB,
    'mauve': 0xFF8839EF, 'red': 0xFFD20F39, 'maroon': 0xFFE64553,
    'peach': 0xFFFE640B, 'yellow': 0xFFDF8E1D, 'green': 0xFF40A02B,
    'teal': 0xFF179299, 'sky': 0xFF04A5E5, 'sapphire': 0xFF209FB5,
    'blue': 0xFF1E66F5, 'lavender': 0xFF7287FD, 'text': 0xFF4C4F69,
    'subtext1': 0xFF5C5F77, 'subtext0': 0xFF6C6F85, 'overlay2': 0xFF7C7F93,
    'overlay1': 0xFF8C8FA1, 'overlay0': 0xFF9CA0B0, 'surface2': 0xFFACB0BE,
    'surface1': 0xFFBCC0CC, 'surface0': 0xFFCCD0DA, 'base': 0xFFEFF1F5,
    'mantle': 0xFFE6E9EF, 'crust': 0xFFDCE0E8,
  }),
  CatppuccinFlavor('frappe', 'Frappé', true, {
    'rosewater': 0xFFF2D5CF, 'flamingo': 0xFFEEBEBE, 'pink': 0xFFF4B8E4,
    'mauve': 0xFFCA9EE6, 'red': 0xFFE78284, 'maroon': 0xFFEA999C,
    'peach': 0xFFEF9F76, 'yellow': 0xFFE5C890, 'green': 0xFFA6D189,
    'teal': 0xFF81C8BE, 'sky': 0xFF99D1DB, 'sapphire': 0xFF85C1DC,
    'blue': 0xFF8CAAEE, 'lavender': 0xFFBABBF1, 'text': 0xFFC6D0F5,
    'subtext1': 0xFFB5BFE2, 'subtext0': 0xFFA5ADCE, 'overlay2': 0xFF949CBB,
    'overlay1': 0xFF838BA7, 'overlay0': 0xFF737994, 'surface2': 0xFF626880,
    'surface1': 0xFF51576D, 'surface0': 0xFF414559, 'base': 0xFF303446,
    'mantle': 0xFF292C3C, 'crust': 0xFF232634,
  }),
  CatppuccinFlavor('macchiato', 'Macchiato', true, {
    'rosewater': 0xFFF4DBD6, 'flamingo': 0xFFF0C6C6, 'pink': 0xFFF5BDE6,
    'mauve': 0xFFC6A0F6, 'red': 0xFFED8796, 'maroon': 0xFFEE99A0,
    'peach': 0xFFF5A97F, 'yellow': 0xFFEED49F, 'green': 0xFFA6DA95,
    'teal': 0xFF8BD5CA, 'sky': 0xFF91D7E3, 'sapphire': 0xFF7DC4E4,
    'blue': 0xFF8AADF4, 'lavender': 0xFFB7BDF8, 'text': 0xFFCAD3F5,
    'subtext1': 0xFFB8C0E0, 'subtext0': 0xFFA5ADCB, 'overlay2': 0xFF939AB7,
    'overlay1': 0xFF8087A2, 'overlay0': 0xFF6E738D, 'surface2': 0xFF5B6078,
    'surface1': 0xFF494D64, 'surface0': 0xFF363A4F, 'base': 0xFF24273A,
    'mantle': 0xFF1E2030, 'crust': 0xFF181926,
  }),
  CatppuccinFlavor('mocha', 'Mocha', true, {
    'rosewater': 0xFFF5E0DC, 'flamingo': 0xFFF2CDCD, 'pink': 0xFFF5C2E7,
    'mauve': 0xFFCBA6F7, 'red': 0xFFF38BA8, 'maroon': 0xFFEBA0AC,
    'peach': 0xFFFAB387, 'yellow': 0xFFF9E2AF, 'green': 0xFFA6E3A1,
    'teal': 0xFF94E2D5, 'sky': 0xFF89DCEB, 'sapphire': 0xFF74C7EC,
    'blue': 0xFF89B4FA, 'lavender': 0xFFB4BEFE, 'text': 0xFFCDD6F4,
    'subtext1': 0xFFBAC2DE, 'subtext0': 0xFFA6ADC8, 'overlay2': 0xFF9399B2,
    'overlay1': 0xFF7F849C, 'overlay0': 0xFF6C7086, 'surface2': 0xFF585B70,
    'surface1': 0xFF45475A, 'surface0': 0xFF313244, 'base': 0xFF1E1E2E,
    'mantle': 0xFF181825, 'crust': 0xFF11111B,
  }),
];

CatppuccinFlavor catppuccinFlavor(String id) =>
    catppuccinFlavors.firstWhere((f) => f.id == id, orElse: () => catppuccinFlavors.last);

/// Тема приложения и терминала из палитры Catppuccin.
ExternalColors catppuccinColors(String flavorId, String accentId) {
  final f = catppuccinFlavor(flavorId);
  final accent = catppuccinAccents.contains(accentId) ? accentId : 'mauve';
  final a = f[accent];
  // Второй и третий цвета схемы - соседи по палитре, чтобы не сливались с акцентом.
  final second = f[accent == 'lavender' ? 'blue' : 'lavender'];
  final third = f[accent == 'pink' ? 'mauve' : 'pink'];
  final base = f['base'], mantle = f['mantle'], crust = f['crust'];
  final s0 = f['surface0'], s1 = f['surface1'];
  Color mix(Color x, double t) => Color.lerp(base, x, t)!;

  final roles = <String, Color>{
    'primary': a,
    'onPrimary': f.dark ? crust : base,
    'primaryContainer': mix(a, 0.28),
    'onPrimaryContainer': f.dark ? a : f['text'],
    'secondary': second,
    'onSecondary': f.dark ? crust : base,
    'secondaryContainer': mix(second, 0.22),
    'onSecondaryContainer': f['text'],
    'tertiary': third,
    'onTertiary': f.dark ? crust : base,
    'tertiaryContainer': mix(third, 0.22),
    'onTertiaryContainer': f['text'],
    'error': f['red'],
    'onError': f.dark ? crust : base,
    'errorContainer': mix(f['red'], 0.22),
    'onErrorContainer': f['red'],
    'success': f['green'],
    'surface': base,
    'onSurface': f['text'],
    'onSurfaceVariant': f['subtext0'],
    'outline': f['overlay0'],
    'outlineVariant': s1,
    'inverseSurface': f['text'],
    'inverseOnSurface': base,
    'inversePrimary': a,
    'surfaceTint': a,
    if (f.dark) ...{
      'surfaceDim': crust,
      'surfaceBright': s0,
      'surfaceContainerLowest': crust,
      'surfaceContainerLow': mantle,
      'surfaceContainer': Color.lerp(base, s0, 0.4)!,
      'surfaceContainerHigh': s0,
      'surfaceContainerHighest': s1,
    } else ...{
      'surfaceDim': crust,
      'surfaceBright': Color.lerp(base, const Color(0xFFFFFFFF), 0.6)!,
      'surfaceContainerLowest': Color.lerp(base, const Color(0xFFFFFFFF), 0.6)!,
      'surfaceContainerLow': base,
      'surfaceContainer': mantle,
      'surfaceContainerHigh': crust,
      'surfaceContainerHighest': s0,
    },
  };
  // Ключи applyRoles ищет в нижнем регистре.
  final lower = {for (final e in roles.entries) e.key.toLowerCase(): e.value};

  final ansi = f.dark
      ? [
          f['surface1'], f['red'], f['green'], f['yellow'],
          f['blue'], f['pink'], f['teal'], f['subtext1'],
          f['surface2'], f['red'], f['green'], f['yellow'],
          f['blue'], f['pink'], f['teal'], f['subtext0'],
        ]
      : [
          f['subtext1'], f['red'], f['green'], f['yellow'],
          f['blue'], f['pink'], f['teal'], f['surface2'],
          f['subtext0'], f['red'], f['green'], f['yellow'],
          f['blue'], f['pink'], f['teal'], f['surface1'],
        ];

  return ExternalColors(
    seed: a,
    source: 'Catppuccin ${f.name}',
    roles: {f.dark ? Brightness.dark : Brightness.light: lower},
    ansi: ansi,
    terminalBackground: base,
    terminalForeground: f['text'],
    brightness: f.dark ? Brightness.dark : Brightness.light,
  );
}
