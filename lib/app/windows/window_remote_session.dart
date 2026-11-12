import 'dart:async';
import 'dart:io';
import 'package:xterm2/core.dart';
import '../../domain/models/session_tab.dart';
import '../../domain/models/host.dart';
import '../../domain/ports/sftp.dart';
import '../../domain/ports/ssh_transport.dart';
import '../terminal/terminal_session.dart';
import 'terminal_mirror.dart';
import 'window_protocol.dart';

/// Input is encoded by the owning terminal, including bracketed paste, kitty
/// keyboard modes and application cursor keys. Only rendered cells are mirrored.
class WindowTerminal extends Terminal {
  WindowTerminal(this.request, {required super.maxLines}) {
    onOutput = (text) => request('raw', {'text': text}).ignore();
    onResize = (width, height, pixelWidth, pixelHeight) {
      if (!applying) {
        unawaited(
          request('resize', {
            'width': width,
            'height': height,
            'pixelWidth': pixelWidth,
            'pixelHeight': pixelHeight,
          }).catchError((Object _) => null),
        );
      }
    };
  }
  final WindowRpc request;
  bool applying = false;

  @override
  bool keyInput(
    TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
    bool superKey = false,
    bool capsLock = false,
    bool numLock = false,
    TerminalKeyEventType type = TerminalKeyEventType.press,
    String? text,
  }) {
    unawaited(
      request('key', {
        'key': key.name,
        'shift': shift,
        'alt': alt,
        'ctrl': ctrl,
        'meta': superKey,
        'capsLock': capsLock,
        'numLock': numLock,
        'event': type.name,
        'text': text,
      }).catchError((Object _) => null),
    );
    return true;
  }

  @override
  void textInput(String text) => request('text', {'text': text}).ignore();
  @override
  void paste(String text) => request('paste', {'text': text}).ignore();
}

class WindowRemoteSession extends TerminalSession {
  WindowRemoteSession({
    required super.host,
    required super.local,
    required this.request,
    required int maxLines,
  }) : super.view(terminal: WindowTerminal(request, maxLines: maxLines));
  final WindowRpc request;
  late final _decoder = TerminalMirrorDecoder(terminal);
  SessionStatus _remoteStatus = SessionStatus.connecting;
  String? _version;
  @override
  SessionStatus get status => _remoteStatus;
  @override
  String? get serverVersion => _version;

  void apply(Map data) {
    final t = terminal as WindowTerminal;
    if (data['frame'] case final Map frame) {
      t.applying = true;
      try {
        _decoder.apply(frame);
      } finally {
        t.applying = false;
      }
    }
    _remoteStatus = SessionStatus.values.byName(data['status']);
    _version = data['version'];
    currentDirectory.value = data['directory'];
    final failure = data['failure'] as Map?;
    lastFailure = failure == null
        ? null
        : SshFailure(
            SshError.values.byName(failure['error']),
            Map<String, String>.from(failure['args']),
          );
    droppedAfterReady = data['dropped'] == true;
    if (data['log'] case final List log) {
      connLog.clear();
      for (final line in log) {
        connLog.add(
          ConnLogEntry(
            (s) => s.isRu ? line['ru'] : line['en'],
            debug: line['debug'] == true,
            error: line['error'] == true,
          ),
        );
      }
    }
    notifyListeners();
  }

  @override
  Future<void> connect() async {
    await request('reconnect', {});
  }

  @override
  Future<void> refreshWorkingDirectory() async {
    await request('directory', {});
  }

  @override
  Future<String> exec(
    String command, {
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      await request('exec', {
            'command': command,
            'timeout': timeout.inMilliseconds,
          })
          as String;
  @override
  void resetSftp() => request('resetSftp', {}).ignore();
  @override
  Future<SftpSession> sftp() async => WindowSftpSession(request);
}

/// File bytes stay in the common process filesystem. Remote operations use the
/// existing owner's SFTP channel, with progress and cancellation across engines.
class WindowSftpSession implements SftpSession {
  WindowSftpSession(this.request);
  final WindowRpc request;
  Future<dynamic> _call(
    String operation, [
    Map<String, Object?> data = const {},
  ]) => request('sftp', {'operation': operation, ...data});
  @override
  Future<String> home() async => await _call('home') as String;
  @override
  Future<List<RemoteEntry>> list(String path) async =>
      (await _call('list', {'path': path}) as List)
          .map((e) => decodeEntry(e))
          .toList();
  @override
  Future<RemoteEntry> stat(String path) async =>
      decodeEntry(await _call('stat', {'path': path}));
  @override
  Future<void> mkdir(String path) async {
    await _call('mkdir', {'path': path});
  }

  @override
  Future<void> rename(String from, String to) async {
    await _call('rename', {'path': from, 'to': to});
  }

  @override
  Future<void> removeFile(String path) async {
    await _call('removeFile', {'path': path});
  }

  @override
  Future<void> removeDir(String path) async {
    await _call('removeDir', {'path': path});
  }

  @override
  Future<void> chmod(String path, int mode) async {
    await _call('chmod', {'path': path, 'mode': mode});
  }

  @override
  Future<void> close() async {} // The owner controls the shared channel lifetime.

  Future<void> _transfer(
    String operation,
    String path,
    File local,
    CancelToken cancel,
    ProgressCallback onProgress,
  ) async {
    if (cancel.isCancelled) throw const TransferCancelled();
    final job = newId();
    var active = true, polling = false;
    cancel.onCancel(() {
      if (active) request('transferCancel', {'job': job}).ignore();
    });
    final timer = Timer.periodic(const Duration(milliseconds: 160), (_) async {
      if (!active || polling) return;
      polling = true;
      try {
        final progress = await request('transferProgress', {'job': job});
        if (active && progress is int) onProgress(progress);
      } catch (_) {
        // The in-flight operation delivers the error to the transfer queue.
      } finally {
        polling = false;
      }
    });
    try {
      final bytes = await _call(operation, {
        'path': path,
        'localPath': local.path,
        'job': job,
      });
      if (bytes is int) onProgress(bytes);
    } finally {
      active = false;
      timer.cancel();
    }
  }

  @override
  Future<void> download(
    String remotePath,
    File local, {
    required CancelToken cancel,
    required ProgressCallback onProgress,
  }) => _transfer('download', remotePath, local, cancel, onProgress);
  @override
  Future<void> upload(
    File local,
    String remotePath, {
    required CancelToken cancel,
    required ProgressCallback onProgress,
  }) => _transfer('upload', remotePath, local, cancel, onProgress);
}
