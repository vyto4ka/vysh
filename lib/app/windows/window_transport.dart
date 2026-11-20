import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

const sessionWindowChannel = WindowMethodChannel(
  'vysh/session-owner',
  mode: ChannelMode.unidirectional,
);

abstract class SessionWindowController {
  String get windowId;
  Future<void> show();
  Future<dynamic> invokeMethod(String method, [dynamic arguments]);
  Future<void> setWindowMethodHandler(
    Future<dynamic> Function(MethodCall) handler,
  );
  Future<dynamic> requestOwner(String method, Map<String, Object?> arguments);
  Future<void> close();
}

class EngineSessionWindow implements SessionWindowController {
  EngineSessionWindow(this.controller);
  final WindowController controller;
  @override
  String get windowId => controller.windowId;
  @override
  Future<void> show() => controller.show();
  @override
  Future<dynamic> invokeMethod(String method, [dynamic arguments]) =>
      controller.invokeMethod(method, arguments);
  @override
  Future<void> setWindowMethodHandler(
    Future<dynamic> Function(MethodCall) handler,
  ) => controller.setWindowMethodHandler(handler);
  @override
  Future<dynamic> requestOwner(String method, Map<String, Object?> arguments) =>
      sessionWindowChannel.invokeMethod(method, arguments);
  @override
  Future<void> close() async {}
}

/// Full-duplex binary RPC channel over a single persistent socket using
/// Flutter's StandardMessageCodec (preserves Int32List / Uint8List without JSON).
class BinarySocketPeer {
  BinarySocketPeer(
    this.socket, {
    required this.onRequest,
    this.onClosed,
  }) {
    _sub = socket.listen(
      _onData,
      onError: (_) => _finish(),
      onDone: _finish,
      cancelOnError: true,
    );
  }

  static const _codec = StandardMessageCodec();
  static const _kindRequest = 0;
  static const _kindResponse = 1;
  static const _kindError = 2;
  static const _headerBytes = 9; // 4 len + 1 kind + 4 id

  final Socket socket;
  final Future<dynamic> Function(String method, dynamic arguments) onRequest;
  final void Function()? onClosed;

  late final StreamSubscription<Uint8List> _sub;
  final _pending = <int, Completer<dynamic>>{};
  final _buffer = BytesBuilder(copy: false);
  int _nextId = 1;
  bool _closed = false;

  bool get isClosed => _closed;

  Future<dynamic> call(String method, [dynamic arguments]) {
    if (_closed) {
      return Future.error(PlatformException(code: 'window_closed'));
    }
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      _send(_kindRequest, id, [method, arguments]);
    } catch (e) {
      _pending.remove(id);
      return Future.error(PlatformException(code: 'window_rpc_failed', message: '$e'));
    }
    return completer.future;
  }

  void _send(int kind, int id, Object? payload) {
    if (_closed) return;
    final encoded = _codec.encodeMessage(payload);
    final body = encoded == null
        ? Uint8List(0)
        : encoded.buffer.asUint8List(encoded.offsetInBytes, encoded.lengthInBytes);
    final frame = Uint8List(_headerBytes + body.length);
    final header = ByteData.sublistView(frame, 0, _headerBytes);
    header.setUint32(0, body.length, Endian.big);
    header.setUint8(4, kind);
    header.setUint32(5, id, Endian.big);
    frame.setRange(_headerBytes, frame.length, body);
    socket.add(frame);
  }

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    while (true) {
      if (_buffer.length < _headerBytes) return;
      final bytes = _buffer.takeBytes();
      var offset = 0;
      while (bytes.length - offset >= _headerBytes) {
        final header = ByteData.sublistView(bytes, offset, offset + _headerBytes);
        final length = header.getUint32(0, Endian.big);
        final total = _headerBytes + length;
        if (bytes.length - offset < total) break;
        final kind = header.getUint8(4);
        final id = header.getUint32(5, Endian.big);
        final dynamic message;
        if (length == 0) {
          message = null;
        } else {
          final aligned = Uint8List(length)
            ..setRange(0, length, bytes, offset + _headerBytes);
          message = _codec.decodeMessage(ByteData.sublistView(aligned));
        }
        offset += total;
        _handleFrame(kind, id, message);
      }
      if (offset < bytes.length) {
        _buffer.add(Uint8List.sublistView(bytes, offset));
      }
      return;
    }
  }

  void _handleFrame(int kind, int id, dynamic message) {
    if (kind == _kindResponse) {
      _pending.remove(id)?.complete(message);
      return;
    }
    if (kind == _kindError) {
      final list = message as List;
      _pending.remove(id)?.completeError(
        PlatformException(
          code: list[0] as String,
          message: list[1] as String?,
        ),
      );
      return;
    }
    if (kind == _kindRequest) {
      final list = message as List;
      final method = list[0] as String;
      final args = list[1];
      unawaited(
        Future<dynamic>.sync(() => onRequest(method, args)).then(
          (value) => _send(_kindResponse, id, value),
          onError: (Object error) {
            final code = error is PlatformException ? error.code : 'window_rpc_failed';
            final msg = error is PlatformException ? error.message : error.toString();
            _send(_kindError, id, [code, msg]);
          },
        ),
      );
    }
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(PlatformException(code: 'window_closed'));
      }
    }
    _pending.clear();
    onClosed?.call();
  }

  Future<void> close() async {
    _finish();
    await _sub.cancel();
    try {
      await socket.close();
    } catch (_) {}
    socket.destroy();
  }
}

/// Linux Flutter engines share an EGL display. Run each new window in its own
/// process so destroying its engine cannot tear down another window's display.
/// Communication runs over a single persistent Unix domain socket (mode 0700)
/// with binary StandardMessageCodec framing and per-window token auth.
class ProcessSessionWindow implements SessionWindowController {
  ProcessSessionWindow._(
    this.windowId,
    this.token, {
    this.server,
    this.socketPath,
  });

