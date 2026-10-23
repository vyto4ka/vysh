import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty/flutter_pty.dart';

import '../../domain/ports/local_shell.dart';
import '../../domain/ports/terminal_shell.dart';

class ProcessLocalShellLauncher implements LocalShellLauncher {
  const ProcessLocalShellLauncher();

  @override
  bool get supported {
    if (kIsWeb) return false;
    return Platform.isWindows ||
        Platform.isLinux ||
        Platform.isMacOS ||
        Platform.isAndroid;
  }

  @override
  String get shellName {
    if (kIsWeb) return '';
    final path = _shellPath();
    final separator = path.lastIndexOf(RegExp(r'[/\\]'));
    return separator < 0 ? path : path.substring(separator + 1);
  }

  @override
  Future<TerminalShell> start({required int columns, required int rows}) async {
    if (kIsWeb) {
      throw const LocalShellFailure(LocalShellError.unsupported);
    }

    final shell = _shellPath();
    final environment = <String, String>{
      'TERM': 'xterm-256color',
      'COLORTERM': 'truecolor',
      'COLUMNS': '$columns',
      'LINES': '$rows',
    };

    if (Platform.isAndroid) {
      final pty = _tryStartPty(shell, columns, rows, environment);
      if (pty != null) return pty;
    }

    if (!Platform.isWindows && !Platform.isAndroid) {
      final script = _findExecutable('script');
      if (script != null) {
        try {
          return await _startWithPty(script, shell, columns, rows, environment);
        } catch (_) {}
      }
    }

    try {
      final process = await Process.start(
        shell,
        _directArguments(),
        environment: environment,
      );
      return _ProcessShell(process, pty: false);
    } catch (e) {
      throw LocalShellFailure(LocalShellError.launchFailed, '$e');
    }
  }

  TerminalShell? _tryStartPty(
    String shell,
    int columns,
    int rows,
    Map<String, String> environment,
  ) {
    try {
      return _PtyShell(
        Pty.start(
          shell,
          arguments: _directArguments(),
          columns: columns,
          rows: rows,
          environment: environment,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<TerminalShell> _startWithPty(
    String script,
    String shell,
    int columns,
    int rows,
    Map<String, String> environment,
  ) async {
    final directory = await Directory.systemTemp.createTemp('vysh-local-');
    final control = File('${directory.path}${Platform.pathSeparator}pty');
    final command = _ptyCommand(shell, control.path, columns, rows);

    final Process process;
    try {
      if (Platform.isMacOS) {
        process = await Process.start(
          script,
          ['-q', '/dev/null', '/bin/sh', '-c', command],
          environment: environment,
        );
      } else {
        process = await Process.start(
          script,
          ['-q', '-f', '-c', command, '/dev/null'],
          environment: environment,
        );
      }
    } catch (_) {
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }

    String? tty;
    int? pid;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final lines = await control.readAsLines();
        if (lines.length >= 2) {
          tty = lines[0].trim();
          pid = int.tryParse(lines[1].trim());
          break;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    if (tty == null || pid == null) {
      try {
        process.kill();
      } catch (_) {}
      try {
        await directory.delete(recursive: true);
      } catch (_) {}
      throw StateError('PTY was not created');
    }

    return _ProcessShell(
      process,
      pty: true,
      childPid: pid,
      ttyPath: tty,
      controlDirectory: directory,
    );
  }

  String _ptyCommand(String shell, String controlPath, int columns, int rows) {
    final control = _quote(controlPath);
    final executable = _quote(shell);
    return 'tty > $control; echo \$\$ >> $control; '
        'stty rows $rows cols $columns 2>/dev/null; '
        'exec $executable${_loginFlag(shell)}';
  }

  List<String> _directArguments() {
    if (Platform.isWindows) return const [];
    return const ['-i'];
  }

  String _shellPath() {
    if (Platform.isWindows) {
      final comspec = Platform.environment['COMSPEC'];
      if (comspec != null && comspec.isNotEmpty) return comspec;
      return 'cmd.exe';
    }
    if (Platform.isAndroid) return '/system/bin/sh';

    final shell = Platform.environment['SHELL'];
    if (shell != null && shell.isNotEmpty && File(shell).existsSync()) {
      return shell;
    }
    for (final candidate in const ['/bin/bash', '/bin/zsh', '/bin/sh']) {
      if (File(candidate).existsSync()) return candidate;
    }
    return '/bin/sh';
  }

  String _loginFlag(String shell) {
    final name = shell.split(RegExp(r'[/\\]')).last.toLowerCase();
    const loginShells = {
      'sh',
      'bash',
      'dash',
      'zsh',
      'ksh',
      'mksh',
      'fish',
      'tcsh',
      'csh',
    };
    return loginShells.contains(name) ? ' -l' : '';
  }

  String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";
}

class _ProcessShell implements TerminalShell {
  _ProcessShell(
    this._process, {
    required bool pty,
    int? childPid,
    String? ttyPath,
    Directory? controlDirectory,
  })  : _pty = pty,
        _childPid = childPid,
        _ttyPath = ttyPath,
        _controlDirectory = controlDirectory {
    _stdoutDone = _pump(_process.stdout);
    _stderrDone = _pump(_process.stderr);
    _process.exitCode.then((_) async {
      _exited = true;
      await Future.wait([_stdoutDone, _stderrDone]);
      if (!_output.isClosed) await _output.close();
      if (!_done.isCompleted) _done.complete();
      _cleanup();
    });
  }

  final Process _process;
  final bool _pty;
  final int? _childPid;
  final String? _ttyPath;
  final Directory? _controlDirectory;

  final _output = StreamController<Uint8List>();
  final _done = Completer<void>();
  late final Future<void> _stdoutDone;
  late final Future<void> _stderrDone;
  Timer? _resizeTimer;
  bool _closed = false;
  bool _exited = false;
  int _lastByte = -1;
  int _columns = 0;
  int _rows = 0;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) {
    if (_closed || _exited) return;
    try {
      _process.stdin.add(data);
    } catch (_) {}
  }

  @override
  void resize(int columns, int rows) {
    if (_ttyPath == null || (columns == _columns && rows == _rows)) return;
    _columns = columns;
    _rows = rows;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 80), () {
      _applyResize(columns, rows);
    });
  }

  void _applyResize(int columns, int rows) {
    final tty = _ttyPath;
    if (tty == null) return;
    final stty = _findExecutable('stty');
    if (stty == null) return;
    final args = Platform.isMacOS
        ? ['-f', tty, 'rows', '$rows', 'cols', '$columns']
        : ['-F', tty, 'rows', '$rows', 'cols', '$columns'];
    Process.run(stty, args).ignore();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _resizeTimer?.cancel();
    if (_exited) return;

    if (Platform.isWindows) {
      Process.run('taskkill', ['/PID', '${_process.pid}', '/T', '/F']).ignore();
    } else {
      final pid = _childPid;
      if (pid != null) {
        try {
          Process.killPid(pid, ProcessSignal.sighup);
        } catch (_) {}
      }
      try {
        _process.kill(ProcessSignal.sighup);
      } catch (_) {}
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        if (!_exited) {
          try {
            _process.kill();
          } catch (_) {}
        }
      });
    }
  }

