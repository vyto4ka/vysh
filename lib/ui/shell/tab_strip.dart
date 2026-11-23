import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import '../motion/pressable_surface.dart';
import '../motion/smooth_scroll.dart';
import '../theme/app_theme.dart';
import '../widgets/strings_context.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/session_tab.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import '../widgets/context_menu.dart';
import '../widgets/app_icon.dart';
import 'ui_state.dart';
import 'window_buttons.dart';
import '../sftp/file_workspace.dart';
import '../../app/windows/detached_windows.dart';
import 'workspace_actions.dart';
import 'tab_drag.dart';
import '../../app/windows/window_scope.dart';

/// Полоса вкладок: закреплённая «главная» + вкладки сессий.
class TabStrip extends ConsumerStatefulWidget {
  const TabStrip({super.key});

  @override
  ConsumerState<TabStrip> createState() => _TabStripState();
}

class _TabStripState extends ConsumerState<TabStrip> {
  final _scroll = SmoothScrollController();
  final _tabKeys = <String, GlobalKey>{};
  final _seenIds = <String>{};
  bool _initializedSeen = false;
  String? _lastFocus;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(tabsProvider);
    final window = ref.watch(windowScopeProvider);
    final ctrl = ref.read(tabsProvider.notifier);
    final external = ref.watch(detachedWindowsProvider);
    final visibleTabs = state.tabs
        .where((tab) => !external.containsKey(tab.id))
        .toList();
    if (!_initializedSeen) {
      _initializedSeen = true;
      for (final t in visibleTabs) {
        _seenIds.add(t.id);
      }
    }
    _seenIds.removeWhere((id) => !visibleTabs.any((t) => t.id == id));

