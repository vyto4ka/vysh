import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';

import 'app_motion.dart';

const _desktopPlatforms = {
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
};

bool get _isDesktopPlatform =>
    !kIsWeb && _desktopPlatforms.contains(defaultTargetPlatform);

const double _kSmoothTau = 0.085;

/// Контроллер прокрутки со сглаживанием щелчков колеса мыши на ПК.
class SmoothScrollController extends ScrollController {
  SmoothScrollController({
    super.initialScrollOffset,
    super.keepScrollOffset,
    super.debugLabel,
  });

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _SmoothScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
    );
  }
}

class _SmoothScrollPosition extends ScrollPositionWithSingleContext {
  _SmoothScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  _SmoothWheelActivity? _wheel;

  @override
  void pointerScroll(double delta) {
    if (delta == 0.0) return;

    final ctx = context.notificationContext;
    if (ctx != null && AppMotion.reduced(ctx)) {
      super.pointerScroll(delta);
      return;
    }

    updateUserScrollDirection(
      delta > 0.0 ? ScrollDirection.reverse : ScrollDirection.forward,
    );

    if (_wheel != null) {
      _wheel!.addDelta(delta);
    } else {
      final activity = _SmoothWheelActivity(
        this,
        initialDelta: delta,
        vsync: context.vsync,
        onDisposed: () => _wheel = null,
      );
      beginActivity(activity);
      _wheel = activity;
    }
  }
}

/// Доводчик по относительному остатку [_remaining]: в ленивых сливерах
/// `maxScrollExtent` уточняется на ходу, поэтому абсолютная цель сбивалась бы.
class _SmoothWheelActivity extends ScrollActivity {
  _SmoothWheelActivity(
    super.delegate, {
    required double initialDelta,
    required TickerProvider vsync,
    required this.onDisposed,
  }) : _remaining = initialDelta {
    _ticker = vsync.createTicker(_tick)..start();
  }

  final VoidCallback onDisposed;
  late final Ticker _ticker;

  _SmoothScrollPosition get _position => delegate as _SmoothScrollPosition;

  double _remaining;
  Duration _lastElapsed = Duration.zero;
  double _velocity = 0.0;

  void addDelta(double delta) => _remaining += delta;

  void _tick(Duration elapsed) {
    final dt =
        (elapsed - _lastElapsed).inMicroseconds /
        Duration.microsecondsPerSecond;
    _lastElapsed = elapsed;
    if (dt <= 0) return;

    if (_remaining.abs() < 0.5) {
      _velocity = 0.0;
      delegate.goBallistic(0.0);
      return;
    }

    double step = _remaining * (1 - math.exp(-dt / _kSmoothTau));
    if (step.abs() > _remaining.abs()) step = _remaining;
    _remaining -= step;
    _velocity = step / dt;

    final overscroll = delegate.setPixels(_position.pixels + step);
    if (overscroll.abs() > 0.5) {
      _remaining = 0.0;
      delegate.goBallistic(0.0);
    }
  }

  @override
  bool get shouldIgnorePointer => false;

  @override
  bool get isScrolling => true;

  @override
  double get velocity => _velocity;

  @override
  void dispose() {
    onDisposed();
    _ticker.dispose();
    super.dispose();
  }
}

/// Предоставляет [SmoothScrollController] на ПК и `null` на мобильных ОС
/// (где нативная инерция пальца уже плавная).
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController? controller)
  builder;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  SmoothScrollController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDesktopPlatform || AppMotion.reduced(context)) {
      return widget.builder(context, null);
    }
    _controller ??= SmoothScrollController();
    return widget.builder(context, _controller);
  }
}

/// Переводит вертикальное вращение колеса мыши в плавную горизонтальную
/// прокрутку [controller] (через `pointerScroll`, а не скачкообразный `jumpTo`).
class HorizontalWheelScroll extends StatelessWidget {
  const HorizontalWheelScroll({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.mouse,
        },
      ),
      child: Listener(
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent) return;
          final delta = event.scrollDelta.dy;
          if (delta == 0 || !controller.hasClients) return;
          final pos = controller.position;
          if (pos.maxScrollExtent <= 0) return;
          if (delta > 0
              ? pos.pixels >= pos.maxScrollExtent
              : pos.pixels <= pos.minScrollExtent) {
            return;
          }
          GestureBinding.instance.pointerSignalResolver.register(event, (_) {
            pos.pointerScroll(delta);
          });
        },
        child: child,
      ),
    );
  }
}

/// Мягкое растворение верхнего/нижнего края списка при прокрутке.
/// В верхнем положении (`extentBefore == 0`) маска не накладывается.
class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({
    super.key,
    this.top = 24,
    this.bottom = 16,
    this.color,
    required this.child,
  });

  final double top;
  final double bottom;

  /// Цвет фона, в который растворяются края. По умолчанию берётся у ближайшего
  /// [Material] или из [ColorScheme.surface].
  final Color? color;
  final Widget child;

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  final _childKey = GlobalKey();
  double _topProgress = 0;
  double _bottomProgress = 0;

  void _update(int depth, ScrollMetrics metrics) {
    if (depth != 0 || metrics.axis != Axis.vertical) return;
    final nextTop = widget.top <= 0
        ? 0.0
        : (metrics.extentBefore / widget.top).clamp(0.0, 1.0);
    final nextBottom = widget.bottom <= 0
        ? 0.0
        : (metrics.extentAfter / widget.bottom).clamp(0.0, 1.0);
    if ((nextTop - _topProgress).abs() > 0.02 ||
        (nextBottom - _bottomProgress).abs() > 0.02 ||
        (nextTop == 0) != (_topProgress == 0) ||
        (nextBottom == 0) != (_bottomProgress == 0)) {
      setState(() {
        _topProgress = nextTop;
        _bottomProgress = nextBottom;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final topSize = widget.top * _topProgress;
    final bottomSize = widget.bottom * _bottomProgress;

    Widget content = KeyedSubtree(key: _childKey, child: widget.child);
    if (topSize > 0.5 || bottomSize > 0.5) {
      // Два тонких градиента поверх краёв вместо ShaderMask(BlendMode.dstIn):
      // не создаёт полноэкранный offscreen-слой (saveLayer) на каждом списке.
      final fadeColor =
          widget.color ??
          Material.maybeOf(context)?.color ??
          Theme.of(context).colorScheme.surface;
      final clear = fadeColor.withValues(alpha: 0);
      content = Stack(
        fit: StackFit.passthrough,
        children: [
          content,
          if (topSize > 0.5)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: topSize,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [fadeColor, clear],
                    ),
                  ),
                ),
              ),
            ),
          if (bottomSize > 0.5)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: bottomSize,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [fadeColor, clear],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        _update(n.depth, n.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          _update(n.depth, n.metrics);
          return false;
        },
        child: content,
      ),
    );
  }
}
