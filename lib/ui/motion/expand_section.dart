import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'app_motion.dart';

/// Плавное раскрытие и сворачивание условного блока на пружине.
///
/// При открытии дочерний виджет монтируется в первом же кадре, а в покое
/// (`expanded == true`, анимация завершена) возвращается напрямую без лишних
/// слоёв обрезки и прозрачности.
class ExpandSection extends StatefulWidget {
  const ExpandSection({
    super.key,
    required this.expanded,
    required this.child,
    this.axis = Axis.vertical,
    this.alignment = AlignmentDirectional.topStart,
    this.spring = AppMotion.spatialDefault,
    this.keepAlive = false,
    this.fade = true,
    this.onAnimatingChanged,
  });

  final bool expanded;
  final Widget child;
  final Axis axis;
  final AlignmentGeometry alignment;
  final SpringDescription spring;
  final bool keepAlive;
  final bool fade;
  final ValueChanged<bool>? onAnimatingChanged;

  @override
  State<ExpandSection> createState() => _ExpandSectionState();
}

class _ExpandSectionState extends State<ExpandSection>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController.unbounded(
    vsync: this,
    value: widget.expanded ? 1 : 0,
  );
  late bool _mountedChild = widget.expanded;
  bool _notifiedAnimating = false;

  void _notifyAnimating(bool animating) {
    if (_notifiedAnimating == animating) return;
    _notifiedAnimating = animating;
    final cb = widget.onAnimatingChanged;
    if (cb == null) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _notifiedAnimating == animating) cb(animating);
      });
    } else {
      cb(animating);
    }
  }

  @override
  void didUpdateWidget(covariant ExpandSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded == widget.expanded) return;

    if (AppMotion.reduced(context)) {
      _ctrl.value = widget.expanded ? 1 : 0;
      _mountedChild = widget.expanded;
      _notifyAnimating(false);
      return;
    }

    if (widget.expanded) {
      _mountedChild = true;
    }
    _notifyAnimating(true);
    final target = widget.expanded ? 1.0 : 0.0;
    AppMotion.springTo(_ctrl, target, spring: widget.spring).whenComplete(() {
      if (!mounted) return;
      if (!_ctrl.isAnimating) {
        _notifyAnimating(false);
        if (!widget.expanded && _mountedChild) {
          setState(() => _mountedChild = false);
        } else {
          setState(() {});
        }
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_mountedChild) {
      if (!widget.keepAlive) return const SizedBox.shrink();
      return Offstage(
        offstage: true,
        child: TickerMode(enabled: false, child: widget.child),
      );
    }

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        if (!_ctrl.isAnimating && widget.expanded && _ctrl.value == 1) {
          return child!;
        }
        final factor = math.max(0.0, _ctrl.value);
        final opacity = _ctrl.value.clamp(0.0, 1.0);
        Widget content = child!;
        if (widget.fade) {
          content = Opacity(opacity: opacity, child: content);
        }
        return IgnorePointer(
          ignoring: !widget.expanded,
          child: ExcludeFocus(
            excluding: !widget.expanded,
            child: ClipRect(
              child: Align(
                alignment: widget.alignment,
                heightFactor: widget.axis == Axis.vertical ? factor : null,
                widthFactor: widget.axis == Axis.horizontal ? factor : null,
                child: content,
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
