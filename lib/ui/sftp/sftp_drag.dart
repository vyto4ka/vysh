import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../app/sftp/sftp_actions.dart';
import '../../app/sftp/sftp_clipboard.dart';
import '../../domain/ports/sftp.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/local_files.dart';

/// Перетаскивание между панелью SFTP, подпапками, терминалом и системным проводником.
///
/// * Наружу в ОС: одиночный или множественный drag всех выделенных файлов/папок.
/// * Внутри одной панели проводника: перетаскивание на строку папки или `..`
///   перемещает (`rename`) выбранные элементы внутрь этой папки.
/// * Между панелями файловой рабочей области: копирует выбранные элементы.
/// * В область терминала: перетаскивание элементов из проводника или файлов ОС
///   вставляет экранированные пути в командную строку.
/// * Из ОС в проводник: загружает файлы и папки в текущую директорию.

/// Переопределение доступности нативного drag-and-drop для виджетных тестов
/// (в безголовом `FLUTTER_TEST` нативный канал по умолчанию отключён).
@visibleForTesting
bool? debugFileDragAndDropOverride;

bool get _fileDragAndDropEnabled =>
    debugFileDragAndDropOverride ?? PlatformCapabilities.fileDragAndDrop;

/// Внутренние данные перетаскивания из проводника vysh.
///
/// Нативный канал `super_native_extensions` сериализует `DragItem.localData`
/// через `irondash_message_channel`, который принимает только примитивы, списки
/// и словари (произвольный Dart-объект выбрасывает `ArgumentError` до старта
/// системного `DoDragDrop`). Поэтому при передаче используется [toJson]/[decode].
class SftpInternalDrag {
  const SftpInternalDrag({
    required this.scopeId,
    required this.entries,
    required this.windowsPaths,
  });

  final String scopeId;
  final List<RemoteEntry> entries;
  final bool windowsPaths;

  Map<String, Object?> toJson() => {
    'vyshSftpDrag': 1,
    'scopeId': scopeId,
    'windowsPaths': windowsPaths,
    'entries': [
      for (final e in entries)
        <String, Object?>{
          'name': e.name,
          'path': e.path,
          'isDir': e.isDir,
          'isLink': e.isLink,
          'size': e.size,
          'modified': e.modified?.millisecondsSinceEpoch,
          'mode': e.mode,
        },
    ],
  };

  static SftpInternalDrag? decode(Object? raw) {
    if (raw is SftpInternalDrag) return raw;
    if (raw is! Map || raw['vyshSftpDrag'] != 1) return null;
    final scopeId = raw['scopeId'];
    final windowsPaths = raw['windowsPaths'];
    final rawEntries = raw['entries'];
    if (scopeId is! String || windowsPaths is! bool || rawEntries is! List) {
      return null;
    }
    final entries = <RemoteEntry>[];
    for (final item in rawEntries) {
      if (item is! Map) continue;
      final name = item['name'];
      final path = item['path'];
      final isDir = item['isDir'];
      if (name is! String || path is! String || isDir is! bool) continue;
      final modifiedMs = item['modified'];
      final mode = item['mode'];
      final size = item['size'];
      entries.add(
        RemoteEntry(
          name: name,
          path: path,
          isDir: isDir,
          isLink: item['isLink'] == true,
          size: size is int ? size : 0,
          modified: modifiedMs is int
              ? DateTime.fromMillisecondsSinceEpoch(modifiedMs)
              : null,
          mode: mode is int ? mode : null,
        ),
      );
    }
    return entries.isEmpty
        ? null
        : SftpInternalDrag(
            scopeId: scopeId,
            entries: entries,
            windowsPaths: windowsPaths,
          );
  }
}

/// Формат «любой файл» для виртуальных файлов.
const _anyFile = SimpleFileFormat(
  uniformTypeIdentifiers: ['public.data'],
  mimeTypes: ['application/octet-stream'],
);

/// Можно ли вытащить эту запись в системный файловый менеджер на текущей платформе.
bool canDragOut(RemoteEntry e, {bool localFiles = false}) {
  if (!_fileDragAndDropEnabled) return false;
  if (localFiles) return !e.isLink;
  if (e.isDir) return !e.isLink && PlatformCapabilities.dragOutFileUri;
  return PlatformCapabilities.dragOutVirtualFiles ||
      PlatformCapabilities.dragOutFileUri;
}

