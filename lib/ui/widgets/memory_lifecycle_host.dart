import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../infra/platform/capabilities.dart';
import '../../infra/platform/memory_trimmer.dart';

/// Отслеживает сворачивание окна и уход приложения в фон:
/// - отключает тикеры анимаций через [TickerMode], пока окно не видно;
/// - сбрасывает кэши и отдаёт свободную память ОС через [MemoryTrimmer].
class MemoryLifecycleHost extends StatefulWidget {
  const MemoryLifecycleHost({super.key, required this.child});

  final Widget child;

  @override
  State<MemoryLifecycleHost> createState() => _MemoryLifecycleHostState();
}

class _MemoryLifecycleHostState extends State<MemoryLifecycleHost>
    with WindowListener {
  late final AppLifecycleListener _lifecycle;
  bool _minimized = false;
  bool _appHidden = false;

  bool get _hidden => _minimized || _appHidden;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    if (PlatformCapabilities.desktopWindow) {
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    if (PlatformCapabilities.desktopWindow) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState state) {
    final hidden =
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (hidden == _appHidden) return;
    _setHiddenState(appHidden: hidden);
  }

  @override
  void onWindowMinimize() {
    if (_minimized) return;
    _setHiddenState(minimized: true);
  }

  @override
  void onWindowRestore() {
    if (!_minimized) return;
    _setHiddenState(minimized: false);
  }

  void _setHiddenState({bool? minimized, bool? appHidden}) {
    final wasHidden = _hidden;
    _minimized = minimized ?? _minimized;
    _appHidden = appHidden ?? _appHidden;
    final nowHidden = _hidden;
    if (wasHidden == nowHidden) return;

    if (nowHidden) {
      MemoryTrimmer.trimOnBackground();
    } else {
      MemoryTrimmer.restoreOnForeground();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return TickerMode(enabled: !_hidden, child: widget.child);
  }
}
