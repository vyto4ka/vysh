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
import '../../domain/ports/sftp.dart';
import '../../domain/ports/secret_store.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/window_placement.dart';
import '../../l10n/app_strings.dart';
import '../dependencies.dart';
import '../settings/app_settings.dart';
import '../controllers/hosts_controller.dart';
import '../controllers/settings_controller.dart';
import '../controllers/external_colors_controller.dart';
import '../controllers/tabs_controller.dart';
import 'window_appearance.dart';
import 'window_protocol.dart';
import 'window_prompts.dart';
import 'terminal_mirror.dart';
import 'tab_transfer.dart';
import 'window_transport.dart';
export 'window_transport.dart' show sessionWindowChannel;

final detachedWindowsProvider =
    NotifierProvider<DetachedWindows, Map<String, String>>(DetachedWindows.new);

/// Linux isolates windows in separate processes to avoid shared EGL teardown.
final processSessionWindowsProvider = Provider<bool>((_) => Platform.isLinux);

/// Process exit hook (overridable in tests) for Linux hidden-owner shutdown.
final exitProcessProvider = Provider<void Function(int)>((_) => exit);

class _WindowLease {
  _WindowLease(this.key, this.token);
  final String key, token;
  SessionWindowController? window;
  final ids = <String>[];
  final mirrors = <String, TerminalMirrorEncoder>{};
  final listeners = <String, void Function()>{};
  final logLengths = <String, int>{};
  final resizeSeqs = <String, int>{};
  final dirty = <String>{};
  bool changed = true;
  Timer? pushTimer;
  bool pushing = false;
  bool pushPending = false;
  bool closed = false;
}

