import 'dart:io';

import '../../domain/models/app_settings.dart';

/// Что за рабочее окружение вокруг нас.
class DesktopEnv {
  DesktopEnv._();

  static String get _desktop =>
      '${Platform.environment['XDG_CURRENT_DESKTOP'] ?? ''}:'
              '${Platform.environment['XDG_SESSION_DESKTOP'] ?? ''}:'
              '${Platform.environment['DESKTOP_SESSION'] ?? ''}'
          .toLowerCase();

  /// Тайлинговые WM: свой заголовок там не нужен, окна раскладывает WM.
  static bool get isTiling {
    if (!Platform.isLinux) return false;
    if (Platform.environment['HYPRLAND_INSTANCE_SIGNATURE'] != null) return true;
    if (Platform.environment['SWAYSOCK'] != null) return true;
    if (Platform.environment['NIRI_SOCKET'] != null) return true;
    const tiling = [
      'hyprland', 'sway', 'i3', 'niri', 'river', 'bspwm', 'dwm', 'qtile',
      'awesome', 'xmonad', 'herbstluftwm', 'leftwm', 'wayfire', 'labwc', 'dwl',
    ];
    final d = _desktop;
    return tiling.any(d.contains);
  }

  /// Окружения, где свой заголовок с вкладками выглядит уместно.
  static bool get supportsCustomTitleBar {
    if (Platform.isWindows) return true;
    if (!Platform.isLinux || isTiling) return false;
    final d = _desktop;
    return d.contains('gnome') || d.contains('kde') || d.contains('plasma');
  }

  /// Wayland: позицию окна задавать нельзя - это решает композитор.
  static bool get isWayland =>
      Platform.isLinux && (Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty ?? false);

  /// Итог настройки «Заголовок окна».
  static bool useCustomTitleBar(TitleBarMode mode) => switch (mode) {
        TitleBarMode.custom => Platform.isWindows || Platform.isLinux,
        TitleBarMode.system => false,
        TitleBarMode.auto => supportsCustomTitleBar,
      };
}
