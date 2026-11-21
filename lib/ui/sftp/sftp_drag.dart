import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../app/sftp/sftp_actions.dart';
import '../../app/sftp/sftp_clipboard.dart';
import '../../domain/ports/sftp.dart';
import '../../infra/platform/capabilities.dart';

/// Перетаскивание между панелью SFTP, подпапками, терминалом и системным проводником.
///
/// * Наружу в ОС: одиночный или множественный drag всех выделенных файлов/папок.
/// * Внутри одной панели проводника: перетаскивание на строку папки или `..`
///   перемещает (`rename`) выбранные элементы внутрь этой папки.
/// * В область терминала: перетаскивание элементов из проводника или файлов ОС
///   вставляет экранированные пути в командную строку.
/// * Из ОС в проводник: загружает файлы и папки в текущую директорию.

/// Внутренние данные перетаскивания из проводника vysh.
class SftpInternalDrag {
  const SftpInternalDrag({
    required this.scopeId,
    required this.entries,
    required this.windowsPaths,
  });

  final String scopeId;
  final List<RemoteEntry> entries;
  final bool windowsPaths;
}

/// Формат «любой файл» для виртуальных файлов.
const _anyFile = SimpleFileFormat(
  uniformTypeIdentifiers: ['public.data'],
  mimeTypes: ['application/octet-stream'],
);

/// Можно ли вытащить эту запись в системный файловый менеджер на текущей платформе.
bool canDragOut(RemoteEntry e) {
  if (!PlatformCapabilities.fileDragAndDrop) return false;
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
  });

  final RemoteEntry entry;
  final String scopeId;

  /// Текущее мультивыделение: если [entry] входит в него, тянем сразу всю группу.
  final List<RemoteEntry> selectedEntries;
  final bool windowsPaths;

  /// null - внешняя выгрузка в ОС недоступна (но внутренний drag в подпапку/терминал работает).
  final SftpActions? Function() actions;
  final Widget child;

  List<RemoteEntry> get _effectiveEntries =>
      selectedEntries.length > 1 &&
          selectedEntries.any((x) => x.path == entry.path)
      ? selectedEntries
      : [entry];

  @override
  Widget build(BuildContext context) {
    if (!PlatformCapabilities.fileDragAndDrop) return child;
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
    final item = DragItem(suggestedName: target.name, localData: localPayload);
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

/// Цель сброса на строку папки (или `..`) для перемещения элементов внутрь неё.
class SftpFolderDropTarget extends StatefulWidget {
  const SftpFolderDropTarget({
    super.key,
    required this.scopeId,
    required this.targetDirPath,
    required this.enabled,
    required this.onMoveEntries,
    required this.child,
  });

  final String scopeId;
  final String targetDirPath;
  final bool enabled;
  final ValueChanged<List<RemoteEntry>> onMoveEntries;
  final Widget child;

  @override
  State<SftpFolderDropTarget> createState() => _SftpFolderDropTargetState();
}

class _SftpFolderDropTargetState extends State<SftpFolderDropTarget> {
  bool _hover = false;

  List<RemoteEntry>? _extractMovable(DropSession session) {
    if (!widget.enabled) return null;
    for (final item in session.items) {
      final local = item.localData;
      if (local is SftpInternalDrag && local.scopeId == widget.scopeId) {
        final valid = local.entries.where((e) {
          if (e.path == widget.targetDirPath) return false;
          if (e.isDir &&
              (widget.targetDirPath.startsWith('${e.path}/') ||
                  widget.targetDirPath.startsWith('${e.path}\\'))) {
            return false;
          }
          return true;
        }).toList();
        return valid.isEmpty ? null : valid;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformCapabilities.fileDragAndDrop) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return DropRegion(
      formats: Formats.standardFormats,
      hitTestBehavior: HitTestBehavior.translucent,
      onDropOver: (event) {
        final movable = _extractMovable(event.session);
        final canAccept = movable != null;
        if (_hover != canAccept) setState(() => _hover = canAccept);
        return canAccept ? DropOperation.move : DropOperation.none;
      },
      onDropLeave: (_) {
        if (_hover) setState(() => _hover = false);
      },
      onDropEnded: (_) {
        if (_hover) setState(() => _hover = false);
      },
      onPerformDrop: (event) async {
        if (_hover) setState(() => _hover = false);
        final movable = _extractMovable(event.session);
        if (movable != null) widget.onMoveEntries(movable);
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
      if (item.localData is SftpInternalDrag) return true;
      if (widget.acceptLocalOsFiles && item.canProvide(Formats.fileUri)) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformCapabilities.fileDragAndDrop) return widget.child;
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
          if (item.localData case final SftpInternalDrag drag) {
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

/// Область панели, принимающая файлы и папки из системного файлового менеджера.
class SftpDropZone extends StatelessWidget {
  const SftpDropZone({
    super.key,
    required this.enabled,
    required this.onHover,
    required this.onDropPaths,
    required this.child,
  });

  final bool enabled;

  /// true - над панелью тянут внешние файлы (показать подсказку), false - ушли.
  final ValueChanged<bool> onHover;
  final ValueChanged<List<String>> onDropPaths;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!PlatformCapabilities.fileDragAndDrop) return child;
    return DropRegion(
      formats: const [Formats.fileUri],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) {
        if (!enabled) return DropOperation.none;
        final items = event.session.items;
        // Свою же строку проводника обратно как внешнюю загрузку не трактуем.
        if (items.any((i) => i.localData is SftpInternalDrag)) {
          return DropOperation.none;
        }
        if (!items.any((i) => i.canProvide(Formats.fileUri))) {
          return DropOperation.none;
        }
        return event.session.allowedOperations.contains(DropOperation.copy)
            ? DropOperation.copy
            : DropOperation.none;
      },
      onDropEnter: (_) => onHover(true),
      onDropLeave: (_) => onHover(false),
      onDropEnded: (_) => onHover(false),
      onPerformDrop: (event) async {
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
