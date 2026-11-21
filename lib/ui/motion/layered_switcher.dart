import 'package:flutter/material.dart';

import 'app_motion.dart';

typedef _UnderLayer = ({int index, double opacity, double offset});

/// Переключатель вкладок/панелей с сохранением состояния всех дочерних
/// виджетов (как [IndexedStack]), направленным пружинным сдвигом и
/// перекрывающейся прозрачностью без моргания фона и вспышек при перебивании.
class LayeredSwitcher extends StatefulWidget {
  const LayeredSwitcher({
    super.key,
    required this.index,
    required this.children,
    this.axis = Axis.horizontal,
    this.shift = 24,
    this.pauseHidden = true,
  });

  final int index;
  final List<Widget> children;
  final Axis axis;
  final double shift;
  final bool pauseHidden;

  @override
  State<LayeredSwitcher> createState() => _LayeredSwitcherState();
}

class _LayeredSwitcherState extends State<LayeredSwitcher>
    with SingleTickerProviderStateMixin {
  late int _to = widget.index;
  var _under = <_UnderLayer>[];
  int _dir = 1;
  late final AnimationController _t = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  // Новая панель проявляется в первой половине хода, уходящая гаснет только
  // когда её уже перекрыли — экран не проваливается в цвет подложки.
  double _inOpacity(double t) => (t / 0.55).clamp(0.0, 1.0);
  double _fade(double t) => 1 - ((t - 0.45) / 0.45).clamp(0.0, 1.0);
  double _inOffset(double t) => _dir * widget.shift * (1 - t);
  double _underOpacity(_UnderLayer l, double t) =>
      (l.opacity * _fade(t)).clamp(0.0, 1.0);
  double _underOffset(_UnderLayer l, double t) =>
      l.offset - _dir * widget.shift * t;

  @override
  void didUpdateWidget(covariant LayeredSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == _to) return;
    if (AppMotion.reduced(context)) {
      _t.value = 1;
      _under = [];
      _to = widget.index;
      return;
    }
    final t = _t.value;
    final moving = _under.isNotEmpty;
    _under = [
      for (final l in _under)
        if (l.index != widget.index &&
            l.index < widget.children.length &&
            _underOpacity(l, t) > 0.01)
          (
            index: l.index,
            opacity: _underOpacity(l, t),
            offset: _underOffset(l, t),
          ),
      if (_to < widget.children.length)
        (
          index: _to,
          opacity: moving ? _inOpacity(t) : 1.0,
          offset: moving ? _inOffset(t) : 0.0,
        ),
    ];
    _dir = widget.index > _to ? 1 : -1;
    _to = widget.index;
    _t.value = 0;
    AppMotion.springTo(_t, 1, spring: AppMotion.spatialDefault).whenComplete(
      () {
        if (mounted && !_t.isAnimating) {
          setState(() => _under = []);
        }
      },
    );
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        final t = _t.value;
        final underIndices = {for (final l in _under) l.index};
        return Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              if (i != _to && !underIndices.contains(i))
                _buildLayer(i, shown: false),
            for (final l in _under)
              _buildLayer(
                l.index,
                shown: true,
                opacity: _underOpacity(l, t),
                offset: _underOffset(l, t),
              ),
            if (_to < widget.children.length)
              if (_under.isEmpty)
                _buildLayer(_to, shown: true)
              else
                _buildLayer(
                  _to,
                  shown: true,
                  opacity: _inOpacity(t),
                  offset: _inOffset(t),
                ),
          ],
        );
      },
    );
  }

  Widget _buildLayer(
    int i, {
    required bool shown,
    double opacity = 1,
    double offset = 0,
  }) {
    final current = i == _to;
    final delta = !shown || offset == 0
        ? Offset.zero
        : (widget.axis == Axis.horizontal
              ? Offset(offset, 0)
              : Offset(0, offset));
    final effectiveOpacity = shown ? opacity.clamp(0.0, 1.0) : 1.0;

    // Постоянная глубина дерева (Opacity → Transform.translate → child) нужна,
    // чтобы завершение анимации не пересоздавало State дочернего виджета.
    final content = Opacity(
      opacity: effectiveOpacity,
      child: Transform.translate(offset: delta, child: widget.children[i]),
    );
    return KeyedSubtree(
      key: ValueKey(i),
      child: Offstage(
        offstage: !shown,
        child: TickerMode(
          enabled: !widget.pauseHidden || shown,
          child: ExcludeFocus(
            excluding: !current,
            child: IgnorePointer(ignoring: !current, child: content),
          ),
        ),
      ),
    );
  }
}

/// Аккуратный переход для сменяемых по ключу состояний (поиск ↔ панель выбора,
/// список ↔ пустое состояние, загрузка ↔ результат) без наложения текста кашей.
class FadeSlideSwitcher extends StatelessWidget {
  const FadeSlideSwitcher({
    super.key,
    required this.child,
    this.duration = AppMotion.durationFast,
    this.offset = const Offset(0, 0.06),
    this.scaleBegin = 0.98,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final Duration duration;
  final Offset offset;
  final double scaleBegin;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final d = AppMotion.duration(context, duration);
    return AnimatedSwitcher(
      duration: d,
      switchInCurve: AppMotion.emphasizedDecelerate,
      switchOutCurve: AppMotion.emphasizedAccelerate,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) {
        final fade = CurvedAnimation(
          parent: animation,
          curve: const Interval(0.25, 1.0),
        );
        return FadeTransition(
          opacity: fade,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: offset,
              end: Offset.zero,
            ).animate(animation),
            child: scaleBegin == 1.0
                ? child
                : ScaleTransition(
                    scale: Tween<double>(
                      begin: scaleBegin,
                      end: 1.0,
                    ).animate(animation),
                    child: child,
                  ),
          ),
        );
      },
      child: child,
    );
  }
}
