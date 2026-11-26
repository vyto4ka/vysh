import 'package:flutter/foundation.dart';

import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import 'app_settings.dart';

/// Итог настройки «Заголовок окна»: рисуем ли свой заголовок с вкладками.
bool useCustomTitleBar(TitleBarMode mode) => switch (mode) {
      TitleBarMode.custom => PlatformCapabilities.desktopWindow,
      TitleBarMode.system => false,
      TitleBarMode.auto => DesktopEnv.supportsCustomTitleBar,
    };

/// Скрываем ли нативный заголовок окна (GTK HeaderBar / Win32 / NSWindow).
/// На Wayland в тайлинговых WM GTK3 рисует собственный CSD-заголовок с
/// кнопками окна (свернуть/развернуть/закрыть), поскольку не поддерживает
/// серверные декорации. Скрываем его, чтобы окном управлял сам WM.
bool hideNativeTitleBar(TitleBarMode mode) => hideNativeTitleBarFor(
      mode,
      customTitleBar: useCustomTitleBar(mode),
      isWayland: DesktopEnv.isWayland,
      isTiling: DesktopEnv.isTiling,
    );

@visibleForTesting
bool hideNativeTitleBarFor(
  TitleBarMode mode, {
  required bool customTitleBar,
  required bool isWayland,
  required bool isTiling,
}) =>
    customTitleBar || (isWayland && isTiling);
