import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:xterm2/core.dart';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/terminal/current_directory.dart';
import 'package:vysh/app/terminal/terminal_session.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/domain/ports/local_shell.dart';
import 'package:vysh/domain/ports/terminal_shell.dart';
import 'package:vysh/domain/ports/secret_store.dart';
import 'package:vysh/domain/ports/session_prompts.dart';
import 'package:vysh/domain/ports/ssh_transport.dart';
import 'package:vysh/domain/ports/sftp.dart';
import 'package:vysh/domain/services/known_hosts.dart';
import 'package:vysh/infra/platform/local_directories.dart';
import 'package:vysh/infra/platform/local_file_session.dart';
import 'package:vysh/infra/local/process_local_shell.dart';

class Unused implements SshConnector, SessionPrompts, SecretStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No SSH or secrets in this test');
}

class Store implements DocumentStore {
  @override
  Object? readSync() => null;
  @override
  Future<bool> write(Object? value) async => true;
}

class Shell implements TerminalShell, DirectoryAwareShell {
  @override
  String get initialDirectory => '/initial';
  Future<String?> directory = Future.value('/changed');
  @override
  Future<String?> workingDirectory() => directory;
  @override
  Stream<Uint8List> get output => const Stream.empty();
  @override
  Future<void> get done => Completer<void>().future;
  @override
  void write(Uint8List data) {}
  @override
  void resize(int columns, int rows) {}
  @override
  void close() {}
}

class Launcher implements LocalShellLauncher {
  Shell shell = Shell();
  @override
  bool get supported => true;
  @override
  String get shellName => 'test';
  @override
  Future<TerminalShell> start({
    required int columns,
    required int rows,
  }) async => shell;
}

