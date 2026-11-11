import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  Future<List<RemoteEntry>> list(String path) async => [
    RemoteEntry(name: path.substring(1), path: '$path/file', isDir: false),
  ];
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
    'single pane follows reports, manual navigation pauses, menu resumes',
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
      session.currentDirectory.value = '/changed';
      await tester.pumpAndSettle();
      expect(path(), '/changed');
      await tester.enterText(find.byType(TextField), '/manual');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      session.currentDirectory.value = '/elsewhere';
      await tester.pumpAndSettle();
      expect(path(), '/manual');
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Follow terminal directory'));
      await tester.pumpAndSettle();
      expect(path(), '/elsewhere');
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
}
