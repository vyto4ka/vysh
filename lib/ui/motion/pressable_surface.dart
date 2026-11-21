import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'app_motion.dart';

/// Интерактивная поверхность с пружинным тактильным откликом на нажатие
/// (масштаб + морфинг углов) и плавным переходом состояния выбора.
///
/// Отслеживает касание через [Listener], не конкурируя с жестами прокрутки,
/// двойного клика и перетаскивания.
class PressableSurface extends StatefulWidget {
  const PressableSurface({
    super.key,
    this.leading,
    required this.child,
    required this.borderRadius,
    this.selectedBorderRadius,
    this.selected = false,
    this.color = Colors.transparent,
    this.selectedColor,
    this.side = BorderSide.none,
    this.selectedSide,
    this.pressScale = 0.022,
    this.morphOnPress = true,
    this.enabled = true,
    this.onTap,
    this.onDoubleTap,
    this.onLongPress,
    this.onLongPressStart,
    this.onSecondaryTapUp,
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
    this.splashColor,
    this.highlightColor,
    this.clipBehavior = Clip.antiAlias,
  });

  /// Элемент слева от основной области нажатия (например, `Checkbox`),
  /// которому не должен мешать `DoubleTapGestureRecognizer` строки.
  final Widget? leading;
  final Widget child;
  final BorderRadius borderRadius;
  final BorderRadius? selectedBorderRadius;
  final bool selected;
  final Color color;
  final Color? selectedColor;
  final BorderSide side;
  final BorderSide? selectedSide;
  final double pressScale;
  final bool morphOnPress;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onLongPress;
  final GestureLongPressStartCallback? onLongPressStart;
  final GestureTapUpCallback? onSecondaryTapUp;
  final GestureTapDownCallback? onTapDown;
  final GestureTapUpCallback? onTapUp;
  final VoidCallback? onTapCancel;
  final Color? splashColor;
  final Color? highlightColor;
  final Clip clipBehavior;

  @override
  State<PressableSurface> createState() => _PressableSurfaceState();
}

class _PressableSurfaceState extends State<PressableSurface>
    with TickerProviderStateMixin {
  late final AnimationController _press = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _select = AnimationController.unbounded(
    vsync: this,
    value: widget.selected ? 1 : 0,
  );
  late final AnimationController _tint = AnimationController.unbounded(
    vsync: this,
    value: widget.selected ? 1 : 0,
  );

  Offset? _downPos;
  bool _pressed = false;

  bool get _interactive =>
      widget.enabled &&
      (widget.onTap != null ||
          widget.onDoubleTap != null ||
          widget.onLongPress != null ||
          widget.onLongPressStart != null);

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    _pressed = pressed;
    final instant = AppMotion.reduced(context);
    AppMotion.springTo(
      _press,
      pressed ? 1 : 0,
      spring: pressed ? AppMotion.effectsFast : AppMotion.spatialFast,
      instant: instant,
    );
  }

  @override
  void didUpdateWidget(covariant PressableSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_interactive && _pressed) {
      _setPressed(false);
    }
    if (oldWidget.selected != widget.selected) {
      final target = widget.selected ? 1.0 : 0.0;
      final instant = AppMotion.reduced(context);
      AppMotion.springTo(
        _select,
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
  }

  @override
  void dispose() {
    _press.dispose();
    _select.dispose();
    _tint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget ink = AnimatedBuilder(
      animation: Listenable.merge([_press, _select, _tint]),
      builder: (context, child) {
        final pressT = _press.value.clamp(0.0, 1.0);
        final selShapeT = _select.value.clamp(0.0, 1.0);
        final tintT = _tint.value.clamp(0.0, 1.0);

        final restRadius = widget.selectedBorderRadius == null
            ? widget.borderRadius
            : BorderRadius.lerp(
                widget.borderRadius,
                widget.selectedBorderRadius,
                selShapeT,
              )!;
        final radius = widget.morphOnPress && pressT > 0
            ? BorderRadius.lerp(
                restRadius,
                AppShape.pressedRadius(restRadius),
                pressT,
              )!
            : restRadius;

        final bgColor = widget.selectedColor == null
            ? widget.color
            : Color.lerp(widget.color, widget.selectedColor, tintT)!;
        final borderSide = widget.selectedSide == null
            ? widget.side
            : BorderSide.lerp(widget.side, widget.selectedSide!, tintT);

        final shape = RoundedRectangleBorder(
          borderRadius: radius,
          side: borderSide,
        );

        final inkWell = InkWell(
          customBorder: shape,
          onTap: widget.enabled ? widget.onTap : null,
          onDoubleTap: widget.enabled ? widget.onDoubleTap : null,
          onLongPress: widget.enabled ? widget.onLongPress : null,
          onSecondaryTapUp: widget.enabled ? widget.onSecondaryTapUp : null,
          onTapDown: widget.enabled ? widget.onTapDown : null,
          onTapUp: widget.enabled ? widget.onTapUp : null,
          onTapCancel: widget.enabled ? widget.onTapCancel : null,
          splashColor: widget.splashColor,
          highlightColor: widget.highlightColor,
          child: child,
        );

        Widget surface = Material(
          color: bgColor,
          shape: shape,
          clipBehavior: widget.clipBehavior,
          // Форму и цвет ведут пружины покадрово — встроенная анимация Material
          // перезапускалась бы на каждом кадре.
          animationDuration: Duration.zero,
          child: widget.leading == null
              ? inkWell
              : Row(
                  children: [
                    widget.leading!,
                    Expanded(child: inkWell),
                  ],
                ),
        );

        // Transform.scale должен оставаться в дереве всегда (при покое scale=1):
        // условная обёртка меняла тип корневого виджета на втором кадре клика
        // и пересоздавала InkWell, сбрасывая активный TapGestureRecognizer.
        final scale = widget.pressScale > 0
            ? 1 - widget.pressScale * pressT
            : 1.0;
        return Transform.scale(scale: scale, child: surface);
      },
      child: widget.child,
    );

    if (widget.onLongPressStart != null) {
      ink = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPressStart: widget.enabled ? widget.onLongPressStart : null,
        child: ink,
      );
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (!_interactive) return;
        if (e.kind == PointerDeviceKind.mouse &&
            e.buttons != kPrimaryMouseButton) {
          return;
        }
        _downPos = e.localPosition;
        _setPressed(true);
      },
      onPointerMove: (e) {
        if (!_pressed || _downPos == null) return;
        if ((e.localPosition - _downPos!).distance > kTouchSlop) {
          _setPressed(false);
        }
      },
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: ink,
    );
  }
}
