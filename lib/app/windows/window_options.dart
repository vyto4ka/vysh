import 'dart:ui';
import 'package:window_manager/window_manager.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/window_placement.dart';
import '../settings/app_settings.dart';
import '../settings/window_chrome.dart';

/// Главное и вынесенные окна используют одинаковые нативные параметры.
WindowOptions appWindowOptions(AppSettings settings, {Size? size}) {
  final hideNative = hideNativeTitleBar(settings.titleBarMode);
  return WindowOptions(
    title: 'vysh',
    size: size,
    minimumSize: WindowPlacement.minSize,
    titleBarStyle: hideNative ? TitleBarStyle.hidden : TitleBarStyle.normal,
    windowButtonVisibility: !hideNative || PlatformCapabilities.isMacOS,
  );
}
