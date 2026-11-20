import 'dart:typed_data';
import 'package:xterm2/core.dart';

/// Transfer rendered cells, not a replay of shell output. This preserves partial
/// escape sequences, alternate screens, styles and scrollback without keeping
/// an unbounded second output journal or creating another SSH connection.
class TerminalMirrorEncoder {
  TerminalMirrorEncoder(this.terminal);
  final Terminal terminal;
  final _ids = Expando<int>();
  Set<int> _known = {};
  Set<int> _viewportIds = {};
  final _hashes = <int, int>{};
  int _next = 0;
  int _width = 0;
  bool? _alt;

  int _hashLine(BufferLine line) {
    var h = 0x811c9dc5;
    h = ((h ^ line.length) * 0x01000193) & 0x7fffffff;
    h = ((h ^ (line.isWrapped ? 1 : 0)) * 0x01000193) & 0x7fffffff;
    final data = line.data;
    final n = line.length * 4;
    for (var i = 0; i < n; i++) {
      h = ((h ^ data[i]) * 0x01000193) & 0x7fffffff;
    }
    if (line.hasCombiningCharacters) {
      for (var x = 0; x < line.length; x++) {
        final c = line.getCombiningCharacters(x);
        if (c != null) {
          h = ((h ^ x ^ c.hashCode) * 0x01000193) & 0x7fffffff;
        }
      }
    }
    for (var x = 0; x < line.length; x++) {
      final u = line.getUnderlineColor(x);
      if (u != 0) {
        h = ((h ^ x ^ u) * 0x01000193) & 0x7fffffff;
      }
    }
    return h;
  }

  Map<String, Object?> capture({bool full = false, int resizeSeq = 0}) {
    if (full) {
      _known.clear();
      _viewportIds.clear();
      _hashes.clear();
    }
    final t = terminal;
    final buffer = t.buffer;
    final reset = _width != t.viewWidth || _alt != t.isUsingAltBuffer;
    if (reset) {
      _hashes.clear();
    }
    final ids = <int>[];
    final nextViewport = <int>{};
    final changed = <Map<String, Object?>>[];
    final scrollBack = buffer.scrollBack;
    for (var i = 0; i < buffer.lines.length; i++) {
      final line = buffer.lines[i];
      final id = _ids[line] ??= ++_next;
      ids.add(id);
      final inViewport = i >= scrollBack;
      if (inViewport) nextViewport.add(id);

      // A line can only be mutated while inside the viewport. Checking both
      // current viewport lines and lines that were in the viewport on the
      // previous frame guarantees that fast scroll bursts never drop updates
      // to lines that just scrolled into scrollback.
      final candidate =
          reset || !_known.contains(id) || inViewport || _viewportIds.contains(id);
      if (candidate) {
        final hash = _hashLine(line);
        if (reset || !_known.contains(id) || _hashes[id] != hash) {
          _hashes[id] = hash;
          final cellCount = line.length * 4;
          final cells = Int32List(cellCount);
          final data = line.data;
          for (var j = 0; j < cellCount; j++) {
            cells[j] = data[j];
          }
          changed.add({
            'id': id,
            'length': line.length,
            'wrapped': line.isWrapped,
            'cells': cells,
            'extra': [
              for (var x = 0; x < line.length; x++)
                if (line.getCombiningCharacters(x) != null ||
                    line.getUnderlineColor(x) != 0)
                  [x, line.getCombiningCharacters(x), line.getUnderlineColor(x)],
            ],
          });
        }
      }
    }
    final alive = ids.toSet();
    _known = alive;
    _viewportIds = nextViewport;
    _hashes.removeWhere((id, _) => !alive.contains(id));
    _width = t.viewWidth;
    _alt = t.isUsingAltBuffer;
    return {
      'width': t.viewWidth,
      'height': t.viewHeight,
      'resizeSeq': resizeSeq,
      'alt': t.isUsingAltBuffer,
      'ids': Int32List.fromList(ids),
      'lines': changed,
      'x': buffer.cursorX,
      'y': buffer.cursorY,
      'visible': t.cursorVisibleMode,
      'blink': t.cursorBlinkMode,
      'reverse': t.reverseDisplayMode,
      'mouse': t.mouseMode.index,
      'report': t.mouseReportMode.index,
      'focus': t.reportFocusMode,
      'altScroll': t.altBufferMouseScrollMode,
      'mouseShift': t.mouseShiftCaptureMode,
      'cursorKeys': t.cursorKeysMode,
      'appKeypad': t.appKeypadMode,
      'altEsc': t.altEscPrefixMode,
      'altSendsEsc': t.altSendsEscapeMode,
      'bracketedPaste': t.bracketedPasteMode,
    };
  }
}

class TerminalMirrorDecoder {
  TerminalMirrorDecoder(this.terminal);
  final Terminal terminal;
  final _lines = <int, BufferLine>{};
  final _hadExtra = <int>{};
  List<int> _lastIds = const [];
  int? _lastMouse;
  int? _lastReport;
  bool? _lastVisible;
  bool? _lastBlink;
  bool? _lastReverse;
  bool? _lastFocus;
  bool? _lastAltScroll;
  bool? _lastMouseShift;

