import 'dart:io';

import 'package:flutter/foundation.dart';

/// Что умеет текущая платформа - вместо разбросанных `Platform.is…`.
/// Код спрашивает о возможности, а не об ОС: так видно, зачем проверка,
/// и новую платформу достаточно описать здесь.
///
/// Поставляемые цели - Windows, Linux, Android и macOS; web и остальные
/// Apple-платформы в проверках встречаются, но готовой поддержкой не считаются.
abstract final class PlatformCapabilities {
  static bool _is(bool Function() check) {
    if (kIsWeb) return false;
    try {
      return check();
    } catch (_) {
      return false;
    }
  }

  /// Своё окно с управлением через window_manager (размер, заголовок).
  static bool get desktopWindow =>
      _is(() => Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// Перетаскивание файлов между панелью SFTP и файловым менеджером
  /// (в безголовом flutter test нативного канала DropManager нет).
  static bool get fileDragAndDrop => _is(
    () =>
        !Platform.environment.containsKey('FLUTTER_TEST') &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS),
  );

  /// Перетаскивание наружу «виртуальным файлом»: получатель (Проводник,
  /// Finder) сам запрашивает содержимое после отпускания. Только файлы.
  static bool get dragOutVirtualFiles =>
      _is(() => Platform.isWindows || Platform.isMacOS);

  /// Перетаскивание наружу ссылкой на файл (text/uri-list, Linux): копия
  /// скачивается во временную папку, получатель забирает её оттуда.
  /// Работает и для папок.
  static bool get dragOutFileUri => _is(() => Platform.isLinux);

  /// Текущая ОС - macOS (нативный светофор, ⌘-шорткаты, свои пути).
  static bool get isMacOS => _is(() => Platform.isMacOS);

  /// Текущая ОС - Windows (буквы дисков `C:\`, пути с `\`, оболочка cmd/pwsh).
  static bool get isWindows => _is(() => Platform.isWindows);

  /// Края окна без системной рамки тянем сами (Linux; на Windows это делает система).
  static bool get selfResizedWindow => _is(() => Platform.isLinux);

  /// Акцент системы читается из реестра Windows.
  static bool get registryAccent => _is(() => Platform.isWindows);

  /// Акцент системы читается через xdg-desktop-portal.
  static bool get portalAccent => _is(() => Platform.isLinux);

  /// Цвета из файлов дотов (pywal, matugen, caelestia).
  static bool get dotfileColors => _is(() => Platform.isLinux);

  /// Скачанные файлы публикуются в общую папку Download (MediaStore).
  static bool get sharedDownloads => _is(() => Platform.isAndroid);

  /// Системные утилиты сети (ping, traceroute) и процессы.
  static bool get processes =>
      _is(() => !Platform.isAndroid && !Platform.isIOS);

  /// Шрифт терминала по умолчанию - свой из сборки: на macOS и Android
  /// подходящего моноширинного в системе нет.
  static bool get bundledMonoFont =>
      _is(() => Platform.isMacOS || Platform.isAndroid);

  /// Список установленных шрифтов можно прочитать из системных папок.
  static bool get systemFontList => desktopWindow;

  /// Ссылку можно открыть в браузере (на Android через ACTION_VIEW).
  static bool get openLinks => desktopWindow || sharedDownloads;

  /// Можно узнать расход памяти процесса (ProcessInfo).
  static bool get memoryInfo => !kIsWeb;
}
