import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/windows/detached_windows.dart';
import '../../domain/models/session_tab.dart';
import '../../l10n/app_strings.dart';
import '../terminal/session_view.dart';
import 'ui_state.dart';
import 'workspace_actions.dart';
import 'tab_drag.dart';

class SessionWorkspace extends ConsumerStatefulWidget {
  const SessionWorkspace({super.key, required this.home});
  final Widget home;
  @override
  ConsumerState<SessionWorkspace> createState() => _SessionWorkspaceState();
}

class _SessionWorkspaceState extends ConsumerState<SessionWorkspace> {
  final _keys = <String, GlobalKey>{};
  final _homeKey = GlobalKey();
  double _ratio = .5;
  @override
  Widget build(BuildContext context) {
    final tabs = ref.watch(tabsProvider);
    final external = ref.watch(detachedWindowsProvider);
    final split = ref.watch(splitTabProvider);
    final layout = ref.watch(splitLayoutProvider);
    final dragging = ref.watch(draggedTabProvider);
    final focused = ref.watch(workspaceFocusProvider);
    final pause = ref.watch(settingsProvider.select((s) => s.pauseHiddenTabs));
    final isRu = AppStrings.of(
      context,
      ref.read(settingsProvider).language,
    ).isRu;
    _keys.removeWhere((id, _) => !tabs.tabs.any((t) => t.id == id));
    final secondary = tabs.tabs
        .where((t) => t.id == split && !external.containsKey(t.id))
        .firstOrNull;
    final primary = tabs.activeTab;
    final hasSplit =
        secondary != null &&
        primary != null &&
        primary.id != split &&
        !external.containsKey(primary.id);
    final activeId = hasSplit && focused == secondary.id
        ? secondary.id
        : primary?.id;
    Widget session(SessionTab tab, bool visible) => TickerMode(
      key: _keys.putIfAbsent(tab.id, () => GlobalKey()),
      enabled: !pause || visible,
      child: Listener(
        onPointerDown: (_) =>
            ref.read(workspaceFocusProvider.notifier).select(tab.id),
        child: SessionView(
          tab: tab,
          active: visible && activeId == tab.id,
          resizeEnabled: visible && !external.containsKey(tab.id),
        ),
      ),
    );
    Widget pane(SessionTab tab, bool visible) => DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: visible && hasSplit && activeId == tab.id
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(hasSplit && visible ? 1 : 0),
        child: session(tab, visible),
      ),
    );
    final home = TickerMode(
      key: _homeKey,
      enabled: !pause || tabs.isHome,
      child: widget.home,
    );
    final detachedPlaceholder = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.open_in_new, size: 40),
          const SizedBox(height: 12),
          Text(
            isRu
                ? 'Эта вкладка открыта в отдельном окне'
                : 'This tab is open in a separate window',
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: primary == null
                ? null
                : () => ref
                      .read(detachedWindowsProvider.notifier)
                      .show(primary.id),
            child: Text(isRu ? 'Показать окно' : 'Show window'),
          ),
          TextButton(
            onPressed: primary == null
                ? null
                : () => ref
                      .read(detachedWindowsProvider.notifier)
                      .returnToTabs(primary.id),
            child: Text(isRu ? 'Вернуть во вкладки' : 'Return to tabs'),
          ),
        ],
      ),
    );
    Widget dropZone(String label, IconData icon, Axis axis, bool reverse) =>
        Expanded(
          child: TabDropTarget(
            canAccept: (id) =>
                tabs.tabs.length - external.length > 1 &&
                !external.containsKey(id),
            onAccept: (id) =>
                splitSession(ref, id, axis: axis, reverse: reverse),
            builder: (context, hover) => Container(
              margin: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer
                    .withValues(alpha: hover ? 1 : .85),
                border: Border.all(
                  width: 3,
                  color: Theme.of(context).colorScheme.primary,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 36),
                    const SizedBox(height: 12),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    // Keep every pane at the same place in the render tree. Moving a GlobalKey
    // between hidden/split/home branches also reparents its semantics subtree.
    return LayoutBuilder(
      builder: (context, box) {
        final horizontal = layout.axis == Axis.horizontal;
        final extent = (horizontal ? box.maxWidth : box.maxHeight) - 8;
        final firstLength = extent > 0 ? extent * _ratio : 0.0;
        final full = Offset.zero & box.biggest;
        final firstRect = horizontal
            ? Rect.fromLTWH(0, 0, firstLength, box.maxHeight)
            : Rect.fromLTWH(0, 0, box.maxWidth, firstLength);
        final secondRect = horizontal
            ? Rect.fromLTWH(
                firstLength + 8,
                0,
                (extent - firstLength).clamp(0, double.infinity),
                box.maxHeight,
              )
            : Rect.fromLTWH(
                0,
                firstLength + 8,
                box.maxWidth,
                (extent - firstLength).clamp(0, double.infinity),
              );
        final firstId = layout.reverse ? secondary?.id : primary?.id;
        void resize(double delta) {
          if (extent > 0) {
            setState(() => _ratio = (_ratio + delta / extent).clamp(.2, .8));
          }
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              key: const ValueKey('workspace-home'),
              child: Offstage(offstage: !tabs.isHome, child: home),
            ),
            for (final tab in tabs.tabs)
              Positioned.fromRect(
                key: ValueKey('workspace-${tab.id}'),
                rect: !hasSplit
                    ? full
                    : tab.id == firstId
                    ? firstRect
                    : secondRect,
                child: Offstage(
                  offstage:
                      tabs.isHome ||
                      external.containsKey(tab.id) ||
                      (tab.id != primary?.id &&
                          (!hasSplit || tab.id != secondary.id)),
                  child: pane(
                    tab,
                    !tabs.isHome &&
                        !external.containsKey(tab.id) &&
                        (tab.id == primary?.id ||
                            hasSplit && tab.id == secondary.id),
                  ),
                ),
              ),
            if (!tabs.isHome && external.containsKey(primary?.id))
              Positioned.fill(child: detachedPlaceholder),
            if (hasSplit)
              Positioned(
                left: horizontal ? firstLength : 0,
                top: horizontal ? 0 : firstLength,
                width: horizontal ? 8 : box.maxWidth,
                height: horizontal ? box.maxHeight : 8,
                child: MouseRegion(
                  cursor: horizontal
                      ? SystemMouseCursors.resizeColumn
                      : SystemMouseCursors.resizeRow,
                  child: GestureDetector(
                    onHorizontalDragUpdate: horizontal
                        ? (d) => resize(d.delta.dx)
                        : null,
                    onVerticalDragUpdate: horizontal
                        ? null
                        : (d) => resize(d.delta.dy),
                    onDoubleTap: () => setState(() => _ratio = .5),
                    child: ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: Center(
                        child: Icon(
                          horizontal ? Icons.drag_indicator : Icons.drag_handle,
                          size: 10,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (dragging != null && tabs.tabs.length - external.length > 1)
              Positioned.fill(
                child: Column(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Row(
                        children: [
                          dropZone(
                            isRu ? 'Открыть слева' : 'Open on the left',
                            Icons.align_horizontal_left,
                            Axis.horizontal,
                            true,
                          ),
                          dropZone(
                            isRu ? 'Открыть справа' : 'Open on the right',
                            Icons.align_horizontal_right,
                            Axis.horizontal,
                            false,
                          ),
                        ],
                      ),
                    ),
                    dropZone(
                      isRu ? 'Открыть снизу' : 'Open below',
                      Icons.align_vertical_bottom,
                      Axis.vertical,
                      false,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
