import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/settings/app_settings.dart';
import 'package:vysh/ui/terminal/clipboard_shortcut.dart';

void main() {
  test('custom clipboard settings survive serialization', () {
    final original = const AppSettings().copyWith(
      customClipboard: true,
      copyShortcut: 'alt+C',
      pasteShortcut: 'ctrl+V',
    );
    final restored = AppSettings.fromJson(original.toJson());
    expect(restored.customClipboard, isTrue);
    expect(restored.copyShortcut, 'alt+C');
    expect(restored.pasteShortcut, 'ctrl+V');
    expect(AppSettings.fromJson({}).customClipboard, isFalse);
  });
  test('shortcut parser preserves modifiers and key', () {
    final a = clipboardActivator('ctrl+shift+C')!;
    expect(a.trigger, LogicalKeyboardKey.keyC);
    expect(a.control, isTrue);
    expect(a.shift, isTrue);
    expect(a.meta, isFalse);
    expect(clipboardActivator('missing'), isNull);
  });
  test('tab and application shortcuts cannot be assigned', () {
    for (final value in [
      'ctrl+TAB',
      'ctrl+shift+W',
      'alt+1',
      'meta+Q',
      'alt+F4',
    ]) {
      expect(reservedClipboardShortcut(value), isTrue, reason: value);
    }
    expect(reservedClipboardShortcut('ctrl+C'), isFalse);
    expect(reservedClipboardShortcut('alt+V'), isFalse);
  });
}