/// Строка панели, которую можно перетащить в файловый менеджер, подпапку или терминал.
class SftpDragSource extends StatelessWidget {
  const SftpDragSource({
    super.key,
    required this.entry,
    required this.scopeId,
    required this.actions,
    required this.child,
    this.selectedEntries = const [],
    this.windowsPaths = false,
    this.localFiles = false,
  });

  final RemoteEntry entry;
  final String scopeId;

  /// Текущее мультивыделение: если [entry] входит в него, тянем сразу всю группу.
  final List<RemoteEntry> selectedEntries;
  final bool windowsPaths;

  /// Записи уже лежат на локальном диске (можно сразу отдать `Formats.fileUri`,
  /// включая папки на Windows и macOS, без скачивания во временную папку).
  final bool localFiles;

  /// null - внешняя выгрузка удалённого файла в ОС недоступна (но внутренний drag работает).
  final SftpActions? Function() actions;
  final Widget child;

  List<RemoteEntry> get _effectiveEntries =>
      selectedEntries.length > 1 &&
          selectedEntries.any((x) => x.path == entry.path)
      ? selectedEntries
      : [entry];

  @override
  Widget build(BuildContext context) {
    if (!_fileDragAndDropEnabled) return child;
    return DragItemWidget(
      allowedOperations: () => const [DropOperation.copy, DropOperation.move],
      dragItemProvider: (request) => _createItem(request, entry, primary: true),
      child: DraggableWidget(
        onDragConfiguration: (config, session) async {
          final group = _effectiveEntries;
          if (group.length <= 1 || config.items.isEmpty) return config;
          final snapshot = config.items.first.image;
          final items = <DragConfigurationItem>[config.items.first];
          for (final other in group) {
            if (other.path == entry.path) continue;
            final extra = await _createItem(
              DragItemRequest(location: Offset.zero, session: session),
              other,
              primary: false,
            );
            if (extra != null) {
              items.add(DragConfigurationItem(item: extra, image: snapshot));
            }
          }
          return DragConfiguration(
            items: items,
            allowedOperations: config.allowedOperations,
          );
        },
        child: child,
      ),
    );
  }

  Future<DragItem?> _createItem(
    DragItemRequest request,
    RemoteEntry target, {
    required bool primary,
  }) async {
    final localPayload = SftpInternalDrag(
      scopeId: scopeId,
      entries: primary ? _effectiveEntries : [target],
      windowsPaths: windowsPaths,
    );
    final item = DragItem(
      suggestedName: LocalFiles.safeName(target.name),
      localData: localPayload.toJson(),
    );
    if (localFiles && !target.isLink) {
      item.add(Formats.fileUri(Uri.file(target.path)));
    } else {
      final a = actions();
      if (a != null && canDragOut(target)) {
        if (PlatformCapabilities.dragOutVirtualFiles && !target.isDir) {
          item.addVirtualFile(
            format: _anyFile,
            provider: (sinkProvider, progress) =>
                _writeVirtual(a, target, sinkProvider, progress),
          );
        } else if (PlatformCapabilities.dragOutFileUri) {
          final download = a.downloadForDrag(target);
          void onCompleted() {
            final op = request.session.dragCompleted.value;
            if (op == DropOperation.none || op == DropOperation.userCancelled) {
              download.cancel();
            }
          }

          request.session.dragCompleted.addListener(onCompleted);
          item.add(
            Formats.fileUri.lazy(() async => Uri.file(await download.path)),
          );
        }
      }
    }
    // Plain-text fallback для перетаскивания в текстовые поля / внешние терминалы.
    item.add(
      Formats.plainText(shellQuotePath(target.path, windows: windowsPaths)),
    );
    return item;
  }

  /// Проводник или Finder попросили содержимое: скачиваем и отдаём потоком.
  Future<void> _writeVirtual(
    SftpActions actions,
    RemoteEntry target,
    VirtualFileEventSinkProvider sinkProvider,
    WriteProgress progress,
  ) async {
    final download = actions.downloadForDrag(target);
    progress.onCancel.addListener(download.cancel);
    EventSink? opened;
    try {
      final file = File(await download.path);
      final sink = opened = sinkProvider(fileSize: await file.length());
      await for (final chunk in file.openRead()) {
        sink.add(chunk);
      }
      sink.close();
    } catch (e) {
      final sink = opened ?? sinkProvider(fileSize: 0);
      sink.addError(e);
      sink.close();
    }
  }
}

