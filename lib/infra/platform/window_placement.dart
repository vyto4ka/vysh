import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../storage/json_store.dart';
import 'desktop_env.dart';

/// Запоминает размер, позицию и «развёрнуто» окна между запусками.
///
/// * Windows / X11: восстанавливаем и позицию, если она всё ещё на видимом мониторе;
///   иначе - по центру монитора, где сейчас курсор.
/// * Wayland и тайлинговые WM: только размер - позицию решает композитор.
class WindowPlacement with WindowListener {
  WindowPlacement._();
  static final instance = WindowPlacement._();

  static const defaultSize = Size(1200, 760);
  static const minSize = Size(640, 420);

  final _store = JsonStore('window.json');
  Timer? _debounce;
  Rect? _normalBounds;
  bool _maximized = false;

  bool get _canPosition => !DesktopEnv.isWayland && !DesktopEnv.isTiling;

  /// Вызывать до показа окна. Возвращает true, если окно нужно развернуть
  /// (делается после show - иначе Windows покажет его раньше времени).
  Future<bool> restore() async {
    final raw = _store.readSync();
    Rect? saved;
    var maximized = false;
    if (raw is Map) {
      final x = (raw['x'] as num?)?.toDouble();
      final y = (raw['y'] as num?)?.toDouble();
      final w = (raw['w'] as num?)?.toDouble();
      final h = (raw['h'] as num?)?.toDouble();
      if (w != null && h != null && w >= minSize.width && h >= minSize.height) {
        saved = Rect.fromLTWH(x ?? 0, y ?? 0, w, h);
      }
      maximized = raw['maximized'] == true;
    }

    final size = saved?.size ?? defaultSize;
    if (_canPosition && saved != null && await _isVisible(saved)) {
      await windowManager.setBounds(saved);
    } else {
      await windowManager.setSize(size);
      if (_canPosition) await windowManager.center();
    }
    _normalBounds = await windowManager.getBounds();
    windowManager.addListener(this);
    _maximized = maximized && !DesktopEnv.isTiling;
    return _maximized;
  }

  /// Окно хотя бы частично (заголовок) попадает на один из мониторов.
  Future<bool> _isVisible(Rect r) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      for (final d in displays) {
        final pos = d.visiblePosition ?? Offset.zero;
        final size = d.visibleSize ?? d.size;
        final screen = pos & size;
        final titleStrip = Rect.fromLTWH(r.left + 40, r.top, r.width - 80, 40);
        final overlap = screen.intersect(titleStrip);
        if (overlap.width > 100 && overlap.height > 20) return true;
      }
    } catch (_) {}
    return false;
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _save);
  }

  Future<void> _save() async {
    try {
      _maximized = await windowManager.isMaximized();
      // Пока окно развёрнуто - помним прежние «нормальные» размеры.
      if (!_maximized && !await windowManager.isMinimized()) {
        _normalBounds = await windowManager.getBounds();
      }
      final b = _normalBounds;
      if (b == null) return;
      await _store.write({
        if (_canPosition) 'x': b.left,
        if (_canPosition) 'y': b.top,
        'w': b.width,
        'h': b.height,
        'maximized': _maximized,
      });
    } catch (_) {}
  }

  @override
  void onWindowMoved() => _scheduleSave();
  @override
  void onWindowResized() => _scheduleSave();
  // На Linux «…ed»-событий нет - слушаем непрерывные и откладываем сохранение.
  @override
  void onWindowMove() {
    if (Platform.isLinux) _scheduleSave();
  }

  @override
  void onWindowResize() {
    if (Platform.isLinux) _scheduleSave();
  }

  @override
  void onWindowMaximize() => _scheduleSave();
  @override
  void onWindowUnmaximize() => _scheduleSave();
}
