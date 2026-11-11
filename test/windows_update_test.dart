import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/infra/update/update_installer.dart';

void main() {
  late Directory temp;
  late WindowsUpdateHandoff handoff;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vysh-updater-test-');
    handoff = WindowsUpdateHandoff(
      File('${temp.path}/status.json'),
      File('${temp.path}/proceed'),
      File('${temp.path}/cancel'),
    );
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('Dart creates a persistent log before a helper is started', () async {
    final marker = 'startup-test-${DateTime.now().microsecondsSinceEpoch}';
    await WindowsUpdateLog.write(marker);
    expect(await WindowsUpdateLog.file.readAsString(), contains(marker));
  });

  test('does not hand off before installer confirms readiness', () async {
    var ready = false;
    final pending = handoff
        .waitUntilReady(timeout: const Duration(seconds: 2))
        .then((_) => ready = true);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(ready, isFalse);
    expect(await handoff.proceedFile.exists(), isFalse);
    await handoff.statusFile.writeAsString(
      '\u{FEFF}${jsonEncode({'state': 'ready', 'detail': ''})}',
    );
    await pending;
    expect(ready, isTrue);
    expect(await handoff.proceedFile.exists(), isFalse);
    await handoff.proceed();
    expect(await handoff.proceedFile.exists(), isTrue);
  });
  test('startup failure is reported without closing the application', () async {
    await handoff.statusFile.writeAsString(
      jsonEncode({'state': 'failed', 'detail': 'Access denied'}),
    );
    await expectLater(
      handoff.waitUntilReady(),
      throwsA(
        isA<UpdateInstallException>()
            .having((e) => e.error, 'error', UpdateInstallError.copyFailed)
            .having((e) => e.detail, 'detail', contains('Access denied')),
      ),
    );
    expect(await handoff.proceedFile.exists(), isFalse);
  });
  test('a helper which never starts times out without handing off', () async {
    await expectLater(
      handoff.waitUntilReady(timeout: const Duration(milliseconds: 100)),
      throwsA(isA<UpdateInstallException>()),
    );
    expect(await handoff.proceedFile.exists(), isFalse);
    await handoff.cancel();
    expect(await handoff.cancelFile.exists(), isTrue);
  });
  test(
    'payload root can be found at the archive root or in a nested folder',
    () async {
      final root = Directory('${temp.path}/payload');
      await root.create();
      expect(WindowsZipUpdate.findPayloadRoot(root), isNull);
      final nested = Directory('${root.path}/vysh');
      await nested.create();
      await File('${nested.path}/vysh.exe').writeAsString('exe');
      expect(WindowsZipUpdate.findPayloadRoot(root), nested.path);
      await File('${root.path}/vysh.exe').writeAsString('exe');
      expect(WindowsZipUpdate.findPayloadRoot(root), root.path);
    },
  );

  group('Windows PowerShell 5.1 updater integration', () {
    Future<File> compileApp(Directory dir, String marker) async {
      await dir.create(recursive: true);
      final code = File('${dir.path}/fixture.cs');
      // The fixture remains alive long enough to hold the executable open.
      await code.writeAsString(
        '''using System; using System.IO; using System.Threading;
class Fixture { static void Main() {
File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "started.txt"), "$marker");
Thread.Sleep(30000);
} }''',
      );
      final exe = File('${dir.path}/vysh.exe');
      final csc =
          '${Platform.environment['SystemRoot']}\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe';
      final result = await Process.run(csc, [
        '/nologo',
        '/target:winexe',
        '/out:${exe.path}',
        code.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      await code.delete();
      return exe;
    }

    Future<void> waitForFile(File file) async {
      final timer = Stopwatch()..start();
      while (!await file.exists() &&
          timer.elapsed < const Duration(seconds: 20)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await file.exists(), isTrue, reason: file.path);
    }

    test(
      'replaces a locked old executable after exit and launches the new one',
      () async {
        final source = Directory(
          '${temp.path}/new build with spaces/Приложение',
        );
        final target = Directory(
          '${temp.path}/installed with spaces/Приложение',
        );
        final newExe = await compileApp(source, 'new');
        final oldExe = await compileApp(target, 'old');
        final old = await Process.start(
          oldExe.path,
          [],
          mode: ProcessStartMode.detached,
        );
        int? newPid;
        addTearDown(() async {
          Process.killPid(old.pid);
          if (newPid != null) Process.killPid(newPid!);
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });
        await waitForFile(File('${target.path}/started.txt'));
        final staging = Directory('${temp.path}/staging');
        await staging.create();
        final cleanup = Directory('${temp.path}/download');
        await cleanup.create();
        final h = await WindowsUpdateHandoff.start(
          staging: staging,
          sourceDir: source.path,
          targetDir: target.path,
          exePath: oldExe.path,
          appPid: old.pid,
          cleanupDir: cleanup.path,
          noErrorDialog: true,
        );
        await h.waitUntilReady(timeout: const Duration(seconds: 20));
        expect(await File('${target.path}/started.txt').readAsString(), 'old');
        expect(
          await UpdateInstaller.sha256OfFile(oldExe),
          isNot(await UpdateInstaller.sha256OfFile(newExe)),
        );
        await File('${target.path}/started.txt').delete();
        await h.proceed();
        // Handoff alone must not overwrite the still-running executable.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(await File('${target.path}/started.txt').exists(), isFalse);
        Process.killPid(old.pid);
        await waitForFile(File('${target.path}/started.txt'));
        expect(await File('${target.path}/started.txt').readAsString(), 'new');
        final timer = Stopwatch()..start();
        while (timer.elapsed < const Duration(seconds: 10)) {
          final status = jsonDecode(
            (await h.statusFile.readAsString()).replaceFirst('\u{FEFF}', ''),
          );
          if (status['state'] == 'complete') {
            newPid = int.parse(status['detail']);
            break;
          }
          if (status['state'] == 'failed') fail(status['detail']);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(newPid, isNotNull);
        expect(
          await UpdateInstaller.sha256OfFile(oldExe),
          await UpdateInstaller.sha256OfFile(newExe),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'invalid payload reports failure before application handoff',
      () async {
        final staging = Directory('${temp.path}/staging');
        await staging.create();
        final target = Directory('${temp.path}/target');
        await target.create();
        final h = await WindowsUpdateHandoff.start(
          staging: staging,
          sourceDir: temp.path,
          targetDir: target.path,
          exePath: '${target.path}/vysh.exe',
          appPid: pid,
          cleanupDir: '${temp.path}/download',
          noErrorDialog: true,
        );
        await expectLater(
          h.waitUntilReady(timeout: const Duration(seconds: 15)),
          throwsA(
            isA<UpdateInstallException>().having(
              (e) => e.detail,
              'detail',
              contains('vysh.exe'),
            ),
          ),
        );
        expect(await h.proceedFile.exists(), isFalse);
      },
    );
  }, skip: !Platform.isWindows);
}
