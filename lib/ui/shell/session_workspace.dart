import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../domain/models/session_tab.dart';
import '../../l10n/app_strings.dart';
import '../terminal/session_view.dart';
import 'ui_state.dart';

/// Stable global keys preserve terminal selection, scroll and file-pane state when reparenting.
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
  String? _focused;
  @override
  Widget build(BuildContext context) {
    final tabs = ref.watch(tabsProvider);
    final split = ref.watch(splitTabProvider);
    final pause = ref.watch(settingsProvider.select((s) => s.pauseHiddenTabs));
    final ru = AppStrings.of(context, ref.read(settingsProvider).language).isRu;
    _keys.removeWhere((id, _) => !tabs.tabs.any((t) => t.id == id));
    final secondary = tabs.tabs.where((t) => t.id == split).firstOrNull;
    final primary = tabs.activeTab;
    final hasSplit =
        secondary != null && primary?.id != split && primary != null;
    Widget session(SessionTab tab, bool visible) => TickerMode(
      key: _keys.putIfAbsent(tab.id, () => GlobalKey()),
      enabled: !pause || visible,
      child: Listener(
        onPointerDown: (_) => setState(() => _focused = tab.id),
        child: SessionView(
          tab: tab,
          active: visible && (!hasSplit || (_focused ?? primary.id) == tab.id),
        ),
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
        if (tab.id != primary?.id && (!hasSplit || tab.id != split))
          Offstage(child: session(tab, false)),
    ];
    Widget content = tabs.isHome ? home : session(primary!, true);
    if (hasSplit) {
      content = LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            SizedBox(
              width: (constraints.maxWidth - 8) * _ratio,
              child: session(primary, true),
            ),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                onHorizontalDragUpdate: (e) => setState(
                  () => _ratio = (_ratio + e.delta.dx / constraints.maxWidth)
                      .clamp(.2, .8),
                ),
                child: Container(
                  width: 8,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  SizedBox(
                    height: 32,
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            secondary.title,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          tooltip: ru ? 'Вернуть во вкладки' : 'Return to tabs',
                          iconSize: 18,
                          onPressed: () =>
                              ref.read(splitTabProvider.notifier).select(null),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: session(secondary, true)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) =>
          tabs.tabs.length > 1 && tabs.tabs.any((t) => t.id == d.data),
      onAcceptWithDetails: (d) {
        final other = tabs.tabs.where((t) => t.id != d.data).firstOrNull;
        if ((primary == null || primary.id == d.data) && other != null) {
          ref
              .read(tabsProvider.notifier)
              .activate(tabs.tabs.indexOf(other) + 1);
        }
        ref.read(splitTabProvider.notifier).select(d.data);
      },
      builder: (context, candidates, _) => Stack(
        fit: StackFit.expand,
        children: [
          ...hidden,
          content,
          if (candidates.isNotEmpty)
            IgnorePointer(
              child: Align(
                alignment: Alignment.centerRight,
                child: FractionallySizedBox(
                  widthFactor: .5,
                  heightFactor: 1,
                  child: ColoredBox(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: .15),
                    child: Center(
                      child: Text(ru ? 'Открыть рядом' : 'Open beside'),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
