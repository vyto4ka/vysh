import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:irondash_message_channel/irondash_message_channel.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:super_native_extensions/src/native/context.dart'
    show superNativeExtensionsContext;
import 'package:vysh/domain/ports/sftp.dart';
import 'package:vysh/infra/platform/local_files.dart';
import 'package:vysh/ui/sftp/sftp_drag.dart';

void _setupMockNativeChannels() {
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
}

void main() {
  setUp(() {
    _setupMockNativeChannels();
    debugFileDragAndDropOverride = true;
  });

  tearDown(() {
    debugFileDragAndDropOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.irondash.engine_context'),
          null,
        );
  });

  test('SftpInternalDrag serializes cleanly through StandardMessageCodec', () {
    final modified = DateTime.fromMillisecondsSinceEpoch(1730000000000);
    final original = SftpInternalDrag(
      scopeId: 'pane:t1',
      windowsPaths: true,
      entries: [
        RemoteEntry(
          name: 'notes.txt',
          path: r'C:\Users\Admin\notes.txt',
          isDir: false,
          size: 42,
          modified: modified,
          mode: 0x1a4,
        ),
        const RemoteEntry(
          name: 'logs',
          path: r'C:\Users\Admin\logs',
          isDir: true,
        ),
      ],
    );

    const codec = StandardMessageCodec();
    // Raw Dart object is rejected by StandardMessageCodec / irondash Serializer.
    expect(() => codec.encodeMessage(original), throwsArgumentError);

    final encoded = codec.encodeMessage(original.toJson());
    expect(encoded, isNotNull);
    final rawDecoded = codec.decodeMessage(encoded);
    final restored = SftpInternalDrag.decode(rawDecoded);

    expect(restored, isNotNull);
    expect(restored!.scopeId, 'pane:t1');
    expect(restored.windowsPaths, isTrue);
    expect(restored.entries, hasLength(2));
    expect(restored.entries[0].name, 'notes.txt');
    expect(restored.entries[0].path, r'C:\Users\Admin\notes.txt');
    expect(restored.entries[0].isDir, isFalse);
    expect(restored.entries[0].size, 42);
    expect(restored.entries[0].modified, modified);
    expect(restored.entries[0].mode, 0x1a4);
    expect(restored.entries[1].name, 'logs');
    expect(restored.entries[1].isDir, isTrue);

    expect(SftpInternalDrag.decode(null), isNull);
    expect(SftpInternalDrag.decode('vysh-sftp'), isNull);
    expect(
      SftpInternalDrag.decode({
        'vyshSftpDrag': 1,
        'scopeId': 'x',
        'windowsPaths': false,
        'entries': const <Object?>[],
      }),
      isNull,
    );
  });

  testWidgets(
    'SftpDragSource sanitizes suggestedName, serializes localData and exposes fileUri for local folders',
    (tester) async {
      expect(
        LocalFiles.safeNameFor('log:2026?.txt', windows: true),
        'log_2026_.txt',
      );
      expect(LocalFiles.safeNameFor('CON.txt', windows: true), '_CON.txt');
      expect(LocalFiles.safeNameFor('report. ', windows: true), 'report');

      const trickyFile = RemoteEntry(
        name: 'sub\\bad\x00name.txt',
        path: '/var/log/sub\\bad\x00name.txt',
        isDir: false,
        size: 12,
      );
      const siblingDir = RemoteEntry(
        name: 'archive',
        path: '/var/log/archive',
        isDir: true,
      );

      expect(canDragOut(siblingDir, localFiles: true), isTrue);
      expect(
        canDragOut(
          const RemoteEntry(
            name: 'sym',
            path: '/var/log/sym',
            isDir: true,
            isLink: true,
          ),
          localFiles: true,
        ),
        isFalse,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SftpDragSource(
            entry: trickyFile,
            scopeId: 'pane:local',
            selectedEntries: const [trickyFile, siblingDir],
            localFiles: true,
            actions: () => null,
            child: const Text('row'),
          ),
        ),
      );

      final itemWidget = tester.widget<DragItemWidget>(
        find.byType(DragItemWidget),
      );
      final item = await itemWidget.dragItemProvider(
        DragItemRequest(location: Offset.zero, session: _FakeDragSession()),
      );
      expect(item, isNotNull);
      expect(item!.suggestedName, 'sub_bad_name.txt');

      // localData must be a Map serializable by StandardMessageCodec.
      expect(item.localData, isA<Map>());
      expect(
        () => const StandardMessageCodec().encodeMessage(item.localData),
        returnsNormally,
      );
      final decoded = SftpInternalDrag.decode(item.localData);
      expect(decoded, isNotNull);
      expect(decoded!.scopeId, 'pane:local');
      expect(decoded.entries.map((e) => e.name), [
        'sub\\bad\x00name.txt',
        'archive',
      ]);

      // Local directory also produces a fileUri representation + plainText fallback.
      await tester.pumpWidget(
        MaterialApp(
          home: SftpDragSource(
            entry: siblingDir,
            scopeId: 'pane:local',
            localFiles: true,
            actions: () => null,
            child: const Text('dir-row'),
          ),
        ),
      );
      final dirItemWidget = tester.widget<DragItemWidget>(
        find.byType(DragItemWidget),
      );
      final dirItem = await dirItemWidget.dragItemProvider(
        DragItemRequest(location: Offset.zero, session: _FakeDragSession()),
      );
      expect(dirItem, isNotNull);
      expect(dirItem!.data.length, greaterThanOrEqualTo(2));
    },
  );

  testWidgets(
    'SftpFolderDropTarget moves intra-pane items, blocks self/descendant folder drops and copies cross-pane items',
    (tester) async {
      List<RemoteEntry>? moved;
      SftpInternalDrag? copiedExternal;

      await tester.pumpWidget(
        MaterialApp(
          home: SftpFolderDropTarget(
            scopeId: 'workspace:left',
            targetDirPath: r'C:\work\logs\sub',
            enabled: true,
            onMoveEntries: (items) => moved = items,
            onCopyExternal: (drag) => copiedExternal = drag,
            child: const SizedBox(width: 200, height: 48),
          ),
        ),
      );

      final region = tester.widget<DropRegion>(find.byType(DropRegion));
      final pos = DropPosition(local: Offset.zero, global: Offset.zero);

      // Dropping parent folder 'C:\work\logs' into its own child 'C:\work\logs\sub' is rejected.
      final invalidSelfSession = _FakeDropSession(
        items: [
          _FakeDropItem(
            localData: const SftpInternalDrag(
              scopeId: 'workspace:left',
              windowsPaths: true,
              entries: [
                RemoteEntry(name: 'logs', path: r'C:\work\logs', isDir: true),
              ],
            ).toJson(),
          ),
        ],
      );
      expect(
        await region.onDropOver(
          DropOverEvent(session: invalidSelfSession, position: pos),
        ),
        DropOperation.none,
      );

      // Intra-pane valid file drop -> move.
      final validMoveSession = _FakeDropSession(
        items: [
          _FakeDropItem(
            localData: const SftpInternalDrag(
              scopeId: 'workspace:left',
              windowsPaths: true,
              entries: [
                RemoteEntry(
                  name: 'app.txt',
                  path: r'C:\work\app.txt',
                  isDir: false,
                ),
              ],
            ).toJson(),
          ),
        ],
      );
      expect(
        await region.onDropOver(
          DropOverEvent(session: validMoveSession, position: pos),
        ),
        DropOperation.move,
      );
      await region.onPerformDrop(
        PerformDropEvent(
          session: validMoveSession,
          position: pos,
          acceptedOperation: DropOperation.move,
        ),
      );
      expect(moved?.map((e) => e.name), ['app.txt']);
      expect(copiedExternal, isNull);

      // Cross-pane drop -> copy.
      final crossSession = _FakeDropSession(
        items: [
          _FakeDropItem(
            localData: const SftpInternalDrag(
              scopeId: 'workspace:right',
              windowsPaths: false,
              entries: [
                RemoteEntry(
                  name: 'remote.conf',
                  path: '/etc/remote.conf',
                  isDir: false,
                ),
              ],
            ).toJson(),
          ),
        ],
      );
      expect(
        await region.onDropOver(
          DropOverEvent(session: crossSession, position: pos),
        ),
        DropOperation.copy,
      );
      await region.onPerformDrop(
        PerformDropEvent(
          session: crossSession,
          position: pos,
          acceptedOperation: DropOperation.copy,
        ),
      );
      expect(copiedExternal?.scopeId, 'workspace:right');
      expect(copiedExternal?.entries.single.name, 'remote.conf');
    },
  );

  testWidgets(
    'SftpDropZone ignores same-scope internal drag, accepts cross-scope drag and reads external fileUri drops',
    (tester) async {
      List<String>? droppedPaths;
      SftpInternalDrag? droppedInternal;

      await tester.pumpWidget(
        MaterialApp(
          home: SftpDropZone(
            scopeId: 'pane:t1',
            enabled: true,
            onHover: (_) {},
            onDropPaths: (paths) => droppedPaths = paths,
            onDropInternal: (drag) => droppedInternal = drag,
            child: const SizedBox(width: 300, height: 200),
          ),
        ),
      );

      final region = tester.widget<DropRegion>(find.byType(DropRegion));
      final pos = DropPosition(local: Offset.zero, global: Offset.zero);

      // Same-scope drag must NOT be treated as external upload.
      final sameScope = _FakeDropSession(
        items: [
          _FakeDropItem(
            hasFileUri: true,
            localData: const SftpInternalDrag(
              scopeId: 'pane:t1',
              windowsPaths: false,
              entries: [
                RemoteEntry(name: 'a.txt', path: '/a.txt', isDir: false),
              ],
            ).toJson(),
          ),
        ],
      );
      expect(
        await region.onDropOver(
          DropOverEvent(session: sameScope, position: pos),
        ),
        DropOperation.none,
      );

      // Cross-scope drag is accepted as copy.
      final otherScope = _FakeDropSession(
        items: [
          _FakeDropItem(
            localData: const SftpInternalDrag(
              scopeId: 'pane:t2',
              windowsPaths: false,
              entries: [
                RemoteEntry(name: 'b.txt', path: '/b.txt', isDir: false),
              ],
            ).toJson(),
          ),
        ],
      );
      expect(
        await region.onDropOver(
          DropOverEvent(session: otherScope, position: pos),
        ),
        DropOperation.copy,
      );
      await region.onPerformDrop(
        PerformDropEvent(
          session: otherScope,
          position: pos,
          acceptedOperation: DropOperation.copy,
        ),
      );
      expect(droppedInternal?.scopeId, 'pane:t2');
      expect(droppedPaths, isNull);

      // External OS drop with empty allowedOperations (e.g. shell without DROPEFFECT_COPY flag) still works.
      final fileUri = Uri.file('/tmp/uploaded report.txt');
      final externalSession = _FakeDropSession(
        allowedOperations: const {},
        items: [
          _FakeDropItem(hasFileUri: true, reader: _FakeUriReader(fileUri)),
        ],
      );
      expect(
        await region.onDropOver(
          DropOverEvent(session: externalSession, position: pos),
        ),
        DropOperation.copy,
      );
      await region.onPerformDrop(
        PerformDropEvent(
          session: externalSession,
          position: pos,
          acceptedOperation: DropOperation.copy,
        ),
      );
      expect(droppedPaths, [fileUri.toFilePath()]);
    },
  );

  testWidgets('SftpTerminalDropZone quotes paths for Windows and POSIX shells', (
    tester,
  ) async {
    String? inserted;

    await tester.pumpWidget(
      MaterialApp(
        home: SftpTerminalDropZone(
          enabled: true,
          windowsShell: true,
          acceptLocalOsFiles: false,
          onInsertText: (text) => inserted = text,
          child: const SizedBox(width: 300, height: 200),
        ),
      ),
    );

    final region = tester.widget<DropRegion>(find.byType(DropRegion));
    final pos = DropPosition(local: Offset.zero, global: Offset.zero);

    // External OS file rejected when acceptLocalOsFiles is false (remote SSH session).
    final extSession = _FakeDropSession(
      items: [_FakeDropItem(hasFileUri: true)],
    );
    expect(
      await region.onDropOver(
        DropOverEvent(session: extSession, position: pos),
      ),
      DropOperation.none,
    );

    // Internal drag inserts Windows-quoted path.
    final internalSession = _FakeDropSession(
      items: [
        _FakeDropItem(
          localData: const SftpInternalDrag(
            scopeId: 'pane:local',
            windowsPaths: true,
            entries: [
              RemoteEntry(
                name: 'my tool.exe',
                path: r'C:\Program Files\My App\my tool.exe',
                isDir: false,
              ),
            ],
          ).toJson(),
        ),
      ],
    );
    expect(
      await region.onDropOver(
        DropOverEvent(session: internalSession, position: pos),
      ),
      DropOperation.copy,
    );
    await region.onPerformDrop(
      PerformDropEvent(
        session: internalSession,
        position: pos,
        acceptedOperation: DropOperation.copy,
      ),
    );
    expect(inserted, r'"C:\Program Files\My App\my tool.exe" ');
  });
}

