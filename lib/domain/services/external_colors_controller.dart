import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infra/platform/color_sources.dart';
import '../models/app_settings.dart';
import '../models/external_colors.dart';
import 'settings_controller.dart';

/// Внешние цвета (акцент системы / доты) с обновлением на лету.
/// null - источник «Свой цвет» или ничего не найдено.
final externalColorsProvider =
    NotifierProvider<ExternalColorsController, ExternalColors?>(ExternalColorsController.new);

class ExternalColorsController extends Notifier<ExternalColors?> {
  final _subs = <StreamSubscription<Object?>>[];
  final _timers = <Timer>[];
  Process? _monitor;
  AppLifecycleListener? _life;

  /// Запасной опрос, секунд; 0 - только события (файлы, портал, фокус окна).
  int _pollEvery = 60;
  Timer? _debounce;
  bool _disposed = false;
  int _gen = 0;

  /// Источник выбран, но ничего не нашлось (для подсказки в настройках).
  bool notFound = false;

  @override
  ExternalColors? build() {
    final source = ref.watch(settingsProvider.select((s) => s.colorSource));
    final dotsPath = ref.watch(settingsProvider.select((s) => s.dotsPath));
    _pollEvery = ref.watch(settingsProvider.select((s) => s.colorPollSec));
    _disposed = false;
    _gen++;
    ref.onDispose(_stop);

    switch (source) {
      case ColorSource.preset:
        notFound = false;
        return null;
      case ColorSource.system:
        _reload(() => Platform.isWindows ? ColorSources.windowsAccent() : ColorSources.portalAccent());
        _watchSystem();
      case ColorSource.dots:
        _reload(() => ColorSources.dots(dotsPath));
        _watchDots(dotsPath);
    }
    return stateOrNull;
  }

  late Future<ExternalColors?> Function() _loader;

  void _reload(Future<ExternalColors?> Function() loader) {
    _loader = loader;
    _load();
  }

  Future<void> _load() async {
    final gen = _gen;
    final next = await _loader();
    // Источник успели сменить, пока читали - результат устарел.
    if (_disposed || gen != _gen) return;
    notFound = next == null;
    final cur = stateOrNull;
    // Не дёргаем перестроение темы, если ничего не поменялось.
    if (next == null && cur == null) {
      ref.notifyListeners();
      return;
    }
    if (next != null && next.sameAs(cur)) return;
    state = next;
  }

  /// Окно видно (не свёрнуто) - только тогда есть смысл опрашивать.
  static bool get _visible {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;
  }

  /// Редкий запасной опрос; пока окно свёрнуто - не опрашиваем совсем.
  void _poll() {
    if (_pollEvery <= 0) return;
    _timers.add(Timer.periodic(Duration(seconds: _pollEvery), (_) {
      if (_visible) _load();
    }));
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  void _watchSystem() {
    if (Platform.isWindows) {
      // Акцент меняют в «Параметрах» - значит, наше окно в это время не в фокусе.
      // Перечитываем реестр, когда окно снова получает фокус, плюс запасной опрос
      // с интервалом из настроек.
      // Раньше был опрос раз в 4 с: это запуск reg.exe 15 раз в минуту.
      _life = AppLifecycleListener(onResume: _schedule);
      _poll();
      return;
    }
    // Linux: слушаем сигнал SettingChanged портала, плюс редкий опрос на всякий случай.
    Process.start('gdbus', [
      'monitor', '--session',
      '--dest', 'org.freedesktop.portal.Desktop',
      '--object-path', '/org/freedesktop/portal/desktop',
    ]).then((p) {
      if (_disposed) {
        p.kill();
        return;
      }
      _monitor = p;
      _subs.add(p.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((chunk) {
        if (chunk.contains('accent-color') || chunk.contains('color-scheme')) _schedule();
      }));
    }).catchError((_) {});
    _poll();
  }

  void _watchDots(String customPath) {
    // Генераторы (matugen, wal, caelestia) обычно пишут во временный файл и
    // переименовывают - поэтому следим за папкой, а не за самим файлом.
    final dirs = <String>{};
    for (final path in ColorSources.dotsCandidates(customPath)) {
      final dir = File(path).parent;
      if (!dirs.add(dir.path) || !dir.existsSync()) continue;
      try {
        _subs.add(dir.watch().listen((e) {
          final p = e.path.replaceAll('\\', '/');
          if (p.endsWith('colors.json') || p.endsWith('scheme.json') || p == path) _schedule();
        }, onError: (_) {}));
      } catch (_) {}
    }
    // Запасной вариант: папки могло не быть при запуске, или ФС без inotify.
    // Обычно хватает слежения за папкой, поэтому опрос редкий.
    _life = AppLifecycleListener(onResume: _schedule);
    _poll();
  }

  /// Перечитать прямо сейчас (кнопка в настройках).
  Future<void> refresh() => _load();

  void _stop() {
    _disposed = true;
    _debounce?.cancel();
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _monitor?.kill();
    _monitor = null;
    _life?.dispose();
    _life = null;
  }
}