TerminalSession session({Launcher? launcher, SftpSession? files}) =>
    TerminalSession(
      host: const Host(id: 'test', label: '', address: 'test'),
      connector: Unused(),
      prompts: Unused(),
      secrets: Unused(),
      knownHosts: KnownHosts(Store()),
      local: launcher != null,
      localShells: launcher,
      localFiles: files ?? const LocalFileSession(),
      onStatus: (_) {},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Android ignores even a readable HOME and starts in its private documents',
    () async {
      final root = await Directory.systemTemp.createTemp('vysh-home-test-');
      try {
        final path = await LocalDirectories.resolve(
          android: true,
          candidates: ['/'],
          documents: () async => '${root.path}/app',
        );
        expect(path, '${root.path}/app');
        expect(await const LocalFileSession().list(path), isEmpty);
        final fallback = await LocalDirectories.resolve(
          android: false,
          candidates: ['${root.path}/missing'],
          documents: () async => path,
        );
        expect(fallback, path);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test('permission failures become a localized domain error', () {
    expect(
      localFilesystemFailure(
        const FileSystemException(
          'Directory listing failed',
          '/',
          OSError('Permission denied', 13),
        ),
      ).code,
      SftpFailureCode.permissionDenied,
    );
  });
  test(
    'accepts absolute OSC paths and rejects malformed or control sequences',
    () {
      expect(reportedDirectory('file://remote/home/a%20b'), '/home/a b');
      expect(
        reportedDirectory('file:///C:/Users/Test%20User'),
        r'C:\Users\Test User',
      );
      expect(reportedDirectory(r'"C:\Users\Test User"'), r'C:\Users\Test User');
      for (final value in [
        'relative',
        'https://host/path',
        'file:///tmp/%0Aevil',
        'file:///tmp?x=1',
        '/tmp/\x00bad',
      ]) {
        expect(reportedDirectory(value), isNull, reason: value);
      }
    },
  );
  test('shell reports work across fragmented OSC 7 and Windows OSC 9;9', () {
    final s = session();
    try {
      s.terminal.write('\x1b]7;file://server/home/test%20folder');
      expect(s.currentDirectory.value, isNull);
      s.terminal.write('\x1b\\');
      expect(s.currentDirectory.value, '/home/test folder');
      s.terminal.write('\x1b]9;9;"C:\\Users\\Test"\x1b\\');
      expect(s.currentDirectory.value, r'C:\Users\Test');
      s.terminal.write('\x1b]7;relative\x07');
      expect(s.currentDirectory.value, r'C:\Users\Test');
    } finally {
      s.dispose();
    }
  });
  test(
    'late OS directory read from a previous local shell is discarded',
    () async {
      final launcher = Launcher();
      final s = session(launcher: launcher);
      try {
        await s.connect();
        expect(await s.sftp(), isA<LocalFileSession>());
        final pending = Completer<String?>();
        launcher.shell.directory = pending.future;
        final oldRead = s.refreshWorkingDirectory();
        launcher.shell = Shell();
        await s.connect();
        pending.complete('/stale');
        await oldRead;
        expect(s.currentDirectory.value, '/initial');
        await s.refreshWorkingDirectory();
        expect(s.currentDirectory.value, '/changed');
      } finally {
        s.dispose();
      }
    },
  );
  test(
    'Windows prompt preserves the configured prompt after the directory report',
    () {
      expect(windowsDirectoryPrompt(r'$P$G'), '\x1b]9;9;"\$P"\x1b\\\$P\$G');
    },
  );
  test(
    'real local shell reports cd without parsing commands or adding stdin probes',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final launcher = ProcessLocalShellLauncher();
      final shell = await launcher.start(columns: 80, rows: 24);
      final subscription = shell.output.listen((_) {});
      try {
        expect(shell, isA<DirectoryAwareShell>());
        shell.write(Uint8List.fromList('cd /tmp\n'.codeUnits));
        String? path;
        final watch = Stopwatch()..start();
        while (watch.elapsed < const Duration(seconds: 4)) {
          path = await (shell as DirectoryAwareShell).workingDirectory();
          if (path == '/tmp' || path == '/private/tmp') break;
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        expect(path, anyOf('/tmp', '/private/tmp'));
      } finally {
        shell.close();
        await subscription.cancel();
      }
    },
  );
  test(
    'POSIX prompt integration reports actual directories after cd',
    () async {
      if (!Platform.isLinux) return;
      final launcher = ProcessLocalShellLauncher();
      if (!['bash', 'sh', 'dash', 'ash'].contains(launcher.shellName)) return;
      final reports = <String>[];
      final terminal = Terminal()..onCurrentDirectoryChange = reports.add;
      final shell = await launcher.start(columns: 80, rows: 24);
      final subscription = shell.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(terminal.write);
      try {
        shell.write(
          Uint8List.fromList(
            utf8.encode('$posixDirectoryReporting\rcd /tmp\r'),
          ),
        );
        final watch = Stopwatch()..start();
        while (!reports.contains('/tmp') &&
            watch.elapsed < const Duration(seconds: 4)) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        expect(reports, contains('/tmp'));
      } finally {
        shell.close();
        await subscription.cancel();
      }
    },
  );
  test('Windows cmd reports the real directory through its prompt', () async {
    if (!Platform.isWindows) return;
    final folder = await Directory.systemTemp.createTemp('vysh-cmd-cwd-');
    final reports = <String>[];
    final terminal = Terminal()
      ..onCurrentDirectoryChange = (value) {
        final path = reportedDirectory(value);
        if (path != null) reports.add(path);
      };
    final shell = await const ProcessLocalShellLauncher().start(
      columns: 80,
      rows: 24,
    );
    final subscription = shell.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);
    try {
      shell.write(
        Uint8List.fromList(utf8.encode('cd /d "${folder.path}"\r\n')),
      );
      final watch = Stopwatch()..start();
      while (!reports.any(
            (p) => p.toLowerCase() == folder.path.toLowerCase(),
          ) &&
          watch.elapsed < const Duration(seconds: 8)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        reports.map((p) => p.toLowerCase()),
        contains(folder.path.toLowerCase()),
      );
    } finally {
      shell.close();
      await subscription.cancel();
      await shell.done.timeout(const Duration(seconds: 5));
      await folder.delete(recursive: true);
    }
  });

  test(
    'remote SSH session tracks shell directory out-of-band on prompt output without stdin writes and yields to OSC 7',
    () async {
      final out = StreamController<Uint8List>.broadcast();
      final stdinWrites = <List<int>>[];
      var execCalls = 0;
      var remoteCwd = '/home/admin';

      final remoteShell = _FakeSshShell(out.stream, onWrite: stdinWrites.add);
      final transport = _FakeSshTransport(
        remoteShell,
        onExec: (cmd) async {
          expect(cmd, remoteShellDirectoryCommand);
          execCalls++;
          return '$remoteCwd\n';
        },
      );
      final s = TerminalSession(
        host: const Host(
          id: 'ssh1',
          label: 'srv',
          address: '10.0.0.1',
          username: 'admin',
        ),
        connector: _FakeSshConnector(transport),
        prompts: Unused(),
        secrets: _EmptySecrets(),
        knownHosts: KnownHosts(Store()),
        onStatus: (_) {},
      );

      final seen = <String?>[];
      s.currentDirectory.addListener(() => seen.add(s.currentDirectory.value));

      try {
        await s.connect();
        await s.refreshWorkingDirectory(force: true);
        expect(s.currentDirectory.value, '/home/admin');
        expect(execCalls, 1);
        expect(stdinWrites, isEmpty);

        // Вывод приглашения после cd запускает фоновую проверку через 220 мс.
        remoteCwd = '/var/log/nginx';
        out.add(Uint8List.fromList(utf8.encode('admin@srv:/var/log/nginx\$ ')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(s.currentDirectory.value, '/var/log/nginx');
        expect(execCalls, 2);
        expect(stdinWrites, isEmpty);

        // В простое (без нового вывода оболочки) повторный опрос не дёргает exec.
        await s.refreshWorkingDirectory();
        expect(execCalls, 2);

        // Если оболочка сама прислала OSC 7, дальнейший вывод обновляет путь
        // напрямую и больше не вызывает фоновый exec.
        out.add(
          Uint8List.fromList(
            utf8.encode('\x1b]7;file://srv/etc/systemd\x07admin@srv\$ '),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(s.currentDirectory.value, '/etc/systemd');
        expect(execCalls, 2);
      } finally {
        s.dispose();
        await out.close();
      }
    },
  );
}

class _FakeSshShell implements SshShell {
  _FakeSshShell(this.output, {required this.onWrite});
  @override
  final Stream<Uint8List> output;
  final void Function(List<int>) onWrite;
  @override
  Future<void> get done => Completer<void>().future;
  @override
  void write(Uint8List data) => onWrite(data);
  @override
  void resize(int columns, int rows) {}
  @override
  void close() {}
}

class _FakeSshTransport implements SshTransport {
  _FakeSshTransport(this.shell, {required this.onExec});
  final SshShell shell;
  final Future<String> Function(String) onExec;
  @override
  Future<void> get done => Completer<void>().future;
  @override
  String? get serverVersion => 'SSH-2.0-OpenSSH';
  @override
  Future<SshShell> openShell({required int columns, required int rows}) async =>
      shell;
  @override
  Future<String> exec(
    String command, {
    Duration timeout = const Duration(seconds: 10),
  }) => onExec(command);
  @override
  Future<SftpSession> openSftp() => throw UnimplementedError();
  @override
  Future<void> close() async {}
}

class _FakeSshConnector implements SshConnector {
  _FakeSshConnector(this.transport);
  final SshTransport transport;
  @override
  bool isKeyEncrypted(String pem) => false;
  @override
  Future<SshTransport> connect(SshConnectRequest r) async => transport;
}

class _EmptySecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}
