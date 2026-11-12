import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:super_clipboard/super_clipboard.dart'
    show SimpleValueFormat, SimplePlatformCodec;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import '../../domain/models/session_tab.dart';
import '../../app/windows/detached_windows.dart';
import '../../app/windows/tab_transfer.dart';
import '../../infra/platform/capabilities.dart';
import 'ui_state.dart';
import 'workspace_actions.dart';

final nativeTabDragProvider = Provider<bool>(
  (_) => PlatformCapabilities.fileDragAndDrop,
);
const _tabFormat = SimpleValueFormat<Object>(
  linux: SimplePlatformCodec(formats: ['application/x-vysh-session-tab']),
  macos: SimplePlatformCodec(formats: ['dev.vysh.session-tab']),
  windows: SimplePlatformCodec(formats: ['Vysh.SessionTab']),
);
TabTransfer? _localTransfer(DropSession session) => session.items
    .map((item) => TabTransfer.decode(item.localData))
    .whereType<TabTransfer>()
    .firstOrNull;

Future<TabTransfer?> _readTransfer(DropSession session) async {
  final local = _localTransfer(session);
  if (local != null) return local;
  for (final item in session.items) {
    final reader = item.dataReader;
    if (reader == null || !item.canProvide(_tabFormat)) continue;
    final value = Completer<Object?>();
    final progress = reader.getValue<Object>(
      _tabFormat,
      (data) {
        if (!value.isCompleted) value.complete(data);
      },
      onError: (_) {
        if (!value.isCompleted) value.complete(null);
      },
    );
    if (progress == null) continue;
    final transfer = TabTransfer.decode(await value.future);
    if (transfer != null) return transfer;
  }
  return null;
}

/// Native dragging receives completion outside the Flutter view as well. A
/// Flutter-only draggable can lose the mouse-up event beyond a GTK window.
class SessionTabDrag extends ConsumerStatefulWidget {
  const SessionTabDrag({
    super.key,
    required this.tab,
    required this.child,
    required this.enabled,
  });
  final SessionTab tab;
  final Widget child;
  final bool enabled;
  @override
  ConsumerState<SessionTabDrag> createState() => _SessionTabDragState();
}

class _SessionTabDragState extends ConsumerState<SessionTabDrag> {
  Offset? _position;
  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    if (!ref.watch(nativeTabDragProvider)) {
      return Draggable<String>(
        data: widget.tab.id,
        feedback: Material(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(widget.tab.title),
          ),
        ),
        onDragStarted: () =>
            ref.read(draggedTabProvider.notifier).select(widget.tab.id),
        onDragUpdate: (d) => _position = d.globalPosition,
        onDragEnd: (d) {
          ref.read(draggedTabProvider.notifier).select(null);
          if (!d.wasAccepted &&
              !(Offset.zero & MediaQuery.sizeOf(context))
                  .inflate(6)
                  .contains(_position ?? d.offset) &&
              PlatformCapabilities.desktopWindow) {
            detachSession(context, ref, widget.tab.id);
          }
        },
        child: widget.child,
      );
    }
    return DragItemWidget(
      allowedOperations: () => [DropOperation.move],
      dragItemProvider: (request) async {
        final owner = ref.read(detachedWindowsProvider.notifier);
        final dragging = ref.read(draggedTabProvider.notifier);
        final transfer = await owner.beginDrag(widget.tab.id);
        if (!mounted) {
          await owner.finishDrag(transfer);
          return null;
        }
        dragging.select(widget.tab.id);
        request.session.dragCompleted.addListener(() {
          final operation = request.session.dragCompleted.value;
          final location = request.session.lastScreenLocation.value;
          if (operation == null) return;
          dragging.select(null);
          unawaited(
            owner.finishDrag(
              transfer,
              accepted: operation == DropOperation.move,
            ),
          );
          if (mounted && operation == DropOperation.none) {
            unawaited(_tearOff(location));
          }
        });
        return DragItem(localData: transfer.toJson())
          ..add(_tabFormat(utf8.encode(jsonEncode(transfer.toJson()))));
      },
      child: DraggableWidget(child: widget.child),
    );
  }

  Future<void> _tearOff(Offset? location) async {
    final point = location ?? await screenRetriever.getCursorScreenPoint();
    final bounds = await windowManager.getBounds();
    if (!mounted || bounds.inflate(6).contains(point)) return;
    await detachSession(context, ref, widget.tab.id);
  }
}

class TabDropTarget extends ConsumerStatefulWidget {
  const TabDropTarget({
    super.key,
    required this.canAccept,
    required this.onAccept,
    required this.builder,
  });
  final bool Function(String id) canAccept;
  final void Function(String id) onAccept;
  final Widget Function(BuildContext context, bool hover) builder;
  @override
  ConsumerState<TabDropTarget> createState() => _TabDropTargetState();
}

class _TabDropTargetState extends ConsumerState<TabDropTarget> {
  bool hover = false;
  String? _validatedToken;
  @override
  Widget build(BuildContext context) {
    final flutterTarget = DragTarget<String>(
      onWillAcceptWithDetails: (d) => widget.canAccept(d.data),
      onAcceptWithDetails: (d) => widget.onAccept(d.data),
      builder: (context, accepted, _) =>
          widget.builder(context, hover || accepted.isNotEmpty),
    );
    if (!ref.watch(nativeTabDragProvider)) return flutterTarget;
    return DropRegion(
      formats: const [_tabFormat],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) async {
        final transfer = _localTransfer(event.session);
        var accepts = transfer == null
            ? event.session.items.any((item) => item.canProvide(_tabFormat))
            : widget.canAccept(transfer.id);
        if (accepts && transfer != null && _validatedToken != transfer.token) {
          accepts = await ref
              .read(detachedWindowsProvider.notifier)
              .canAcceptDrag(transfer);
          if (accepts) _validatedToken = transfer.token;
        }
        if (!mounted) return DropOperation.none;
        if (hover != accepts) setState(() => hover = accepts);
        return accepts ? DropOperation.move : DropOperation.none;
      },
      onDropLeave: (_) => setState(() => hover = false),
      onDropEnded: (_) => setState(() {
        hover = false;
        _validatedToken = null;
      }),
      onPerformDrop: (event) async {
        final owner = ref.read(detachedWindowsProvider.notifier);
        final transfer = await _readTransfer(event.session);
        if (!mounted || transfer == null || !widget.canAccept(transfer.id)) {
          return;
        }
        if (!await owner.canAcceptDrag(transfer)) return;
        await owner.acceptDrag(transfer);
        if (mounted) {
          widget.onAccept(transfer.id);
          await windowManager.focus();
        }
      },
      child: flutterTarget,
    );
  }
}