  @override
  final String windowId;
  final String token;
  final ServerSocket? server;
  final String? socketPath;
  BinarySocketPeer? _peer;
  Process? process;
  Future<dynamic> Function(MethodCall)? _handler;
  bool _closed = false;

  static String _createSocketPath(String windowId) {
    final runtime = Platform.environment['XDG_RUNTIME_DIR'];
    final baseDir = runtime != null && runtime.isNotEmpty
        ? '$runtime/vysh-ipc-$pid'
        : '${Directory.systemTemp.path}/vysh-ipc-$pid';
    final dir = Directory(baseDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      try {
        Process.runSync('chmod', ['700', dir.path]);
      } catch (_) {}
    }
    final shortId = windowId.length > 16 ? windowId.substring(0, 16) : windowId;
    final candidate = '${dir.path}/w-$shortId.sock';
    // Unix domain socket sun_path limit is 108 bytes on Linux.
    if (candidate.length < 96) return candidate;
    return '${Directory.systemTemp.path}/vysh-$pid-$shortId.sock';
  }

  static Future<ProcessSessionWindow> launch(
    Map<String, Object?> arguments, {
    required Future<dynamic> Function(MethodCall) owner,
    required Future<void> Function() onExit,
  }) async {
    final windowId = arguments['windowKey'] as String;
    final token = arguments['token'] as String;
    final sockPath = _createSocketPath(windowId);
    final sockFile = File(sockPath);
    if (sockFile.existsSync()) {
      try {
        sockFile.deleteSync();
      } catch (_) {}
    }
    final server = await ServerSocket.bind(
      InternetAddress(sockPath, type: InternetAddressType.unix),
      0,
    );
    try {
      Process.runSync('chmod', ['600', sockPath]);
    } catch (_) {}

    final window = ProcessSessionWindow._(
      windowId,
      token,
      server: server,
      socketPath: sockPath,
    );
    final ready = Completer<void>();
    var exited = false;
    Future<void> handleExit() async {
      if (exited) return;
      exited = true;
      await window.close();
      await onExit();
    }

    server.listen((socket) {
      if (window._peer != null) {
        socket.destroy();
        return;
      }
      var authed = false;
      window._peer = BinarySocketPeer(
        socket,
        onClosed: () => unawaited(handleExit()),
        onRequest: (method, rawArgs) async {
          final args = rawArgs is Map
              ? Map<String, dynamic>.from(rawArgs)
              : <String, dynamic>{};
          if (!authed) {
            if (args['token'] != token || args['windowKey'] != windowId) {
              socket.destroy();
              throw PlatformException(code: 'stale_window');
            }
            authed = true;
          }
          if (method == '_bootstrap') {
            return arguments['initial'];
          }
          if (method == '_ready') {
            if (!ready.isCompleted) ready.complete();
            return null;
          }
          return owner(
            MethodCall(method, {
              ...args,
              'windowKey': windowId,
              'token': token,
            }),
          );
        },
      );
    });

    try {
      final boot = {...arguments, 'socketPath': sockPath}..remove('initial');
      window.process = await Process.start(Platform.resolvedExecutable, [
        '--vysh-session-window',
        jsonEncode(boot),
      ], mode: ProcessStartMode.inheritStdio);
      unawaited(
        window.process!.exitCode.then((code) async {
          if (!ready.isCompleted) {
            ready.completeError(
              StateError('Window exited before startup ($code)'),
            );
          }
          await handleExit();
        }),
      );
      await ready.future.timeout(const Duration(seconds: 30));
      return window;
    } catch (_) {
      window.process?.kill();
      await window.close();
      rethrow;
    }
  }

  static Future<ProcessSessionWindow> connect(
    Map<String, dynamic> arguments, {
    void Function()? onDisconnected,
  }) async {
    final windowId = arguments['windowKey'] as String;
    final token = arguments['token'] as String;
    final sockPath = arguments['socketPath'] as String;
    final socket = await Socket.connect(
      InternetAddress(sockPath, type: InternetAddressType.unix),
      0,
    );
    final window = ProcessSessionWindow._(windowId, token);
    window._peer = BinarySocketPeer(
      socket,
      onClosed: onDisconnected,
      onRequest: (method, rawArgs) async {
        final handler = window._handler;
        if (handler == null) {
          throw PlatformException(code: 'window_not_ready');
        }
        return handler(MethodCall(method, rawArgs));
      },
    );
    arguments['initial'] = await window.requestOwner('_bootstrap', {
      'windowKey': windowId,
      'token': token,
    });
    return window;
  }

  @override
  Future<void> show() async {
    await invokeMethod('focus');
  }

  @override
  Future<dynamic> invokeMethod(String method, [dynamic arguments]) {
    final peer = _peer;
    if (peer == null || _closed) {
      return Future.error(PlatformException(code: 'window_closed'));
    }
    return peer.call(method, arguments);
  }

  @override
  Future<dynamic> requestOwner(String method, Map<String, Object?> arguments) {
    final peer = _peer;
    if (peer == null || _closed) {
      return Future.error(PlatformException(code: 'window_closed'));
    }
    return peer.call(method, {
      ...arguments,
      'windowKey': windowId,
      'token': token,
    });
  }

  @override
  Future<void> setWindowMethodHandler(
    Future<dynamic> Function(MethodCall) handler,
  ) async {
    _handler = handler;
    await requestOwner('_ready', {});
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _peer?.close();
    _peer = null;
    try {
      await server?.close();
    } catch (_) {}
    final path = socketPath;
    if (path != null) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }
}
