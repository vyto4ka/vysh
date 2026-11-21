import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_motion.dart';

/// Плавная смена темы и акцента без покадровой перестройки открытых терминалов:
/// снимает один снимок предыдущего кадра (`toImageSync`) и растворяет его
/// (или раскрывает круговой волной из точки клика) поверх новой темы.
class ThemeTransitionHost extends StatefulWidget {
  const ThemeTransitionHost({
    super.key,
    required this.themeKey,
    required this.child,
  });

  final Object themeKey;
  final Widget child;

  @override
  State<ThemeTransitionHost> createState() => _ThemeTransitionHostState();
}

class _ThemeTransitionHostState extends State<ThemeTransitionHost>
    with SingleTickerProviderStateMixin {
  final _boundaryKey = GlobalKey();
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  );

  ui.Image? _snapshot;
  Offset? _lastPointer;
  DateTime? _lastPointerAt;
  Offset? _revealOrigin;

  void _disposeSnapshot() {
    _snapshot?.dispose();
    _snapshot = null;
    _revealOrigin = null;
  }

  @override
  void didUpdateWidget(covariant ThemeTransitionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.themeKey == widget.themeKey) return;
    if (!AppMotion.allowInfiniteAnimations || AppMotion.reduced(context)) {
      _disposeSnapshot();
      return;
    }
    _capturePreviousFrame();
  }

  void _capturePreviousFrame() {
    final ro = _boundaryKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || ro.debugNeedsPaint || !ro.hasSize) {
      return;
    }
    final size = ro.size;
    if (size.isEmpty) return;
    final dpr = View.maybeOf(context)?.devicePixelRatio ?? 1.0;
    try {
      final image = ro.toImageSync(pixelRatio: dpr.clamp(1.0, 1.5));
      _disposeSnapshot();
      _snapshot = image;

      final now = DateTime.now();
      final recentTap =
          _lastPointer != null &&
          _lastPointerAt != null &&
          now.difference(_lastPointerAt!) < const Duration(milliseconds: 450);
      _revealOrigin = recentTap ? _lastPointer : null;
      _ctrl.duration = recentTap
          ? const Duration(milliseconds: 360)
          : const Duration(milliseconds: 220);
      _ctrl.forward(from: 0).whenComplete(() {
        if (mounted && !_ctrl.isAnimating) {
          setState(_disposeSnapshot);
        }
      });
    } catch (_) {
      _disposeSnapshot();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _disposeSnapshot();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _lastPointer = e.localPosition;
        _lastPointerAt = DateTime.now();
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          RepaintBoundary(key: _boundaryKey, child: widget.child),
          if (_snapshot != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _ctrl,
                  builder: (context, child) {
                    final t = AppMotion.emphasizedDecelerate.transform(
                      _ctrl.value.clamp(0.0, 1.0),
                    );
                    if (_revealOrigin != null) {
                      return ClipPath(
                        clipper: _CircularRevealHoleClipper(
                          origin: _revealOrigin!,
                          progress: t,
                        ),
                        child: Opacity(
                          opacity: (1 - ((t - 0.75) / 0.25).clamp(0.0, 1.0)),
                          child: child,
                        ),
                      );
                    }
                    return Opacity(
                      opacity: (1 - t).clamp(0.0, 1.0),
                      child: child,
                    );
                  },
                  child: RawImage(
                    image: _snapshot,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.low,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Вырезает растущее прозрачное круглое «окно» в снимке старой темы, открывая
/// под ним уже отрисованную новую тему из точки нажатия.
class _CircularRevealHoleClipper extends CustomClipper<Path> {
  const _CircularRevealHoleClipper({
    required this.origin,
    required this.progress,
  });

  final Offset origin;
  final double progress;

  @override
  Path getClip(Size size) {
    final dx = math.max(origin.dx, size.width - origin.dx);
    final dy = math.max(origin.dy, size.height - origin.dy);
    final maxRadius = math.sqrt(dx * dx + dy * dy);
    final radius = maxRadius * progress;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addOval(Rect.fromCircle(center: origin, radius: radius));
  }

  @override
  bool shouldReclip(_CircularRevealHoleClipper oldClipper) =>
      oldClipper.progress != progress || oldClipper.origin != origin;
}
