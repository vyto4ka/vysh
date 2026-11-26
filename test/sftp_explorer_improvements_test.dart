import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'package:vysh/app/controllers/transfer_queue.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/app/settings/app_settings.dart';
import 'package:vysh/app/sftp/file_copy.dart';
import 'package:vysh/app/sftp/sftp_actions.dart';
import 'package:vysh/app/sftp/sftp_clipboard.dart';
import 'package:vysh/app/sftp/sftp_directory.dart';
import 'package:vysh/app/terminal/terminal_session.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/models/session_tab.dart';
import 'package:vysh/domain/ports/sftp.dart';
import 'package:vysh/infra/platform/local_file_session.dart';
import 'package:vysh/infra/platform/local_files.dart';
import 'package:vysh/l10n/app_strings.dart';
import 'package:vysh/ui/sftp/sftp_pane.dart';
import 'package:vysh/ui/sftp/sftp_text_editor.dart';
import 'package:vysh/ui/theme/app_theme.dart';

import 'directory_tracking_test.dart' as fixture;

class _RootedLocalSession extends LocalFileSession {
  const _RootedLocalSession(this.rootPath);
  final String rootPath;
  @override
  Future<String> home() async => rootPath;
}

class _Tabs extends TabsController {
  _Tabs(this.session);
  final TerminalSession session;
  @override
  TabsState build() => const TabsState(
    tabs: [
      SessionTab(
        id: 't1',
        title: 'srv',
        isLocal: false,
        status: SessionStatus.ready,
        host: Host(id: 'h1', label: 'srv', address: '10.0.0.1'),
      ),
    ],
    active: 1,
  );
  @override
  TerminalSession? sessionOf(String tabId) => session;
}

class _VirtualTreeSftp extends LocalFileSession {
  final Map<String, List<RemoteEntry>> tree = {
    '/': const [RemoteEntry(name: 'work', path: '/work', isDir: true)],
    '/work': const [
      RemoteEntry(name: 'logs', path: '/work/logs', isDir: true),
      RemoteEntry(name: 'alpha.txt', path: '/work/alpha.txt', isDir: false),
      RemoteEntry(name: 'bravo.conf', path: '/work/bravo.conf', isDir: false),
    ],
    '/work/logs': const [
      RemoteEntry(name: 'app.log', path: '/work/logs/app.log', isDir: false),
    ],
  };

  @override
  Future<String> home() async => '/work';

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final items = tree[path];
    if (items == null) {
      throw const SftpFailure(SftpFailureCode.noSuchFile);
    }
    return items;
  }
}

