import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    style: color == null ? null : ButtonStyle(foregroundColor: WidgetStatePropertyAll(color)),
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
    return MenuAnchor(
      controller: _controller,
      menuChildren: _items,
      onClose: widget.onClose,
      child: widget.child,
    );
  }
}

/// Кнопка «⋮», открывающая меню M3.
class MenuIconButton extends StatelessWidget {
  const MenuIconButton({
    super.key,
    required this.items,
    this.icon = Icons.more_vert,
    this.tooltip = 'Ещё',
    this.enabled = true,
  });

  final List<Widget> items;
  final IconData icon;
  final String tooltip;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: items,
      builder: (context, controller, _) => IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: !enabled
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Сочетания клавиш для подписей в меню.
class Keys {
  Keys._();
  static const copy = SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true);
  static const paste = SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true);
  static const files = SingleActivator(LogicalKeyboardKey.keyE, control: true, shift: true);
  static const reconnect = SingleActivator(LogicalKeyboardKey.keyR, control: true, shift: true);
  static const closeTab = SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true);
  static const newHost = SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true);
  static const delete = SingleActivator(LogicalKeyboardKey.delete);
  static const rename = SingleActivator(LogicalKeyboardKey.f2);
  static const refresh = SingleActivator(LogicalKeyboardKey.f5);
}
