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
  int _next = 0;
  int _width = 0;
  bool? _alt;
  Map<String, Object?> capture({bool full = false}) {
    if (full) _known.clear();
    final t = terminal;
    final buffer = t.buffer;
    final reset = _width != t.viewWidth || _alt != t.isUsingAltBuffer;
    final ids = <int>[];
    final changed = <Map<String, Object?>>[];
    for (var i = 0; i < buffer.lines.length; i++) {
      final line = buffer.lines[i];
      final id = _ids[line] ??= ++_next;
      ids.add(id);
      if (reset || !_known.contains(id) || i >= buffer.scrollBack) {
        changed.add({
          'id': id,
          'length': line.length,
          'wrapped': line.isWrapped,
          'cells': Int32List.fromList(line.data.take(line.length * 4).toList()),
          'extra': [
            for (var x = 0; x < line.length; x++)
              if (line.getCombiningCharacters(x) != null ||
                  line.getUnderlineColor(x) != 0)
                [x, line.getCombiningCharacters(x), line.getUnderlineColor(x)],
          ],
        });
      }
    }
    _known = ids.toSet();
    _width = t.viewWidth;
    _alt = t.isUsingAltBuffer;
    return {
      'width': t.viewWidth,
      'height': t.viewHeight,
      'alt': t.isUsingAltBuffer,
      'ids': ids,
      'lines': changed,
      'x': buffer.cursorX,
      'y': buffer.cursorY,
      'visible': t.cursorVisibleMode,
      'blink': t.cursorBlinkMode,
      'reverse': t.reverseDisplayMode,
      'mouse': t.mouseMode.index,
      'report': t.mouseReportMode.index,
      'focus': t.reportFocusMode,
    };
  }
}

class TerminalMirrorDecoder {
  TerminalMirrorDecoder(this.terminal);
  final Terminal terminal;
  final _lines = <int, BufferLine>{};
  void apply(Map frame) {
    final t = terminal;
    final width = frame['width'] as int, height = frame['height'] as int;
    if (t.viewWidth != width || t.viewHeight != height) t.resize(width, height);
    final alt = frame['alt'] == true;
    if (t.isUsingAltBuffer != alt) {
      t.write(alt ? '\x1b[?1049h' : '\x1b[?1049l');
    }
    for (final raw in frame['lines'] as List) {
      final line = _lines[raw['id']] ??= BufferLine(raw['length']);
      if (line.length != raw['length']) line.resize(raw['length']);
      line.isWrapped = raw['wrapped'];
      final cells = raw['cells'] as List;
      for (var x = 0; x < line.length; x++) {
        line.setCellData(
          x,
          CellData.empty()
            ..foreground = cells[x * 4]
            ..background = cells[x * 4 + 1]
            ..flags = cells[x * 4 + 2]
            ..content = cells[x * 4 + 3],
        );
      }
      for (final extra in raw['extra'] as List) {
        final x = extra[0] as int;
        final cell = line.createCellData(x)..underlineColor = extra[2];
        line.setCellData(x, cell);
        for (final rune in (extra[1] as String? ?? '').runes) {
          line.addCombiningCharacter(x, rune);
        }
      }
    }
    final ids = (frame['ids'] as List).cast<int>();
    final alive = ids.toSet();
    _lines.removeWhere((id, _) => !alive.contains(id));
    final buffer = t.buffer;
    buffer.lines.clear();
    for (final id in ids) {
      buffer.lines.push(_lines[id]!);
    }
    // Only mode escapes are parsed locally; all keyboard protocol decisions and
    // application state remain in the owner's terminal.
    const mouse = [9, 1000, 1002, 1003];
    final mode = MouseMode.values[frame['mouse'] as int];
    t.write(
      [
        for (final m in mouse)
          '\x1b[?$m'
              'l',
        for (final m in [1005, 1006, 1015, 1016])
          '\x1b[?$m'
              'l',
        if (mode != MouseMode.none)
          '\x1b[?${switch (mode) {
            MouseMode.clickOnly => 9,
            MouseMode.upDownScroll => 1000,
            MouseMode.upDownScrollDrag => 1002,
            _ => 1003,
          }}h',
        if (frame['report'] != 0)
          '\x1b[?${[0, 1005, 1006, 1016, 1015][frame['report'] as int]}h',
        '\x1b[?25${frame['visible'] == true ? 'h' : 'l'}',
        '\x1b[?12${frame['blink'] == true ? 'h' : 'l'}',
        '\x1b[?5${frame['reverse'] == true ? 'h' : 'l'}',
        '\x1b[?1004${frame['focus'] == true ? 'h' : 'l'}',
      ].join(),
    );
    buffer.setCursorX(frame['x']);
    buffer.setCursorY(frame['y']);
    // Public terminal mutations notify the renderer after the cell import.
    t.write('');
  }
}
