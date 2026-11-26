import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../infra/platform/desktop_env.dart';
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

/// Root-level drop observer on each window: tracks pointer entry/exit for
/// Wayland-safe tear-off and reveals split drop zones for cross-window drags.
/// Uses [DropMonitor] rather than [DropRegion] because a [DropRegion] returning
/// [DropOperation.none] never becomes the active region and therefore never
/// receives [DropRegion.onDropLeave] or [DropRegion.onDropEnded].
class WindowTabDragScope extends ConsumerWidget {
  const WindowTabDragScope({super.key, required this.child});
  final Widget child;

  void _syncPointerBounds(BuildContext context, WidgetRef ref, Offset local) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      ref
          .read(pointerInsideWindowProvider.notifier)
          .set((Offset.zero & box.size).contains(local));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(nativeTabDragProvider)) return child;
    return MouseRegion(
      hitTestBehavior: HitTestBehavior.translucent,
      onEnter: (_) => ref.read(pointerInsideWindowProvider.notifier).set(true),
      onExit: (_) => ref.read(pointerInsideWindowProvider.notifier).set(false),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => _syncPointerBounds(context, ref, e.localPosition),
        onPointerMove: (e) => _syncPointerBounds(context, ref, e.localPosition),
        child: DropMonitor(
          formats: const [_tabFormat],
          hitTestBehavior: HitTestBehavior.translucent,
          onDropOver: (event) {
            if (!event.session.items.any((i) => i.canProvide(_tabFormat))) {
              return;
            }
            ref.read(tabDragInsideWindowProvider.notifier).set(event.isInside);
            if (ref.read(draggedTabProvider) == null) {
              ref.read(incomingTabDragProvider.notifier).set(event.isInside);
            }
          },
          onDropLeave: (_) {
            ref.read(tabDragInsideWindowProvider.notifier).set(false);
            ref.read(incomingTabDragProvider.notifier).set(false);
          },
          onDropEnded: (_) {
            ref.read(incomingTabDragProvider.notifier).set(false);
          },
          child: child,
        ),
      ),
    );
  }
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
  bool _cancelledByEscape = false;
  bool _listeningEscape = false;

  bool _onEscapeKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelledByEscape = true;
    }
    return false;
  }

  void _startEscapeWatch() {
    _cancelledByEscape = false;
    if (!_listeningEscape) {
      _listeningEscape = true;
      HardwareKeyboard.instance.addHandler(_onEscapeKey);
    }
  }

  void _stopEscapeWatch() {
    if (_listeningEscape) {
      _listeningEscape = false;
      HardwareKeyboard.instance.removeHandler(_onEscapeKey);
    }
  }

  @override
  void dispose() {
    _stopEscapeWatch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    if (!ref.watch(nativeTabDragProvider)) {
      final scheme = Theme.of(context).colorScheme;
      final feedback = Material(
        elevation: 6,
        color: scheme.secondaryContainer,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            widget.tab.title,
            style: TextStyle(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      );
      void onDragStarted() =>
          ref.read(draggedTabProvider.notifier).select(widget.tab.id);
      void onDragUpdate(DragUpdateDetails d) => _position = d.globalPosition;
      void onDragEnd(DraggableDetails d) {
        ref.read(draggedTabProvider.notifier).select(null);
        if (!d.wasAccepted &&
            !(Offset.zero & MediaQuery.sizeOf(context))
                .inflate(6)
                .contains(_position ?? d.offset) &&
            PlatformCapabilities.desktopWindow) {
          detachSession(context, ref, widget.tab.id);
        }
      }

      if (DesktopEnv.isMobile) {
        return LongPressDraggable<String>(
          data: widget.tab.id,
          feedback: feedback,
          onDragStarted: onDragStarted,
          onDragUpdate: onDragUpdate,
          onDragEnd: onDragEnd,
          child: widget.child,
        );
      }
      return Draggable<String>(
        data: widget.tab.id,
        feedback: feedback,
        onDragStarted: onDragStarted,
        onDragUpdate: onDragUpdate,
        onDragEnd: onDragEnd,
        child: widget.child,
      );
    }
    return DragItemWidget(
      allowedOperations: () => [DropOperation.move],
      dragItemProvider: (request) async {
        final owner = ref.read(detachedWindowsProvider.notifier);
        final dragging = ref.read(draggedTabProvider.notifier);
        final inside = ref.read(tabDragInsideWindowProvider.notifier);
        final transfer = await owner.beginDrag(widget.tab.id);
        if (!mounted) {
          await owner.finishDrag(transfer);
          return null;
        }
        final startedInside = ref.read(pointerInsideWindowProvider);
        var pointerExitedDuringDrag = !startedInside;
        final removePointerListener = ref.listenManual<bool>(
          pointerInsideWindowProvider,
          (_, next) {
            if (!next) pointerExitedDuringDrag = true;
          },
        );
        dragging.select(widget.tab.id);
        inside.set(startedInside);
        _startEscapeWatch();
        request.session.dragCompleted.addListener(() {
          final operation = request.session.dragCompleted.value;
          final location = request.session.lastScreenLocation.value;
          if (operation == null) return;
          removePointerListener.close();
          final cancelled = _cancelledByEscape;
          final wasInside = ref.read(tabDragInsideWindowProvider);
          final pointerExited = pointerExitedDuringDrag;
          _stopEscapeWatch();
          dragging.select(null);
          unawaited(
            owner.finishDrag(
              transfer,
              accepted: operation == DropOperation.move,
            ),
          );
          if (mounted && operation == DropOperation.none && !cancelled) {
            unawaited(
              _tearOff(
                location,
                insideWindow: wasInside,
                pointerExitedDuringDrag: pointerExited,
              ),
            );
          } else {
            inside.set(false);
          }
        });
        return DragItem(localData: transfer.toJson())
          ..add(_tabFormat(utf8.encode(jsonEncode(transfer.toJson()))));
      },
      child: DraggableWidget(child: widget.child),
    );
  }

  Future<void> _tearOff(
    Offset? location, {
    required bool insideWindow,
    required bool pointerExitedDuringDrag,
  }) async {
    final bool shouldDetach;
    if (DesktopEnv.isWayland) {
      final effectiveInside = await resolveWaylandInsideWindow(
        initialDropInside: insideWindow,
        pointerExitedDuringDrag: pointerExitedDuringDrag,
        readDropInside: () => ref.read(tabDragInsideWindowProvider),
        readPointerInside: () => ref.read(pointerInsideWindowProvider),
      );
      if (mounted) {
        ref.read(tabDragInsideWindowProvider.notifier).set(false);
      }
      if (!mounted) return;
      shouldDetach = shouldTearOffTab(
        isWayland: true,
        insideWindow: effectiveInside,
      );
    } else {
      ref.read(tabDragInsideWindowProvider.notifier).set(false);
      // On macOS super_native_extensions reports lastScreenLocation in Cocoa
      // screen coordinates (bottom-left origin, Y up), while window_manager
      // and screen_retriever use top-left coordinates (Y down).
      final point = PlatformCapabilities.isMacOS
          ? await screenRetriever.getCursorScreenPoint()
          : location ?? await screenRetriever.getCursorScreenPoint();
      final bounds = await windowManager.getBounds();
      if (!mounted) return;
      shouldDetach = shouldTearOffTab(
        isWayland: false,
        insideWindow: insideWindow,
        cursorPoint: point,
        windowBounds: bounds,
      );
    }
    if (!mounted || !shouldDetach) return;
    await detachSession(context, ref, widget.tab.id);
  }
}

