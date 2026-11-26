import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/settings/app_settings.dart';
import 'package:vysh/app/settings/window_chrome.dart';
import 'package:vysh/infra/platform/desktop_env.dart';

void main() {
  group('DesktopEnv.isTilingFor', () {
    test('распознаёт Hyprland, Sway и Niri по переменным сокетов', () {
      expect(
        DesktopEnv.isTilingFor(
          {'HYPRLAND_INSTANCE_SIGNATURE': 'abc'},
          isLinux: true,
        ),
        isTrue,
      );
      expect(
        DesktopEnv.isTilingFor({'SWAYSOCK': '/run/user/1000/sway'}, isLinux: true),
        isTrue,
      );
      expect(
        DesktopEnv.isTilingFor({'NIRI_SOCKET': '/run/user/1000/niri'}, isLinux: true),
        isTrue,
      );
    });

    test('распознаёт тайлинговый WM по XDG_CURRENT_DESKTOP и не срабатывает на GNOME/KDE', () {
      expect(
        DesktopEnv.isTilingFor({'XDG_CURRENT_DESKTOP': 'Hyprland'}, isLinux: true),
        isTrue,
      );
      expect(
        DesktopEnv.isTilingFor({'XDG_CURRENT_DESKTOP': 'river'}, isLinux: true),
        isTrue,
      );
      expect(
        DesktopEnv.isTilingFor({'XDG_CURRENT_DESKTOP': 'GNOME'}, isLinux: true),
        isFalse,
      );
      expect(
        DesktopEnv.isTilingFor({'XDG_CURRENT_DESKTOP': 'KDE'}, isLinux: true),
        isFalse,
      );
      expect(
        DesktopEnv.isTilingFor({'HYPRLAND_INSTANCE_SIGNATURE': 'abc'}, isLinux: false),
        isFalse,
      );
    });
  });

  group('hideNativeTitleBarFor', () {
    test('скрывает нативный заголовок на Wayland в тайлинговых WM во всех режимах', () {
      for (final mode in TitleBarMode.values) {
        expect(
          hideNativeTitleBarFor(
            mode,
            customTitleBar: mode == TitleBarMode.custom,
            isWayland: true,
            isTiling: true,
          ),
          isTrue,
        );
      }
    });

    test('на X11 в тайлинговых WM и в обычных DE следует customTitleBar', () {
      expect(
        hideNativeTitleBarFor(
          TitleBarMode.auto,
          customTitleBar: false,
          isWayland: false,
          isTiling: true,
        ),
        isFalse,
      );
      expect(
        hideNativeTitleBarFor(
          TitleBarMode.system,
          customTitleBar: false,
          isWayland: true,
          isTiling: false,
        ),
        isFalse,
      );
      expect(
        hideNativeTitleBarFor(
          TitleBarMode.custom,
          customTitleBar: true,
          isWayland: true,
          isTiling: false,
        ),
        isTrue,
      );
    });
  });
}
