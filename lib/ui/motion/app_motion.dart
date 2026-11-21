import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Единая система движения в духе Material 3 Expressive:
/// пружины для геометрии (с естественным перелётом) и эффектов (критическое
/// затухание без перелёта для цвета и прозрачности), кривые и учёт системного
/// отключения анимаций.
abstract final class AppMotion {
  // ── Пространственные пружины (перемещения, размеры, скругления) ──

  /// Быстрая упругая пружина: вкладки, чипы, отклик при отпускании кнопки.
  static const spatialFast = SpringDescription(
    mass: 1,
    stiffness: 800,
    damping: 2 * 0.65 * 28.28427, // ζ ≈ 0.65
  );

  /// Основная пространственная пружина: панели, карточки, шторки.
  static const spatialDefault = SpringDescription(
    mass: 1,
    stiffness: 380,
    damping: 2 * 0.80 * 19.49359, // ζ ≈ 0.80
  );

  /// Мягкая пружина для крупных переходов между разделами.
  static const spatialSlow = SpringDescription(
    mass: 1,
    stiffness: 220,
    damping: 2 * 0.82 * 14.83240, // ζ ≈ 0.82
  );

  /// Пружина сворачивания групп и выдвижных секций с лёгкой отдачей.
  static const fold = SpringDescription(
    mass: 1,
    stiffness: 380,
    damping: 2 * 0.60 * 19.49359, // ζ ≈ 0.60
  );

  // ── Пружины эффектов (ζ = 1.0, без перелёта для цвета и прозрачности) ──

  static const effectsFast = SpringDescription(
    mass: 1,
    stiffness: 3800,
    damping: 2 * 61.64414,
  );

  static const effectsDefault = SpringDescription(
    mass: 1,
    stiffness: 1600,
    damping: 2 * 40.0,
  );

  static const effectsSlow = SpringDescription(
    mass: 1,
    stiffness: 800,
    damping: 2 * 28.28427,
  );

  // ── Длительности и кривые M3 ──

  static const durationFast = Duration(milliseconds: 180);
  static const durationDefault = Duration(milliseconds: 280);
  static const durationSlow = Duration(milliseconds: 400);

  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);
  static const emphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);

  static const spatialCurve = SpringCurve(
    spatialDefault,
    Duration(milliseconds: 360),
  );
  static const fastSpringCurve = SpringCurve(
    spatialFast,
    Duration(milliseconds: 260),
  );
  static const foldCurve = SpringCurve(fold, Duration(milliseconds: 420));

  /// В `flutter test` бесконечные тикеры мешают `pumpAndSettle`.
  static bool allowInfiniteAnimations = !Platform.environment.containsKey(
    'FLUTTER_TEST',
  );

  /// Уважать системное «Убрать анимации» / «Уменьшение движения».
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration duration(BuildContext context, Duration normal) =>
      reduced(context) ? Duration.zero : normal;

  /// Виден ли виджет на экране и не свёрнуто ли приложение (важно на Android,
  /// где свёрнутое приложение само не выключает корневой TickerMode).
  static bool onScreen(ValueListenable<TickerModeData>? ticking) {
    final life = WidgetsBinding.instance.lifecycleState;
    return (ticking?.value.enabled ?? true) &&
        life != AppLifecycleState.hidden &&
        life != AppLifecycleState.paused &&
        life != AppLifecycleState.detached;
  }

  /// Довести [controller] до [target] по пружине [spring].
  /// `snapToEnd: true` гарантирует точное завершение без бесконечного хвоста.
  static TickerFuture springTo(
    AnimationController controller,
    double target, {
    SpringDescription spring = spatialDefault,
    bool snapToEnd = true,
    bool instant = false,
  }) {
    if (instant ||
        (!controller.isAnimating &&
            (controller.value - target).abs() < 0.0005)) {
      controller.value = target;
      return TickerFuture.complete();
    }
    return controller.animateWith(
      SpringSimulation(
        spring,
        controller.value,
        target,
        0,
        snapToEnd: snapToEnd,
      ),
    );
  }
}

/// Адаптер пружины под [Curve] для неявных виджетов вроде [AnimatedSize] и
/// [AnimatedContainer].
class SpringCurve extends Curve {
  const SpringCurve(this.spring, this.duration);

  final SpringDescription spring;
  final Duration duration;

  @override
  double transformInternal(double t) => SpringSimulation(
    spring,
    0,
    1,
    0,
    snapToEnd: true,
  ).x(t * duration.inMicroseconds / 1e6);
}

/// Морфинг углов при нажатии и выборе в стиле Material 3 Expressive.
abstract final class AppShape {
  static const double pill = 999;

  /// Уменьшенный радиус при нажатии: плитка становится чуть собраннее.
  static double pressedCorner(double corner) => switch (corner) {
    >= pill => corner,
    >= 28 => 20,
    >= 20 => 14,
    >= 14 => 9,
    >= 8 => 5,
    _ => corner,
  };

  static BorderRadius pressedRadius(BorderRadius base) => BorderRadius.only(
    topLeft: Radius.circular(pressedCorner(base.topLeft.x)),
    topRight: Radius.circular(pressedCorner(base.topRight.x)),
    bottomLeft: Radius.circular(pressedCorner(base.bottomLeft.x)),
    bottomRight: Radius.circular(pressedCorner(base.bottomRight.x)),
  );
}

/// Горизонтальное покачивание при ошибке ввода (например, неверный пароль).
class ShakeBox extends StatefulWidget {
  const ShakeBox({
    super.key,
    required this.trigger,
    required this.child,
    this.amplitude = 8,
  });

  /// При каждом изменении ненулевого счётчика или флага проигрывается импульс.
  final int trigger;
  final double amplitude;
  final Widget child;

  @override
  State<ShakeBox> createState() => _ShakeBoxState();
}

class _ShakeBoxState extends State<ShakeBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
  );

  @override
  void initState() {
    super.initState();
    if (widget.trigger > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !AppMotion.reduced(context)) _ctrl.forward(from: 0);
      });
    }
  }

  @override
  void didUpdateWidget(ShakeBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trigger != oldWidget.trigger && widget.trigger > 0) {
      if (!AppMotion.reduced(context)) _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ctrl.value;
        final dx = (t == 0 || t == 1)
            ? 0.0
            : math.sin(t * math.pi * 5) * (1 - t) * (1 - t) * widget.amplitude;
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: widget.child,
    );
  }
}
