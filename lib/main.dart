import 'dart:io';
import 'dart:convert';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'ui/shell/session_window.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'ui/vysh_app.dart';
import 'app/settings/app_settings.dart';
import 'app/settings/terminal_font.dart';
import 'app/windows/window_options.dart';
import 'app/windows/window_transport.dart';
import 'app/dependencies.dart';
import 'infra/platform/capabilities.dart';
import 'infra/platform/desktop_env.dart';
import 'infra/platform/font_files.dart';
import 'infra/platform/memory_trimmer.dart';
import 'infra/platform/window_placement.dart';
import 'infra/storage/app_paths.dart';
import 'infra/storage/json_store.dart';
import 'l10n/app_strings.dart';
import 'ui/dialogs/session_prompt_dialogs.dart';
import 'ui/widgets/modifiers.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  Modifiers.init();
  if (PlatformCapabilities.desktopWindow) {
    final native = await WindowController.fromCurrentEngine();
    final arguments = args.length == 2 && args.first == '--vysh-session-window'
        ? jsonDecode(args[1]) as Map<String, dynamic>
        : native.arguments.isNotEmpty
        ? jsonDecode(native.arguments) as Map<String, dynamic>
        : <String, dynamic>{};
    if (arguments.isNotEmpty) {
      final SessionWindowController controller =
          args.length == 2 && args.first == '--vysh-session-window'
          ? await ProcessSessionWindow.connect(arguments)
          : EngineSessionWindow(native);
      if (arguments['type'] == 'session') {
        // A child engine must never take the profile lock or initialize another
        // set of SSH sessions. Only display the main engine's existing session.
        await AppPaths.init();
        await _loadTerminalFont();
        final childSettings = AppSettings.fromJson(
          Map<String, Object?>.from(arguments['initial']['settings']),
        );
        _configureRenderer(childSettings, childWindow: true);
        final initialTitle = arguments['title'] as String?;
        final windowTitle = initialTitle == null || initialTitle.isEmpty
            ? 'vysh'
            : '$initialTitle — vysh';
        await windowManager.ensureInitialized();
        windowManager.waitUntilReadyToShow(
          appWindowOptions(
            childSettings,
            size: Size(
              (arguments['width'] as num).toDouble(),
              (arguments['height'] as num).toDouble(),
            ),
          ),
          () async {
            await windowManager.setTitle(windowTitle);
            final canPosition = !DesktopEnv.isWayland && !DesktopEnv.isTiling;
            final targetSize = Size(
              (arguments['width'] as num).toDouble(),
              (arguments['height'] as num).toDouble(),
            );
            if (canPosition) {
              await windowManager.setPosition(
                Offset(
                  (arguments['x'] as num).toDouble(),
                  (arguments['y'] as num).toDouble(),
                ),
              );
            }
            await windowManager.show();
            // GTK can apply its initial default size when mapping the window.
            // Reapply the requested geometry after the surface is visible.
            if (canPosition) {
              await windowManager.setBounds(
                Rect.fromLTWH(
                  (arguments['x'] as num).toDouble(),
                  (arguments['y'] as num).toDouble(),
                  targetSize.width,
                  targetSize.height,
                ),
              );
            } else if (!DesktopEnv.isTiling) {
              await windowManager.setSize(targetSize);
            }
            await windowManager.focus();
          },
        );
        runApp(SessionWindowApp(window: controller, arguments: arguments));
        return;
      }
    }
  }
  // Палитра Catppuccin - данные, а не пакет: её лицензию Flutter сам не найдёт.
  LicenseRegistry.addLicense(
    () => Stream.value(
      const LicenseEntryWithLineBreaks([
        'Catppuccin (palette)',
      ], _catppuccinLicense),
    ),
  );
  // Шрифт в сборке (assets/fonts) - тоже не пакет.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'JetBrains Mono (font)',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  await AppPaths.init();
  final profileFree = await AppPaths.lockProfile();

  if (PlatformCapabilities.desktopWindow) {
    await windowManager.ensureInitialized();

    if (!profileFree) {
      windowManager.waitUntilReadyToShow(
        const WindowOptions(size: Size(420, 220), center: true, title: 'vysh'),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      );
      runApp(const _AlreadyRunning());
      return;
    }

    // Настройки нужны до показа окна: от них зависит, чей будет заголовок.
    final raw = JsonStore('settings.json').readSync();
    final settings = raw is Map<String, Object?>
        ? AppSettings.fromJson(raw)
        : const AppSettings();

    _configureRenderer(settings);

    final options = appWindowOptions(settings);
    windowManager.waitUntilReadyToShow(options, () async {
      final maximize = await WindowPlacement.instance.restore();
      await windowManager.show();
      if (maximize) await windowManager.maximize();
      await windowManager.focus();
    });
  }

  if (!profileFree) {
    runApp(const _AlreadyRunning());
    return;
  }

  if (!PlatformCapabilities.desktopWindow) {
    MemoryTrimmer.configureStartupLimits();
  }

  await _loadTerminalFont();

  runApp(
    ProviderScope(
      overrides: [
        sessionPromptsProvider.overrideWithValue(
          DialogSessionPrompts(rootNavigatorKey),
        ),
      ],
      child: const VyshApp(),
    ),
  );
}

/// Запоминаем фактический рендерер и задаём экономные лимиты кэшей Skia
/// и ImageCache для всех окон (и главного, и вынесенных).
void _configureRenderer(AppSettings settings, {bool childWindow = false}) {
  startupRenderer = switch (Platform.environment['VYSH_RENDERER']) {
    'impeller' => Renderer.impeller,
    'skia' => Renderer.skia,
    _ => settings.renderer,
  };
  MemoryTrimmer.configureStartupLimits(
    childWindow: childWindow,
    useSkia: startupRenderer == Renderer.skia,
  );
}

/// Свой шрифт терминала (файл из профиля) нужен до первого кадра: иначе
/// терминал измерит ячейки запасным шрифтом.
Future<void> _loadTerminalFont() async {
  try {
    final raw = JsonStore('settings.json').readSync();
    if (raw is! Map<String, Object?>) return;
    final file = TerminalFont.fileName(AppSettings.fromJson(raw).terminalFont);
    if (file != null && file.isNotEmpty) await FontFiles.loadByFileName(file);
  } catch (_) {}
}

/// Второй экземпляр: только сообщение, профиль не трогаем.
class _AlreadyRunning extends StatelessWidget {
  const _AlreadyRunning();

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.forLanguage(AppLanguage.auto);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(s.alreadyRunning, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => exit(0), child: Text(s.close)),
            ],
          ),
        ),
      ),
    );
  }
}

const _catppuccinLicense = '''MIT License

Copyright (c) 2021 Catppuccin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''';
