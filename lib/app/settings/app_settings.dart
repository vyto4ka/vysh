import 'package:flutter/material.dart';

import '../../domain/models/json_read.dart';

/// Что делает правый клик (и тап двумя пальцами по тачпаду) в терминале.
enum RightClickAction {
  /// Контекстное меню.
  menu,

  /// Вставка из буфера (как в PuTTY).
  paste,

  /// Есть выделение - копировать, нет - вставить (как в Windows Terminal).
  smart,
}

/// Откуда брать цвета интерфейса.
enum ColorSource {
  /// Свой акцентный цвет из настроек.
  preset,

  /// Акцент системы: Windows - цвет акцента, Linux - xdg-desktop-portal.
  system,

  /// Файлы дотов: свой colors.json, caelestia, pywal (Linux).
  dots,

  /// Готовая тема Catppuccin (вариант и акцент - в настройках).
  catppuccin,
}

/// Движок отрисовки Flutter. Выбирается до запуска движка (windows/runner/main.cpp,
/// linux/runner/my_application.cc), поэтому меняется только после перезапуска.
enum Renderer {
  /// Экономнее по памяти; так рисовал Flutter до 3.47.
  skia,

  /// Новый движок Flutter: без подтормаживаний при первой анимации, но
  /// держит больше памяти под текстуры.
  impeller,
}

/// Движок, с которым приложение запущено (пишется в main.dart).
Renderer startupRenderer = Renderer.skia;

/// Заголовок окна.
enum TitleBarMode {
  /// Свой на Windows, GNOME и KDE; системный в тайлинговых WM.
  auto,

  /// Рамку и заголовок рисует система / оконный менеджер.
  system,

  /// Свой заголовок с вкладками.
  custom,
}

/// Язык интерфейса приложения.
enum AppLanguage {
  /// Автоматически по языку системы Android / ОС.
  auto,

  /// Русский язык.
  ru,