/// One owner for connections and profile writes; every native window is an
/// autonomous peer with its own tabs, focus and split layout. Closing the
/// initial window closes its own tabs without affecting detached windows;
/// closing a detached window closes its own tabs without resurrecting a
/// closed initial window.
class DetachedWindows extends Notifier<Map<String, String>>
    with WindowListener {
  final _leases = <String, _WindowLease>{};
  final _drags = <String, ({String id, String? source, DateTime expires})>{};
  final _opening = <String>{};
  final _jobs = <String, ({String sessionId, CancelToken cancel, int bytes})>{};
  StreamSubscription<void>? _windows;
  bool _initialized = false;
  Future<void>? _initializing;
  bool _mainClosed = false;
  bool _shuttingDown = false;

  void _changed() {
    for (final lease in _leases.values) {
      lease.changed = true;
      _schedulePush(lease);
    }
  }

  void _schedulePush(_WindowLease lease) {
    if (lease.closed || lease.window == null) return;
    if (lease.pushing) {
      lease.pushPending = true;
      return;
    }
    lease.pushTimer ??= Timer(
      const Duration(milliseconds: 12),
      () => _flushPush(lease),
    );
  }

  Future<void> _flushPush(_WindowLease lease) async {
    lease.pushTimer?.cancel();
    lease.pushTimer = null;
    if (lease.closed || lease.window == null || !ref.mounted) return;
    final payload = _buildFrame(lease, full: false);
    if (payload == null) return;
    lease.pushing = true;
    try {
      await lease.window!.invokeMethod('push', payload);
    } catch (_) {
      // If the push fails, mark changed so the next frame catches up.
      lease.changed = true;
    } finally {
      lease.pushing = false;
      if (lease.pushPending && !lease.closed && ref.mounted) {
        lease.pushPending = false;
        _schedulePush(lease);
      }
    }
  }

  @override
  Map<String, String> build() {
    ref.listen(tabsProvider, (_, next) {
      final alive = next.tabs.map((t) => t.id).toSet();
      for (final lease in _leases.values.toList()) {
        for (final id in lease.ids.toList()) {
          if (!alive.contains(id)) _release(lease, id);
        }
      }
      // Cancel file transfer jobs whose owning session was actually closed.
      for (final entry in _jobs.entries.toList()) {
        if (!alive.contains(entry.value.sessionId)) {
          entry.value.cancel.cancel();
        }
      }
      // Never let the initial window activate a tab that belongs to another window.
      final activeId = next.activeTab?.id;
      if (activeId != null && state.containsKey(activeId)) {
        final other = next.tabs
            .where((t) => !state.containsKey(t.id))
            .firstOrNull;
        scheduleMicrotask(() {
          if (!ref.mounted) return;
          final current = ref.read(tabsProvider);
          if (current.activeTab?.id != activeId) return;
          final idx = other == null
              ? 0
              : current.tabs.indexWhere((t) => t.id == other.id) + 1;
          ref.read(tabsProvider.notifier).activate(idx < 0 ? 0 : idx);
        });
      }
      _changed();
    });
    ref.listen(settingsProvider, (_, _) => _changed());
    ref.listen(hostsProvider, (_, _) => _changed());
    ref.listen(externalColorsProvider, (_, _) => _changed());
    ref.onDispose(() {
      _windows?.cancel();
      for (final lease in _leases.values) {
        lease.closed = true;
        lease.pushTimer?.cancel();
      }
      for (final job in _jobs.values) {
        job.cancel.cancel();
      }
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
    if (!ref.read(processSessionWindowsProvider)) {
      await sessionWindowChannel.setMethodCallHandler(_handle);
    }
    _initialized = true;
    windowManager.addListener(this);
    if (!ref.read(processSessionWindowsProvider)) {
      _windows = onWindowsChanged.listen((_) async {
        final alive = (await WindowController.getAll())
            .map((w) => w.windowId)
            .toSet();
        if (!ref.mounted) return;
        for (final lease in _leases.values.toList()) {
          if (lease.window != null && !alive.contains(lease.window!.windowId)) {
            await _closeLease(lease, notifyWindow: false);
          }
        }
      });
    }
  }

  void _adopt(_WindowLease lease, String id) {
    final session = ref.read(tabsProvider.notifier).sessionOf(id);
    if (session == null || lease.ids.contains(id)) return;
    lease.ids.add(id);
    lease.mirrors[id] = TerminalMirrorEncoder(session.terminal);
    void changed() {
      lease.dirty.add(id);
      _schedulePush(lease);
    }

    lease.listeners[id] = changed;
    session.terminal.addListener(changed);
    session.currentDirectory.addListener(changed);
    lease.dirty.add(id);
    lease.changed = true;
    if (lease.window != null) {
      session.prompts = WindowPrompts(
        (method, data) => lease.window!.invokeMethod(method, data),
      );
      state = {...state, id: lease.window!.windowId};
      _schedulePush(lease);
    }
  }

  void _release(_WindowLease lease, String id) {
    final session = ref.read(tabsProvider.notifier).sessionOf(id);
    final listener = lease.listeners.remove(id);
    if (listener != null && session != null && !session.isDisposed) {
      session.terminal.removeListener(listener);
      session.currentDirectory.removeListener(listener);
      session.prompts = ref.read(sessionPromptsProvider);
    }
    lease.ids.remove(id);
    lease.mirrors.remove(id);
    lease.logLengths.remove(id);
    lease.resizeSeqs.remove(id);
    lease.dirty.remove(id);
    lease.changed = true;
    state = {...state}..remove(id);
    _schedulePush(lease);
  }

  Map<String, Object?> _documents() => {
    for (final name in ['settings.json', 'hosts.json', 'known_hosts.json'])
      name: ref.read(documentStoreProvider(name)).readSync(),
  };

  Map<String, Object?> _metadata(_WindowLease lease) {
    final tabs = ref.read(tabsProvider).tabs;
    return {
      'tabs': [
        for (final id in lease.ids)
          for (final tab in tabs.where((t) => t.id == id))
            {
              ...encodeTab(tab),
              'maxLines': ref
                  .read(tabsProvider.notifier)
                  .sessionOf(id)!
                  .terminal
                  .maxLines,
            },
      ],
      'documents': _documents(),
      'settings': ref.read(settingsProvider).toJson(),
      'colors': encodeWindowColors(ref.read(externalColorsProvider)),
    };
  }

  Future<void> detach(String id) => _detach(id);
  Future<void> _detach(String id, {bool move = false, Size? sourceSize}) async {
    if (!PlatformCapabilities.desktopWindow) return;
    if (state.containsKey(id) && !move) {
      await show(id);
      return;
    }
    if (!_opening.add(id)) return;
    final session = ref.read(tabsProvider.notifier).sessionOf(id);
    final tab = ref
        .read(tabsProvider)
        .tabs
        .where((t) => t.id == id)
        .firstOrNull;
    if (session == null || tab == null) {
      _opening.remove(id);
      return;
    }
    await _initialize();
    final previous = _leases.values
        .where((l) => l.ids.contains(id))
        .firstOrNull;
    final lease = _WindowLease(newId(), newId());
    _leases[lease.key] = lease;
    _adopt(lease, id);
    try {
      await windowManager.setPreventClose(true);
      Offset point = Offset.zero;
      try {
        point = await screenRetriever.getCursorScreenPoint();
      } catch (_) {}
      final size = sourceSize ?? (await windowManager.getBounds()).size;
      var width = size.width,
          height = size.height,
          x = point.dx - 120,
          y = point.dy - 24;
      try {
        for (final display in await screenRetriever.getAllDisplays()) {
          final area =
              (display.visiblePosition ?? Offset.zero) &
              (display.visibleSize ?? display.size);
          if (area.contains(point)) {
            width = width.clamp(WindowPlacement.minSize.width, area.width);
            height = height.clamp(WindowPlacement.minSize.height, area.height);
            x = x.clamp(area.left, area.right - width);
            y = y.clamp(area.top, area.bottom - height);
            break;
          }
        }
      } catch (_) {}
      final arguments = <String, Object?>{
        'type': 'session',
        'windowKey': lease.key,
        'token': lease.token,
        'title': tab.title,
        'initial': _metadata(lease),
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };
      final window = ref.read(processSessionWindowsProvider)
          ? await ProcessSessionWindow.launch(
              arguments,
              owner: _handle,
              onExit: () async {
                if (ref.mounted && _leases.containsKey(lease.key)) {
                  await _closeLease(lease, notifyWindow: false);
                }
              },
            )
          : EngineSessionWindow(
              await WindowController.create(
                WindowConfiguration(
                  arguments: jsonEncode(arguments),
                  hiddenAtLaunch: true,
                ),
              ),
            );
      if (!ref.mounted || session.isDisposed) {
        unawaited(window.invokeMethod('close').catchError((Object _) => null));
        unawaited(window.close());
        if (ref.mounted) _leases.remove(lease.key);
        return;
      }
      lease.window = window;
      if (previous != null) {
        _release(previous, id);
        if (previous.ids.isEmpty) {
          _park(previous, notifyWindow: true);
        }
      }
      session.prompts = WindowPrompts(
        (method, data) => window.invokeMethod(method, data),
      );
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
      _schedulePush(lease);
    } catch (_) {
      _release(lease, id);
      _park(lease);
      if (previous != null && previous.ids.contains(id)) {
        state = {...state, id: previous.window!.windowId};
        session.prompts = WindowPrompts(
          (method, data) => previous.window!.invokeMethod(method, data),
        );
      }
      rethrow;
    } finally {
      _opening.remove(id);
    }
  }

  void _park(_WindowLease lease, {bool notifyWindow = true}) {
    lease.closed = true;
    lease.pushTimer?.cancel();
    lease.pushTimer = null;
    _leases.remove(lease.key);
    final window = lease.window;
    if (window != null) {
      if (notifyWindow) {
        unawaited(
          window
              .invokeMethod('close')
              .catchError((Object _) => null)
              .whenComplete(() => window.close()),
        );
      } else {
        unawaited(window.close());
      }
    }
    if (!_mainClosed) {
      unawaited(
        windowManager.setPreventClose(Platform.isLinux || _leases.isNotEmpty),
      );
    }
  }

  /// Close a detached window and all tabs belonging to it (browser model).
  /// Never resurrects a previously closed initial window; shuts down the
  /// owner process if no visible windows remain.
  Future<void> _closeLease(
    _WindowLease lease, {
    bool notifyWindow = true,
  }) async {
    if (lease.closed && !_leases.containsKey(lease.key)) return;
    final ids = lease.ids.toList();
    final ctrl = ref.read(tabsProvider.notifier);
    for (final id in ids) {
      _release(lease, id);
      ctrl.close(id);
    }
    _park(lease, notifyWindow: notifyWindow);
    if (_mainClosed && _leases.isEmpty) {
      await _shutdownOwner();
    }
  }

  Future<void> _shutdownOwner() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    try {
      await WindowPlacement.instance.flush();
    } catch (_) {}
    final ctrl = ref.read(tabsProvider.notifier);
    for (final tab in ref.read(tabsProvider).tabs.toList()) {
      ctrl.close(tab.id);
    }
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {}
    // On Linux gtk_window_close() on a hidden window does not always terminate
    // the GApplication loop; exit cleanly now that sessions and bounds are saved.
    if (Platform.isLinux) {
      ref.read(exitProcessProvider)(0);
    }
  }

  Future<void> show(String id) async {
    final window = state[id];
    if (window == null) return;
    final controller = _leaseOf(id)?.window;
    if (controller == null) return;
    await controller.show();
    try {
      await controller.invokeMethod('focus');
    } catch (_) {}
  }

  Future<void> attach(String id) => returnToTabs(id);

  _WindowLease? _leaseOf(String id) =>
      _leases.values.where((lease) => lease.ids.contains(id)).firstOrNull;

  Future<TabTransfer> beginDrag(String id) async {
    if (!ref.read(tabsProvider).tabs.any((tab) => tab.id == id)) {
      throw PlatformException(code: 'session_closed');
    }
    final token = newId();
    final now = DateTime.now();
    _drags.removeWhere((_, grant) => grant.expires.isBefore(now));
    _drags[token] = (
      id: id,
      source: _leaseOf(id)?.key,
      expires: now.add(const Duration(minutes: 1)),
    );
    return TabTransfer(id, token);
  }

  Future<void> finishDrag(TabTransfer transfer, {bool accepted = false}) async {
    // A native cross-process drop may complete at the source before the target
    // finishes reading its payload. The target consumes the grant atomically.
    if (!accepted) _drags.remove(transfer.token);
  }

  Future<bool> canAcceptDrag(TabTransfer transfer) async =>
      _allowsDrag(transfer);

  bool _allowsDrag(TabTransfer transfer) {
    final grant = _drags[transfer.token];
    return grant != null &&
        grant.expires.isAfter(DateTime.now()) &&
        grant.id == transfer.id &&
        grant.source == _leaseOf(transfer.id)?.key &&
        ref.read(tabsProvider).tabs.any((tab) => tab.id == transfer.id);
  }

  Future<void> acceptDrag(TabTransfer transfer) => _receiveDrag(null, transfer);

  Future<void> _receiveDrag(_WindowLease? target, TabTransfer transfer) async {
    if (!_allowsDrag(transfer)) {
      throw PlatformException(code: 'stale_tab_drag');
    }
    final source = _leaseOf(transfer.id);
    _drags.remove(transfer.token);
    if (source != target) {
      if (source != null) {
        _release(source, transfer.id);
        // Browser behavior: merging the last tab out of a detached window
        // automatically closes the now-empty source window.
        if (source.ids.isEmpty) {
          _park(source, notifyWindow: true);
        }
      }
      if (target != null) _adopt(target, transfer.id);
    }
    final ctrl = ref.read(tabsProvider.notifier);
    final tabs = ref.read(tabsProvider);
    if (target == null) {
      _mainClosed = false;
      ctrl.activate(tabs.tabs.indexWhere((tab) => tab.id == transfer.id) + 1);
    } else if (tabs.activeTab?.id == transfer.id) {
      final other = tabs.tabs
          .where((tab) => !state.containsKey(tab.id))
          .firstOrNull;
      ctrl.activate(other == null ? 0 : tabs.tabs.indexOf(other) + 1);
    }
  }

  Future<void> returnToTabs(String id) async {
    final lease = _leases.values.where((l) => l.ids.contains(id)).firstOrNull;
    if (lease == null) return;
    _release(lease, id);
    if (lease.ids.isEmpty) {
      _park(lease, notifyWindow: true);
    }
    await _showMain(id);
  }

  Future<void> _returnWindow(
    _WindowLease lease, {
    bool notifyWindow = true,
  }) async {
    final first = lease.ids.firstOrNull;
    for (final id in lease.ids.toList()) {
      _release(lease, id);
    }
    _park(lease, notifyWindow: notifyWindow);
    await _showMain(first);
  }

  Future<void> _showMain(String? id) async {
    _mainClosed = false;
    if (!PlatformCapabilities.isMacOS) {
      try {
        await windowManager.setSkipTaskbar(false);
      } catch (_) {}
    }
    await windowManager.show();
    await windowManager.focus();
    final tabs = ref.read(tabsProvider);
    final index = tabs.tabs.indexWhere((t) => t.id == id);
    if (index >= 0) ref.read(tabsProvider.notifier).activate(index + 1);
  }

  @override
  void onWindowClose() {
    if (_leases.isNotEmpty) {
      // Browser behavior: close only the tabs belonging to the initial window
      // and hide its native surface so all detached windows stay autonomous.
      _mainClosed = true;
      final ctrl = ref.read(tabsProvider.notifier);
      final mainTabs = ref
          .read(tabsProvider)
          .tabs
          .where((t) => !state.containsKey(t.id))
          .toList();
      for (final tab in mainTabs) {
        ctrl.close(tab.id);
      }
      unawaited(() async {
        try {
          await WindowPlacement.instance.flush();
        } catch (_) {}
        // On macOS setSkipTaskbar toggles NSApplication.activationPolicy to
        // .accessory for the whole process, hiding the app from Dock/Cmd+Tab
        // even while detached windows are still open.
        if (!PlatformCapabilities.isMacOS) {
          try {
            await windowManager.setSkipTaskbar(true);
          } catch (_) {}
        }
        await windowManager.hide();
      }());
    } else {
      unawaited(_shutdownOwner());
    }
  }

  Future<dynamic> _handle(MethodCall call) async {
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final lease = _leases[args['windowKey']];
    if (lease == null || lease.token != args['token']) {
      throw PlatformException(code: 'stale_window');
    }
    try {
      return await _dispatch(lease, call.method, args);
    } on SftpFailure catch (e) {
      return {'windowError': 'sftp', 'code': e.code.name, 'args': e.args};
    } on TransferCancelled {
      return {'windowError': 'cancelled'};
    } on SecretStoreUnavailable catch (e) {
      return {'windowError': 'secret', 'detail': e.detail};
    }
  }

  Map<String, Object?>? _buildFrame(_WindowLease lease, {required bool full}) {
    if (!full && !lease.changed && lease.dirty.isEmpty) return null;
    final ctrl = ref.read(tabsProvider.notifier);
    final metadata = full || lease.changed;
    lease.changed = false;
    final result = <String, Object?>{
      if (metadata) ..._metadata(lease),
      'sessions': <String, Object?>{
        for (final id in lease.ids)
          if (full || lease.dirty.contains(id))
            if (ctrl.sessionOf(id) case final s?)
              id: (() {
                final logs = full || lease.logLengths[id] != s.connLog.length;
                lease.logLengths[id] = s.connLog.length;
                return {
                  'frame': lease.mirrors[id]!.capture(
                    full: full,
                    resizeSeq: lease.resizeSeqs[id] ?? 0,
                  ),
                  'status': s.status.name,
                  'version': s.serverVersion,
                  'directory': s.currentDirectory.value,
                  'failure': s.lastFailure == null
                      ? null
                      : {
                          'error': s.lastFailure!.error.name,
                          'args': s.lastFailure!.args,
                        },
                  'dropped': s.droppedAfterReady,
                  if (logs)
                    'log': [
                      for (final line in s.connLog)
                        {
                          'ru': line.text(
                            AppStrings.forLanguage(AppLanguage.ru),
                          ),
                          'en': line.text(
                            AppStrings.forLanguage(AppLanguage.en),
                          ),
                          'debug': line.debug,
                          'error': line.error,
                        },
                    ],
                };
              })(),
      },
    };
    lease.dirty.clear();
    return result;
  }

  Future<dynamic> _dispatch(
    _WindowLease lease,
    String method,
    Map<String, dynamic> args,
  ) async {
    final ctrl = ref.read(tabsProvider.notifier);
    if (method == 'frame') {
      return _buildFrame(lease, full: args['force'] == true);
    }
    if (method == 'closeWindow') {
      await _closeLease(lease, notifyWindow: false);
      return null;
    }
    if (method == 'returnWindow') {
      await _returnWindow(lease, notifyWindow: false);
      return null;
    }
    if (method == 'beginDrag') {
      final id = args['sessionId'] as String;
      if (!lease.ids.contains(id)) {
        throw PlatformException(code: 'foreign_session');
      }
      return (await beginDrag(id)).toJson();
    }
    if (method == 'canAcceptDrag' ||
        method == 'acceptDrag' ||
        method == 'finishDrag') {
      final transfer = TabTransfer.decode(args['transfer']);
      if (transfer == null) throw PlatformException(code: 'invalid_tab_drag');
      if (method == 'canAcceptDrag') return canAcceptDrag(transfer);
      if (method == 'finishDrag') {
        final grant = _drags[transfer.token];
        if (grant?.source == lease.key) {
          await finishDrag(transfer, accepted: args['accepted'] == true);
        }
        return null;
      }
      await _receiveDrag(lease, transfer);
      return {..._metadata(lease), 'activate': transfer.id};
    }
    if (method == 'document') {
      final name = args['name'] as String;
      if (!['settings.json', 'hosts.json', 'known_hosts.json'].contains(name)) {
        throw PlatformException(code: 'unknown_document');
      }
      final ok = await ref
          .read(documentStoreProvider(name))
          .write(args['data']);
      if (ok) {
        if (name == 'settings.json') ref.invalidate(settingsProvider);
        if (name == 'hosts.json') ref.invalidate(hostsProvider);
        if (name == 'known_hosts.json') ref.invalidate(knownHostsProvider);
        _changed();
      }
      return ok;
    }
    if (method == 'secret') {
      final store = ref.read(secretStoreProvider), key = args['key'] as String;
      if (!key.startsWith('vysh.password.') &&
          !key.startsWith('vysh.passphrase.')) {
        throw PlatformException(code: 'unknown_secret');
      }
      switch (args['operation']) {
        case 'read':
          return store.read(key);
        case 'write':
          await store.write(key, args['value']);
          return null;
        case 'delete':
          await store.delete(key);
          return null;
      }
    }
    if (method == 'openLocal' ||
        method == 'openHost' ||
        method == 'duplicate') {
      final active = ref.read(tabsProvider).active;
      if (method == 'openLocal') {
        ctrl.openLocal();
      } else if (method == 'openHost') {
        ctrl.openHost(
          Host.fromJson(Map<String, Object?>.from(args['host'])),
          password: args['password'],
        );
      } else {
        if (!lease.ids.contains(args['sessionId'])) {
          throw PlatformException(code: 'foreign_session');
        }
        ctrl.duplicate(args['sessionId']);
      }
      final id = ref.read(tabsProvider).tabs.last.id;
      _adopt(lease, id);
      ctrl.activate(active);
      return id;
    }
    if (method == 'move') {
      final ids = (args['ids'] as List).cast<String>();
      if (ids.length == lease.ids.length &&
          ids.toSet().length == ids.length &&
          ids.every(lease.ids.contains)) {
        lease.ids
          ..clear()
          ..addAll(ids);
        lease.changed = true;
      }
      return null;
    }
    if (method == 'transferProgress') return _jobs[args['job']]?.bytes;
    if (method == 'transferCancel') {
      _jobs[args['job']]?.cancel.cancel();
      return null;
    }
    final id = args['sessionId'] as String?;
    if (id == null || !lease.ids.contains(id)) {
      throw PlatformException(code: 'foreign_session');
    }
    final session = ctrl.sessionOf(id);
    if (session == null) throw PlatformException(code: 'session_closed');
    final t = session.terminal;
    switch (method) {
      case 'key':
        final ctrlPressed = args['ctrl'] == true;
        final altPressed = args['alt'] == true;
        final metaPressed = args['meta'] == true;
        final handled = t.keyInput(
          TerminalKey.values.byName(args['key']),
          ctrl: ctrlPressed,
          alt: altPressed,
          shift: args['shift'] == true,
          superKey: metaPressed,
          capsLock: args['capsLock'] == true,
          numLock: args['numLock'] == true,
          type: TerminalKeyEventType.values.byName(args['event']),
          text: args['text'],
        );
        final altBlocks =
            altPressed &&
            (Platform.isMacOS ? t.altSendsEscapeMode : t.altEscPrefixMode);
        if (!handled &&
            args['event'] != 'release' &&
            !ctrlPressed &&
            !metaPressed &&
            !altBlocks &&
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
        if (args['seq'] is int) {
          lease.resizeSeqs[id] = args['seq'] as int;
        }
        t.resize(
          (args['width'] as int).clamp(10, 1000),
          (args['height'] as int).clamp(2, 500),
          args['pixelWidth'],
          args['pixelHeight'],
        );
        lease.dirty.add(id);
        _schedulePush(lease);
      case 'reconnect':
        ctrl.reconnect(id);
        lease.dirty.add(id);
        _schedulePush(lease);
      case 'close':
        ctrl.close(id);
      case 'forgetPassword':
        session.forgetPassword();
      case 'directory':
        await session.refreshWorkingDirectory(force: args['force'] == true);
        lease.dirty.add(id);
        _schedulePush(lease);
      case 'exec':
        return session.exec(
          args['command'],
          timeout: Duration(
            milliseconds: (args['timeout'] as int).clamp(100, 60000),
          ),
        );
      case 'resetSftp':
        session.resetSftp();
      case 'attach':
        await returnToTabs(id);
      case 'detach':
        await _detach(
          id,
          move: true,
          sourceSize: args['width'] is num && args['height'] is num
              ? Size(
                  (args['width'] as num).toDouble(),
                  (args['height'] as num).toDouble(),
                )
              : null,
        );
      case 'sftp':
        return _fileOperation(id, args);
      default:
        throw PlatformException(code: 'unknown_window_method');
    }
    return null;
  }

  Future<dynamic> _fileOperation(String id, Map args) async {
    final session = ref.read(tabsProvider.notifier).sessionOf(id)!;
    final operation = args['operation'];
    if (operation == 'download' || operation == 'upload') {
      final job = args['job'] as String, cancel = CancelToken();
      _jobs[job] = (sessionId: id, cancel: cancel, bytes: 0);
      try {
        final sftp = await session.sftp();
        void progress(int bytes) {
          if (_jobs.containsKey(job)) {
            _jobs[job] = (sessionId: id, cancel: cancel, bytes: bytes);
          }
        }

        final local = File(args['localPath']);
        if (operation == 'download') {
          await sftp.download(
            args['path'],
            local,
            cancel: cancel,
            onProgress: progress,
          );
        } else {
          await sftp.upload(
            local,
            args['path'],
            cancel: cancel,
            onProgress: progress,
          );
        }
        return _jobs[job]?.bytes ?? 0;
      } finally {
        _jobs.remove(job);
      }
    }
    final sftp = await session.sftp();
    switch (operation) {
      case 'home':
        return sftp.home();
      case 'list':
        return (await sftp.list(args['path'])).map(encodeEntry).toList();
      case 'stat':
        return encodeEntry(await sftp.stat(args['path']));
      case 'mkdir':
        await sftp.mkdir(args['path']);
      case 'rename':
        await sftp.rename(args['path'], args['to']);
      case 'removeFile':
        await sftp.removeFile(args['path']);
      case 'removeDir':
        await sftp.removeDir(args['path']);
      case 'chmod':
        await sftp.chmod(args['path'], args['mode']);
      default:
        throw PlatformException(code: 'unknown_file_operation');
    }
    return null;
  }
}