/// Цель сброса на строку папки (или `..`) для перемещения элементов внутрь неё
/// (или копирования из соседней панели, если задан [onCopyExternal]).
class SftpFolderDropTarget extends StatefulWidget {
  const SftpFolderDropTarget({
    super.key,
    required this.scopeId,
    required this.targetDirPath,
    required this.enabled,
    required this.onMoveEntries,
    required this.child,
    this.onCopyExternal,
  });

  final String scopeId;
  final String targetDirPath;
  final bool enabled;
  final ValueChanged<List<RemoteEntry>> onMoveEntries;
  final ValueChanged<SftpInternalDrag>? onCopyExternal;
  final Widget child;

  @override
  State<SftpFolderDropTarget> createState() => _SftpFolderDropTargetState();
}

class _SftpFolderDropTargetState extends State<SftpFolderDropTarget> {
  bool _hover = false;

  ({DropOperation op, List<RemoteEntry>? move, SftpInternalDrag? copy})
  _resolve(DropSession session) {
    if (!widget.enabled) {
      return (op: DropOperation.none, move: null, copy: null);
    }
    for (final item in session.items) {
      final local = SftpInternalDrag.decode(item.localData);
      if (local == null) continue;
      if (local.scopeId == widget.scopeId) {
        final valid = local.entries.where((e) {
          if (e.path == widget.targetDirPath) return false;
          if (e.isDir &&
              (widget.targetDirPath.startsWith('${e.path}/') ||
                  widget.targetDirPath.startsWith('${e.path}\\'))) {
            return false;
          }
          return true;
        }).toList();
        return valid.isEmpty
            ? (op: DropOperation.none, move: null, copy: null)
            : (op: DropOperation.move, move: valid, copy: null);
      }
      if (widget.onCopyExternal != null && local.entries.isNotEmpty) {
        return (op: DropOperation.copy, move: null, copy: local);
      }
    }
    return (op: DropOperation.none, move: null, copy: null);
  }

