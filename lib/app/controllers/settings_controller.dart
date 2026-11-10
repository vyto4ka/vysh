import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infra/platform/desktop_env.dart';
import '../dependencies.dart';
import '../settings/app_settings.dart';

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class SettingsController extends Notifier<AppSettings> {
  late final _store = ref.read(documentStoreProvider('settings.json'));

  @override
  AppSettings build() {
    final raw = _store.readSync();
    final s = raw is Map<String, Object?> ? AppSettings.fromJson(raw) : const AppSettings();
    // На Android язык выбирается в системе (язык приложения), своей настройки нет.
    return DesktopEnv.isMobile ? s.copyWith(language: AppLanguage.auto) : s;
  }

  void setThemeMode(ThemeMode mode) => _update(state.copyWith(themeMode: mode));
  void setSeedColor(int color) => _update(state.copyWith(seedColor: color));
  void setCompact(bool value) => _update(state.copyWith(compact: value));
  void setTerminalFontSize(double v) {
    final next = state.copyWith(terminalFontSize: v.clamp(8, 32).toDouble());
    state = next;
    if (state.rememberTerminalFontSize) {
      _store.write(next.toJson());
    }
  }

  void setRememberTerminalFontSize(bool value) {
    final next = state.copyWith(rememberTerminalFontSize: value);
    state = next;
    if (value) {
      _store.write(next.toJson());
    } else {
      _store.write({...next.toJson(), 'terminalFontSize': 14});
    }
  }

  void setTerminalFont(String value) => _update(state.copyWith(terminalFont: value));
  void setTerminalLineHeight(double v) =>
      _update(state.copyWith(terminalLineHeight: (v.clamp(1.0, 1.6) * 20).round() / 20));

  void setCopyOnSelect(bool value) =>
      _update(state.copyWith(copyOnSelect: value));
  void setPingHosts(bool v) => _update(state.copyWith(pingHosts: v));
  void setRightClick(RightClickAction v) =>
      _update(state.copyWith(rightClick: v));
  void setDownloadsDir(String dir) => _update(state.copyWith(downloadsDir: dir));
  void setMiddleClickPaste(bool v) => _update(state.copyWith(middleClickPaste: v));
  void setCtrlVPaste(bool v) => _update(state.copyWith(ctrlVPaste: v));

  /// Стиль буфера: «как в Linux» (выделение копирует, средняя кнопка вставляет)
  /// или только клавишами. Правый клик подстраивается: в Linux-стиле он просто
  /// вставляет, в клавишном - копирует выделенное, а без выделения вставляет.
  void setLinuxClipboard(bool linux) => _update(state.copyWith(
        copyOnSelect: linux,
        middleClickPaste: linux,
        rightClick: state.rightClick == RightClickAction.menu
            ? RightClickAction.menu
            : (linux ? RightClickAction.paste : RightClickAction.smart),
      ));

  void setRightClickPaste(bool on) => _update(state.copyWith(
        rightClick: !on
            ? RightClickAction.menu
            : (state.copyOnSelect ? RightClickAction.paste : RightClickAction.smart),
      ));
  void setConfirmMultilinePaste(bool v) =>
      _update(state.copyWith(confirmMultilinePaste: v));
  void setColorSource(ColorSource v) => _update(state.copyWith(colorSource: v));
  void setDotsPath(String v) => _update(state.copyWith(dotsPath: v));
  void setCatppuccinFlavor(String v) => _update(state.copyWith(catppuccinFlavor: v));
  void setCatppuccinAccent(String v) => _update(state.copyWith(catppuccinAccent: v));
  void setServerStats(bool v) => _update(state.copyWith(serverStats: v));
  void setTitleBarMode(TitleBarMode v) =>
      _update(state.copyWith(titleBarMode: v));
  void setKeepAliveSeconds(int seconds) =>
      _update(state.copyWith(keepAliveSeconds: seconds));

  void setShowAccessoryBar(bool v) =>
      _update(state.copyWith(showAccessoryBar: v));
  void setLanguage(AppLanguage lang) => _update(state.copyWith(language: lang));
  void setScrollbackLines(int v) => _update(state.copyWith(scrollbackLines: v));
  void setPingIntervalSec(int v) => _update(state.copyWith(pingIntervalSec: v));
  void setPingOnlyVisible(bool v) => _update(state.copyWith(pingOnlyVisible: v));
  void setColorPollSec(int v) => _update(state.copyWith(colorPollSec: v));
  void setPauseHiddenTabs(bool v) => _update(state.copyWith(pauseHiddenTabs: v));
  void setRenderer(Renderer v) => _update(state.copyWith(renderer: v));

  void setCheckForUpdates(bool v) =>
      _update(state.copyWith(checkForUpdates: v));
  void setUpdatePromptDays(int days) =>
      _update(state.copyWith(updatePromptDays: days));

  void _update(AppSettings next) {
    state = next;
    final json = next.toJson();
    if (!next.rememberTerminalFontSize) {
      json['terminalFontSize'] = 14;
    }
    _store.write(json);
  }
}
