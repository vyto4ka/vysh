import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:irondash_message_channel/irondash_message_channel.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:super_native_extensions/src/native/context.dart'
    show superNativeExtensionsContext;
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/domain/ports/sftp.dart';
import 'package:vysh/domain/models/session_tab.dart';
import 'package:vysh/infra/platform/local_file_session.dart';
import 'package:vysh/ui/sftp/file_workspace.dart';
import 'package:vysh/ui/sftp/sftp_drag.dart';
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

  testWidgets(
    'FileWorkspace supports external OS drop, intra-pane folder move and cross-pane drag copy',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dev.irondash.engine_context'),
            (call) async => call.method == 'getEngineHandle' ? 1 : null,
          );
      final ctx = superNativeExtensionsContext;
      if (ctx is MockMessageChannelContext) {
        ctx.registerMockMethodCallHandler('DropManager', (_) => null);
        ctx.registerMockMethodCallHandler('DragManager', (_) => null);
      }
      debugFileDragAndDropOverride = true;
      addTearDown(() {
        debugFileDragAndDropOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('dev.irondash.engine_context'),
              null,
            );
      });

      late Directory temp;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('vysh-file-dnd-');
        await Directory('${temp.path}/left/sub').create(recursive: true);
        await Directory('${temp.path}/right').create();
        await Directory('${temp.path}/outside').create();
        await File('${temp.path}/left/move_me.txt').writeAsString('moved');
        await File('${temp.path}/outside/dropped.txt').writeAsString('from os');
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
              _Local('${temp.path}/left'),
            ),
          ],
          child: const MaterialApp(home: FileWorkspace()),
        ),
      );

      Future<void> io() async {
        for (var i = 0; i < 25; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 40));
          });
          if (i >= 4 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
      }

      await io();
      await tester.enterText(find.byType(TextField).last, '${temp.path}/right');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await io();

      // 1. External OS file drop onto left pane.
      final leftZone = tester.widget<SftpDropZone>(
        find.byWidgetPredicate(
          (w) => w is SftpDropZone && w.scopeId == 'workspace:left',
        ),
      );
      await tester.runAsync(() async {
        leftZone.onDropPaths(['${temp.path}/outside/dropped.txt']);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await io();
      await tester.runAsync(() async {
        expect(
          await File('${temp.path}/left/dropped.txt').readAsString(),
          'from os',
        );
      });

      // 2. Cross-pane drag copy from left pane onto right pane.
      final rightZone = tester.widget<SftpDropZone>(
        find.byWidgetPredicate(
          (w) => w is SftpDropZone && w.scopeId == 'workspace:right',
        ),
      );
      await tester.runAsync(() async {
        rightZone.onDropInternal!(
          SftpInternalDrag(
            scopeId: 'workspace:left',
            windowsPaths: false,
            entries: [
              RemoteEntry(
                name: 'dropped.txt',
                path: '${temp.path}/left/dropped.txt',
                isDir: false,
                size: 7,
              ),
            ],
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      await io();
      await tester.runAsync(() async {
        expect(
          await File('${temp.path}/right/dropped.txt').readAsString(),
          'from os',
        );
      });

      // 3. Intra-pane folder move onto 'sub' folder row in left pane.
      final subDropTarget = tester.widget<SftpFolderDropTarget>(
        find.byWidgetPredicate(
          (w) =>
              w is SftpFolderDropTarget &&
              w.scopeId == 'workspace:left' &&
              w.targetDirPath == '${temp.path}/left/sub',
        ),
      );
      await tester.runAsync(() async {
        subDropTarget.onMoveEntries([
          RemoteEntry(
            name: 'move_me.txt',
            path: '${temp.path}/left/move_me.txt',
            isDir: false,
            size: 5,
          ),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await io();
      await tester.runAsync(() async {
        expect(await File('${temp.path}/left/move_me.txt').exists(), isFalse);
        expect(
          await File('${temp.path}/left/sub/move_me.txt').readAsString(),
          'moved',
        );
      });

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