    final split = ref.watch(splitTabProvider);
    final focused = ref.watch(workspaceFocusProvider);
    final splitVisible =
        !state.isHome &&
        split != null &&
        split != state.activeTab?.id &&
        !external.containsKey(split) &&
        !external.containsKey(state.activeTab?.id);
    final focusId = splitVisible && focused == split
        ? split
        : state.activeTab?.id;
    _tabKeys.removeWhere((id, _) => !state.tabs.any((t) => t.id == id));
    if (_lastFocus != focusId) {
      _lastFocus = focusId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _tabKeys[focusId]?.currentContext;
        if (mounted && target != null) {
          Scrollable.ensureVisible(
            target,
            duration: AppMotion.duration(
              context,
              const Duration(milliseconds: 220),
            ),
            curve: AppMotion.emphasized,
            alignment: .5,
          );
        }
      });
    }
    final lang = ref.watch(settingsProvider.select((s) => s.language));
    final strings = AppStrings.of(context, lang);
    final scheme = Theme.of(context).colorScheme;

    final custom = ref.watch(customTitleBarProvider);

    final tabs = Padding(
      padding: EdgeInsets.zero,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HomeTab(
            selected: state.isHome,
            strings: strings,
            onTap: () => ctrl.activate(0),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: HorizontalWheelScroll(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: List.generate(visibleTabs.length, (i) {
                    final tab = visibleTabs[i];
                    final isNew = _seenIds.add(tab.id);
                    return TabDropTarget(
                      key: _tabKeys.putIfAbsent(tab.id, () => GlobalKey()),
                      canAccept: (id) => id != tab.id,
                      onAccept: (id) {
                        final current = ref.read(tabsProvider);
                        final from = current.tabs.indexWhere((t) => t.id == id);
                        final to = current.tabs.indexWhere(
                          (t) => t.id == tab.id,
                        );
                        if (from >= 0 && to >= 0) ctrl.move(from, to);
                      },
                      builder: (context, hover) => _TabEntrance(
                        animateIn: isNew,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ExpandSection(
                                expanded: hover,
                                axis: Axis.horizontal,
                                spring: AppMotion.spatialFast,
                                child: Container(
                                  width: 3,
                                  height: 22,
                                  margin: const EdgeInsets.only(right: 5),
                                  decoration: BoxDecoration(
                                    color: scheme.primary,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                              SessionTabDrag(
                                tab: tab,
                                enabled: !external.containsKey(tab.id),
                                child: _SessionTabChip(
                                  tab: tab,
                                  index: i + 1,
                                  selected:
                                      !state.isHome &&
                                      focusId == tab.id &&
                                      !external.containsKey(tab.id),
                                  beside:
                                      splitVisible &&
                                      (tab.id == split ||
                                          tab.id == state.activeTab?.id),
                                  placement:
                                      ref.watch(splitLayoutProvider).axis ==
                                          Axis.vertical
                                      ? (tab.id == split
                                            ? Icons.align_vertical_bottom
                                            : Icons.align_vertical_top)
                                      : ((tab.id == split) !=
                                                ref
                                                    .watch(splitLayoutProvider)
                                                    .reverse
                                            ? Icons.align_horizontal_right
                                            : Icons.align_horizontal_left),
                                  external: external.containsKey(tab.id),
                                  strings: strings,
                                  onTap: () {
                                    if (external.containsKey(tab.id)) {
                                      ref
                                          .read(
                                            detachedWindowsProvider.notifier,
                                          )
                                          .show(tab.id);
                                    } else {
                                      if (!(splitVisible &&
                                          (tab.id == split ||
                                              tab.id == state.activeTab?.id))) {
                                        ctrl.activate(
                                          state.tabs.indexOf(tab) + 1,
                                        );
                                      }
                                      ref
                                          .read(workspaceFocusProvider.notifier)
                                          .select(tab.id);
                                    }
                                  },
                                  onClose: () => ctrl.close(tab.id),
                                  onDuplicate: () => ctrl.duplicate(tab.id),
                                  onReconnect: () => ctrl.reconnect(tab.id),
                                  onSplit: () => splitSession(ref, tab.id),
                                  onSplitDown: () => splitSession(
                                    ref,
                                    tab.id,
                                    axis: Axis.vertical,
                                  ),
                                  onDetach: PlatformCapabilities.desktopWindow
                                      ? () =>
                                            detachSession(context, ref, tab.id)
                                      : null,
                                  onAttach: window != null
                                      ? () => window.returnToMain(tab.id)
                                      : external.containsKey(tab.id)
                                      ? () => ref
                                            .read(
                                              detachedWindowsProvider.notifier,
                                            )
                                            .returnToTabs(tab.id)
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
          ExpandSection(
            expanded: !state.isHome,
            axis: Axis.horizontal,
            spring: AppMotion.spatialFast,
            child: MenuIconButton(
              isSelected: splitVisible,
              tooltip: strings.isRu
                  ? 'Компоновка и действия сессии'
                  : 'Layout and session actions',
              icon: splitVisible
                  ? Icons.view_column
                  : Icons.space_dashboard_outlined,
              items: [
                menuItem(
                  strings.isRu
                      ? 'Открыть вкладку справа'
                      : 'Open a tab on the right',
                  icon: Icons.vertical_split_outlined,
                  onPressed:
                      state.tabs
                              .where((t) => !external.containsKey(t.id))
                              .length >
                          1
                      ? () => chooseSplit(context, ref, Axis.horizontal)
                      : null,
                ),
                menuItem(
                  strings.isRu ? 'Открыть вкладку снизу' : 'Open a tab below',
                  icon: Icons.horizontal_split_outlined,
                  onPressed:
                      state.tabs
                              .where((t) => !external.containsKey(t.id))
                              .length >
                          1
                      ? () => chooseSplit(context, ref, Axis.vertical)
                      : null,
                ),
                menuItem(
                  strings.isRu ? 'Убрать разделение' : 'Unsplit',
                  icon: Icons.crop_landscape,
                  onPressed: splitVisible
                      ? () => ref.read(splitTabProvider.notifier).select(null)
                      : null,
                ),
                if (PlatformCapabilities.desktopWindow)
                  menuItem(
                    strings.isRu
                        ? 'В отдельное окно'
                        : 'Move to separate window',
                    icon: Icons.open_in_new,
                    onPressed: focusId == null
                        ? null
                        : () => detachSession(context, ref, focusId),
                  ),
                menuDivider(),
                menuItem(
                  strings.reconnect,
                  icon: Icons.refresh,
                  shortcut: Keys.reconnect,
                  onPressed: focusId == null
                      ? null
                      : () => ctrl.reconnect(focusId),
                ),
                menuItem(
                  strings.duplicate,
                  icon: Icons.copy_all_outlined,
                  onPressed: focusId == null
                      ? null
                      : () => ctrl.duplicate(focusId),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: strings.isRu ? 'Файлы: две панели' : 'Files: two panes',
            icon: const Icon(Icons.folder_copy_outlined),
            onPressed: () => showFileWorkspace(context),
          ),
          IconButton(
            tooltip: DesktopEnv.isDesktop
                ? strings.newTabDesktopTooltip
                : strings.newTabTooltip,
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add),
            onPressed: () {
              ctrl.activate(0);
              ref.read(homeSectionProvider.notifier).select(0);
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => ref.read(hostSearchFocusProvider).requestFocus(),
              );
            },
          ),
        ],
      ),
    );

    // macOS со своим заголовком: нативный светофор рисуется слева поверх
    // полосы - вкладки отступают от него, свои кнопки окна не нужны.
    // С системным заголовком светофор в нём, полоса обычная.
    final trafficLights = custom && PlatformCapabilities.isMacOS;

    return TabDropTarget(
      canAccept: (_) => true,
      onAccept: (id) {
        final tabs = ref.read(tabsProvider);
        final index = tabs.tabs.indexWhere((tab) => tab.id == id);
        if (index >= 0) ctrl.activate(index + 1);
      },
      builder: (context, hover) => Container(
        height: DesktopEnv.isMobile ? 56 : 40,
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          border: Border(
            bottom: BorderSide(
              color: hover ? scheme.primary : scheme.outlineVariant,
            ),
          ),
        ),
        padding: EdgeInsets.only(
          left: trafficLights ? 0 : 6,
          right: custom && !trafficLights ? 0 : 6,
        ),
        child: Row(
          children: [
            Expanded(
              // Свой заголовок: пустое место вокруг вкладок таскает окно,
              // двойной клик - развернуть/восстановить.
              child: custom
                  ? Stack(
                      children: [
                        const Positioned.fill(
                          child: DragToMoveArea(child: SizedBox.expand()),
                        ),
                        Padding(
                          padding: EdgeInsets.only(
                            left: trafficLights ? 80 : 0,
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: _stripButtons(tabs),
                          ),
                        ),
                      ],
                    )
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: _stripButtons(tabs),
                    ),
            ),
            if (custom && !trafficLights) ...[
              const SizedBox(width: 6),
              const WindowButtons(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _stripButtons(Widget child) {
    if (DesktopEnv.isMobile) return child;
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(32),
          maximumSize: const Size.square(32),
          padding: EdgeInsets.zero,
          iconSize: 18,
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      child: child,
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({
    required this.selected,
    required this.strings,
    required this.onTap,
  });

  final bool selected;
  final AppStrings strings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: strings.homeTooltip,
      child: _TabSurface(
        selected: selected,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIcon(),
              if (MediaQuery.sizeOf(context).width >= 600)
                const SizedBox(width: 8),
              if (MediaQuery.sizeOf(context).width >= 600)
                Text(
                  'vysh',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurface,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionTabChip extends StatefulWidget {
  const _SessionTabChip({
    required this.tab,
    required this.index,
    required this.selected,
    required this.beside,
    required this.placement,
    required this.strings,
    required this.onTap,
    required this.onClose,
    required this.onDuplicate,
    required this.onReconnect,
    required this.onSplit,
    required this.onSplitDown,
    required this.onDetach,
    required this.onAttach,
    required this.external,
  });

  final SessionTab tab;
  final int index;
  final bool selected;
  final AppStrings strings;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onDuplicate;
  final VoidCallback onReconnect;
  final VoidCallback onSplit;
  final VoidCallback onSplitDown;
  final VoidCallback? onDetach;
  final VoidCallback? onAttach;
  final bool external;
  final bool beside;
  final IconData placement;

  @override
  State<_SessionTabChip> createState() => _SessionTabChipState();
}

class _SessionTabChipState extends State<_SessionTabChip> {
  bool _hover = false;

  final _menu = GlobalKey<ContextMenuAreaState>();

  void _showMenu(Offset position) {
    final s = widget.strings;
    _menu.currentState?.open(position, [
      menuItem(
        s.reconnect,
        icon: Icons.refresh,
        shortcut: Keys.reconnect,
        onPressed: widget.onReconnect,
      ),
      menuItem(
        s.duplicate,
        icon: Icons.copy_all_outlined,
        onPressed: widget.onDuplicate,
      ),
      if (!widget.external) ...[
        menuItem(
          s.isRu ? 'Открыть справа' : 'Open on the right',
          icon: Icons.vertical_split,
          onPressed: widget.onSplit,
        ),
        menuItem(
          s.isRu ? 'Открыть снизу' : 'Open below',
          icon: Icons.horizontal_split,
          onPressed: widget.onSplitDown,
        ),
        if (widget.onDetach != null)
          menuItem(
            s.isRu ? 'В отдельное окно' : 'Move to separate window',
            icon: Icons.open_in_new,
            onPressed: widget.onDetach,
          ),
      ],
      if (widget.onAttach != null)
        menuItem(
          s.isRu ? 'Вернуть во вкладки' : 'Return to tabs',
          icon: Icons.tab,
          onPressed: widget.onAttach,
        ),
      menuDivider(),
      menuItem(
        s.closeTab,
        icon: Icons.close,
        shortcut: Keys.closeTab,
        onPressed: widget.onClose,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = widget.selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        // Средняя кнопка мыши закрывает вкладку, как в браузерах.
        onPointerDown: (e) {
          if (e.buttons == kMiddleMouseButton) widget.onClose();
        },
        child: ContextMenuArea(
          key: _menu,
          child: GestureDetector(
            onSecondaryTapUp: (d) => _showMenu(d.globalPosition),
            child: _TabSurface(
              selected: widget.selected,
              onTap: widget.onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 120, maxWidth: 220),
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.external)
                        const Icon(Icons.open_in_new, size: 16)
                      else
                        _StatusDot(status: widget.tab.status),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          widget.tab.title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: fg, fontSize: 13),
                        ),
                      ),
                      ExpandSection(
                        expanded: widget.beside,
                        axis: Axis.horizontal,
                        spring: AppMotion.spatialFast,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Tooltip(
                            message: widget.strings.isRu
                                ? 'В рабочей области'
                                : 'Visible in workspace',
                            child: Icon(widget.placement, size: 14, color: fg),
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      AnimatedOpacity(
                        duration: AppMotion.duration(
                          context,
                          const Duration(milliseconds: 140),
                        ),
                        curve: Curves.easeOut,
                        opacity:
                            _hover || widget.selected || DesktopEnv.isMobile
                            ? 1
                            : 0,
                        child: IconButton(
                          tooltip: DesktopEnv.isDesktop
                              ? context.strings.closeWithShortcut
                              : context.strings.close,
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            minimumSize: Size.square(
                              DesktopEnv.isMobile ? 48 : 24,
                            ),
                            maximumSize: Size.square(
                              DesktopEnv.isMobile ? 48 : 24,
                            ),
                            tapTargetSize: DesktopEnv.isMobile
                                ? MaterialTapTargetSize.padded
                                : MaterialTapTargetSize.shrinkWrap,
                          ),
                          padding: EdgeInsets.zero,
                          icon: Icon(Icons.close_rounded, color: fg),
                          onPressed: widget.onClose,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabEntrance extends StatefulWidget {
  const _TabEntrance({required this.animateIn, required this.child});

  final bool animateIn;
  final Widget child;

  @override
  State<_TabEntrance> createState() => _TabEntranceState();
}

class _TabEntranceState extends State<_TabEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController.unbounded(
    vsync: this,
    value: widget.animateIn ? 0 : 1,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animateIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        AppMotion.springTo(
          _ctrl,
          1,
          spring: AppMotion.spatialFast,
          instant: AppMotion.reduced(context),
        );
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  final _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final keyed = KeyedSubtree(key: _childKey, child: widget.child);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        if (!_ctrl.isAnimating && _ctrl.value == 1) return child!;
        final width = math.max(0.0, _ctrl.value);
        final opacity = _ctrl.value.clamp(0.0, 1.0);
        return ClipRect(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: width,
            child: Opacity(opacity: opacity, child: child),
          ),
        );
      },
      child: keyed,
    );
  }
}

class _TabSurface extends StatelessWidget {
  const _TabSurface({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final h = DesktopEnv.isMobile ? 48.0 : 32.0;
    return SizedBox(
      height: h,
      child: Semantics(
        selected: selected,
        child: PressableSurface(
          selected: selected,
          borderRadius: BorderRadius.circular(h / 2),
          selectedBorderRadius: BorderRadius.circular(
            DesktopEnv.isMobile ? 16 : 11,
          ),
          color: Colors.transparent,
          selectedColor: scheme.secondaryContainer,
          pressScale: 0.03,
          onTap: onTap,
          child: Center(widthFactor: 1, child: child),
        ),
      ),
    );
  }
}

class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.status});

  final SessionStatus status;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  );
  late final AnimationController _pop = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(
    onStateChange: (_) => _syncPulse(),
  );
  ValueListenable<TickerModeData>? _ticking;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ticking?.removeListener(_syncPulse);
    _ticking = TickerMode.getValuesNotifier(context)..addListener(_syncPulse);
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _syncPulse();
      if ((widget.status == SessionStatus.ready ||
              widget.status == SessionStatus.lost) &&
          !AppMotion.reduced(context)) {
        _pop.value = 1.45;
        AppMotion.springTo(_pop, 1, spring: AppMotion.spatialFast);
      }
    }
  }

  void _syncPulse() {
    final shouldPulse =
        widget.status == SessionStatus.connecting &&
        AppMotion.allowInfiniteAnimations &&
        !AppMotion.reduced(context) &&
        AppMotion.onScreen(_ticking);
    if (shouldPulse) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      if (_pulse.isAnimating) _pulse.stop();
    }
  }

  @override
  void dispose() {
    _ticking?.removeListener(_syncPulse);
    _lifecycle.dispose();
    _pulse.dispose();
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, tip) = switch (widget.status) {
      SessionStatus.connecting => (
        scheme.tertiary,
        context.strings.statusConnecting,
      ),
      SessionStatus.ready => (
        AppSemanticColors.of(context).success,
        context.strings.statusConnected,
      ),
      SessionStatus.lost => (scheme.error, context.strings.statusLost),
      SessionStatus.closed => (
        scheme.outline,
        context.strings.statusClosedShort,
      ),
    };
    return Tooltip(
      message: tip,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulse, _pop]),
        builder: (context, child) {
          final pulseScale = _pulse.isAnimating
              ? 0.80 + 0.36 * Curves.easeInOutSine.transform(_pulse.value)
              : 1.0;
          final pulseAlpha = _pulse.isAnimating
              ? 0.55 + 0.45 * Curves.easeInOutSine.transform(_pulse.value)
              : 1.0;
          final scale = pulseScale * _pop.value.clamp(0.5, 1.8);
          return Transform.scale(
            scale: scale,
            child: Opacity(opacity: pulseAlpha, child: child),
          );
        },
        child: AnimatedContainer(
          duration: AppMotion.duration(
            context,
            const Duration(milliseconds: 220),
          ),
          curve: Curves.easeOut,
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
