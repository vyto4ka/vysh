import 'package:flutter/material.dart';

/// Что делает правый клик (и тап двумя пальцами по тачпаду) в терминале.
enum RightClickAction {
  /// Контекстное меню.
  menu,

  /// Вставка из буфера (как в PuTTY).
  paste,

  /// Есть выделение — копировать, нет — вставить (как в Windows Terminal).
  smart,
}

/// Откуда брать цвета интерфейса.
enum ColorSource {
  /// Свой акцентный цвет из настроек.
  preset,

  /// Акцент системы: Windows — цвет акцента, Linux — xdg-desktop-portal.
  system,

  /// Файлы дотов: свой colors.json, caelestia, pywal (Linux).
  dots,
}

/// Заголовок окна.
enum TitleBarMode {
  /// Свой на Windows, GNOME и KDE; системный в тайлинговых WM.
  auto,

  /// Рамку и заголовок рисует система / оконный менеджер.
  system,

  /// Свой заголовок с вкладками.
  custom,
}

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.seedColor = 0xFF6750A4,
    this.compact = false,
    this.terminalFontSize = 14,
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
    this.scrollbackLines = 10000,
    this.pingIntervalSec = 30,
    this.pingOnlyVisible = true,
    this.colorPollSec = 60,
    this.pauseHiddenTabs = true,
  });

  final ThemeMode themeMode;
  final int seedColor;
  final bool compact;
  final double terminalFontSize;
  final bool copyOnSelect;

  /// Папка для скачанных файлов; пусто — системная «Загрузки».
  final String downloadsDir;

  /// Проверять доступность хостов на главной (TCP к порту SSH раз в 30 с).
  final bool pingHosts;

  final RightClickAction rightClick;

  /// Вставка средней кнопкой мыши (как в Linux).
  final bool middleClickPaste;

  /// Ctrl+V вставляет (по умолчанию Ctrl+V уходит в терминал как есть).
  final bool ctrlVPaste;

  /// Спрашивать перед вставкой нескольких строк.
  final bool confirmMultilinePaste;

  final ColorSource colorSource;

  /// Свой путь к файлу цветов; пусто — искать автоматически.
  final String dotsPath;

  final TitleBarMode titleBarMode;

  // ── Производительность ──

  /// Строк истории терминала (для новых вкладок).
  final int scrollbackLines;

  /// Как часто проверять доступность хостов, секунд.
  final int pingIntervalSec;

  /// Проверять доступность, только пока список хостов на экране.
  final bool pingOnlyVisible;

  /// Запасной опрос цветов системы/дотов, секунд; 0 — только по событиям.
  final int colorPollSec;

  /// Останавливать анимации во вкладках, которые не на экране.
  final bool pauseHiddenTabs;

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? seedColor,
    bool? compact,
    double? terminalFontSize,
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
    int? scrollbackLines,
    int? pingIntervalSec,
    bool? pingOnlyVisible,
    int? colorPollSec,
    bool? pauseHiddenTabs,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        seedColor: seedColor ?? this.seedColor,
        compact: compact ?? this.compact,
        terminalFontSize: terminalFontSize ?? this.terminalFontSize,
        copyOnSelect: copyOnSelect ?? this.copyOnSelect,
        downloadsDir: downloadsDir ?? this.downloadsDir,
        pingHosts: pingHosts ?? this.pingHosts,
        rightClick: rightClick ?? this.rightClick,
        middleClickPaste: middleClickPaste ?? this.middleClickPaste,
        ctrlVPaste: ctrlVPaste ?? this.ctrlVPaste,
        confirmMultilinePaste: confirmMultilinePaste ?? this.confirmMultilinePaste,
        colorSource: colorSource ?? this.colorSource,
        dotsPath: dotsPath ?? this.dotsPath,
        titleBarMode: titleBarMode ?? this.titleBarMode,
        scrollbackLines: scrollbackLines ?? this.scrollbackLines,
        pingIntervalSec: pingIntervalSec ?? this.pingIntervalSec,
        pingOnlyVisible: pingOnlyVisible ?? this.pingOnlyVisible,
        colorPollSec: colorPollSec ?? this.colorPollSec,
        pauseHiddenTabs: pauseHiddenTabs ?? this.pauseHiddenTabs,
      );

  Map<String, Object?> toJson() => {
        'themeMode': themeMode.name,
        'seedColor': seedColor,
        'compact': compact,
        'terminalFontSize': terminalFontSize,
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
        'scrollbackLines': scrollbackLines,
        'pingIntervalSec': pingIntervalSec,
        'pingOnlyVisible': pingOnlyVisible,
        'colorPollSec': colorPollSec,
        'pauseHiddenTabs': pauseHiddenTabs,
      };

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
        themeMode: ThemeMode.values.firstWhere(
          (m) => m.name == json['themeMode'],
          orElse: () => ThemeMode.system,
        ),
        seedColor: (json['seedColor'] as num?)?.toInt() ?? 0xFF6750A4,
        compact: json['compact'] as bool? ?? false,
        terminalFontSize:
            ((json['terminalFontSize'] as num?)?.toDouble() ?? 14).clamp(8, 32).toDouble(),
        copyOnSelect: json['copyOnSelect'] as bool? ?? false,
        downloadsDir: json['downloadsDir'] as String? ?? '',
        pingHosts: json['pingHosts'] as bool? ?? true,
        rightClick: RightClickAction.values.firstWhere(
          (a) => a.name == json['rightClick'],
          orElse: () => RightClickAction.menu,
        ),
        middleClickPaste: json['middleClickPaste'] as bool? ?? false,
        ctrlVPaste: json['ctrlVPaste'] as bool? ?? false,
        confirmMultilinePaste: json['confirmMultilinePaste'] as bool? ?? true,
        colorSource: ColorSource.values.firstWhere(
          (c) => c.name == json['colorSource'],
          orElse: () => ColorSource.preset,
        ),
        dotsPath: json['dotsPath'] as String? ?? '',
        titleBarMode: TitleBarMode.values.firstWhere(
          (m) => m.name == json['titleBarMode'],
          orElse: () => TitleBarMode.auto,
        ),
        scrollbackLines:
            ((json['scrollbackLines'] as num?)?.toInt() ?? 10000).clamp(500, maxScrollback).toInt(),
        pingIntervalSec: ((json['pingIntervalSec'] as num?)?.toInt() ?? 30).clamp(5, 3600).toInt(),
        pingOnlyVisible: json['pingOnlyVisible'] as bool? ?? true,
        colorPollSec: ((json['colorPollSec'] as num?)?.toInt() ?? 60).clamp(0, 3600).toInt(),
        pauseHiddenTabs: json['pauseHiddenTabs'] as bool? ?? true,
      );

  /// Верхний предел истории: xterm2 сразу резервирует список на столько строк.
  static const maxScrollback = 1000000;
}
