import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/controllers/settings_controller.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/app/terminal/terminal_session.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/models/session_tab.dart';
import 'package:vysh/domain/ports/sftp.dart';
import 'package:vysh/infra/platform/local_file_session.dart';
import 'package:vysh/ui/sftp/sftp_pane.dart';
import 'package:vysh/ui/sftp/file_workspace.dart';
import 'directory_tracking_test.dart' as fixture;

class Files extends LocalFileSession {
  @override
  Future<String> home() async => '/initial';
  @override
  Future<List<RemoteEntry>> list(String path) async {
    if (path == '/denied') {
      throw const SftpFailure(SftpFailureCode.permissionDenied);
    }
    return [
      RemoteEntry(name: 'subfolder', path: '$path/subfolder', isDir: true),
      RemoteEntry(name: path.substring(1), path: '$path/file', isDir: false),
    ];
  }
}

class Tabs extends TabsController {
  Tabs(this.session);
  final TerminalSession session;
  @override
  TabsState build() => const TabsState(
    tabs: [
      SessionTab(
        id: 'test',
        title: 'local',
        isLocal: true,
        status: SessionStatus.ready,
        host: Host(id: 'h', label: '', address: 'localhost'),
      ),
    ],
    active: 1,
  );
  @override
  TerminalSession? sessionOf(String tabId) => session;
}

void main() {
  testWidgets(
    'folder icon selects without opening while single click on folder name enters it',
    (tester) async {
      final files = Files();
      final session = fixture.session(
        launcher: (fixture.Launcher()..shell.directory = Future.value(null)),
        files: files,
      );
      await session.connect();
      final tabs = Tabs(session);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tabsProvider.overrideWith(() => tabs),
            documentStoreProvider.overrideWith((ref, name) => fixture.Store()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SftpPane(tab: tabs.build().tabs.single, active: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      String path() =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      expect(path(), '/initial');

      // Клик по иконке папки выделяет её, не открывая внутрь.
      await tester.tap(find.byIcon(Icons.folder_rounded));
      await tester.pumpAndSettle();
      expect(path(), '/initial');
      expect(find.text('Selected: 1'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);

      // Повторный клик по иконке снимает выделение.
      await tester.tap(find.byIcon(Icons.check_circle));
      await tester.pumpAndSettle();
      expect(path(), '/initial');
      expect(find.text('Selected: 1'), findsNothing);

      // Одиночный клик по названию папки сразу перебрасывает внутрь (без двойного клика).
      await tester.tap(find.text('subfolder'));
      await tester.pumpAndSettle();
      expect(path(), '/initial/subfolder');

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'single pane continuously follows CLI cd, supports snap-back, menu toggle and settings toggle',
    (tester) async {
      final files = Files();
      final session = fixture.session(
        launcher: (fixture.Launcher()..shell.directory = Future.value(null)),
        files: files,
      );
      await session.connect();
      final tabs = Tabs(session);
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tabsProvider.overrideWith(() => tabs),
            documentStoreProvider.overrideWith((ref, name) => fixture.Store()),
          ],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return MaterialApp(
                home: Scaffold(
                  body: SftpPane(tab: tabs.build().tabs.single, active: true),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      String path() =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      expect(path(), '/initial');

      // CLI переходит в /changed — проводник переходит следом.
      session.currentDirectory.value = '/changed';
      await tester.pumpAndSettle();
      expect(path(), '/changed');

      // Ручной переход не отключает слежение навсегда, но пока CLI стоит на месте —
      // проводник остаётся в /manual и предлагает кнопку возврата к папке CLI.
      await tester.enterText(find.byType(TextField), '/manual');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(path(), '/manual');
      expect(find.byIcon(Icons.my_location_outlined), findsOneWidget);

      // Кнопка в адресной строке мгновенно возвращает к текущей папке CLI.
      await tester.tap(find.byIcon(Icons.my_location_outlined));
      await tester.pumpAndSettle();
      expect(path(), '/changed');

      // Снова ушли вручную в /manual, а затем выполнили cd /elsewhere в CLI —
      // проводник автоматически следует за новым cd!
      await tester.enterText(find.byType(TextField), '/manual');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      session.currentDirectory.value = '/elsewhere';
      await tester.pumpAndSettle();
      expect(path(), '/elsewhere');

      // Отключение через галочку в настройках приостанавливает слежение.
      container
          .read(settingsProvider.notifier)
          .setFollowTerminalDirectory(false);
      await tester.pumpAndSettle();
      session.currentDirectory.value = '/while-disabled';
      await tester.pumpAndSettle();
      expect(path(), '/elsewhere');

      // Включение галочки в настройках сразу синхронизирует проводник с CLI.
      container
          .read(settingsProvider.notifier)
          .setFollowTerminalDirectory(true);
      await tester.pumpAndSettle();
      expect(path(), '/while-disabled');

      // Отключение/включение через меню «⋮» конкретной вкладки также работает.
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Follow terminal directory'));
      await tester.pumpAndSettle();
      session.currentDirectory.value = '/yet-another';
      await tester.pumpAndSettle();
      expect(path(), '/while-disabled');

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Follow terminal directory'));
      await tester.pumpAndSettle();
      expect(path(), '/yet-another');

      await tester.enterText(find.byType(TextField), '/denied');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(path(), '/denied');
      expect(find.textContaining('Permission denied'), findsOneWidget);
      await tester.tap(find.text('Home folder'));
      await tester.pumpAndSettle();
      expect(path(), '/initial');

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets('two-pane workspace does not follow terminal reports', (
    tester,
  ) async {
    final files = Files();
    final session = fixture.session(
      launcher: (fixture.Launcher()..shell.directory = Future.value(null)),
      files: files,
    );
    await session.connect();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tabsProvider.overrideWith(() => Tabs(session)),
          documentStoreProvider.overrideWith((ref, name) => fixture.Store()),
          fileWorkspaceLocalProvider.overrideWithValue(files),
        ],
        child: const MaterialApp(home: FileWorkspace()),
      ),
    );
    await tester.pumpAndSettle();
    session.currentDirectory.value = '/elsewhere';
    await tester.pumpAndSettle();
    final paths = tester
        .widgetList<TextField>(find.byType(TextField, skipOffstage: false))
        .map((t) => t.controller!.text);
    expect(paths, everyElement('/initial'));
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
  testWidgets('copy is disabled when destination navigation failed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final files = Files();
    final session = fixture.session(
      launcher: (fixture.Launcher()..shell.directory = Future.value(null)),
      files: files,
    );
    await session.connect();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tabsProvider.overrideWith(() => Tabs(session)),
          documentStoreProvider.overrideWith((ref, name) => fixture.Store()),
          fileWorkspaceLocalProvider.overrideWithValue(files),
        ],
        child: const MaterialApp(home: FileWorkspace()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '/denied');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Copy to right'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Home folder'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Copy to right'))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}
