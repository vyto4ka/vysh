import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Stable representation shared by the recorder, settings and terminal.
SingleActivator? clipboardActivator(String value) {
  final parts = value.split('+');
  final key = LogicalKeyboardKey.knownLogicalKeys
      .where((key) => key.keyLabel.toUpperCase() == parts.last.toUpperCase())
      .firstOrNull;
  if (key == null || parts.length < 2) return null;
  return SingleActivator(
    key,
    control: parts.contains('ctrl'),
    shift: parts.contains('shift'),
    alt: parts.contains('alt'),
    meta: parts.contains('meta'),
  );
}

String? recordClipboardShortcut(KeyEvent event) {
  if (event is! KeyDownEvent) return null;
  final k = HardwareKeyboard.instance;
  final label = event.logicalKey.keyLabel;
  if (label.isEmpty ||
      label.contains('Shift') ||
      label.contains('Control') ||
      label.contains('Alt') ||
      label.contains('Meta') ||
      !(k.isControlPressed || k.isAltPressed || k.isMetaPressed)) {
    return null;
  }
  return [
    if (k.isControlPressed) 'ctrl',
    if (k.isShiftPressed) 'shift',
    if (k.isAltPressed) 'alt',
    if (k.isMetaPressed) 'meta',
    label.toUpperCase(),
  ].join('+');
}

bool reservedClipboardShortcut(String value) {
  final parts = value.split('+');
  final key = parts.last.toUpperCase();
  return key == 'TAB' ||
      key.startsWith('F') && int.tryParse(key.substring(1)) != null ||
      (parts.contains('meta') &&
          (RegExp(r'^[1-9]$').hasMatch(key) ||
              ['Q', 'W', 'T', 'N', 'R', 'E', ','].contains(key))) ||
      (parts.contains('alt') && RegExp(r'^[1-9]$').hasMatch(key)) ||
      (parts.contains('ctrl') &&
          (key == ',' ||
              parts.contains('shift') &&
                  ['T', 'W', 'R', 'N', 'E'].contains(key)));
}
