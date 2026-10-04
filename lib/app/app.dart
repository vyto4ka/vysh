import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../domain/models/app_settings.dart';
import '../domain/services/external_colors_controller.dart';
import '../domain/services/settings_controller.dart';
import '../ui/shell/app_shell.dart';
import '../ui/shell/ui_state.dart';
import '../ui/theme/app_theme.dart';

/// Корневой навигатор - через него сессии показывают диалоги
/// (пароль, ключ сервера) из не-UI кода.
final rootNavigatorKey = GlobalKey<NavigatorState>();

class VyshApp extends ConsumerWidget {
  const VyshApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ext = ref.watch(externalColorsProvider);

    // Переключили режим заголовка - применяем сразу, без перезапуска.
    ref.listen<bool>(customTitleBarProvider, (_, custom) {
      if (Platform.isWindows || Platform.isLinux) {
        windowManager.setTitleBarStyle(
          custom ? TitleBarStyle.hidden : TitleBarStyle.normal,
          windowButtonVisibility: !custom,
        );
      }
    });

    final e = s.colorSource == ColorSource.preset ? null : ext;
    final seed = e?.seed ?? Color(s.seedColor);

    // Доты задают тёмный/светлый режим - следуем им, если тема «Системная».
    var mode = s.themeMode;
    final dotsBrightness = e?.brightness;
    if (mode == ThemeMode.system && dotsBrightness != null) {
      mode = dotsBrightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
    }

    ThemeData theme(Brightness b) => buildTheme(
          seed: seed,
          brightness: b,
          compact: s.compact,
          roles: e?.roles[b],
        );

    return MaterialApp(
      title: 'vysh',
      navigatorKey: rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeAnimationDuration: const Duration(milliseconds: 300),
      home: const AppShell(),
    );
  }
}