  Future<void> _pump(Stream<List<int>> stream) {
    final finished = Completer<void>();
    stream.listen(
      _add,
      onError: (_) {},
      onDone: finished.complete,
      cancelOnError: false,
    );
    return finished.future;
  }

  void _add(List<int> data) {
    if (_output.isClosed) return;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    _output.add(_pty ? bytes : _normalizeNewlines(bytes));
  }

  Uint8List _normalizeNewlines(Uint8List bytes) {
    final builder = BytesBuilder(copy: false);
    for (final byte in bytes) {
      if (byte == 0x0a && _lastByte != 0x0d) builder.addByte(0x0d);
      builder.addByte(byte);
      _lastByte = byte;
    }
    return builder.takeBytes();
  }

  void _cleanup() {
    final directory = _controlDirectory;
    if (directory == null) return;
    try {
      directory.delete(recursive: true).ignore();
    } catch (_) {}
  }
}

/// Оболочка в настоящем псевдотерминале (flutter_pty): эхо ввода, Ctrl+C
/// и полноэкранные программы работают так же, как по SSH.
class _PtyShell implements TerminalShell {
  _PtyShell(this._pty) {
    _outputDone = _pump(_pty.output);
    _pty.exitCode.then((_) async {
      _exited = true;
      await _outputDone;
      if (!_output.isClosed) await _output.close();
      if (!_done.isCompleted) _done.complete();
    });
  }

  final Pty _pty;

  final _output = StreamController<Uint8List>();
  final _done = Completer<void>();
  late final Future<void> _outputDone;
  Timer? _resizeTimer;
  bool _closed = false;
  bool _exited = false;
  int _columns = 0;
  int _rows = 0;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void write(Uint8List data) {
    if (_closed || _exited) return;
    try {
      _pty.write(data);
    } catch (_) {}
  }

  @override
  void resize(int columns, int rows) {
    if (_closed || _exited) return;
    if (columns == _columns && rows == _rows) return;
    _columns = columns;
    _rows = rows;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 80), () {
      if (_closed || _exited) return;
      try {
        _pty.resize(rows, columns);
      } catch (_) {}
    });
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _resizeTimer?.cancel();
    if (_exited) return;
    try {
      _pty.kill(ProcessSignal.sighup);
    } catch (_) {}
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      if (_exited) return;
      try {
        _pty.kill();
      } catch (_) {}
    });
  }

  Future<void> _pump(Stream<Uint8List> stream) {
    final finished = Completer<void>();
    stream.listen(
      (data) {
        if (_output.isClosed) return;
        _output.add(data);
      },
      onError: (_) {},
      onDone: finished.complete,
      cancelOnError: false,
    );
    return finished.future;
  }
}

String? _findExecutable(String name) {
  final path = Platform.environment['PATH'];
  if (path == null || path.isEmpty) return null;
  for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
    if (directory.isEmpty) continue;
    final candidate = '$directory${Platform.pathSeparator}$name';
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
