import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_motion.dart';

class ExpressiveSegment<T> {
  const ExpressiveSegment({
    required this.value,
    required this.label,
    this.icon,
  });

  final T value;
  final String label;
  final IconData? icon;
}

/// Связанная группа кнопок-переключателей в стиле Material 3 Expressive:
/// внешние края скруглены пилюлей, внутренние швы тонкие (8dp), а выбранный
/// сегмент на пружине скругляет все углы и подсвечивается акцентом.
class ExpressiveSegments<T> extends StatelessWidget {
  const ExpressiveSegments({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.expand = false,
    this.height = 38,
  });

  final List<ExpressiveSegment<T>> segments;
  final T? selected;
  final ValueChanged<T> onChanged;

  /// `true` — сегменты делят всю доступную ширину поровну;
  /// `false` — занимают ширину по тексту (с переносом при нехватке места).
  final bool expand;
  final double height;

  static const double _gap = 2;
  static const double _innerCorner = 8;

  // Половина высоты, а не 999: иначе лерп радиуса почти весь ход стоит на месте.
  static double _pillCorner(double height) => height / 2;

  static BorderRadius _restRadius(int index, int count, double height) {
    final outer = Radius.circular(_pillCorner(height));
    const inner = Radius.circular(_innerCorner);
    return BorderRadius.horizontal(
      left: index == 0 ? outer : inner,
      right: index == count - 1 ? outer : inner,
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = Theme.of(context).visualDensity == VisualDensity.compact;
    final effectiveHeight = compact ? height - 4 : height;
    final pill = _pillCorner(effectiveHeight);

    if (expand) {
      return SizedBox(
        height: effectiveHeight,
        child: Row(
          children: [
            for (var i = 0; i < segments.length; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              Expanded(
                child: _SegmentButton<T>(
                  segment: segments[i],
                  selected: segments[i].value == selected,
                  restRadius: _restRadius(i, segments.length, effectiveHeight),
                  pillCorner: pill,
                  height: effectiveHeight,
                  expand: true,
                  onTap: () {
                    if (segments[i].value == selected) return;
                    HapticFeedback.selectionClick();
                    onChanged(segments[i].value);
                  },
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Wrap(
      spacing: _gap,
      runSpacing: 4,
      children: [
        for (var i = 0; i < segments.length; i++)
          _SegmentButton<T>(
            segment: segments[i],
            selected: segments[i].value == selected,
            restRadius: _restRadius(i, segments.length, effectiveHeight),
            pillCorner: pill,
            height: effectiveHeight,
            expand: false,
            onTap: () {
              if (segments[i].value == selected) return;
              HapticFeedback.selectionClick();
              onChanged(segments[i].value);
            },
          ),
      ],
    );
  }
}

class _SegmentButton<T> extends StatefulWidget {
  const _SegmentButton({
    required this.segment,
    required this.selected,
    required this.restRadius,
    required this.pillCorner,
    required this.height,
    required this.expand,
    required this.onTap,
  });

  final ExpressiveSegment<T> segment;
  final bool selected;
  final BorderRadius restRadius;
  final double pillCorner;
  final double height;
  final bool expand;
  final VoidCallback onTap;

  @override
  State<_SegmentButton<T>> createState() => _SegmentButtonState<T>();
}

class _SegmentButtonState<T> extends State<_SegmentButton<T>>
    with TickerProviderStateMixin {
  late final AnimationController _shape = AnimationController.unbounded(
    vsync: this,
    value: widget.selected ? 1 : 0,
  );
  late final AnimationController _tint = AnimationController.unbounded(
    vsync: this,
    value: widget.selected ? 1 : 0,
  );
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  );
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    _pressed = pressed;
    AppMotion.springTo(
      _press,
      pressed ? 1 : 0,
      spring: pressed ? AppMotion.effectsFast : AppMotion.spatialFast,
      instant: AppMotion.reduced(context),
    );
  }

  @override
  void didUpdateWidget(covariant _SegmentButton<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected == widget.selected) return;
    final target = widget.selected ? 1.0 : 0.0;
    final instant = AppMotion.reduced(context);
    AppMotion.springTo(
      _shape,
      target,
      spring: AppMotion.spatialDefault,
      instant: instant,
    );
    AppMotion.springTo(
      _tint,
      target,
      spring: AppMotion.effectsDefault,
      instant: instant,
    );
  }

  @override
  void dispose() {
    _shape.dispose();
    _tint.dispose();
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final baseStyle =
        Theme.of(context).textTheme.labelLarge ?? const TextStyle(fontSize: 13);
    final restStyle = baseStyle.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
    );
    final selectedStyle = baseStyle.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: scheme.onSecondaryContainer,
    );
    final selectedRadius = BorderRadius.circular(widget.pillCorner);

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.mouse &&
            e.buttons != kPrimaryMouseButton) {
          return;
        }
        _setPressed(true);
      },
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: MergeSemantics(
        child: Semantics(
          button: true,
          selected: widget.selected,
          child: AnimatedBuilder(
            animation: Listenable.merge([_shape, _tint, _press]),
            builder: (context, _) {
              final shapeT = _shape.value.clamp(0.0, 1.0);
              final tintT = _tint.value.clamp(0.0, 1.0);
              final pressT = _press.value.clamp(0.0, 1.0);

              final rest = BorderRadius.lerp(
                widget.restRadius,
                selectedRadius,
                shapeT,
              )!;
              final radius = pressT > 0
                  ? BorderRadius.lerp(
                      rest,
                      AppShape.pressedRadius(rest),
                      pressT,
                    )!
                  : rest;
              final border = RoundedRectangleBorder(borderRadius: radius);
              final bg = Color.lerp(
                scheme.surfaceContainerHighest.withValues(alpha: 0.72),
                scheme.secondaryContainer,
                tintT,
              )!;
              final iconColor = Color.lerp(
                scheme.onSurfaceVariant,
                scheme.onSecondaryContainer,
                tintT,
              )!;

              Widget label = Text(
                widget.segment.label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle.lerp(restStyle, selectedStyle, tintT),
              );
              if (widget.expand) {
                label = Flexible(
                  child: FittedBox(fit: BoxFit.scaleDown, child: label),
                );
              }

              final content = Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.expand ? 10 : 14,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (widget.segment.icon != null) ...[
                      Icon(widget.segment.icon, size: 17, color: iconColor),
                      const SizedBox(width: 6),
                    ],
                    label,
                  ],
                ),
              );

              Widget tile = SizedBox(
                height: widget.height,
                child: Material(
                  color: bg,
                  shape: border,
                  clipBehavior: Clip.antiAlias,
                  animationDuration: Duration.zero,
                  child: InkWell(
                    onTap: widget.onTap,
                    customBorder: border,
                    child: Center(
                      widthFactor: widget.expand ? null : 1,
                      child: content,
                    ),
                  ),
                ),
              );

              return Transform.scale(scale: 1 - 0.035 * pressT, child: tile);
            },
          ),
        ),
      ),
    );
  }
}
