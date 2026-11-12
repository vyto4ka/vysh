import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../infra/platform/capabilities.dart';

import 'strings_context.dart';

/// Пункт меню Material 3 (MenuItemButton): иконка слева, сочетание клавиш справа.
Widget menuItem(
  String label, {
  IconData? icon,
  SingleActivator? shortcut,
  VoidCallback? onPressed,
  Color? color,
}) {
  return MenuItemButton(
    leadingIcon: icon == null ? null : Icon(icon, size: 20, color: color),
    // Подписи клавиш - приглушённые, как в спецификации M3.
    shortcut: shortcut,
    onPressed: onPressed,
    style: color == null
        ? null
        : ButtonStyle(foregroundColor: WidgetStatePropertyAll(color)),
    child: Text(label),
  );
}

/// Разделитель между группами пунктов.
Widget menuDivider() => const Padding(
  padding: EdgeInsets.symmetric(vertical: 4),
  child: Divider(height: 1, indent: 8, endIndent: 8),
);

/// Область, в которой можно открыть контекстное меню M3 в точке клика.
///
/// ```dart
/// final menu = GlobalKey<ContextMenuAreaState>();
/// ContextMenuArea(key: menu, child: ...);
/// menu.currentState?.open(details.globalPosition, [menuItem(...), ...]);
/// ```
class ContextMenuArea extends StatefulWidget {
  const ContextMenuArea({super.key, required this.child, this.onClose});

  final Widget child;
  final VoidCallback? onClose;

  /// Ближайшая область меню выше по дереву.
  static ContextMenuAreaState? of(BuildContext context) =>
      context.findAncestorStateOfType<ContextMenuAreaState>();

  @override
  State<ContextMenuArea> createState() => ContextMenuAreaState();
}

class ContextMenuAreaState extends State<ContextMenuArea> {
  final _controller = MenuController();
  List<Widget> _items = const [];

  bool get isOpen => _controller.isOpen;

  void open(Offset globalPosition, List<Widget> items) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || items.isEmpty) return;
    final local = box.globalToLocal(globalPosition);
    if (_controller.isOpen) _controller.close();
    setState(() => _items = items);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.open(position: local);
    });
  }

  void close() => _controller.close();

  @override
  Widget build(BuildContext context) {
    // Терминал/список не входит в TapRegion якоря: иначе Flutter считает
    // клик по нему кликом внутри открытого меню.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          child: _DismissibleMenuAnchor(
            controller: _controller,
            menuChildren: _items,
            onClose: widget.onClose,
            consumeOutsideTap: true,
            child: const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// Кнопка «⋮», открывающая меню M3.
class MenuIconButton extends StatelessWidget {
  const MenuIconButton({
    super.key,
    required this.items,
    this.icon = Icons.more_vert,
    this.tooltip,
    this.enabled = true,
    this.isSelected = false,
  });

  final List<Widget> items;
  final IconData icon;

  /// null - «Ещё» на языке интерфейса.
  final String? tooltip;
  final bool enabled;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    return _DismissibleMenuAnchor(
      menuChildren: items,
      builder: (context, controller, _) => IconButton(
        isSelected: isSelected || controller.isOpen,
        style: isSelected || controller.isOpen
            ? IconButton.styleFrom(
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.secondaryContainer,
                foregroundColor: Theme.of(
                  context,
                ).colorScheme.onSecondaryContainer,
              )
            : null,
        tooltip: tooltip ?? context.strings.more,
        icon: Icon(icon),
        onPressed: !enabled
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// MenuAnchor закрывается по клику внутри приложения. За его границами
/// указатель уже не приходит во Flutter, поэтому учитываем фокус окна.
class _DismissibleMenuAnchor extends StatefulWidget {
  const _DismissibleMenuAnchor({
    required this.menuChildren,
    this.controller,
    this.onClose,
    this.builder,
    this.child,
    this.consumeOutsideTap = false,
  });

  final List<Widget> menuChildren;
  final MenuController? controller;
  final VoidCallback? onClose;
  final MenuAnchorChildBuilder? builder;
  final Widget? child;
  final bool consumeOutsideTap;

  @override
  State<_DismissibleMenuAnchor> createState() => _DismissibleMenuAnchorState();
}

class _DismissibleMenuAnchorState extends State<_DismissibleMenuAnchor>
    with WidgetsBindingObserver, WindowListener {
  final _fallbackController = MenuController();
  bool _observing = false;

  MenuController get _controller => widget.controller ?? _fallbackController;

  void _onOpen() {
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    if (PlatformCapabilities.desktopWindow) windowManager.addListener(this);
    setState(() {});
  }

  void _stopObserving() {
    if (!_observing) return;
    _observing = false;
    WidgetsBinding.instance.removeObserver(this);
    if (PlatformCapabilities.desktopWindow) windowManager.removeListener(this);
  }

  void _onClose() {
    _stopObserving();
    if (mounted) setState(() {});
    widget.onClose?.call();
  }

  @override
  void onWindowBlur() => _controller.close();

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId == View.of(context).viewId &&
        event.state == ViewFocusState.unfocused) {
      _controller.close();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller.close();
  }

  @override
  void dispose() {
    _stopObserving();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: _controller,
    menuChildren: widget.menuChildren,
    onOpen: _onOpen,
    onClose: _onClose,
    builder: widget.builder,
    consumeOutsideTap: widget.consumeOutsideTap,
    child: widget.child,
  );
}

/// Сочетания клавиш для подписей в меню.
class Keys {
  Keys._();
  static const copy = SingleActivator(
    LogicalKeyboardKey.keyC,
    control: true,
    shift: true,
  );
  static const paste = SingleActivator(
    LogicalKeyboardKey.keyV,
    control: true,
    shift: true,
  );
  static const files = SingleActivator(
    LogicalKeyboardKey.keyE,
    control: true,
    shift: true,
  );
  static const reconnect = SingleActivator(
    LogicalKeyboardKey.keyR,
    control: true,
    shift: true,
  );
  static const closeTab = SingleActivator(
    LogicalKeyboardKey.keyW,
    control: true,
    shift: true,
  );
  static const newHost = SingleActivator(
    LogicalKeyboardKey.keyN,
    control: true,
    shift: true,
  );
  static const delete = SingleActivator(LogicalKeyboardKey.delete);
  static const rename = SingleActivator(LogicalKeyboardKey.f2);
  static const refresh = SingleActivator(LogicalKeyboardKey.f5);

  // macOS: те же действия через ⌘ - для подписей в меню.
  static const macCopy = SingleActivator(LogicalKeyboardKey.keyC, meta: true);
  static const macPaste = SingleActivator(LogicalKeyboardKey.keyV, meta: true);
  static const macFiles = SingleActivator(LogicalKeyboardKey.keyE, meta: true);
  static const macReconnect = SingleActivator(
    LogicalKeyboardKey.keyR,
    meta: true,
  );
}
