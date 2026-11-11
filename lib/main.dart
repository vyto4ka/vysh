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
import 'app/settings/window_chrome.dart';
import 'app/dependencies.dart';
import 'infra/platform/font_files.dart';
import 'infra/platform/window_placement.dart';
import 'infra/storage/app_paths.dart';
import 'infra/storage/json_store.dart';
import 'l10n/app_strings.dart';
import 'ui/dialogs/session_prompt_dialogs.dart';
import 'ui/widgets/modifiers.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  Modifiers.init();
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    final controller = await WindowController.fromCurrentEngine();
    if (controller.arguments.isNotEmpty) {
      final arguments =
          jsonDecode(controller.arguments) as Map<String, dynamic>;
      if (arguments['type'] == 'session') {
        // A child engine must never take the profile lock or initialize another
        // set of SSH sessions. Only display the main engine's existing session.
        await AppPaths.init();
        await _loadTerminalFont();
        await windowManager.ensureInitialized();
        windowManager.waitUntilReadyToShow(
          WindowOptions(
            size: Size(
              (arguments['width'] as num).toDouble(),
              (arguments['height'] as num).toDouble(),
            ),
            minimumSize: Size(540, 340),
            titleBarStyle: TitleBarStyle.normal,
          ),
          () async {
            await windowManager.setTitle('${arguments['title']} — vysh');
            await windowManager.setPosition(
              Offset(
                (arguments['x'] as num).toDouble(),
                (arguments['y'] as num).toDouble(),
              ),
            );
            await windowManager.show();
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

  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    await windowManager.ensureInitialized();

    // Настройки нужны до показа окна: от них зависит, чей будет заголовок.
    final raw = JsonStore('settings.json').readSync();
    final settings = raw is Map<String, Object?>
        ? AppSettings.fromJson(raw)
        : const AppSettings();
    final custom = useCustomTitleBar(settings.titleBarMode);

    // Движок уже выбран нативным кодом и передан в VYSH_RENDERER - запоминаем
    // фактический, чтобы настройки могли подсказать «нужен перезапуск».
    startupRenderer = switch (Platform.environment['VYSH_RENDERER']) {
      'impeller' => Renderer.impeller,
      'skia' => Renderer.skia,
      _ => settings.renderer,
    };
    if (startupRenderer == Renderer.skia) {
      // Кэш текстур Skia по умолчанию растёт до 48 байт на пиксель окна:
      // для развёрнутого окна на большом мониторе это сотни мегабайт.
      // Интерфейсу vysh с запасом хватает 64 МБ.
      SystemChannels.skia
          .invokeMethod<void>('Skia.setResourceCacheMaxBytes', 64 << 20)
          .catchError((_) {});
    }

    final options = WindowOptions(
      title: 'vysh',
      minimumSize: WindowPlacement.minSize,
      titleBarStyle: custom ? TitleBarStyle.hidden : TitleBarStyle.normal,
      // macOS: светофор остаётся всегда, прячем только полосу заголовка.
      windowButtonVisibility: !custom || Platform.isMacOS,
    );
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