class _FakeDragSession extends DragSession {
  @override
  final ValueListenable<bool> dragging = ValueNotifier<bool>(true);

  @override
  final ValueListenable<DropOperation?> dragCompleted =
      ValueNotifier<DropOperation?>(null);

  @override
  final ValueListenable<Offset?> lastScreenLocation = ValueNotifier<Offset?>(
    null,
  );

  @override
  Future<List<Object?>?> getLocalData() async => null;
}

class _FakeDropSession extends DropSession {
  _FakeDropSession({
    required this.items,
    this.allowedOperations = const {DropOperation.copy, DropOperation.move},
  });

  @override
  final List<DropItem> items;

  @override
  final Set<DropOperation> allowedOperations;

  @override
  final Listenable onDisposed = ValueNotifier<void>(null);
}

class _FakeDropItem extends DropItem {
  _FakeDropItem({this.localData, this.hasFileUri = false, DataReader? reader})
    : _reader = reader;

  @override
  final Object? localData;

  final bool hasFileUri;
  final DataReader? _reader;

  @override
  bool canProvide(DataFormat f) => hasFileUri && identical(f, Formats.fileUri);

  @override
  DataReader? get dataReader => _reader;

  @override
  List<PlatformFormat> get platformFormats => const [];
}

class _FakeReadProgress extends ReadProgress {
  @override
  final ValueListenable<bool> cancellable = ValueNotifier<bool>(false);

