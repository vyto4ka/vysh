import 'dart:io';

/// Где vysh хранит свои файлы (хосты, настройки, known_hosts).
///
/// Всегда в профиле пользователя - неважно, откуда запущен exe.
/// Поэтому обновление = удалить старую папку с программой и распаковать
/// новую: хосты и настройки останутся.
///
/// * Windows: `%APPDATA%\vysh`
/// * Linux: `$XDG_CONFIG_HOME/vysh` (обычно `~/.config/vysh`)
class AppPaths {
  AppPaths._();

  static Directory? _configDir;

  static Directory get configDir =>
      _configDir ?? Directory(_join(Directory.systemTemp.path, 'vysh'));

  static Future<void> init() async {
    final dir = Directory(_resolve());
    await dir.create(recursive: true);
    _configDir = dir;
  }

  static File file(String name) => File(_join(configDir.path, name));

  static String _resolve() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final base = env['APPDATA'] ?? env['USERPROFILE'] ?? '.';
      return _join(base, 'vysh');
    }
    final xdg = env['XDG_CONFIG_HOME'];
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : _join(env['HOME'] ?? '.', '.config');
    return _join(base, 'vysh');
  }

  static String _join(String a, String b) => '$a${Platform.pathSeparator}$b';
}
