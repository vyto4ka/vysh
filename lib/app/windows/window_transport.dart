import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
}

/// Linux Flutter engines share an EGL display. Run each new window in its own
/// process so destroying its engine cannot tear down another window's display.
/// RPC is authenticated and bound only to the loopback interface.
class ProcessSessionWindow implements SessionWindowController {
  ProcessSessionWindow._(this.windowId, this.token, this.server, this.peerPort);
  @override
  final String windowId;
  final String token;
  final HttpServer server;
  int peerPort;
  Process? process;
  Future<dynamic> Function(MethodCall)? _handler;

  static Future<ProcessSessionWindow> launch(
    Map<String, Object?> arguments, {
    required Future<dynamic> Function(MethodCall) owner,
    required Future<void> Function() onExit,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final window = ProcessSessionWindow._(
      arguments['windowKey'] as String,
      arguments['token'] as String,
      server,
      0,
    );
    final ready = Completer<void>();
    server.listen(
      (request) => window._serve(request, (call) async {
        if (call.method == '_bootstrap') return arguments['initial'];
        if (call.method == '_ready') {
          final port = (call.arguments as Map)['port'];
          if (port is! int || port < 1 || port > 65535) {
            throw PlatformException(code: 'invalid_window_port');
          }
          window.peerPort = port;
          if (!ready.isCompleted) ready.complete();
          return null;
        }
        return owner(call);
      }),
    );
    try {
      final boot = {...arguments, 'ownerPort': server.port}..remove('initial');
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
          await onExit();
          await server.close(force: true);
        }),
      );
      await ready.future.timeout(const Duration(seconds: 30));
      return window;
    } catch (_) {
      window.process?.kill();
      await server.close(force: true);
      rethrow;
    }
  }

  static Future<ProcessSessionWindow> connect(
    Map<String, dynamic> arguments,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final window = ProcessSessionWindow._(
      arguments['windowKey'],
      arguments['token'],
      server,
      arguments['ownerPort'],
    );
    server.listen(
      (request) => window._serve(request, (call) async {
        final handler = window._handler;
        if (handler == null) throw PlatformException(code: 'window_not_ready');
        return handler(call);
      }),
    );
    arguments['initial'] = await window.requestOwner('_bootstrap', {});
    return window;
  }

  Future<void> _serve(
    HttpRequest request,
    Future<dynamic> Function(MethodCall) handler,
  ) async {
    try {
      if (request.method != 'POST') {
        throw PlatformException(code: 'invalid_window_request');
      }
      final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      if (data['token'] != token || data['windowKey'] != windowId) {
        throw PlatformException(code: 'stale_window');
      }
      final args = Map<String, dynamic>.from(data['arguments'] as Map);
      final value = await handler(
        MethodCall(data['method'] as String, {
          ...args,
          'windowKey': windowId,
          'token': token,
        }),
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'value': value}));
    } catch (error) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'error': error is PlatformException
              ? error.code
              : 'window_rpc_failed',
          'message': error is PlatformException
              ? error.message
              : error.toString(),
        }),
      );
    } finally {
      await request.response.close();
    }
  }

  Future<dynamic> _call(String method, dynamic arguments) async {
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:$peerPort/'),
      );
      request.persistentConnection = false;
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'method': method,
          'arguments': arguments ?? {},
          'windowKey': windowId,
          'token': token,
        }),
      );
      final response = await request.close();
      final data = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      if (data['error'] != null) {
        throw PlatformException(code: data['error'], message: data['message']);
      }
      return data['value'];
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> show() async {
    await invokeMethod('focus');
  }

  @override
  Future<dynamic> invokeMethod(String method, [dynamic arguments]) =>
      _call(method, arguments);
  @override
  Future<dynamic> requestOwner(String method, Map<String, Object?> arguments) =>
      _call(method, arguments);
  @override
  Future<void> setWindowMethodHandler(
    Future<dynamic> Function(MethodCall) handler,
  ) async {
    _handler = handler;
    await requestOwner('_ready', {'port': server.port});
  }
}
