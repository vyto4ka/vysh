import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../infra/platform/capabilities.dart';
import '../../l10n/app_strings.dart';
import '../widgets/strings_context.dart';

/// Кнопки окна для своего заголовка: свернуть / развернуть / закрыть.
/// На macOS окно управляется нативным светофором - своих кнопок не рисуем.
class WindowButtons extends StatefulWidget {
  const WindowButtons({super.key, this.height = 40});

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
    // macOS: светофор рисует система слева, свои кнопки только продублировали бы его.
    if (PlatformCapabilities.isMacOS) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          tooltip: context.strings.minimize,
          icon: Icons.remove_rounded,
          height: widget.height,
          onTap: windowManager.minimize,
        ),
        _CaptionButton(
          tooltip: _maximized
              ? context.strings.restore
              : context.strings.maximize,
          icon: _maximized
              ? Icons.filter_none_rounded
              : Icons.crop_square_rounded,
          height: widget.height,
          onTap: () => _maximized
              ? windowManager.unmaximize()
              : windowManager.maximize(),
        ),
        _CaptionButton(
          tooltip: context.strings.close,
          icon: Icons.close_rounded,
          height: widget.height,
          danger: true,
          onTap: windowManager.close,
        ),
      ],
    );
  }
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    required this.height,
    this.danger = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final double height;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 36,
      height: height,
      child: Center(
        child: IconButton(
          tooltip: tooltip,
          onPressed: onTap,
          style:
              IconButton.styleFrom(
                minimumSize: const Size.square(32),
                maximumSize: const Size.square(32),
                padding: EdgeInsets.zero,
                iconSize: 16,
                visualDensity: VisualDensity.standard,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: scheme.onSurfaceVariant,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ).copyWith(
                foregroundColor: danger
                    ? WidgetStateProperty.resolveWith(
                        (states) =>
                            states.any(
                              (state) =>
                                  state == WidgetState.hovered ||
                                  state == WidgetState.focused ||
                                  state == WidgetState.pressed,
                            )
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      )
                    : null,
                overlayColor: danger
                    ? WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.pressed) ||
                            states.contains(WidgetState.focused)) {
                          return scheme.error.withValues(alpha: .12);
                        }
                        return states.contains(WidgetState.hovered)
                            ? scheme.error.withValues(alpha: .08)
                            : Colors.transparent;
                      })
                    : null,
              ),
          icon: Icon(icon),
        ),
      ),
    );
  }
}