  @override
  final ValueListenable<double?> fraction = ValueNotifier<double?>(1.0);

  @override
  void cancel() {}
}

class _FakeUriReader extends DataReader {
  _FakeUriReader(this.uri);
  final Uri uri;

  @override
  List<DataFormat> getFormats(List<DataFormat> allFormats) => [
    if (allFormats.contains(Formats.fileUri)) Formats.fileUri,
  ];

  @override
  ReadProgress? getValue<T extends Object>(
    ValueFormat<T> format,
    AsyncValueChanged<T?> onValue, {
    ValueChanged<Object>? onError,
  }) {
    if (identical(format, Formats.fileUri)) {
      scheduleMicrotask(() => onValue(uri as T));
      return _FakeReadProgress();
    }
    return null;
  }

  @override
  ReadProgress? getFile(
    FileFormat? format,
    AsyncValueChanged<DataReaderFile> onFile, {
    ValueChanged<Object>? onError,
    bool allowVirtualFiles = true,
    bool synthesizeFilesFromURIs = true,
  }) => null;

  @override
  Future<String?> getSuggestedName() async => null;

  @override
  Future<VirtualFileReceiver?> getVirtualFileReceiver({
    FileFormat? format,
  }) async => null;

  @override
  bool isSynthesized(DataFormat format) => false;

  @override
  bool isVirtual(DataFormat format) => false;

  @override
  List<PlatformFormat> get platformFormats => const [];
}
