import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../infra/platform/capabilities.dart';
import '../infra/platform/font_files.dart';
import '../app/settings/app_settings.dart';
import '../app/settings/terminal_font.dart';
import '../app/controllers/external_colors_controller.dart';
import '../app/controllers/monet_colors_provider.dart';
import '../app/controllers/settings_controller.dart';
import '../infra/platform/desktop_env.dart';
import 'shell/app_shell.dart';
import 'shell/ui_state.dart';
import 'theme/app_theme.dart';

/// Корневой навигатор - через него сессии показывают диалоги
/// (пароль, ключ сервера) из не-UI кода.
final rootNavigatorKey = GlobalKey<NavigatorState>();

class VyshApp extends ConsumerWidget {
  const VyshApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Корень приложения перестраивается только от настроек темы и языка.
    final s = ref.watch(
      settingsProvider.select(
        (s) => (
          colorSource: s.colorSource,
          seedColor: s.seedColor,
          themeMode: s.themeMode,
          compact: s.compact,
          language: s.language,
        ),
      ),
    );
    final ext = ref.watch(externalColorsProvider);
    ref.listen(settingsProvider.select((s) => s.terminalFont), (_, font) {
      final file = TerminalFont.fileName(font);
      if (file != null && file.isNotEmpty) {
        FontFiles.loadByFileName(file).ignore();
      }
    });
    final monet = ref.watch(monetColorsProvider).value;

    // Переключили режим заголовка - применяем сразу, без перезапуска.
    ref.listen<bool>(customTitleBarProvider, (_, custom) {
      if (PlatformCapabilities.desktopWindow) {
        // macOS: светофор остаётся всегда, прячем только полосу заголовка.
        windowManager.setTitleBarStyle(
          custom ? TitleBarStyle.hidden : TitleBarStyle.normal,
          windowButtonVisibility: PlatformCapabilities.isMacOS || !custom,
        );
      }
    });

    // Android: Monet (при недоступности фиолетовый) или Catppuccin.
    // Прочие платформы: свой цвет / акцент системы / доты / Catppuccin.
    final catppuccin = s.colorSource == ColorSource.catppuccin;
    final e = DesktopEnv.isMobile
        ? (catppuccin ? ext : null)
        : (s.colorSource == ColorSource.preset ? null : ext);
    final seed = DesktopEnv.isMobile && e == null
        ? (monet?.accentPrimary ?? const Color(0xFF6750A4))
        : (e?.seed ?? Color(s.seedColor));

    // Доты задают тёмный/светлый режим - следуем им, если тема «Системная».
    var mode = s.themeMode;
    final dotsBrightness = e?.brightness;
    // Catppuccin: у каждого варианта свой режим (Latte светлый, прочие тёмные).
    if (dotsBrightness != null &&
        (mode == ThemeMode.system || s.colorSource == ColorSource.catppuccin)) {
      mode = dotsBrightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light;
    }

    ThemeData theme(Brightness b) =>
        _cachedTheme(seed, b, s.compact, e?.roles[b]);

    return MaterialApp(
      title: 'vysh',
      navigatorKey: rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      // Без плавного перехода: анимация перестраивала всё окно вместе с
      // терминалом на каждом кадре и заметно тормозила.
      themeAnimationDuration: Duration.zero,
      locale: s.language == AppLanguage.ru
          ? const Locale('ru')
          : (s.language == AppLanguage.en ? const Locale('en') : null),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeResolutionCallback: (locale, supportedLocales) {
        if (locale != null) {
          final code = locale.languageCode.toLowerCase();
          if (code.startsWith('ru') ||
              code.startsWith('be') ||
              code.startsWith('uk')) {
            return const Locale('ru');
          }
        }
        return const Locale('en');
      },
      home: const AppShell(),
    );
  }
}

/// Тема пересчитывается только при смене цветов, а не при любой настройке
/// (ColorScheme.fromSeed и ThemeData дорогие, а VyshApp следит за всеми настройками).
final _themeCache = <(int, Brightness, bool, Map<String, Color>?), ThemeData>{};

ThemeData _cachedTheme(
  Color seed,
  Brightness b,
  bool compact,
  Map<String, Color>? roles,
) {
  final key = (seed.toARGB32(), b, compact, roles);
  final hit = _themeCache[key];
  if (hit != null) return hit;
  if (_themeCache.length > 8) _themeCache.clear();
  return _themeCache[key] = buildTheme(
    seed: seed,
    brightness: b,
    compact: compact,
    roles: roles,
  );
}