  void apply(Map frame, {bool allowResize = true}) {
    final t = terminal;
    final width = frame['width'] as int, height = frame['height'] as int;
    if (allowResize && (t.viewWidth != width || t.viewHeight != height)) {
      t.resize(width, height);
    }
    final alt = frame['alt'] == true;
    final switchedAlt = t.isUsingAltBuffer != alt;
    if (switchedAlt) {
      t.write(alt ? '\x1b[?1049h' : '\x1b[?1049l');
      _lastIds = const [];
    }
    for (final raw in frame['lines'] as List) {
      final id = raw['id'] as int;
      final length = raw['length'] as int;
      final line = _lines[id] ??= BufferLine(length);
      if (line.length != length) line.resize(length);
      line.isWrapped = raw['wrapped'] == true;
      final cells = raw['cells'] as List;
      final extra = raw['extra'] as List;
      if (!_hadExtra.contains(id) && extra.isEmpty) {
        final data = line.data;
        final n = length * 4;
        for (var j = 0; j < n; j++) {
          data[j] = cells[j] as int;
        }
      } else {
        for (var x = 0; x < length; x++) {
          line.setCellData(
            x,
            CellData.empty()
              ..foreground = cells[x * 4] as int
              ..background = cells[x * 4 + 1] as int
              ..flags = cells[x * 4 + 2] as int
              ..content = cells[x * 4 + 3] as int,
          );
        }
        for (final item in extra) {
          final x = item[0] as int;
          final cell = line.createCellData(x)..underlineColor = item[2] as int;
          line.setCellData(x, cell);
          for (final rune in (item[1] as String? ?? '').runes) {
            line.addCombiningCharacter(x, rune);
          }
        }
        if (extra.isEmpty) {
          _hadExtra.remove(id);
        } else {
          _hadExtra.add(id);
        }
      }
    }

    final rawIds = frame['ids'] as List;
    final ids = rawIds is Int32List ? rawIds : rawIds.cast<int>();
    final alive = ids.toSet();
    _lines.removeWhere((id, _) => !alive.contains(id));
    _hadExtra.removeWhere((id) => !alive.contains(id));

    final buffer = t.buffer;
    // Update the circular buffer in-place so existing BufferLine objects stay
    // attached and active text selections / scroll positions are preserved.
    if (!switchedAlt &&
        buffer.lines.length == _lastIds.length &&
        _lastIds.isNotEmpty &&
        ids.isNotEmpty) {
      final firstId = ids[0];
      if (_lastIds[0] != firstId) {
        final shift = _lastIds.indexOf(firstId);
        if (shift > 0 && shift <= buffer.lines.length) {
          buffer.lines.trimStart(shift);
        } else if (shift < 0) {
          buffer.lines.clear();
        }
      }
    } else if (switchedAlt || buffer.lines.length != _lastIds.length) {
      buffer.lines.clear();
    }

    for (var i = 0; i < ids.length; i++) {
      final target = _lines[ids[i]]!;
      if (i < buffer.lines.length) {
        if (!identical(buffer.lines[i], target)) {
          buffer.lines[i] = target;
        }
      } else {
        buffer.lines.push(target);
      }
    }
    while (buffer.lines.length > ids.length) {
      buffer.lines.pop();
    }
    _lastIds = List<int>.of(ids, growable: false);

    // Sync terminal display/mouse modes only when they actually change.
    final mouseIdx = frame['mouse'] as int;
    final reportIdx = frame['report'] as int;
    final visible = frame['visible'] == true;
    final blink = frame['blink'] == true;
    final reverse = frame['reverse'] == true;
    final focus = frame['focus'] == true;
    final altScroll = frame['altScroll'] == true;
    final mouseShift = frame['mouseShift'] == true;

    final modesChanged =
        _lastMouse != mouseIdx ||
        _lastReport != reportIdx ||
        _lastVisible != visible ||
        _lastBlink != blink ||
        _lastReverse != reverse ||
        _lastFocus != focus ||
        _lastAltScroll != altScroll ||
        _lastMouseShift != mouseShift;
    if (modesChanged) {
      _lastMouse = mouseIdx;
      _lastReport = reportIdx;
      _lastVisible = visible;
      _lastBlink = blink;
      _lastReverse = reverse;
      _lastFocus = focus;
      _lastAltScroll = altScroll;
      _lastMouseShift = mouseShift;

      const mouseModes = [9, 1000, 1002, 1003];
      final mode = MouseMode.values[mouseIdx];
      t.write(
        [
          for (final m in mouseModes) '\x1b[?${m}l',
          for (final m in [1005, 1006, 1015, 1016]) '\x1b[?${m}l',
          if (mode != MouseMode.none)
            '\x1b[?${switch (mode) {
              MouseMode.clickOnly => 9,
              MouseMode.upDownScroll => 1000,
              MouseMode.upDownScrollDrag => 1002,
              _ => 1003,
            }}h',
          if (reportIdx != 0)
            '\x1b[?${[0, 1005, 1006, 1016, 1015][reportIdx]}h',
          '\x1b[?25${visible ? 'h' : 'l'}',
          '\x1b[?12${blink ? 'h' : 'l'}',
          '\x1b[?5${reverse ? 'h' : 'l'}',
          '\x1b[?1004${focus ? 'h' : 'l'}',
          '\x1b[?1007${altScroll ? 'h' : 'l'}',
        ].join(),
      );
    }

    buffer.setCursorX(frame['x'] as int);
    buffer.setCursorY(frame['y'] as int);
    // Public terminal mutations notify the renderer after the cell import.
    t.write('');
  }
}
