import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models/external_colors.dart';
import '../storage/app_paths.dart';

/// Чтение цветов из системы и файлов дотов.
class ColorSources {
  ColorSources._();

  static String get _home {
    final env = Platform.environment;
    return env['HOME'] ?? env['USERPROFILE'] ?? '';
  }

  static String _expand(String p) => p.startsWith('~') ? '$_home${p.substring(1)}' : p;

  // ─── Системный акцент ─────────────────────────────────────────────

  /// Windows: HKCU\Software\Microsoft\Windows\DWM\AccentColor (DWORD в формате ABGR).
  static Future<ExternalColors?> windowsAccent() async {
    try {
      final r = await Process.run(
        'reg',
        ['query', r'HKCU\Software\Microsoft\Windows\DWM', '/v', 'AccentColor'],
      );
      final m = RegExp(r'0x([0-9a-fA-F]{1,8})').firstMatch('${r.stdout}');
      if (m == null) return null;
      final v = int.parse(m.group(1)!, radix: 16);
      final color = Color.fromARGB(255, v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF);
      return ExternalColors(seed: color, source: 'Акцент Windows');
    } catch (_) {
      return null;
    }
  }

  /// Linux: xdg-desktop-portal, org.freedesktop.appearance accent-color (GNOME 47+, KDE 6).
  static Future<ExternalColors?> portalAccent() async {
    try {
      final r = await Process.run('gdbus', [
        'call', '--session',
        '--dest', 'org.freedesktop.portal.Desktop',
        '--object-path', '/org/freedesktop/portal/desktop',
        '--method', 'org.freedesktop.portal.Settings.ReadOne',
        'org.freedesktop.appearance', 'accent-color',
      ]);
      final nums = RegExp(r'-?\d+(?:\.\d+)?(?:e-?\d+)?')
          .allMatches('${r.stdout}')
          .map((m) => double.parse(m.group(0)!))
          .toList();
      if (r.exitCode != 0 || nums.length < 3) return null;
      final rgb = nums.sublist(nums.length - 3);
      // Вне 0..1 - портал сообщает «акцент не задан».
      if (rgb.any((x) => x < 0 || x > 1)) return null;
      int ch(double x) => (x * 255).round().clamp(0, 255).toInt();
      return ExternalColors(
        seed: Color.fromARGB(255, ch(rgb[0]), ch(rgb[1]), ch(rgb[2])),
        source: 'Акцент системы (xdg-portal)',
      );
    } catch (_) {
      return null;
    }
  }

  // ─── Файлы дотов ──────────────────────────────────────────────────

  /// Где искать файлы цветов, по приоритету.
  static List<String> dotsCandidates(String customPath) => [
        if (customPath.trim().isNotEmpty) _expand(customPath.trim()),
        AppPaths.file('colors.json').path,
        '$_stateHome/caelestia/scheme.json',
        '$_cacheHome/wal/colors.json',
      ];

  static String get _stateHome {
    final x = Platform.environment['XDG_STATE_HOME'];
    return (x != null && x.isNotEmpty) ? x : '$_home/.local/state';
  }

  static String get _cacheHome {
    final x = Platform.environment['XDG_CACHE_HOME'];
    return (x != null && x.isNotEmpty) ? x : '$_home/.cache';
  }

  /// Первый найденный и разобранный файл из [dotsCandidates].
  static Future<ExternalColors?> dots(String customPath) async {
    for (final path in dotsCandidates(customPath)) {
      final f = File(path);
      if (!await f.exists()) continue;
      try {
        final parsed = parse(jsonDecode(await f.readAsString()), path);
        if (parsed != null) return parsed;
      } catch (_) {
        // Файл пишется прямо сейчас или битый - пробуем следующий.
      }
    }
    return null;
  }

