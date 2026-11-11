import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/windows/detached_windows.dart';
import '../../domain/models/session_tab.dart';
import '../../infra/platform/capabilities.dart';
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
          resizeEnabled: !external.containsKey(tab.id),
        ),
      ),
    );
    Widget pane(SessionTab tab) => DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          width: 2,
          color: activeId == tab.id
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        children: [
          Material(
            color: activeId == tab.id
                ? Theme.of(context).colorScheme.secondaryContainer
                : Theme.of(context).colorScheme.surfaceContainer,
            child: SizedBox(
              height: 34,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  const Icon(Icons.terminal, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(tab.title, overflow: TextOverflow.ellipsis),
                  ),
                  if (PlatformCapabilities.desktopWindow)
                    IconButton(
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      tooltip: isRu
                          ? 'В отдельное окно'
                          : 'Move to separate window',
                      onPressed: () => detachSession(context, ref, tab.id),
                      icon: const Icon(Icons.open_in_new),
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: session(tab, true)),
        ],
      ),
    );
    final home = TickerMode(
      key: _homeKey,
      enabled: !pause || tabs.isHome,
      child: widget.home,
    );
    final hidden = <Widget>[
      if (!tabs.isHome) Offstage(child: home),
      for (final tab in tabs.tabs)
        if (tab.id != primary?.id || external.containsKey(tab.id))
          if (!hasSplit || tab.id != secondary.id)
            Offstage(child: session(tab, false)),
    ];
    Widget content;
    if (tabs.isHome) {
      content = home;
    } else if (external.containsKey(primary!.id)) {
      content = Center(
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
              onPressed: () =>
                  ref.read(detachedWindowsProvider.notifier).show(primary.id),
              child: Text(isRu ? 'Показать окно' : 'Show window'),
            ),
            TextButton(
              onPressed: () => ref
                  .read(detachedWindowsProvider.notifier)
                  .returnToTabs(primary.id),
              child: Text(isRu ? 'Вернуть во вкладки' : 'Return to tabs'),
            ),
          ],
        ),
      );
    } else {
      Widget terminals = pane(primary);
      if (hasSplit) {
        terminals = LayoutBuilder(
          builder: (context, box) {
            final horizontal = layout.axis == Axis.horizontal;
            final length = (horizontal ? box.maxWidth : box.maxHeight) - 10;
            final first = layout.reverse ? secondary : primary;
            final second = layout.reverse ? primary : secondary;
            void resize(double delta) => setState(
              () => _ratio = (_ratio + delta / length).clamp(.2, .8),
            );
            return Flex(
              direction: layout.axis,
              children: [
                SizedBox(
                  width: horizontal ? length * _ratio : null,
                  height: horizontal ? null : length * _ratio,
                  child: pane(first),
                ),
                MouseRegion(
                  cursor: horizontal
                      ? SystemMouseCursors.resizeColumn
                      : SystemMouseCursors.resizeRow,
                  child: GestureDetector(
                    onHorizontalDragUpdate: horizontal
                        ? (e) => resize(e.delta.dx)
                        : null,
                    onVerticalDragUpdate: horizontal
                        ? null
                        : (e) => resize(e.delta.dy),
                    onDoubleTap: () => setState(() => _ratio = .5),
                    child: Container(
                      width: horizontal ? 10 : null,
                      height: horizontal ? null : 10,
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: Center(
                        child: Icon(
                          horizontal ? Icons.drag_indicator : Icons.drag_handle,
                          size: 10,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(child: pane(second)),
              ],
            );
          },
        );
      }
      content = Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: SizedBox(
              height: 42,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Icon(hasSplit ? Icons.splitscreen : Icons.tab, size: 18),
                  const SizedBox(width: 8),
                  Text(
                    hasSplit
                        ? (isRu ? 'Две панели' : 'Two panes')
                        : (isRu ? 'Одна панель' : 'One pane'),
                  ),
                  const Spacer(),
                  PopupMenuButton<Axis>(
                    tooltip: isRu
                        ? 'Разделить рабочую область'
                        : 'Split workspace',
                    onSelected: (axis) => chooseSplit(context, ref, axis),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: Axis.horizontal,
                        child: Text(
                          isRu
                              ? 'Открыть вкладку справа'
                              : 'Open a tab on the right',
                        ),
                      ),
                      PopupMenuItem(
                        value: Axis.vertical,
                        child: Text(
                          isRu ? 'Открыть вкладку снизу' : 'Open a tab below',
                        ),
                      ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.vertical_split, size: 18),
                          const SizedBox(width: 6),
                          Text(isRu ? 'Разделить' : 'Split'),
                          const Icon(Icons.arrow_drop_down),
                        ],
                      ),
                    ),
                  ),
                  if (hasSplit)
                    TextButton.icon(
                      onPressed: () =>
                          ref.read(splitTabProvider.notifier).select(null),
                      icon: const Icon(Icons.tab, size: 18),
                      label: Text(isRu ? 'Объединить' : 'Unsplit'),
                    ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
          Expanded(child: terminals),
        ],
      );
    }
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
    return Stack(
      fit: StackFit.expand,
      children: [
        ...hidden,
        content,
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
  }
}
