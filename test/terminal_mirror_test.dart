import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/core.dart';
import 'package:vysh/app/windows/terminal_mirror.dart';

void sameScreen(Terminal owner, Terminal mirror) {
  expect(mirror.viewWidth, owner.viewWidth);
  expect(mirror.viewHeight, owner.viewHeight);
  expect(mirror.buffer.cursorX, owner.buffer.cursorX);
  expect(mirror.buffer.cursorY, owner.buffer.cursorY);
  expect(mirror.buffer.lines.length, owner.buffer.lines.length);
  expect(mirror.isUsingAltBuffer, owner.isUsingAltBuffer);
  for (var y = 0; y < owner.buffer.lines.length; y++) {
    final a = owner.buffer.lines[y], b = mirror.buffer.lines[y];
    expect(b.isWrapped, a.isWrapped);
    expect(
      b.data.take(b.length * 4).toList(),
      a.data.take(a.length * 4).toList(),
      reason: 'line $y',
    );
    for (var x = 0; x < a.length; x++) {
      expect(b.getCombiningCharacters(x), a.getCombiningCharacters(x));
      expect(b.getUnderlineColor(x), a.getUnderlineColor(x));
    }
  }
}

void main() {
  test(
    'preserves color, wide characters, combining characters and a partial escape sequence',
    () {
      final owner = Terminal(maxLines: 200)..resize(40, 8);
      final mirror = Terminal(maxLines: 200);
      final encoder = TerminalMirrorEncoder(owner),
          decoder = TerminalMirrorDecoder(mirror);
      owner.write('history\r\n\x1b[31mRed\x1b[0m 漢字 e\u0301\r\n\x1b[');
      decoder.apply(encoder.capture());
      sameScreen(owner, mirror);
      owner.write('32mGreen\x1b[0m');
      decoder.apply(encoder.capture());
      sameScreen(owner, mirror);
    },
  );
  test('updates scrollback and reflow without replaying the server stream', () {
    final owner = Terminal(maxLines: 100)..resize(30, 6),
        mirror = Terminal(maxLines: 100);
    final encoder = TerminalMirrorEncoder(owner),
        decoder = TerminalMirrorDecoder(mirror);
    for (var i = 0; i < 150; i++) {
      owner.write('line $i: some long content for wrapping\r\n');
      decoder.apply(encoder.capture());
    }
    sameScreen(owner, mirror);
    owner.resize(18, 10);
    decoder.apply(encoder.capture());
    sameScreen(owner, mirror);
  });
  test('switches alternate buffers and preserves the original main screen', () {
    final owner = Terminal(maxLines: 100)..resize(30, 8),
        mirror = Terminal(maxLines: 100);
    final encoder = TerminalMirrorEncoder(owner),
        decoder = TerminalMirrorDecoder(mirror);
    owner.write('before vim\r\n');
    decoder.apply(encoder.capture());
    owner.write(
      '\x1b[?1049h\x1b[2J\x1b[3;5Heditor\x1b[?25l\x1b[?1002h\x1b[?1006h',
    );
    decoder.apply(encoder.capture());
    sameScreen(owner, mirror);
    expect(mirror.cursorVisibleMode, isFalse);
    expect(mirror.mouseMode, owner.mouseMode);
    expect(mirror.mouseReportMode, owner.mouseReportMode);
    owner.write('\x1b[?1049l\x1b[?25h');
    decoder.apply(encoder.capture());
    sameScreen(owner, mirror);
  });
  test('full synchronization can restore a newly created renderer', () {
    final owner = Terminal(maxLines: 100)..resize(30, 5);
    final encoder = TerminalMirrorEncoder(owner);
    owner.write('first\r\nsecond\r\nthird\r\nfourth\r\nfifth\r\n');
    encoder.capture();
    final mirror = Terminal(maxLines: 100);
    TerminalMirrorDecoder(mirror).apply(encoder.capture(full: true));
    sameScreen(owner, mirror);
  });
}
