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

const sessionWindowChannel = WindowMethodChannel(
  'vysh/session-owner',
  mode: ChannelMode.unidirectional,
);
final detachedWindowsProvider =
    NotifierProvider<DetachedWindows, Map<String, String>>(DetachedWindows.new);

class _WindowLease {
  _WindowLease(this.key, this.token);
  final String key, token;
  WindowController? window;
  final ids = <String>[];
  final mirrors = <String, TerminalMirrorEncoder>{};
  final listeners = <String, void Function()>{};
  final logLengths = <String, int>{};
  final dirty = <String>{};
  final jobs = <String, ({CancelToken cancel, int bytes})>{};
  bool changed = true;
}

/// One owner for connections and profile writes; every native window uses the
/// same app UI with its own tabs/focus/split state. A lease authenticates a whole
/// window, so closing its first tab cannot orphan sessions opened afterwards.
class DetachedWindows extends Notifier<Map<String, String>>
    with WindowListener {
  final _parked = <WindowController>[];
  final _parking = <String>{};
  final _leases = <String, _WindowLease>{};
  final _opening = <String>{};
  StreamSubscription<void>? _windows;
  bool _initialized = false;
  Future<void>? _initializing;

  void _changed() {
    for (final lease in _leases.values) {
      lease.changed = true;
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
      _changed();
    });
    ref.listen(settingsProvider, (_, _) => _changed());
    ref.listen(hostsProvider, (_, _) => _changed());
    ref.listen(externalColorsProvider, (_, _) => _changed());
    ref.onDispose(() {
      _windows?.cancel();
      for (final lease in _leases.values) {
        for (final job in lease.jobs.values) {
          job.cancel.cancel();
        }
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
    await sessionWindowChannel.setMethodCallHandler(_handle);
    _initialized = true;
    windowManager.addListener(this);
    _windows = onWindowsChanged.listen((_) async {
      final alive = (await WindowController.getAll())
          .map((w) => w.windowId)
          .toSet();
      if (!ref.mounted) return;
      for (final lease in _leases.values.toList()) {
        if (lease.window != null && !alive.contains(lease.window!.windowId)) {
          await _returnWindow(lease, notifyWindow: false);
        }
      }
    });
  }

  void _adopt(_WindowLease lease, String id) {
    final session = ref.read(tabsProvider.notifier).sessionOf(id);
    if (session == null || lease.ids.contains(id)) return;
    lease.ids.add(id);
    lease.mirrors[id] = TerminalMirrorEncoder(session.terminal);
    void changed() => lease.dirty.add(id);
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
    lease.dirty.remove(id);
    lease.changed = true;
    state = {...state}..remove(id);
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
  Future<void> _detach(String id, {bool move = false}) async {
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
      final point = await screenRetriever.getCursorScreenPoint();
      var width = 1000.0, height = 700.0, x = point.dx - 120, y = point.dy - 24;
      try {
        for (final display in await screenRetriever.getAllDisplays()) {
          final area =
              (display.visiblePosition ?? Offset.zero) &
              (display.visibleSize ?? display.size);
          if (area.contains(point)) {
            width = width.clamp(540.0, area.width);
            height = height.clamp(340.0, area.height);
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
      WindowController window;
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
      if (!ref.mounted || session.isDisposed) {
        unawaited(window.invokeMethod('close'));
        if (ref.mounted) _leases.remove(lease.key);
        return;
      }
      lease.window = window;
      if (previous != null) {
        _release(previous, id);
        if (previous.ids.isEmpty) _park(previous);
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
      await window.show();
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
    _leases.remove(lease.key);
    for (final job in lease.jobs.values) {
      job.cancel.cancel();
    }
    final window = lease.window;
    if (window != null) {
      if (Platform.isLinux && _parking.add(window.windowId)) {
        _parked.add(window);
      }
      if (notifyWindow) {
        unawaited(window.invokeMethod('close').catchError((Object _) => null));
      }
    }
    unawaited(
      windowManager.setPreventClose(Platform.isLinux || _leases.isNotEmpty),
    );
  }

  Future<void> show(String id) async {
    final window = state[id];
    if (window == null) return;
    await WindowController.fromWindowId(window).show();
    try {
      await WindowController.fromWindowId(window).invokeMethod('focus');
    } catch (_) {}
  }

  Future<void> attach(String id) => returnToTabs(id);
  Future<void> returnToTabs(String id) async {
    final lease = _leases.values.where((l) => l.ids.contains(id)).firstOrNull;
    if (lease == null) return;
    _release(lease, id);
    if (lease.ids.isEmpty) _park(lease);
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
    await windowManager.show();
    await windowManager.focus();
    final tabs = ref.read(tabsProvider);
    final index = tabs.tabs.indexWhere((t) => t.id == id);
    if (index >= 0) ref.read(tabsProvider.notifier).activate(index + 1);
  }

  @override
  void onWindowClose() {
    if (_leases.isNotEmpty) {
      unawaited(windowManager.hide());
    } else if (Platform.isLinux) {
      exit(0);
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

  Future<dynamic> _dispatch(
    _WindowLease lease,
    String method,
    Map<String, dynamic> args,
  ) async {
    final ctrl = ref.read(tabsProvider.notifier);
    if (method == 'frame') {
      final full = args['force'] == true;
      if (!full && !lease.changed && lease.dirty.isEmpty) return null;
      final metadata = full || lease.changed;
      lease.changed = false;
      final result = <String, Object?>{
        if (metadata) ..._metadata(lease),
        'sessions': <String, Object?>{
          for (final id in lease.ids)
            if (full || lease.dirty.contains(id))
              id: (() {
                final s = ctrl.sessionOf(id)!;
                final logs = full || lease.logLengths[id] != s.connLog.length;
                lease.logLengths[id] = s.connLog.length;
                return {
                  'frame': lease.mirrors[id]!.capture(full: full),
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
    if (method == 'returnWindow') {
      await _returnWindow(lease, notifyWindow: false);
      return null;
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
    if (method == 'transferProgress') return lease.jobs[args['job']]?.bytes;
    if (method == 'transferCancel') {
      lease.jobs[args['job']]?.cancel.cancel();
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
        final handled = t.keyInput(
          TerminalKey.values.byName(args['key']),
          ctrl: args['ctrl'] == true,
          alt: args['alt'] == true,
          shift: args['shift'] == true,
          superKey: args['meta'] == true,
          capsLock: args['capsLock'] == true,
          numLock: args['numLock'] == true,
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
        t.resize(
          (args['width'] as int).clamp(10, 1000),
          (args['height'] as int).clamp(2, 500),
          args['pixelWidth'],
          args['pixelHeight'],
        );
      case 'reconnect':
        ctrl.reconnect(id);
        lease.dirty.add(id);
      case 'close':
        ctrl.close(id);
      case 'forgetPassword':
        session.forgetPassword();
      case 'directory':
        await session.refreshWorkingDirectory();
        lease.dirty.add(id);
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
        await _detach(id, move: true);
      case 'sftp':
        return _fileOperation(lease, id, args);
      default:
        throw PlatformException(code: 'unknown_window_method');
    }
    return null;
  }

  Future<dynamic> _fileOperation(
    _WindowLease lease,
    String id,
    Map args,
  ) async {
    final session = ref.read(tabsProvider.notifier).sessionOf(id)!;
    final operation = args['operation'];
    if (operation == 'download' || operation == 'upload') {
      final job = args['job'] as String, cancel = CancelToken();
      lease.jobs[job] = (cancel: cancel, bytes: 0);
      try {
        final sftp = await session.sftp();
        void progress(int bytes) {
          if (lease.jobs.containsKey(job)) {
            lease.jobs[job] = (cancel: cancel, bytes: bytes);
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
        return lease.jobs[job]?.bytes ?? 0;
      } finally {
        lease.jobs.remove(job);
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