  @override
  Widget build(BuildContext context) {
    if (!_fileDragAndDropEnabled) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return DropRegion(
      formats: Formats.standardFormats,
      hitTestBehavior: HitTestBehavior.translucent,
      onDropOver: (event) {
        final resolved = _resolve(event.session);
        final canAccept = resolved.op != DropOperation.none;
        if (_hover != canAccept) setState(() => _hover = canAccept);
        return resolved.op;
      },
      onDropLeave: (_) {
        if (_hover) setState(() => _hover = false);
      },
      onDropEnded: (_) {
        if (_hover) setState(() => _hover = false);
      },
      onPerformDrop: (event) async {
        if (_hover) setState(() => _hover = false);
        final resolved = _resolve(event.session);
        if (resolved.move != null) {
          widget.onMoveEntries(resolved.move!);
        } else if (resolved.copy != null) {
          widget.onCopyExternal?.call(resolved.copy!);
        }
      },
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: _hover ? Border.all(color: scheme.primary, width: 2) : null,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Зона терминала, принимающая перетаскиваемые файлы/папки и вставляющая их пути.
class SftpTerminalDropZone extends StatefulWidget {
  const SftpTerminalDropZone({
    super.key,
    required this.enabled,
    required this.windowsShell,
    required this.acceptLocalOsFiles,
    required this.onInsertText,
    required this.child,
  });

  final bool enabled;
  final bool windowsShell;
  final bool acceptLocalOsFiles;
  final ValueChanged<String> onInsertText;
  final Widget child;

  @override
  State<SftpTerminalDropZone> createState() => _SftpTerminalDropZoneState();
}

class _SftpTerminalDropZoneState extends State<SftpTerminalDropZone> {
  bool _hover = false;

  bool _canAccept(DropSession session) {
    if (!widget.enabled) return false;
    for (final item in session.items) {
      if (SftpInternalDrag.decode(item.localData) != null) return true;
      if (widget.acceptLocalOsFiles && item.canProvide(Formats.fileUri)) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!_fileDragAndDropEnabled) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return DropRegion(
      formats: const [Formats.fileUri, Formats.plainText],
      hitTestBehavior: HitTestBehavior.translucent,
      onDropOver: (event) {
        final ok = _canAccept(event.session);
        if (_hover != ok) setState(() => _hover = ok);
        return ok ? DropOperation.copy : DropOperation.none;
      },
      onDropLeave: (_) {
        if (_hover) setState(() => _hover = false);
      },
      onDropEnded: (_) {
        if (_hover) setState(() => _hover = false);
      },
      onPerformDrop: (event) async {
        if (_hover) setState(() => _hover = false);
        for (final item in event.session.items) {
          if (SftpInternalDrag.decode(item.localData) case final drag?) {
            final quoted = drag.entries
                .map(
                  (e) => shellQuotePath(e.path, windows: widget.windowsShell),
                )
                .join(' ');
            if (quoted.isNotEmpty) widget.onInsertText('$quoted ');
            return;
          }
        }
        if (!widget.acceptLocalOsFiles) return;
        final paths = <String>[];
        for (final item in event.session.items) {
          final reader = item.dataReader;
          if (reader == null || !reader.canProvide(Formats.fileUri)) continue;
          final uri = await SftpDropZone._read(reader);
          if (uri != null && uri.isScheme('file')) {
            paths.add(
              shellQuotePath(uri.toFilePath(), windows: widget.windowsShell),
            );
          }
        }
        if (paths.isNotEmpty) widget.onInsertText('${paths.join(' ')} ');
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_hover)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.primary, width: 2),
                    color: scheme.primary.withValues(alpha: 0.08),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Область панели, принимающая файлы и папки из системного файлового менеджера
/// (а также при наличии [onDropInternal] - из другой панели vysh).
class SftpDropZone extends StatelessWidget {
  const SftpDropZone({
    super.key,
    required this.enabled,
    required this.onHover,
    required this.onDropPaths,
    required this.child,
    this.scopeId,
    this.onDropInternal,
  });

  final bool enabled;
  final String? scopeId;

  /// true - над панелью тянут файлы для загрузки/копирования, false - ушли.
  final ValueChanged<bool> onHover;
  final ValueChanged<List<String>> onDropPaths;
  final ValueChanged<SftpInternalDrag>? onDropInternal;
  final Widget child;

  SftpInternalDrag? _extractInternal(DropSession session) {
    for (final item in session.items) {
      final decoded = SftpInternalDrag.decode(item.localData);
      if (decoded != null) return decoded;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_fileDragAndDropEnabled) return child;
    return DropRegion(
      formats: const [Formats.fileUri, Formats.plainText],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) {
        if (!enabled) return DropOperation.none;
        final internal = _extractInternal(event.session);
        if (internal != null) {
          if (onDropInternal != null &&
              internal.scopeId != scopeId &&
              internal.entries.isNotEmpty) {
            return DropOperation.copy;
          }
          // Свою же строку проводника обратно как внешнюю загрузку не трактуем.
          return DropOperation.none;
        }
        final items = event.session.items;
        if (!items.any((i) => i.canProvide(Formats.fileUri))) {
          return DropOperation.none;
        }
        final ops = event.session.allowedOperations;
        return ops.isEmpty || ops.contains(DropOperation.copy)
            ? DropOperation.copy
            : DropOperation.none;
      },
      onDropEnter: (_) => onHover(true),
      onDropLeave: (_) => onHover(false),
      onDropEnded: (_) => onHover(false),
      onPerformDrop: (event) async {
        final internal = _extractInternal(event.session);
        if (internal != null) {
          if (onDropInternal != null &&
              internal.scopeId != scopeId &&
              internal.entries.isNotEmpty) {
            onDropInternal!(internal);
          }
          return;
        }
        final paths = <String>[];
        for (final item in event.session.items) {
          final reader = item.dataReader;
          if (reader == null || !reader.canProvide(Formats.fileUri)) continue;
          final uri = await _read(reader);
          if (uri != null && uri.isScheme('file')) paths.add(uri.toFilePath());
        }
        if (paths.isNotEmpty) onDropPaths(paths);
      },
      child: child,
    );
  }

  static Future<Uri?> _read(DataReader reader) {
    final c = Completer<Uri?>();
    final started = reader.getValue<Uri>(
      Formats.fileUri,
      (value) {
        if (!c.isCompleted) c.complete(value);
      },
      onError: (_) {
        if (!c.isCompleted) c.complete(null);
      },
    );
    if (started == null && !c.isCompleted) c.complete(null);
    return c.future;
  }
}
