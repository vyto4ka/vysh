import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../domain/models/session_tab.dart';
import '../../domain/services/tabs_controller.dart';
import '../widgets/context_menu.dart';
import 'ui_state.dart';
import 'window_buttons.dart';

/// Полоса вкладок: закреплённая «главная» + вкладки сессий.
class TabStrip extends ConsumerWidget {
  const TabStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(tabsProvider);
    final ctrl = ref.read(tabsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    final custom = ref.watch(customTitleBarProvider);

    final tabs = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HomeTab(selected: state.isHome, onTap: () => ctrl.activate(0)),
          const SizedBox(width: 4),
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              itemCount: state.tabs.length,
              onReorderItem: ctrl.move,
              proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
              itemBuilder: (context, i) {
                final tab = state.tabs[i];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(tab.id),
                  index: i,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _SessionTabChip(
                      tab: tab,
                      index: i + 1,
                      selected: state.active == i + 1,
                      onTap: () => ctrl.activate(i + 1),
                      onClose: () => ctrl.close(tab.id),
                      onDuplicate: () => ctrl.duplicate(tab.id),
                      onReconnect: () => ctrl.reconnect(tab.id),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: 'Новая вкладка (Ctrl+Shift+T)',
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

    return Container(
      height: 46,
      color: scheme.surfaceContainer,
      padding: EdgeInsets.only(left: 6, right: custom ? 0 : 6),
      child: Row(
        children: [
          Expanded(
            // Свой заголовок: пустое место справа от вкладок таскает окно,
            // двойной клик - развернуть/восстановить.
            child: custom
                ? Stack(
                    children: [
                      const Positioned.fill(child: DragToMoveArea(child: SizedBox.expand())),
                      Align(alignment: Alignment.centerLeft, child: tabs),
                    ],
                  )
                : Align(alignment: Alignment.centerLeft, child: tabs),
          ),
          if (custom) ...[
            const SizedBox(width: 6),
            const WindowButtons(),
          ],
        ],
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Главная (Alt+1)',
      child: _TabSurface(
        selected: selected,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Декодируем сразу в нужном размере, а не все 256×256.
              Image.asset(
                'assets/icon/vysh_256.png',
                width: 18,
                height: 18,
                cacheWidth: (18 * MediaQuery.devicePixelRatioOf(context)).ceil(),
                filterQuality: FilterQuality.medium,
              ),
              const SizedBox(width: 8),
              Text('vysh',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: selected ? scheme.onSecondaryContainer : scheme.onSurface,
                  )),
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
    required this.onTap,
    required this.onClose,
    required this.onDuplicate,
    required this.onReconnect,
  });

  final SessionTab tab;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback onDuplicate;
  final VoidCallback onReconnect;

  @override
  State<_SessionTabChip> createState() => _SessionTabChipState();
}

class _SessionTabChipState extends State<_SessionTabChip> {
  bool _hover = false;

  final _menu = GlobalKey<ContextMenuAreaState>();

  void _showMenu(Offset position) {
    _menu.currentState?.open(position, [
      menuItem('Переподключить',
          icon: Icons.refresh, shortcut: Keys.reconnect, onPressed: widget.onReconnect),
      menuItem('Дублировать', icon: Icons.copy_all_outlined, onPressed: widget.onDuplicate),
      menuDivider(),
      menuItem('Закрыть вкладку',
          icon: Icons.close, shortcut: Keys.closeTab, onPressed: widget.onClose),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = widget.selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

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
                    _StatusDot(status: widget.tab.status),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.tab.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg, fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 2),
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 120),
                      opacity: _hover || widget.selected ? 1 : 0,
                      child: IconButton(
                        tooltip: 'Закрыть (Ctrl+Shift+W)',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
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

class _TabSurface extends StatelessWidget {
  const _TabSurface({required this.selected, required this.onTap, required this.child});

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      height: 34,
      decoration: BoxDecoration(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Center(widthFactor: 1, child: child),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final SessionStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, tip) = switch (status) {
      SessionStatus.connecting => (scheme.tertiary, 'Подключение…'),
      SessionStatus.ready => (Colors.green.shade500, 'Подключено'),
      SessionStatus.lost => (scheme.error, 'Соединение потеряно'),
      SessionStatus.closed => (scheme.outline, 'Закрыто'),
    };
    return Tooltip(
      message: tip,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
