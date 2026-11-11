import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm2/xterm.dart';
import '../../app/settings/app_settings.dart';
import 'clipboard_shortcut.dart';

/// Shared by SSH, local sessions and detached windows, including select-all.
Map<ShortcutActivator, Intent> terminalShortcuts(
  AppSettings settings, {
  required Intent pasteIntent,
}) => {
  for (final e in defaultTerminalShortcuts.entries)
    if (e.value is! PasteTextIntent &&
        (!settings.customClipboard || e.value is! CopySelectionTextIntent))
      e.key: e.value,
  if (settings.customClipboard) ...{
    ?clipboardActivator(settings.copyShortcut): CopySelectionTextIntent.copy,
    ?clipboardActivator(settings.pasteShortcut): pasteIntent,
  } else ...{
    const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
        pasteIntent,
    const SingleActivator(LogicalKeyboardKey.insert, shift: true): pasteIntent,
    if (settings.ctrlVPaste)
      const SingleActivator(LogicalKeyboardKey.keyV, control: true):
          pasteIntent,
    if (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS)
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true): pasteIntent,
  },
};
