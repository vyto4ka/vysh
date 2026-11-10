import 'package:flutter_test/flutter_test.dart';

import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/infra/update/update_installer.dart';
import 'package:vysh/infra/update/update_service.dart';
import 'package:vysh/ui/dialogs/update_dialog.dart' show sanitizeReleaseNotes;

late DocumentStore Function() _defaultStateStore;
late Future<UpdateInfo?> Function() _defaultFetch;

void main() {
  _defaultStateStore = UpdateService.stateStore;
  _defaultFetch = UpdateService.fetchUpdate;
  TestWidgetsFlutterBinding.ensureInitialized();

  group('сравнение версий', () {
    test('stripTag убирает ведущую v', () {
      expect(UpdateService.stripTag('v0.6.0'), '0.6.0');
      expect(UpdateService.stripTag('0.6.0'), '0.6.0');
      expect(UpdateService.stripTag('v10.0.1-beta'), '10.0.1');
    });

    test('compareVersions по номерам', () {
      expect(UpdateService.compareVersions('v0.6.0', '0.5.9'), 1);
      expect(UpdateService.compareVersions('0.5.9', 'v0.6.0'), -1);
      expect(UpdateService.compareVersions('v0.5.9', '0.5.9'), 0);
      // Разная длина дополняется нулями: 1.0 равна 1.
      expect(UpdateService.compareVersions('1.0', '1'), 0);
      expect(UpdateService.compareVersions('1.1', '1'), 1);
    });

    test('isNewerRelease: равные версии не новее', () {
      expect(UpdateService.isNewerRelease('v0.6.0', '0.6.0'), isFalse);
    });

    test('isNewerRelease: тот же номер, но релиз переиздан позже', () {
      // 0.5.9 выше 0.5.9b? нет: префикс обрезается, даты решают.
      final later = DateTime(2026, 11, 8);
      final earlier = DateTime(2026, 11, 7);
      // Версии равны по номерам - false независимо от дат.
      expect(
        UpdateService.isNewerRelease(
          '0.5.9',
          '0.5.9',
          latestPublished: later,
          currentPublished: earlier,
        ),
        isFalse,
      );
    });

    test('isNewerRelease: меньший номер никогда не считается новым (нет отката)', () {
      // Выпуск исправления для старой ветки не должен предлагать откат,
      // даже если он опубликован позже.
      expect(
        UpdateService.isNewerRelease(
          '0.5.8',
          '0.5.9',
          latestPublished: DateTime(2026, 11, 8),
          currentPublished: DateTime(2026, 11, 7),
        ),
        isFalse,
      );
      expect(
        UpdateService.isNewerRelease('0.5.8', '0.5.9'),
        isFalse,
      );
    });
  });

  group('buildUpdateInfo', () {
    final assets = [
      {
        'name': 'vysh-v0.6.0-windows-x64.zip',
        'size': 25 * 1024 * 1024,
        'browser_download_url':
            'https://github.com/vyto4ka/vysh/releases/download/v0.6.0/vysh-v0.6.0-windows-x64.zip',
      },
      {
        'name': 'vysh-v0.6.0-linux-x64.tar.gz',
        'size': 20 * 1024 * 1024,
        'browser_download_url':
            'https://github.com/vyto4ka/vysh/releases/download/v0.6.0/vysh-v0.6.0-linux-x64.tar.gz',
      },
      {
        'name': 'vysh-v0.6.0-android-arm64-v8a.apk',
        'size': 12 * 1024 * 1024,
        'browser_download_url': 'https://example.com/a.apk',
      },
    ];

    Map<String, dynamic> release(String tag, List assets, {DateTime? at}) => {
          'tag_name': tag,
          'assets': assets,
          'body': 'Текст релиза',
          'published_at': (at ?? DateTime(2026, 11, 8)).toIso8601String(),
          'html_url': 'https://github.com/vyto4ka/vysh/releases/tag/$tag',
        };

    test('нет релизов новее - null', () {
      final releases = [release('v0.5.9', assets)];
      expect(UpdateService.buildUpdateInfo(releases, '0.5.9'), isNull);
    });

    test('текущая версия выше тегов - null (даты совпадают не нужны)', () {
      final releases = [release('v0.5.9', assets)];
      expect(UpdateService.buildUpdateInfo(releases, '0.6.0'), isNull);
    });

    test('выбирается наибольший номер версии, даже если старую ветку выпустили позже', () {
      final releases = [
        release('v0.5.10', assets, at: DateTime(2026, 11, 9)),
        release('v0.6.0', assets, at: DateTime(2026, 11, 8)),
      ];
      final info = UpdateService.buildUpdateInfo(releases, '0.5.9');
      expect(info?.latestVersion, 'v0.6.0');
    });

    test('APK выбирается по ABI процесса из Platform.version', () {
      expect(
        UpdateService.androidAbiFromVersion(
          '3.8.0 (stable) on "android_arm"',
        ),
        'armeabi-v7a',
      );
      expect(
        UpdateService.androidAbiFromVersion(
          '3.8.0 (stable) on "android_arm64"',
        ),
        'arm64-v8a',
      );
      expect(
        UpdateService.androidAbiFromVersion(
          '3.8.0 (stable) on "android_x64"',
        ),
        'x86_64',
      );
      final apkAssets = [
        {'name': 'vysh-v0.6.0-android-arm64-v8a.apk'},
        {'name': 'vysh-v0.6.0-android-armeabi-v7a.apk'},
      ];
      expect(
        UpdateService.findApkAsset(apkAssets, 'armeabi-v7a')?['name'],
        'vysh-v0.6.0-android-armeabi-v7a.apk',
      );
    });
  });

  group('parseSha256', () {
    test('берёт хеш своей строки из манифеста', () {
      const manifest = '''
aaaabbbbccccddddeeeeffff0000111122223333444455556666777788889999  vysh-v0.6.0-windows-x64.zip
1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff  other-file.zip
''';
      expect(
        UpdateInstaller.parseSha256(
            manifest, 'vysh-v0.6.0-windows-x64.zip'),
        'aaaabbbbccccddddeeeeffff0000111122223333444455556666777788889999',
      );
    });

    test('не подставляет хеш чужого файла, если нашего нет в SHA256SUMS', () {
      const manifest = '''
aaaabbbbccccddddeeeeffff0000111122223333444455556666777788889999  other-file.zip
''';
      expect(
        UpdateInstaller.parseSha256(manifest, 'no-such-file.zip'),
        isNull,
      );
    });

    test('одиночный хеш без имени файла (<файл>.sha256) принимается', () {
      const manifest =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n';
      expect(
        UpdateInstaller.parseSha256(manifest, 'any.zip'),
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
    });

    test('пустой манифест - null', () {
      expect(UpdateInstaller.parseSha256('', 'x.zip'), isNull);
    });
  });

  group('MacOSDmgUpdate.mountPointOf', () {
    test('находит точку монтирования, в том числе с пробелами в имени тома', () {
      const out = '/dev/disk4\tGUID_partition_scheme\t\n'
          '/dev/disk4s1\tApple_HFS\t/Volumes/vysh 0.5.11\n';
      expect(MacOSDmgUpdate.mountPointOf(out), '/Volumes/vysh 0.5.11');
    });
  });

  group('extensionFromUrl', () {
    test('распознаёт tar.gz и zip', () {
      expect(
        UpdateInstaller.extensionFromUrl(
            'https://github.com/x/vysh-v0.6.0-linux-x64.tar.gz'),
        '.tar.gz',
      );
      expect(
        UpdateInstaller.extensionFromUrl(
            'https://github.com/x/vysh-v0.6.0-windows-x64.zip'),
        '.zip',
      );
    });

    test('неизвестный формат - исключение', () {
      expect(
        () => UpdateInstaller.extensionFromUrl('https://x/y.exe'),
        throwsA(isA<UpdateInstallException>()),
      );
    });
  });

  group('sanitizeReleaseNotes (диалог)', () {
    test('HTML-теги и бейджи убраны, ссылки развёрнуты', () {
      const raw = '<p>Что нового</p>\n'
          '[![Windows](https://img.shields.io/badge/Windows-x64-blue)](https://github.com/vyto4ka/vysh/releases)\n'
          'Подробнее в [документации](https://example.com/docs).';
      final text = sanitizeReleaseNotes(raw);
      expect(text, isNot(contains('<p>')));
      expect(text, isNot(contains('shields.io')));
      expect(text, contains('документации (https://example.com/docs)'));
    });

    test('пустые строки схлопнуты', () {
      expect(sanitizeReleaseNotes('a\n\n\n\nb'), 'a\n\nb');
    });
  });

  group('периодичность и пропуск версии', () {
    test('skipVersion: пропущенная версия узнаётся', () async {
      final store = _MemoryStore();
      UpdateService.stateStore = () => store;
      addTearDown(() => UpdateService.stateStore =
          _defaultStateStore);

      expect(await UpdateService.isSkipped('v0.6.0'), isFalse);
      await UpdateService.skipVersion('v0.6.0');
      expect(await UpdateService.isSkipped('v0.6.0'), isTrue);
      expect(await UpdateService.isSkipped('v0.6.1'), isFalse);
    });

    test('autoPromptDue: не раньше, чем раз в N дней', () async {
      final store = _MemoryStore();
      UpdateService.stateStore = () => store;
      addTearDown(() => UpdateService.stateStore =
          _defaultStateStore);

      // Никогда не показывали - пора.
      expect(await UpdateService.autoPromptDue(3), isTrue);

      final now = DateTime(2026, 11, 8, 12);
      await UpdateService.markAutoPrompted(now: now);
      // Вчера показывали - не пора.
      expect(
        await UpdateService.autoPromptDue(3, now: now.add(const Duration(hours: 12))),
        isFalse,
      );
      // Три дня прошли - пора.
      expect(
        await UpdateService.autoPromptDue(3, now: now.add(const Duration(days: 3))),
        isTrue,
      );
      // Часы ушли назад - верить отметке нельзя, показываем.
      expect(
        await UpdateService.autoPromptDue(3, now: now.subtract(const Duration(days: 1))),
        isTrue,
      );
    });
  });

  group('auto-проверка', () {
    test('не чаще minAutoCheckGap, кэш не затирается ошибкой', () async {
      UpdateService.resetAutoCheck();
      UpdateService.minAutoCheckGap = const Duration(hours: 1);
      addTearDown(() {
        UpdateService.resetAutoCheck();
        UpdateService.minAutoCheckGap = const Duration(minutes: 30);
      });

      final info = UpdateInfo(
        currentVersion: '0.5.9',
        latestVersion: 'v0.6.0',
        downloadUrl: 'https://x/y.zip',
        releaseUrl: 'https://x',
        assetSize: 1,
        openInBrowser: false,
      );
      var calls = 0;
      UpdateService.fetchUpdate = () async {
        calls++;
        return info;
      };
      addTearDown(() => UpdateService.fetchUpdate =
          _defaultFetch);

      expect(await UpdateService.checkForUpdate(), info);
      expect(await UpdateService.checkForUpdate(), info);
      expect(calls, 1);

      // Ошибка после успешной проверки не затирает результат (кэш жив).
      UpdateService.fetchUpdate = () async => throw 'net down';
      await expectLater(
        UpdateService.checkForUpdate(force: true),
        throwsA(anything),
      );
      expect(UpdateService.lastAutoCheckAt, isNotNull);
    });
  });
}

class _MemoryStore implements DocumentStore {
  Object? _data;
  @override
  Object? readSync() => _data;
  @override
  Future<bool> write(Object? data) async {
    _data = data;
    return true;
  }
}

