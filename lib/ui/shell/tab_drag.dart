import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:super_clipboard/super_clipboard.dart'
    show SimpleValueFormat, SimplePlatformCodec;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import '../../domain/models/session_tab.dart';
import '../../infra/platform/capabilities.dart';
import 'ui_state.dart';
import 'workspace_actions.dart';

final nativeTabDragProvider = Provider<bool>(
  (_) => PlatformCapabilities.fileDragAndDrop,
);
const _tabFormat = SimpleValueFormat<String>(
  linux: SimplePlatformCodec(formats: ['application/x-vysh-session-tab']),
  macos: SimplePlatformCodec(formats: ['dev.vysh.session-tab']),
  windows: SimplePlatformCodec(formats: ['Vysh.SessionTab']),
);
String? _tabId(Object? value) =>
    value is Map && value['type'] == 'vysh-tab' ? value['id'] as String? : null;

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
        ref.read(draggedTabProvider.notifier).select(widget.tab.id);
        request.session.dragCompleted.addListener(() {
          final operation = request.session.dragCompleted.value;
          final location = request.session.lastScreenLocation.value;
          if (!mounted || operation == null) return;
          ref.read(draggedTabProvider.notifier).select(null);
          if (operation == DropOperation.none) unawaited(_tearOff(location));
        });
        return DragItem(localData: {'type': 'vysh-tab', 'id': widget.tab.id})
          ..add(_tabFormat(widget.tab.id));
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
      onDropOver: (event) {
        final id = event.session.items
            .map((item) => _tabId(item.localData))
            .whereType<String>()
            .firstOrNull;
        final accepts = id != null && widget.canAccept(id);
        if (hover != accepts) setState(() => hover = accepts);
        return accepts ? DropOperation.move : DropOperation.none;
      },
      onDropLeave: (_) => setState(() => hover = false),
      onDropEnded: (_) => setState(() => hover = false),
      onPerformDrop: (event) async {
        final id = event.session.items
            .map((item) => _tabId(item.localData))
            .whereType<String>()
            .firstOrNull;
        if (id != null && widget.canAccept(id)) widget.onAccept(id);
      },
      child: flutterTarget,
    );
  }
}