/// Resolves whether a Wayland tab drag ended inside our surface.
///
/// On GTK3/Wayland (Hyprland, Sway, Mutter, KWin):
/// - `PlatformDropContext` defers `drag_leave` via `RunLoop::schedule_next`
///   while `PlatformDragContext` emits `cancel` synchronously on fast flicks.
/// - `PlatformDataReader::reader_info()` drops the first `drag_motion`, so an
///   upward exit from the top tab bar in <=1 motion frame never creates a Dart
///   `DropSession` or invokes `onDropLeave`.
/// - On `wl_data_device.start_drag` the compositor clears `wl_pointer` focus
///   ([pointerExitedDuringDrag] becomes `true`), and upon ending an unaccepted
///   drag (`cleanupDndState`) it immediately resends `wl_pointer.enter` if and
///   only if the cursor is still over our surface.
@visibleForTesting
Future<bool> resolveWaylandInsideWindow({
  required bool initialDropInside,
  required bool pointerExitedDuringDrag,
  required bool Function() readDropInside,
  required bool Function() readPointerInside,
  Duration settleDelay = const Duration(milliseconds: 24),
}) async {
  await Future<void>.delayed(settleDelay);
  if (pointerExitedDuringDrag) {
    return readPointerInside();
  }
  return initialDropInside && readDropInside();
}

/// Decides whether a completed unaccepted tab drag should detach into a new
/// window. On Wayland global coordinates are unavailable, so the decision
/// relies solely on [insideWindow].
@visibleForTesting
bool shouldTearOffTab({
  required bool isWayland,
  required bool insideWindow,
  Offset? cursorPoint,
  Rect? windowBounds,
}) {
  if (isWayland) return !insideWindow;
  if (!insideWindow) return true;
  if (cursorPoint == null || windowBounds == null) return false;
  return !windowBounds.inflate(6).contains(cursorPoint);
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
          ref.read(incomingTabDragProvider.notifier).set(false);
          widget.onAccept(transfer.id);
          await windowManager.focus();
        }
      },
      child: flutterTarget,
    );
  }
}
