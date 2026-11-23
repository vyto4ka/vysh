import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum DiagKind { ping, traceroute, port }

/// Собственные сообщения диагностики; текст выбирает интерфейс.
enum DiagMessage {
  /// Нет системных утилит (веб-версия).
  unavailable,

  /// args: host.
  badAddress,
  noTraceroute,

  /// args: detail.
  failed,

  /// args: target, ms.
  portOpen,
  stopped,

  /// args: code.
  exitCode,

  /// args: detail.
  cannotRun,
}

/// Строка вывода: либо вывод утилиты как есть, либо своё сообщение.
class DiagLine {
  const DiagLine(DiagMessage this.message, [this.args = const {}]) : raw = null;
  const DiagLine.raw(String this.raw)
      : message = null,
        args = const {};

  final String? raw;
  final DiagMessage? message;
  final Map<String, String> args;
}

/// Сетевая диагностика системными утилитами: ping, tracert/traceroute.
/// Вывод идёт потоком строк [DiagLine]; [stop] прерывает.
class NetDiag {
  NetDiag(this.kind, this.host, this.port);

  final DiagKind kind;
  final String host;
  final int port;

  final _out = StreamController<DiagLine>.broadcast();
  Stream<DiagLine> get output => _out.stream;

  Process? _process;
  Socket? _socket;
  bool _stopped = false;

  Future<void> start() async {
    if (kIsWeb) {
      _out.add(const DiagLine(DiagMessage.unavailable));
      await _out.close();
      return;
    }
    // Адрес уходит в командную строку - пускаем только безопасные символы
    // и запрещаем ведущий дефис, чтобы адрес не трактовался как флаг утилиты.
    if (!RegExp(r'^[A-Za-z0-9:][A-Za-z0-9.:_\-]*$').hasMatch(host)) {
      _out.add(DiagLine(DiagMessage.badAddress, {'host': host}));
      await _out.close();
      return;
    }
    try {
      switch (kind) {
        case DiagKind.port:
          await _checkPort();
        case DiagKind.ping:
          await _run(
            (!kIsWeb && Platform.isWindows)
                ? ['ping', '-n', '4', host]
                : ['ping', '-c', '4', '-W', '2', '--', host],
          );
        case DiagKind.traceroute:
          if (!kIsWeb && Platform.isWindows) {
            await _run(['tracert', '-d', '-w', '1000', '-h', '30', host]);
          } else if (await _exists('traceroute')) {
            await _run(['traceroute', '-n', '-w', '2', '-q', '1', '--', host]);
          } else if (await _exists('tracepath')) {
            await _run(['tracepath', '-n', '--', host]);
          } else {
            _out.add(const DiagLine(DiagMessage.noTraceroute));
          }
      }
    } catch (e) {
      _out.add(DiagLine(DiagMessage.failed, {'detail': '$e'}));
    } finally {
      await _out.close();
    }
  }

  void stop() {
    _stopped = true;
    final p = _process;
    // На Windows утилита - дочерний процесс cmd: kill() убил бы только cmd.
    if (p != null && !kIsWeb && Platform.isWindows) {
      Process.run('taskkill', ['/PID', '${p.pid}', '/T', '/F']).ignore();
    } else {
      p?.kill();
    }
    _socket?.destroy();
  }

  Future<void> _checkPort() async {
    for (var i = 1; i <= 3 && !_stopped; i++) {
      final sw = Stopwatch()..start();
      try {
        final s = await Socket.connect(host, port, timeout: const Duration(seconds: 4));
        _socket = s;
        sw.stop();
        _out.add(DiagLine(DiagMessage.portOpen, {'target': '$host:$port', 'ms': '${sw.elapsedMilliseconds}'}));
        s.destroy();
      } on SocketException catch (e) {
        _out.add(DiagLine.raw('TCP $host:$port: ${e.osError?.message ?? e.message}'));
      } catch (e) {
        _out.add(DiagLine.raw('TCP $host:$port: $e'));
      }
      if (i < 3 && !_stopped) await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _run(List<String> cmd) async {
    _out.add(DiagLine.raw('\$ ${cmd.join(' ')}'));
    try {
      final p = (!kIsWeb && Platform.isWindows)
          ? await Process.start('cmd', ['/c', 'chcp 65001 >nul & ${cmd.join(' ')}'])
          : await Process.start(cmd.first, cmd.sublist(1), environment: {'LC_ALL': 'C'});
      _process = p;
      final lines = p.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .where((l) => l.trim().isNotEmpty);
      final err = p.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .where((l) => l.trim().isNotEmpty);
      await Future.wait([
        lines.forEach((l) => _out.add(DiagLine.raw(l))),
        err.forEach((l) => _out.add(DiagLine.raw(l))),
      ]);
      final code = await p.exitCode;
      if (_stopped) {
        _out.add(const DiagLine(DiagMessage.stopped));
      } else if (code != 0) {
        _out.add(DiagLine(DiagMessage.exitCode, {'code': '$code'}));
      }
    } catch (e) {
      _out.add(DiagLine(DiagMessage.cannotRun, {'detail': '$e'}));
    }
  }

  Future<bool> _exists(String bin) async {
    try {
      final r = await Process.run('which', [bin]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
