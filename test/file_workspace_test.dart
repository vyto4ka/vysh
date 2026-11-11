import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/domain/models/session_tab.dart';
import 'package:vysh/infra/platform/local_file_session.dart';
import 'package:vysh/ui/sftp/file_workspace.dart';
import 'package:vysh/ui/sftp/sftp_entry_row.dart';

class _Store implements DocumentStore {
  @override
  Object? readSync() => null;
  @override
  Future<bool> write(Object? value) async => true;
}

class _Tabs extends TabsController {
  @override
  TabsState build() => const TabsState(tabs: [], active: 0);
}

class _Local extends LocalFileSession {
  const _Local(this.path);
  final String path;
  @override
  Future<String> home() async => path;
}

void main() {
  testWidgets(
    'selection survives narrow layout and copy uses the other pane directory',
    (tester) async {
      late Directory temp;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('vysh-file-ui-');
        await Directory('${temp.path}/source').create();
        await Directory('${temp.path}/target').create();
        await File(
          '${temp.path}/source/example.txt',
        ).writeAsString('selected file');
      });
      addTearDown(() => temp.delete(recursive: true));
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tabsProvider.overrideWith(_Tabs.new),
            documentStoreProvider.overrideWith((ref, name) => _Store()),
            fileWorkspaceLocalProvider.overrideWithValue(
              _Local('${temp.path}/source'),
            ),
          ],
          child: const MaterialApp(home: FileWorkspace()),
        ),
      );
      Future<void> io() async {
        for (var i = 0; i < 5; i++) {
          await tester.pump();
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 60));
          });
        }
        await tester.pumpAndSettle();
      }

      await io();
      // Navigate only the destination; a subsequent adaptive layout must retain it.
      await tester.enterText(
        find.byType(TextField).last,
        '${temp.path}/target',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await io();
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('Selected: 1'), findsOneWidget);
      tester.view.physicalSize = const Size(600, 800);
      await tester.pumpAndSettle();
      expect(find.text('Selected: 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await tester.tap(find.text('Copy to other pane'));
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await io();
      await tester.runAsync(() async {
        expect(
          await File('${temp.path}/target/example.txt').readAsString(),
          'selected file',
        );
      });
      await tester.tap(find.text('Right pane'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is SftpEntryRow && w.entry?.name == 'example.txt',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
