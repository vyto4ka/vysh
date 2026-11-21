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
    for (var attempt = 0; attempt < 20; attempt++) {
      if (!await temp.exists()) return;
      try {
        await temp.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 19) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
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
      expect(
        Directory(WindowsZipUpdate.findPayloadRoot(root)!).absolute.uri,
        nested.absolute.uri,
      );
      await File('${root.path}/vysh.exe').writeAsString('exe');
      expect(WindowsZipUpdate.findPayloadRoot(root), root.path);
    },
  );

  group('Windows PowerShell 5.1 updater integration', () {
    Future<File> compileApp(Directory dir, String marker) async {
      await dir.create(recursive: true);
      final code = File('${dir.path}/fixture.cs'.replaceAll('/', '\\'));
      // The fixture remains alive long enough to hold the executable open.
      await code.writeAsString(
        '''using System; using System.IO; using System.Threading;
class Fixture { static void Main() {
File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "started.txt"), "$marker");
Thread.Sleep(30000);
} }''',
      );
      final exe = File('${dir.path}/vysh.exe'.replaceAll('/', '\\'));
      final csc =
          '${Platform.environment['SystemRoot']}\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe';
      final result = await Process.run(csc, [
        '/nologo',
        '/target:winexe',
        '/out:${exe.path}',
        code.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason:
            'csc=$csc; source=${code.path}; exists=${await code.exists()}; exe=${exe.path}\n${result.stdout}\n${result.stderr}',
      );
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
          if (newPid != null) Process.killPid(newPid);
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
      'PowerShell helper survives the Dart application exiting',
      () async {
        final sdk = Platform.environment['FLUTTER_ROOT']!;
        final dart = '$sdk/bin/cache/dart-sdk/bin/dart.exe'.replaceAll(
          '/',
          r'\',
        );
        final script = File('${temp.path}/launcher.dart'.replaceAll('/', r'\'));
        final launcher = File(
          '${temp.path}/launcher.exe'.replaceAll('/', r'\'),
        );
        final marker = File('${temp.path}/survived.txt');
        await script.writeAsString(r"""import 'dart:io';
Future<void> main(List<String> args) async {
  final process = await Process.start(args[0], [
    '-NoProfile', '-NonInteractive', '-Command',
    r'[IO.File]::WriteAllText($env:VYSH_UPDATE_PROBE + ".ready", "ready"); Start-Sleep -Seconds 1; [IO.File]::WriteAllText($env:VYSH_UPDATE_PROBE, "survived")'
  ], environment: {'VYSH_UPDATE_PROBE': args[1]}, mode: ProcessStartMode.normal);
  await process.stdin.close();
  process.stdout.drain<void>(); process.stderr.drain<void>();
  final ready = File(args[1] + '.ready');
  for (var i = 0; i < 200; i++) {
    if (await ready.exists()) exit(0);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  exit(1);
}
""");
        final compilation = await Process.run(dart, [
          'compile',
          'exe',
          script.path,
          '-o',
          launcher.path,
        ]);
        expect(
          compilation.exitCode,
          0,
          reason: '${compilation.stdout}\n${compilation.stderr}',
        );
        final result = await Process.run(launcher.path, [
          WindowsUpdateHandoff.powershellExecutable,
          marker.path,
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        await waitForFile(marker);
        expect(await marker.readAsString(), 'survived');
      },
      skip: !Platform.isWindows || Platform.environment['FLUTTER_ROOT'] == null,
      timeout: const Timeout(Duration(minutes: 3)),
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

    test(
      'hung old process is force-terminated after grace period and updated cleanly',
      () async {
        final source = Directory('${temp.path}/hung_new');
        final target = Directory('${temp.path}/hung_installed');
        final newExe = await compileApp(source, 'new-after-hang');
        final oldExe = await compileApp(target, 'old-hung');
        await Directory('${source.path}/data').create(recursive: true);
        await Directory('${target.path}/data').create(recursive: true);
        await File('${source.path}/data/app.so').writeAsString('aot-v2');
        await File('${target.path}/data/app.so').writeAsString('aot-v1');

        final old = await Process.start(
          oldExe.path,
          [],
          mode: ProcessStartMode.detached,
        );
        int? newPid;
        addTearDown(() async {
          Process.killPid(old.pid);
          if (newPid != null) Process.killPid(newPid);
          await Future<void>.delayed(const Duration(milliseconds: 500));
        });
        await waitForFile(File('${target.path}/started.txt'));

        final staging = Directory('${temp.path}/hung_staging');
        await staging.create();
        final cleanup = Directory('${temp.path}/hung_download');
        await cleanup.create();
        final h = await WindowsUpdateHandoff.start(
          staging: staging,
          sourceDir: source.path,
          targetDir: target.path,
          exePath: oldExe.path,
          appPid: old.pid,
          cleanupDir: cleanup.path,
          gracefulWaitMs: 800,
          noErrorDialog: true,
        );
        await h.waitUntilReady(timeout: const Duration(seconds: 20));
        await File('${target.path}/started.txt').delete();
        // Confirm handoff WITHOUT killing old.pid from Dart: updater must
        // wait gracefully, then force-terminate the hung process and finish.
        await h.proceed();

        await waitForFile(File('${target.path}/started.txt'));
        expect(
          await File('${target.path}/started.txt').readAsString(),
          'new-after-hang',
        );
        final timer = Stopwatch()..start();
        while (timer.elapsed < const Duration(seconds: 15)) {
          final status = jsonDecode(
            (await h.statusFile.readAsString()).replaceFirst('\u{FEFF}', ''),
          );
          if (status['state'] == 'complete') {
            newPid = int.parse(status['detail']);
            break;
          }
          if (status['state'] == 'failed') fail('${status['detail']}');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(newPid, isNotNull);
        expect(
          await UpdateInstaller.sha256OfFile(oldExe),
          await UpdateInstaller.sha256OfFile(newExe),
        );
        expect(
          await File('${target.path}/data/app.so').readAsString(),
          'aot-v2',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'rolls back modified files when a later target file is locked externally',
      () async {
        final source = Directory('${temp.path}/rb_new');
        final target = Directory('${temp.path}/rb_installed');
        final newExe = await compileApp(source, 'new-rb');
        final oldExe = await compileApp(target, 'old-rb');
        await Directory('${source.path}/data').create(recursive: true);
        await Directory('${target.path}/data').create(recursive: true);
        await File('${source.path}/data/app.so').writeAsString('aot-new');
        await File('${target.path}/data/app.so').writeAsString('aot-old');
        await File('${source.path}/added_only_in_new.txt').writeAsString('x');
        final srcTail = File('${source.path}/z_locked.dat');
        final dstTail = File('${target.path}/z_locked.dat');
        await srcTail.writeAsString('locked-new');
        await dstTail.writeAsString('locked-old');

        final oldExeHash = await UpdateInstaller.sha256OfFile(oldExe);
        expect(oldExeHash, isNot(await UpdateInstaller.sha256OfFile(newExe)));

        final lockReady = File('${temp.path}/lock.ready');
        final locker = await Process.start(
          WindowsUpdateHandoff.powershellExecutable,
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r'$s = [IO.File]::Open($env:LOCK_PATH, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read); [IO.File]::WriteAllText($env:LOCK_READY, "1"); Start-Sleep -Seconds 30',
          ],
          environment: {
            'LOCK_PATH': dstTail.path.replaceAll('/', r'\'),
            'LOCK_READY': lockReady.path.replaceAll('/', r'\'),
          },
        );
        addTearDown(() async {
          locker.kill();
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await waitForFile(lockReady);

        // Dummy already-exited PID so updater proceeds straight to copying.
        final exitedDummy = await Process.start(
          WindowsUpdateHandoff.powershellExecutable,
          ['-NoProfile', '-NonInteractive', '-Command', 'exit 0'],
        );
        await exitedDummy.exitCode;

        final staging = Directory('${temp.path}/rb_staging');
        await staging.create();
        final cleanup = Directory('${temp.path}/rb_download');
        await cleanup.create();
        final h = await WindowsUpdateHandoff.start(
          staging: staging,
          sourceDir: source.path,
          targetDir: target.path,
          exePath: oldExe.path,
          appPid: exitedDummy.pid,
          cleanupDir: cleanup.path,
          gracefulWaitMs: 100,
          copyRetries: 2,
          noErrorDialog: true,
        );
        await h.waitUntilReady(timeout: const Duration(seconds: 20));
        await h.proceed();

        Map<String, dynamic>? failedStatus;
        final timer = Stopwatch()..start();
        while (timer.elapsed < const Duration(seconds: 20)) {
          if (await h.statusFile.exists()) {
            final raw = (await h.statusFile.readAsString()).replaceFirst(
              '\u{FEFF}',
              '',
            );
            if (raw.trim().isNotEmpty) {
              final parsed = jsonDecode(raw) as Map<String, dynamic>;
              if (parsed['state'] == 'failed') {
                failedStatus = parsed;
                break;
              }
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(failedStatus, isNotNull);
        expect('${failedStatus!['detail']}', contains('z_locked.dat'));

        // Neither vysh.exe nor data/app.so may remain on the new version.
        expect(await UpdateInstaller.sha256OfFile(oldExe), oldExeHash);
        expect(
          await File('${target.path}/data/app.so').readAsString(),
          'aot-old',
        );
        expect(
          await File('${target.path}/added_only_in_new.txt').exists(),
          isFalse,
        );
        locker.kill();
        await locker.exitCode;
        expect(await dstTail.readAsString(), 'locked-old');
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }, skip: !Platform.isWindows);
}