void main() {
  test(
    'sortSftpEntries sorts by name, size, modified and type with dirs first',
    () {
      final t1 = DateTime(2026, 1, 1);
      final t2 = DateTime(2026, 5, 1);
      final items = [
        RemoteEntry(
          name: 'beta.log',
          path: '/beta.log',
          isDir: false,
          size: 500,
          modified: t1,
        ),
        RemoteEntry(
          name: 'alpha.conf',
          path: '/alpha.conf',
          isDir: false,
          size: 100,
          modified: t2,
        ),
        const RemoteEntry(name: 'zeta_dir', path: '/zeta_dir', isDir: true),
        const RemoteEntry(name: 'adir', path: '/adir', isDir: true),
      ];

      expect(sortSftpEntries(items, SftpSortField.name).map((e) => e.name), [
        'adir',
        'zeta_dir',
        'alpha.conf',
        'beta.log',
      ]);
      expect(
        sortSftpEntries(
          items,
          SftpSortField.size,
          ascending: false,
        ).map((e) => e.name),
        ['zeta_dir', 'adir', 'beta.log', 'alpha.conf'],
      );
      expect(
        sortSftpEntries(
          items,
          SftpSortField.modified,
          ascending: false,
        ).map((e) => e.name),
        ['zeta_dir', 'adir', 'alpha.conf', 'beta.log'],
      );
      expect(sortSftpEntries(items, SftpSortField.type).map((e) => e.name), [
        'adir',
        'zeta_dir',
        'alpha.conf',
        'beta.log',
      ]);
    },
  );

  test('SftpPathHistory, sftpBreadcrumbs, Windows roots and shell quoting', () {
    final h = SftpPathHistory();
    h.record('/a');
    h.record('/a/b');
    h.record('/a/b/c');
    expect(h.canBack, isTrue);
    expect(h.back(), '/a/b');
    expect(h.back(), '/a');
    expect(h.canBack, isFalse);
    expect(h.forward(), '/a/b');
    h.record('/x');
    expect(h.canForward, isFalse);

    expect(sftpBreadcrumbs('/var/log/nginx', windows: false), [
      (label: '/', path: '/'),
      (label: 'var', path: '/var'),
      (label: 'log', path: '/var/log'),
      (label: 'nginx', path: '/var/log/nginx'),
    ]);
    expect(sftpBreadcrumbs(r'C:\Users\Admin', windows: true), [
      (label: r'\', path: r'\'),
      (label: r'C:\', path: r'C:\'),
      (label: 'Users', path: r'C:\Users'),
      (label: 'Admin', path: r'C:\Users\Admin'),
    ]);

    expect(LocalFiles.parentPathFor(r'C:\Users', windows: true), r'C:\');
    expect(LocalFiles.parentPathFor(r'C:\', windows: true), r'\');
    expect(LocalFiles.isRootPathFor(r'C:\', windows: true), isFalse);
    expect(LocalFiles.isRootPathFor(r'\', windows: true), isTrue);

    expect(
      shellQuotePath('/var/log/a b.log', windows: false),
      "'/var/log/a b.log'",
    );
    expect(shellQuotePath("/tmp/it's", windows: false), r"'/tmp/it'\''s'");
    expect(
      shellQuotePath(r'C:\Program Files\App', windows: true),
      r'"C:\Program Files\App"',
    );
    expect(shellCdCommand('/var/log', windows: false), 'cd -- /var/log\r');
  });

  test(
    'createEmptySftpFile, read/write text with binary guard and clipboard paste',
    () async {
      final temp = await Directory.systemTemp.createTemp('vysh-sftp-ops-');
      try {
        const sftp = LocalFileSession();
        final f1 = '${temp.path}/hello.conf';
        await createEmptySftpFile(sftp, f1);
        expect(await File(f1).exists(), isTrue);
        await expectLater(
          createEmptySftpFile(sftp, f1),
          throwsA(isA<SftpFailure>()),
        );

        await writeSftpTextFile(sftp, f1, 'listen 8080;\n');
        final stat1 = await sftp.stat(f1);
        expect(await readSftpTextFile(sftp, stat1), 'listen 8080;\n');
        expect(await estimateTransferBytes(sftp, [stat1]), stat1.size);

        final bin = '${temp.path}/bin.dat';
        await File(bin).writeAsBytes([0x7F, 0x45, 0x00, 0x01]);
        await expectLater(
          readSftpTextFile(sftp, await sftp.stat(bin)),
          throwsA(
            isA<SftpTextEditException>().having(
              (e) => e.error,
              'error',
              SftpTextEditError.binary,
            ),
          ),
        );

        // Быстрое перемещение через буфер обмена (cut: true) в подпапку.
        final sub = '${temp.path}/sub';
        await sftp.mkdir(sub);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final clip = SftpClipboardData(
          sourceIdentity: 'local',
          openSource: () async => sftp,
          entries: [stat1],
          cut: true,
        );
        await pasteSftpClipboard(
          clip: clip,
          targetIdentity: 'local',
          target: sftp,
          targetDir: sub,
          joinPath: (d, n) => '$d/$n',
          tabId: 'test',
          queue: container.read(transferQueueProvider.notifier),
          resolveConflict: (_) async => const CopyDecision(CopyChoice.replace),
        );
        expect(await File(f1).exists(), isFalse);
        expect(await File('$sub/hello.conf').readAsString(), 'listen 8080;\n');
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'SftpPane breadcrumbs, Back/Forward history, root .. hiding, live filter and keyboard arrows',
    (tester) async {
      final memSftp = _VirtualTreeSftp();
      final session = fixture.session(
        launcher: (fixture.Launcher()..shell.directory = Future.value(null)),
        files: memSftp,
      );
      await session.connect();
      session.currentDirectory.value = '/work';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tabsProvider.overrideWith(() => _Tabs(session)),
            documentStoreProvider.overrideWith((ref, name) => fixture.Store()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 520,
                height: 640,
                child: SftpPane(
                  tab: const SessionTab(
                    id: 't1',
                    title: 'local',
                    isLocal: true,
                    status: SessionStatus.ready,
                    host: Host(id: 'h', label: '', address: 'localhost'),
                  ),
                  active: true,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      String path() => tester
          .widget<TextField>(find.byType(TextField).first)
          .controller!
          .text;
      expect(path(), '/work');
      expect(find.text('..'), findsOneWidget);

      // Клик по папке logs сразу переходит в /work/logs.
      await tester.tap(find.text('logs'));
      await tester.pumpAndSettle();
      expect(path(), '/work/logs');

      // Клик по хлебной крошке «work» возвращает в /work.
      await tester.tap(find.text('work'));
      await tester.pumpAndSettle();
      expect(path(), '/work');

      // Кнопки Назад и Вперёд ходят по истории переходов.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(path(), '/work/logs');

      await tester.tap(find.byIcon(Icons.arrow_forward));
      await tester.pumpAndSettle();
      expect(path(), '/work');

      // В корне `/` строка `..` скрыта.
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();
      expect(path(), '/');
      expect(find.text('..'), findsNothing);

      // Вернёмся в /work и проверим живой фильтр по имени.
      await tester.tap(find.text('work'));
      await tester.pumpAndSettle();
      expect(find.text('alpha.txt'), findsOneWidget);
      expect(find.text('bravo.conf'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'bravo');
      await tester.pumpAndSettle();
      expect(find.text('alpha.txt'), findsNothing);
      expect(find.text('bravo.conf'), findsOneWidget);

      // Escape закрывает и очищает строку фильтра.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('alpha.txt'), findsOneWidget);

      // Стрелка вниз выделяет первый элемент (папку logs), Enter входит в неё.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(find.text('Selected: 1'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(path(), '/work/logs');

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('openSftpTextEditor loads, edits and saves UTF-8 file', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late Directory temp;
    late RemoteEntry entry;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('vysh-editor-');
      final f = File('${temp.path}/nginx.conf');
      await f.writeAsString('worker_processes 1;\n');
      entry = await const LocalFileSession().stat(f.path);
    });
    addTearDown(() => temp.delete(recursive: true));

    final sftp = _RootedLocalSession(temp.path);
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                result = await openSftpTextEditor(
                  ctx,
                  openSession: () async => sftp,
                  entry: entry,
                  strings: const AppStrings(isRu: false),
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      ),
    );

    await tester.runAsync(() async {
      await tester.tap(find.text('Edit'));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pumpAndSettle();
    expect(find.text('nginx.conf'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'worker_processes auto;\n');
    await tester.pump();
    expect(find.text('• nginx.conf'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('• nginx.conf'), findsNothing);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(result, isTrue);

    await tester.runAsync(() async {
      final disk = await File(
        '${temp.path}/nginx.conf',
      ).readAsString(encoding: utf8);
      expect(disk, 'worker_processes auto;\n');
    });
  });

  testWidgets(
    'SftpPane right-click does not shift file list vertically and context menu fits 864px window without scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 864);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final memSftp = _VirtualTreeSftp();
      final session = fixture.session(
        launcher: (fixture.Launcher()..shell.directory = Future.value(null)),
        files: memSftp,
      );
      await session.connect();
      session.currentDirectory.value = '/work';

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tabsProvider.overrideWith(() => _Tabs(session)),
            documentStoreProvider.overrideWith((ref, name) => fixture.Store()),
          ],
          child: MaterialApp(
            theme: buildTheme(seed: Colors.purple, brightness: Brightness.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: 460,
                  height: 800,
                  child: SftpPane(
                    tab: const SessionTab(
                      id: 't1',
                      title: 'srv',
                      isLocal: false,
                      status: SessionStatus.ready,
                      host: Host(id: 'h1', label: 'srv', address: '10.0.0.1'),
                    ),
                    active: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fileFinder = find.text('alpha.txt');
      final dyBefore = tester.getTopLeft(fileFinder).dy;

      // Правый клик по файлу выделяет его и открывает контекстное меню,
      // не сдвигая список по вертикали ни во время анимации, ни после неё.
      await tester.tap(fileFinder, buttons: kSecondaryMouseButton);
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getTopLeft(fileFinder).dy, dyBefore);
      await tester.pumpAndSettle();
      expect(find.text('Selected: 1'), findsOneWidget);
      expect(tester.getTopLeft(fileFinder).dy, dyBefore);

      // Полное меню по файлу (20+ пунктов) целиком помещается в окно высотой 864px без прокрутки.
      expect(find.text('Edit text'), findsOneWidget);
      expect(find.text('Hidden files'), findsOneWidget);
      final menuScrollables = tester.widgetList<Scrollable>(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_MenuPanel',
          ),
          matching: find.byType(Scrollable),
        ),
      );
      for (final s in menuScrollables) {
        final state = tester.state<ScrollableState>(find.byWidget(s));
        expect(state.position.maxScrollExtent, 0.0);
      }

      // Закрываем меню и проверяем то же самое в корне `/`, где нет строки `..`.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();
      final rootEntry = find.text('work');
      final rootDyBefore = tester.getTopLeft(rootEntry).dy;
      await tester.tap(rootEntry, buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
      expect(find.text('Selected: 1'), findsOneWidget);
      expect(tester.getTopLeft(rootEntry).dy, rootDyBefore);

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