  /// English.
  en,
}

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.seedColor = 0xFF6750A4,
    this.compact = false,
    this.terminalFontSize = 14,
    this.rememberTerminalFontSize = true,
    this.terminalFont = '',
    this.terminalLineHeight = 1.2,
    this.copyOnSelect = false,
    this.downloadsDir = '',
    this.pingHosts = true,
    this.rightClick = RightClickAction.menu,
    this.middleClickPaste = false,
    this.ctrlVPaste = false,
    this.confirmMultilinePaste = true,
    this.colorSource = ColorSource.preset,
    this.dotsPath = '',
    this.titleBarMode = TitleBarMode.auto,
    this.keepAliveSeconds = 60,
    this.appIcon = 'monet',
    this.showAccessoryBar = true,
    this.language = AppLanguage.auto,
    this.scrollbackLines = 10000,
    this.pingIntervalSec = 30,
    this.pingOnlyVisible = true,
    this.colorPollSec = 60,
    this.pauseHiddenTabs = true,
    this.renderer = Renderer.skia,
    this.catppuccinFlavor = 'mocha',
    this.catppuccinAccent = 'mauve',
    this.serverStats = true,
    this.updatePromptDays = 3,
  });

  final ThemeMode themeMode;
  final int seedColor;
  final bool compact;
  final double terminalFontSize;
  final bool rememberTerminalFontSize;

  /// Шрифт терминала: '' - по умолчанию, `system:<семейство>`,
  /// `file:<имя файла>` (см. TerminalFont).
  final String terminalFont;

  /// Межстрочный интервал терминала, 1.0-1.6.
  final double terminalLineHeight;

  final bool copyOnSelect;

  /// Иконка приложения (системная Monet-иконка на Android).
  final String appIcon;

  /// Показывать строку горячих клавиш терминала (Ctrl, Esc, стрелки) над клавиатурой.
  final bool showAccessoryBar;

  /// Проверять доступность хостов на главной (TCP к порту SSH раз в 30 с).
  final bool pingHosts;

  /// Интервал KeepAlive пакетов в SSH-сессиях в секундах (0 - выключен, 15, 30, 60, 120, 300).
  /// По умолчанию 60 секунд (1 минута).
  final int keepAliveSeconds;

  final RightClickAction rightClick;

  /// Папка для скачанных файлов; пусто - системная «Загрузки».
  final String downloadsDir;

  /// Вставка средней кнопкой мыши (как в Linux).
  final bool middleClickPaste;

  /// Ctrl+V вставляет (по умолчанию Ctrl+V уходит в терминал как есть).
  final bool ctrlVPaste;

  /// Спрашивать перед вставкой нескольких строк.
  final bool confirmMultilinePaste;

  final ColorSource colorSource;

  /// Свой путь к файлу цветов; пусто - искать автоматически.
  final String dotsPath;

  final TitleBarMode titleBarMode;

  /// Язык интерфейса ('auto', 'ru', 'en').
  final AppLanguage language;

  // ── Производительность ──

  /// Строк истории терминала (для новых вкладок).
  final int scrollbackLines;

  /// Как часто проверять доступность хостов, секунд.
  final int pingIntervalSec;

  /// Проверять доступность, только пока список хостов на экране.
  final bool pingOnlyVisible;

  /// Запасной опрос цветов системы/дотов, секунд; 0 - только по событиям.
  final int colorPollSec;

  /// Останавливать анимации во вкладках, которые не на экране.
  final bool pauseHiddenTabs;

  /// Движок отрисовки (применяется после перезапуска).
  final Renderer renderer;

  /// Catppuccin: latte, frappe, macchiato, mocha.
  final String catppuccinFlavor;

  /// Catppuccin: акцент (mauve, blue, pink…).
  final String catppuccinAccent;

  /// Нагрузка сервера в строке состояния терминала.
  final bool serverStats;

  /// Как часто всплывать окном о новой версии, дней (1, 3, 7).
  final int updatePromptDays;

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? seedColor,
    bool? compact,
    double? terminalFontSize,
    bool? rememberTerminalFontSize,
    String? terminalFont,
    double? terminalLineHeight,
    bool? copyOnSelect,
    String? downloadsDir,
    bool? pingHosts,
    RightClickAction? rightClick,
    bool? middleClickPaste,
    bool? ctrlVPaste,
    bool? confirmMultilinePaste,
    ColorSource? colorSource,
    String? dotsPath,
    TitleBarMode? titleBarMode,
    int? keepAliveSeconds,
    String? appIcon,
    bool? showAccessoryBar,
    AppLanguage? language,
    int? scrollbackLines,
    int? pingIntervalSec,
    bool? pingOnlyVisible,
    int? colorPollSec,
    bool? pauseHiddenTabs,
    Renderer? renderer,
    String? catppuccinFlavor,
    String? catppuccinAccent,
    bool? serverStats,
    int? updatePromptDays,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        seedColor: seedColor ?? this.seedColor,
        compact: compact ?? this.compact,
        terminalFontSize: terminalFontSize ?? this.terminalFontSize,
        rememberTerminalFontSize:
            rememberTerminalFontSize ?? this.rememberTerminalFontSize,
        terminalFont: terminalFont ?? this.terminalFont,
        terminalLineHeight: terminalLineHeight ?? this.terminalLineHeight,
        copyOnSelect: copyOnSelect ?? this.copyOnSelect,
        downloadsDir: downloadsDir ?? this.downloadsDir,
        pingHosts: pingHosts ?? this.pingHosts,
        rightClick: rightClick ?? this.rightClick,
        middleClickPaste: middleClickPaste ?? this.middleClickPaste,
        ctrlVPaste: ctrlVPaste ?? this.ctrlVPaste,
        confirmMultilinePaste:
            confirmMultilinePaste ?? this.confirmMultilinePaste,
        colorSource: colorSource ?? this.colorSource,
        dotsPath: dotsPath ?? this.dotsPath,
        titleBarMode: titleBarMode ?? this.titleBarMode,
        keepAliveSeconds: keepAliveSeconds ?? this.keepAliveSeconds,
        appIcon: appIcon ?? this.appIcon,
        showAccessoryBar: showAccessoryBar ?? this.showAccessoryBar,
        language: language ?? this.language,
        scrollbackLines: scrollbackLines ?? this.scrollbackLines,
        pingIntervalSec: pingIntervalSec ?? this.pingIntervalSec,
        pingOnlyVisible: pingOnlyVisible ?? this.pingOnlyVisible,
        colorPollSec: colorPollSec ?? this.colorPollSec,
        pauseHiddenTabs: pauseHiddenTabs ?? this.pauseHiddenTabs,
        renderer: renderer ?? this.renderer,
        catppuccinFlavor: catppuccinFlavor ?? this.catppuccinFlavor,
        catppuccinAccent: catppuccinAccent ?? this.catppuccinAccent,
        serverStats: serverStats ?? this.serverStats,
        updatePromptDays: updatePromptDays ?? this.updatePromptDays,
      );

  Map<String, Object?> toJson() => {
        'themeMode': themeMode.name,
        'seedColor': seedColor,
        'compact': compact,
        'terminalFontSize': terminalFontSize,
        'rememberTerminalFontSize': rememberTerminalFontSize,
        'terminalFont': terminalFont,
        'terminalLineHeight': terminalLineHeight,
        'copyOnSelect': copyOnSelect,
        'downloadsDir': downloadsDir,
        'pingHosts': pingHosts,
        'rightClick': rightClick.name,
        'middleClickPaste': middleClickPaste,
        'ctrlVPaste': ctrlVPaste,
        'confirmMultilinePaste': confirmMultilinePaste,
        'colorSource': colorSource.name,
        'dotsPath': dotsPath,
        'titleBarMode': titleBarMode.name,
        'keepAliveSeconds': keepAliveSeconds,
        'appIcon': appIcon,
        'showAccessoryBar': showAccessoryBar,
        'language': language.name,
        'scrollbackLines': scrollbackLines,
        'pingIntervalSec': pingIntervalSec,
        'pingOnlyVisible': pingOnlyVisible,
        'colorPollSec': colorPollSec,
        'pauseHiddenTabs': pauseHiddenTabs,
        // Читается и нативным кодом до запуска движка - ключ не переименовывать.
        'renderer': renderer.name,
        'catppuccinFlavor': catppuccinFlavor,
        'catppuccinAccent': catppuccinAccent,
        'serverStats': serverStats,
        'updatePromptDays': updatePromptDays,
      };

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
        themeMode: ThemeMode.values.firstWhere(
          (m) => m.name == json['themeMode'],
          orElse: () => ThemeMode.system,
        ),
        seedColor: json.integer('seedColor') ?? 0xFF6750A4,
        compact: json.boolean('compact') ?? false,
        terminalFontSize: (json.boolean('rememberTerminalFontSize') ?? true)
            ? (json.dbl('terminalFontSize') ?? 14)
                .clamp(8, 32)
                .toDouble()
            : 14,
        rememberTerminalFontSize:
            json.boolean('rememberTerminalFontSize') ?? true,
        terminalFont: json.str('terminalFont') ?? '',
        terminalLineHeight: _finite(json.dbl('terminalLineHeight'), 1.2)
            .clamp(1.0, 1.6)
            .toDouble(),
        copyOnSelect: json.boolean('copyOnSelect') ?? false,
        downloadsDir: json.str('downloadsDir') ?? '',
        pingHosts: json.boolean('pingHosts') ?? true,
        rightClick: RightClickAction.values.firstWhere(
          (a) => a.name == json['rightClick'],
          orElse: () => RightClickAction.menu,
        ),
        middleClickPaste: json.boolean('middleClickPaste') ?? false,
        ctrlVPaste: json.boolean('ctrlVPaste') ?? false,
        confirmMultilinePaste: json.boolean('confirmMultilinePaste') ?? true,
        colorSource: ColorSource.values.firstWhere(
          (c) => c.name == json['colorSource'],
          orElse: () => ColorSource.preset,
        ),
        dotsPath: json.str('dotsPath') ?? '',
        titleBarMode: TitleBarMode.values.firstWhere(
          (m) => m.name == json['titleBarMode'],
          orElse: () => TitleBarMode.auto,
        ),
        keepAliveSeconds: json.integer('keepAliveSeconds') ?? 60,
        appIcon: json.str('appIcon') ?? 'monet',
        showAccessoryBar: json.boolean('showAccessoryBar') ?? true,
        language: AppLanguage.values.firstWhere(
          (l) => l.name == json['language'],
          orElse: () => AppLanguage.auto,
        ),
        scrollbackLines: (json.integer('scrollbackLines') ?? 10000)
            .clamp(500, maxScrollback)
            .toInt(),
        pingIntervalSec: (json.integer('pingIntervalSec') ?? 30)
            .clamp(5, 3600)
            .toInt(),
        pingOnlyVisible: json.boolean('pingOnlyVisible') ?? true,
        colorPollSec: (json.integer('colorPollSec') ?? 60)
            .clamp(0, 3600)
            .toInt(),
        pauseHiddenTabs: json.boolean('pauseHiddenTabs') ?? true,
        renderer: json['renderer'] == 'impeller'
            ? Renderer.impeller
            : Renderer.skia,
        catppuccinFlavor: json.str('catppuccinFlavor') ?? 'mocha',
        catppuccinAccent: json.str('catppuccinAccent') ?? 'mauve',
        serverStats: json.boolean('serverStats') ?? true,
        updatePromptDays: switch (json.integer('updatePromptDays')) {
          1 => 1,
          7 => 7,
          _ => 3,
        },
      );

  static double _finite(double? v, double fallback) =>
      v != null && v.isFinite ? v : fallback;

  /// Верхний предел истории: xterm2 сразу резервирует список на столько строк.
  static const maxScrollback = 1000000;
}
