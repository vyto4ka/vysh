import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Кнопки окна для своего заголовка: свернуть / развернуть / закрыть.
class WindowButtons extends StatefulWidget {
  const WindowButtons({super.key, this.height = 46});

  final double height;

  @override
  State<WindowButtons> createState() => _WindowButtonsState();
}

class _WindowButtonsState extends State<WindowButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);
  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          tooltip: 'Свернуть',
          icon: Icons.remove_rounded,
          height: widget.height,
          onTap: windowManager.minimize,
        ),
        _CaptionButton(
          tooltip: _maximized ? 'Восстановить' : 'Развернуть',
          icon: _maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
          iconSize: _maximized ? 14 : 16,
          height: widget.height,
          onTap: () => _maximized ? windowManager.unmaximize() : windowManager.maximize(),
        ),
        _CaptionButton(
          tooltip: 'Закрыть',
          icon: Icons.close_rounded,
          height: widget.height,
          danger: true,
          onTap: windowManager.close,
        ),
      ],
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    required this.height,
    this.iconSize = 18,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final double height;
  final double iconSize;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Крестик краснеет, как принято в Windows; остальные - мягкая подсветка M3.
    final bg = !_hover
        ? Colors.transparent
        : widget.danger
            ? const Color(0xFFC42B1C).withValues(alpha: _down ? 0.8 : 1)
            : scheme.onSurface.withValues(alpha: _down ? 0.12 : 0.08);
    final fg = _hover && widget.danger ? Colors.white : scheme.onSurfaceVariant;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 800),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _down = false;
        }),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 46,
            height: widget.height,
            color: bg,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: widget.iconSize, color: fg),
          ),
        ),
      ),
    );
  }
}
