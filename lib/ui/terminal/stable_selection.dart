import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart';

/// Контроллер терминала, который на время перетаскивания мышью принимает
/// выделение только от [DragSelectionFix].
///
/// Зачем: xterm2 запоминает начало выделения как точку на экране и при каждом
/// движении заново переводит её в строку буфера с учётом текущей прокрутки.
/// Стоит терминалу прокрутиться (тянем мышь за верхний край, крутим колесо) -
/// начало выделения «уезжает» вместе с экраном, и выделение получается кривым.
class StableSelectionController extends TerminalController {
  bool _locked = false;
  bool _own = false;

  @override
  void setSelection(CellAnchor base, CellAnchor extent, {SelectionMode? mode}) {
    if (_locked && !_own) {
      // Выделение от библиотеки во время нашего перетаскивания - отбрасываем.
      base.dispose();
      extent.dispose();
      return;
    }
    super.setSelection(base, extent, mode: mode);
  }

  void _setOwn(CellAnchor base, CellAnchor extent, SelectionMode mode) {
    _own = true;
    try {
      super.setSelection(base, extent, mode: mode);
    } finally {
      _own = false;
    }
  }
}

/// Выделение мышью, привязанное к строкам буфера, а не к точкам экрана.
///
/// Начало запоминается якорем в буфере ([CellAnchor]) - он не сдвигается
/// при прокрутке. Конец берётся из текущего положения мыши. Если увести мышь
/// за верхний или нижний край терминала, история прокручивается сама - тем
/// быстрее, чем дальше мышь от края, - и выделение продолжается.
class DragSelectionFix {
  DragSelectionFix({
    required this.controller,
    required this.viewKey,
    required this.scroll,
    required this.terminal,
  });

  final StableSelectionController controller;
  final GlobalKey<TerminalViewState> viewKey;
  final ScrollController scroll;
  final Terminal? Function() terminal;

  CellAnchor? _base;
  Offset? _down;
  Offset? _last;
  bool _dragging = false;
  Timer? _auto;

  /// Мышь сдвинулась меньше - это клик (или двойной клик), не перетаскивание.
  static const _slop = 4.0;

  void onPointerDown(PointerDownEvent e) {
    _finish();
    if (e.kind != PointerDeviceKind.mouse || e.buttons != kPrimaryMouseButton) return;
    final t = terminal();
    // Программа сама следит за мышью (mc, htop, vim с mouse=a) - не мешаем.
    if (t == null || t.mouseMode != MouseMode.none) return;
    final cell = _cellAt(e.position);
    if (cell == null) return;
    _base = t.buffer.createAnchorFromOffset(cell);
    _down = e.position;
  }

  void onPointerMove(PointerMoveEvent e) {
    final down = _down;
    if (_base == null || down == null) return;
    _last = e.position;
    if (!_dragging) {
      if ((e.position - down).distance < _slop) return;
      _dragging = true;
      controller._locked = true;
    }
    _update();
    _autoScrollIfOutside();
  }

  void onPointerUp(PointerEvent e) => _finish();

  /// Терминал прокрутился (автопрокрутка у края или колесо) во время выделения.
  void onScroll() {
    if (_dragging) _update();
  }

  void dispose() => _finish();

  void _finish() {
    _auto?.cancel();
    _auto = null;
    _dragging = false;
    controller._locked = false;
    _base?.dispose();
    _base = null;
    _down = null;
    _last = null;
  }

  /// Мышь за краем терминала - крутим историю, пока она там.
  void _autoScrollIfOutside() {
    if (_auto != null || _overflow() == 0) return;
    _auto = Timer.periodic(const Duration(milliseconds: 30), (_) {
      final over = _overflow();
      if (!_dragging || over == 0 || !scroll.hasClients) {
        _auto?.cancel();
        _auto = null;
        return;
      }
      final line = _lineHeight();
      // От полстроки до 8 строк за шаг - в зависимости от того, как далеко мышь.
      final speed = (0.5 + over.abs() / 30).clamp(0.5, 8.0) * line;
      final pos = scroll.position;
      final target = (pos.pixels + (over < 0 ? -speed : speed))
          .clamp(pos.minScrollExtent, pos.maxScrollExtent)
          .toDouble();
      if (target != pos.pixels) scroll.jumpTo(target); // → onScroll → _update
    });
  }

  /// На сколько пикселей мышь вышла за верх (< 0) или низ (> 0) терминала.
  double _overflow() {
    final last = _last;
    if (last == null) return 0;
    try {
      final render = viewKey.currentState?.renderTerminal;
      if (render == null || !render.attached) return 0;
      final y = render.globalToLocal(last).dy;
      if (y < 0) return y;
      if (y > render.size.height) return y - render.size.height;
      return 0;
    } catch (_) {
      return 0;
    }
  }

  double _lineHeight() {
    try {
      return viewKey.currentState?.renderTerminal.lineHeight ?? 16;
    } catch (_) {
      return 16;
    }
  }

  CellOffset? _cellAt(Offset global) {
    try {
      final render = viewKey.currentState?.renderTerminal;
      if (render == null || !render.attached) return null;
      return render.getCellOffset(render.globalToLocal(global));
    } catch (_) {
      return null; // терминал ещё не отрисован
    }
  }

  void _update() {
    final t = terminal();
    final base = _base;
    final last = _last;
    if (t == null || base == null || last == null) return;
    // Строку с началом выделения вытеснило из истории - выделять нечего.
    if (!base.attached) {
      _finish();
      return;
    }
    final to = _cellAt(last);
    if (to == null) return;
    final from = base.offset;

    final alt = HardwareKeyboard.instance.isAltPressed;
    final mode = alt ? SelectionMode.block : SelectionMode.line;
    final buffer = t.buffer;

    final (CellOffset a, CellOffset b) = to.isAfterOrSame(from)
        ? (_start(t, from), _end(t, to))
        : (_end(t, from), _start(t, to));
    controller._setOwn(
      buffer.createAnchorFromOffset(a),
      buffer.createAnchorFromOffset(b),
      mode,
    );
  }

  /// Начало ячейки: правая половина широкого символа (CJK, эмодзи) → левая.
  static CellOffset _start(Terminal t, CellOffset p) {
    final line = t.buffer.lines[p.y];
    if (p.x > 0 && line.getWidth(p.x) == 0 && line.getWidth(p.x - 1) == 2) {
      return CellOffset(p.x - 1, p.y);
    }
    return p;
  }

  /// Конец ячейки (не включительно), с учётом широких символов.
  static CellOffset _end(Terminal t, CellOffset p) {
    final s = _start(t, p);
    final width = t.buffer.lines[s.y].getWidth(s.x) == 2 ? 2 : 1;
    final x = s.x + width;
    return CellOffset(x > t.viewWidth ? t.viewWidth : x, s.y);
  }
}
