import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xterm2/core.dart';
import '../../domain/models/host.dart';
import '../../infra/platform/capabilities.dart';
import '../controllers/settings_controller.dart';
import '../controllers/external_colors_controller.dart';
import 'window_appearance.dart';
import '../controllers/tabs_controller.dart';
import 'terminal_mirror.dart';

const sessionWindowChannel = WindowMethodChannel(
  'vysh/session-owner',
  mode: ChannelMode.unidirectional,
);
final detachedWindowsProvider =
    NotifierProvider<DetachedWindows, Map<String, String>>(DetachedWindows.new);

/// A request to open the shared file workspace from a detached terminal.
final windowFilesRequestProvider = NotifierProvider<WindowFilesRequest, int>(
  WindowFilesRequest.new,
);

class WindowFilesRequest extends Notifier<int> {
  @override
  int build() => 0;
  void request() => state++;
}

class DetachedWindows extends Notifier<Map<String, String>>
    with WindowListener {
  // Flutter Linux 3.47 terminates the shared EGL display when an engine is
  // destroyed. Reuse parked engines so returning one tab cannot kill siblings.
  final _parked = <WindowController>[];
  final _parking = <String>{};
  final _tokens = <String, String>{};
  final _mirrors = <String, TerminalMirrorEncoder>{};
  final _dirty = <String, bool>{};
  final _listeners = <String, void Function()>{};
  StreamSubscription<void>? _windows;
  bool _initialized = false;
  Future<void>? _initializing;
  @override
  Map<String, String> build() {
    ref.listen(tabsProvider, (_, next) {
      for (final id in state.keys.toList()) {
        if (!next.tabs.any((t) => t.id == id)) unawaited(_closeRemoved(id));
      }
    });
    ref.listen(settingsProvider, (_, _) {
      for (final id in _dirty.keys.toList()) {
        _dirty[id] = true;
      }
    });
    ref.listen(externalColorsProvider, (_, _) {
      for (final id in _dirty.keys.toList()) {
        _dirty[id] = true;
      }
    });
    ref.onDispose(() {
      _windows?.cancel();
      if (_initialized) {
        windowManager.removeListener(this);
        unawaited(sessionWindowChannel.setMethodCallHandler(null));
      }
    });
    return {};
  }

  Future<void> _initialize() {
    if (_initialized) return Future.value();
    return _initializing ??= _setup().catchError((Object e) {
      _initializing = null;
      throw e;
    });
  }

  Future<void> _setup() async {
    if (_initialized) return;
    await sessionWindowChannel.setMethodCallHandler(_handle);
    _initialized = true;
    windowManager.addListener(this);
    _windows = onWindowsChanged.listen((_) async {
      final alive = (await WindowController.getAll())
          .map((w) => w.windowId)
          .toSet();
      if (!ref.mounted) return;
      for (final entry in state.entries.toList()) {
        if (!alive.contains(entry.value)) await attach(entry.key);
      }
    });
  }

  Future<void> detach(String id) async {
    if (!PlatformCapabilities.desktopWindow) return;
    if (state.containsKey(id)) {
      await show(id);
      return;
    }
    if (_tokens.containsKey(id)) return;
    final session = ref.read(tabsProvider.notifier).sessionOf(id);
    final tab = ref
        .read(tabsProvider)
        .tabs
        .where((t) => t.id == id)
        .firstOrNull;
    if (session == null || tab == null) return;
    await _initialize();
    final token = newId();
    _tokens[id] = token;
    final mirror = TerminalMirrorEncoder(session.terminal);
    _mirrors[id] = mirror;
    _dirty[id] = true;
    void changed() {
      _dirty[id] = true;
    }

    _listeners[id] = changed;
    session.terminal.addListener(changed);
    WindowController? window;
    try {
      final point = await screenRetriever.getCursorScreenPoint();
      var width = 900.0, height = 620.0, x = point.dx - 120, y = point.dy - 24;
      try {
        final displays = await screenRetriever.getAllDisplays();
        for (final display in displays) {
          final origin = display.visiblePosition ?? const Offset(0, 0);
          final size = display.visibleSize ?? display.size;
          final area = origin & size;
          if (area.contains(point)) {
            width = width.clamp(540.0, size.width);
            height = height.clamp(340.0, size.height);
            x = x.clamp(area.left, area.right - width);
            y = y.clamp(area.top, area.bottom - height);
            break;
          }
        }
      } catch (_) {}
      final arguments = <String, Object?>{
        'type': 'session',
        'tabId': id,
        'token': token,
        'title': tab.title,
        'settings': ref.read(settingsProvider).toJson(),
        'colors': encodeWindowColors(ref.read(externalColorsProvider)),
        'maxLines': session.terminal.maxLines,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
      if (Platform.isLinux && _parked.isNotEmpty) {
        window = _parked.removeLast();
        _parking.remove(window.windowId);
        await window.invokeMethod('close');
        await window.invokeMethod('bind', arguments);
      } else {
        window = await WindowController.create(
          WindowConfiguration(arguments: jsonEncode(arguments)),
        );
      }
      if (!ref.mounted || !_tokens.containsKey(id) || session.isDisposed) {
        try {
          await window.invokeMethod('close');
        } catch (_) {}
        if (ref.mounted) await attach(id);
        return;
      }
      state = {...state, id: window.windowId};
      await windowManager.setPreventClose(true);
      final tabs = ref.read(tabsProvider);
      if (tabs.activeTab?.id == id) {
        final other = tabs.tabs
            .where((t) => t.id != id && !state.containsKey(t.id))
            .firstOrNull;
        ref
            .read(tabsProvider.notifier)
            .activate(other == null ? 0 : tabs.tabs.indexOf(other) + 1);
      }
      await window.show();
    } catch (_) {
      await attach(id);
      if (window != null) {
        try {
          await window.invokeMethod('close');
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> show(String id) async {
    final window = state[id];
    if (window != null) {
      await WindowController.fromWindowId(window).show();
      try {
        await WindowController.fromWindowId(window).invokeMethod('focus');
      } catch (_) {}
    }
  }

  Future<void> attach(String id) async {
    final session = ref.read(tabsProvider.notifier).sessionOf(id);
    final listener = _listeners.remove(id);
    if (listener != null) session?.terminal.removeListener(listener);
    _tokens.remove(id);
    _mirrors.remove(id);
    _dirty.remove(id);
    final window = state[id];
    state = {...state}..remove(id);
    if (Platform.isLinux && window != null && _parking.add(window)) {
      _parked.add(WindowController.fromWindowId(window));
    }
    await windowManager.setPreventClose(Platform.isLinux || state.isNotEmpty);
    await windowManager.show();
    await windowManager.focus();
    final tabs = ref.read(tabsProvider);
    final index = tabs.tabs.indexWhere((t) => t.id == id);
    if (index >= 0) ref.read(tabsProvider.notifier).activate(index + 1);
  }

  Future<void> returnToTabs(String id) async {
    final window = state[id];
    await attach(id);
    if (window != null) {
      try {
        await WindowController.fromWindowId(window).invokeMethod('close');
      } catch (_) {}
    }
  }

  Future<void> _closeRemoved(String id) => returnToTabs(id);
  @override
  void onWindowClose() {
    if (state.isNotEmpty) {
      unawaited(windowManager.hide());
    } else if (Platform.isLinux) {
      // Parked native windows intentionally live until the application exits.
      exit(0);
    }
  }

  Future<dynamic> _handle(MethodCall call) async {
    final args = call.arguments as Map;
    final id = args['tabId'] as String;
    if (_tokens[id] != args['token']) {
      throw PlatformException(code: 'stale_window');
    }
    final ctrl = ref.read(tabsProvider.notifier);
    final session = ctrl.sessionOf(id);
    if (session == null) throw PlatformException(code: 'session_closed');
    final t = session.terminal;
    switch (call.method) {
      case 'frame':
        if (_dirty[id] != true && args['force'] != true) return null;
        _dirty[id] = false;
        return {
          'frame': _mirrors[id]!.capture(full: args['force'] == true),
          'status': session.status.name,
          'settings': ref.read(settingsProvider).toJson(),
          'colors': encodeWindowColors(ref.read(externalColorsProvider)),
        };
      case 'key':
        final key = TerminalKey.values.byName(args['key']);
        final handled = t.keyInput(
          key,
          ctrl: args['ctrl'] == true,
          alt: args['alt'] == true,
          shift: args['shift'] == true,
          superKey: args['meta'] == true,
          type: TerminalKeyEventType.values.byName(args['event']),
          text: args['text'],
        );
        if (!handled &&
            args['event'] != 'release' &&
            args['text'] is String &&
            (args['text'] as String).isNotEmpty) {
          t.textInput(args['text']);
        }
      case 'text':
        t.textInput(args['text']);
      case 'raw':
        t.onOutput?.call(args['text']);
      case 'paste':
        t.paste(args['text']);
      case 'resize':
        final w = (args['width'] as int).clamp(10, 1000),
            h = (args['height'] as int).clamp(2, 500);
        t.resize(w, h, args['pixelWidth'], args['pixelHeight']);
      case 'reconnect':
        ctrl.reconnect(id);
        _dirty[id] = true;
      case 'attach':
        await attach(id);
      case 'files':
        await windowManager.show();
        await windowManager.focus();
        ref.read(windowFilesRequestProvider.notifier).request();
      default:
        throw PlatformException(code: 'unknown_window_method');
    }
    return null;
  }
}
