import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/windows/detached_windows.dart';
import '../../domain/models/session_tab.dart';
import '../../l10n/app_strings.dart';
import '../motion/app_motion.dart';
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

class _SessionWorkspaceState extends ConsumerState<SessionWorkspace>
    with TickerProviderStateMixin {
  final _keys = <String, GlobalKey>{};
  final _homeKey = GlobalKey();
  double _ratio = .5;
  double _ratioFrom = .5;
  double _ratioTo = .5;
  bool _splitterHovered = false;
  String? _lastVisibleSignature;

  late final AnimationController _switchCtrl = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  late final AnimationController _ratioCtrl = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  late final AnimationController _dropOverlayCtrl =
      AnimationController.unbounded(vsync: this, value: 0);
  bool _showDropOverlay = false;

  @override
  void dispose() {
    _switchCtrl.dispose();
    _ratioCtrl.dispose();
    _dropOverlayCtrl.dispose();
    super.dispose();
  }

  void _animateRatioTo(double target) {
    if (AppMotion.reduced(context)) {
      setState(() => _ratio = target);
      return;
    }
    _ratioFrom = _currentRatio;
    _ratioTo = target;
    _ratioCtrl.value = 0;
    AppMotion.springTo(_ratioCtrl, 1, spring: AppMotion.spatialDefault)
        .whenComplete(() {
          if (mounted) setState(() => _ratio = target);
        });
  }

  double get _currentRatio => _ratioCtrl.isAnimating
      ? (_ratioFrom + (_ratioTo - _ratioFrom) * _ratioCtrl.value).clamp(
          0.18,
          0.82,
        )
      : _ratio;

  void _syncDropOverlay(bool wanted) {
    if (wanted == _showDropOverlay && !_dropOverlayCtrl.isAnimating) return;
    if (AppMotion.reduced(context)) {
      _showDropOverlay = wanted;
      _dropOverlayCtrl.value = wanted ? 1 : 0;
      return;
    }
    if (wanted) {
      _showDropOverlay = true;
    }
    AppMotion.springTo(
      _dropOverlayCtrl,
      wanted ? 1 : 0,
      spring: AppMotion.spatialFast,
    ).whenComplete(() {
      if (mounted && !wanted && !_dropOverlayCtrl.isAnimating) {
        setState(() => _showDropOverlay = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ref.watch(tabsProvider);
    final external = ref.watch(detachedWindowsProvider);
    final split = ref.watch(splitTabProvider);
    final layout = ref.watch(splitLayoutProvider);
    final dragging = ref.watch(draggedTabProvider);
    final incomingDrag = ref.watch(incomingTabDragProvider);
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

    final signature = tabs.isHome
        ? 'home'
        : hasSplit
        ? 'split:${primary.id}:${secondary.id}'
        : 'tab:${primary?.id ?? ''}';
    if (_lastVisibleSignature != null && _lastVisibleSignature != signature) {
      if (!AppMotion.reduced(context)) {
        _switchCtrl.value = 0;
        AppMotion.springTo(_switchCtrl, 1, spring: AppMotion.spatialFast);
      }
    }
    _lastVisibleSignature = signature;

    final visibleCount = tabs.tabs.length - external.length;
    final dropZonesActive =
        (dragging != null && visibleCount > 1) ||
        (incomingDrag && visibleCount > 0);
    _syncDropOverlay(dropZonesActive);

    Widget session(SessionTab tab, bool visible) => TickerMode(
      key: _keys.putIfAbsent(tab.id, () => GlobalKey()),
      enabled: !pause || visible,
      child: Listener(
        onPointerDown: (_) =>
            ref.read(workspaceFocusProvider.notifier).select(tab.id),
        child: SessionView(
          tab: tab,
          active: visible && activeId == tab.id,
          resizeEnabled:
              visible &&
              !external.containsKey(tab.id) &&
              !_ratioCtrl.isAnimating,
        ),
      ),
    );

    Widget pane(SessionTab tab, bool visible) => AnimatedContainer(
      duration: AppMotion.duration(context, AppMotion.durationFast),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        border: Border.all(
          color: visible && hasSplit && activeId == tab.id
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
        ),
      ),
      padding: EdgeInsets.all(hasSplit && visible ? 1 : 0),
      child: session(tab, visible),
    );

    Widget withEntrance(Widget child, bool visible) {
      if (!visible) return child;
      return AnimatedBuilder(
        animation: _switchCtrl,
        builder: (context, inner) {
          if (!_switchCtrl.isAnimating && _switchCtrl.value == 1) return inner!;
          final t = _switchCtrl.value.clamp(0.0, 1.0);
          final opacity = (0.35 + 0.65 * t).clamp(0.0, 1.0);
          final dy = 8.0 * (1 - _switchCtrl.value);
          return Opacity(
            opacity: opacity,
            child: Transform.translate(offset: Offset(0, dy), child: inner),
          );
        },
        child: child,
      );
    }

    final home = TickerMode(
      key: _homeKey,
      enabled: !pause || tabs.isHome,
      child: withEntrance(widget.home, tabs.isHome),
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
                (incomingDrag && visibleCount > 0) ||
                (visibleCount > 1 && !external.containsKey(id)),
            onAccept: (id) =>
                splitSession(ref, id, axis: axis, reverse: reverse),
            builder: (context, hover) {
              final scheme = Theme.of(context).colorScheme;
              return AnimatedScale(
                scale: hover ? 1.015 : 0.985,
                duration: AppMotion.duration(context, AppMotion.durationFast),
                curve: AppMotion.fastSpringCurve,
                child: AnimatedContainer(
                  duration: AppMotion.duration(context, AppMotion.durationFast),
                  curve: AppMotion.fastSpringCurve,
                  margin: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(
                      alpha: hover ? 0.96 : 0.82,
                    ),
                    border: Border.all(
                      width: hover ? 3.5 : 2.5,
                      color: hover ? scheme.primary : scheme.primary.withValues(alpha: 0.75),
                    ),
                    borderRadius: BorderRadius.circular(hover ? 22 : 16),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 36, color: scheme.onPrimaryContainer),
                        const SizedBox(height: 12),
                        Text(
                          label,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: scheme.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );

    // Keep every pane at the same place in the render tree. Moving a GlobalKey
    // between hidden/split/home branches also reparents its semantics subtree.
    return AnimatedBuilder(
      animation: Listenable.merge([_ratioCtrl, _dropOverlayCtrl]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final horizontal = layout.axis == Axis.horizontal;
          final extent = (horizontal ? box.maxWidth : box.maxHeight) - 8;
          final ratio = _currentRatio;
          final firstLength = extent > 0 ? extent * ratio : 0.0;
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
              _ratioCtrl.stop();
              setState(
                () => _ratio = (_currentRatio + delta / extent).clamp(.2, .8),
              );
            }
          }

          final scheme = Theme.of(context).colorScheme;
          final overlayT = _dropOverlayCtrl.value.clamp(0.0, 1.0);

          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                key: const ValueKey('workspace-home'),
                child: Offstage(offstage: !tabs.isHome, child: home),
              ),
              for (final tab in tabs.tabs)
                Builder(
                  key: ValueKey('workspace-${tab.id}'),
                  builder: (context) {
                    final isVisible =
                        !tabs.isHome &&
                        !external.containsKey(tab.id) &&
                        (tab.id == primary?.id ||
                            hasSplit && tab.id == secondary.id);
                    return Positioned.fromRect(
                      rect: !hasSplit
                          ? full
                          : tab.id == firstId
                          ? firstRect
                          : secondRect,
                      child: Offstage(
                        offstage: !isVisible,
                        child: withEntrance(pane(tab, isVisible), isVisible),
                      ),
                    );
                  },
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
                    onEnter: (_) => setState(() => _splitterHovered = true),
                    onExit: (_) => setState(() => _splitterHovered = false),
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
                      onDoubleTap: () => _animateRatioTo(.5),
                      child: AnimatedContainer(
                        duration: AppMotion.duration(
                          context,
                          AppMotion.durationFast,
                        ),
                        color: _splitterHovered
                            ? scheme.primary.withValues(alpha: 0.22)
                            : scheme.surfaceContainer,
                        child: Center(
                          child: Icon(
                            horizontal
                                ? Icons.drag_indicator
                                : Icons.drag_handle,
                            size: 10,
                            color: _splitterHovered
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_showDropOverlay || dropZonesActive)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !dropZonesActive,
                    child: Opacity(
                      opacity: overlayT,
                      child: Transform.scale(
                        scale: 0.96 + 0.04 * overlayT,
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
                                    isRu
                                        ? 'Открыть справа'
                                        : 'Open on the right',
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
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