  /// Разбор форматов: pywal, caelestia, свой (matugen/wallust-шаблон vysh).
  static ExternalColors? parse(Object? json, String path) {
    if (json is! Map) return null;
    final name = path.replaceAll('\\', '/');

    // pywal: {"special": {...}, "colors": {"color0": "#..", ...}}
    final special = json['special'];
    final walColors = json['colors'];
    if (special is Map && walColors is Map && walColors.containsKey('color0')) {
      final ansi = [for (var i = 0; i < 16; i++) parseColor(walColors['color$i'])];
      if (ansi.any((c) => c == null)) return null;
      final list = ansi.cast<Color>();
      final bg = parseColor(special['background']) ?? list[0];
      final fg = parseColor(special['foreground']) ?? list[7];
      return ExternalColors(
        // Самый насыщенный из цветов 1-6 - он и будет акцентом.
        seed: _mostSaturated(list.sublist(1, 7)),
        source: 'pywal',
        path: name,
        ansi: list,
        terminalBackground: bg,
        terminalForeground: fg,
        brightness: _brightnessOf(bg),
      );
    }

    // caelestia ("colours") или свой формат ("colors"/"dark"/"light").
    final mode = '${json['mode'] ?? ''}'.toLowerCase();
    final modeBrightness = mode == 'dark'
        ? Brightness.dark
        : mode == 'light'
            ? Brightness.light
            : null;

    final roles = <Brightness, Map<String, Color>>{};
    final flat = json['colours'] ?? json['colors'];
    if (flat is Map) {
      roles[modeBrightness ?? Brightness.dark] = _roleMap(flat);
    }
    for (final (key, b) in [('dark', Brightness.dark), ('light', Brightness.light)]) {
      final m = json[key];
      if (m is Map) roles[b] = _roleMap(m);
    }

    final active = roles[modeBrightness] ?? roles[Brightness.dark] ?? roles[Brightness.light];
    final seed = parseColor(json['seed']) ??
        active?['primary'] ??
        (flat is Map ? parseColor(flat['primary_paletteKeyColor']) : null);
    if (seed == null) return null;

    // Терминал: term0..term15 (caelestia) или "terminal": {"colors": [...]}.
    List<Color>? ansi;
    Color? termBg, termFg;
    if (flat is Map && flat.containsKey('term0')) {
      final t = [for (var i = 0; i < 16; i++) parseColor(flat['term$i'])];
      if (t.every((c) => c != null)) ansi = t.cast<Color>();
    }
    final term = json['terminal'];
    if (term is Map) {
      final cs = term['colors'];
      if (cs is List && cs.length >= 16) {
        final t = [for (final c in cs.take(16)) parseColor(c)];
        if (t.every((c) => c != null)) ansi = t.cast<Color>();
      }
      termBg = parseColor(term['background']);
      termFg = parseColor(term['foreground']);
    }

    final isCaelestia = name.contains('/caelestia/');
    return ExternalColors(
      seed: seed,
      source: isCaelestia ? 'caelestia' : 'Файл цветов',
      path: name,
      roles: roles,
      ansi: ansi,
      terminalBackground: termBg,
      terminalForeground: termFg,
      brightness: modeBrightness ??
          (active?['surface'] != null ? _brightnessOf(active!['surface']!) : null),
    );
  }

  /// Ключи приводим к виду «onprimarycontainer»: snake_case и camelCase совпадут.
  static Map<String, Color> _roleMap(Map m) {
    final out = <String, Color>{};
    m.forEach((k, v) {
      final c = parseColor(v);
      if (c != null) out['$k'.replaceAll('_', '').toLowerCase()] = c;
    });
    return out;
  }

  /// `#rrggbb`, `rrggbb`, `#aarrggbb`, `0xff..`.
  static Color? parseColor(Object? v) {
    if (v is! String) return null;
    var s = v.trim().toLowerCase();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.startsWith('0x')) s = s.substring(2);
    if (!RegExp(r'^[0-9a-f]{6}([0-9a-f]{2})?$').hasMatch(s)) return null;
    final n = int.parse(s, radix: 16);
    return s.length == 6 ? Color(0xFF000000 | n) : Color(n);
  }

  static Brightness _brightnessOf(Color c) =>
      c.computeLuminance() < 0.4 ? Brightness.dark : Brightness.light;

  static Color _mostSaturated(List<Color> colors) {
    double sat(Color c) {
      final mx = math.max(c.r, math.max(c.g, c.b));
      final mn = math.min(c.r, math.min(c.g, c.b));
      return mx == 0 ? 0 : (mx - mn) / mx;
    }

    return colors.reduce((a, b) => sat(a) >= sat(b) ? a : b);
  }
}
