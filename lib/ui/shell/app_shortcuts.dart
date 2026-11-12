import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../../infra/platform/capabilities.dart';

enum AppCommand {
  newTab,
  closeTab,
  nextTab,
  previousTab,
  reconnect,
  newHost,
  settings,
  files,
  tab1,
  tab2,
  tab3,
  tab4,
  tab5,
  tab6,
  tab7,
  tab8,
  tab9,
}

/// Both the shell and the terminal recognize these keys. A global hardware
/// handler alone does not stop FocusManager's handler from forwarding a key.
Map<ShortcutActivator, AppCommand> applicationShortcuts({bool? macOS}) => {
  const SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true):
      AppCommand.newTab,
  const SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true):
      AppCommand.closeTab,
  const SingleActivator(LogicalKeyboardKey.tab, control: true):
      AppCommand.nextTab,
  const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
      AppCommand.previousTab,
  const SingleActivator(LogicalKeyboardKey.keyR, control: true, shift: true):
      AppCommand.reconnect,
  const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true):
      AppCommand.newHost,
  const SingleActivator(LogicalKeyboardKey.comma, control: true):
      AppCommand.settings,
  const SingleActivator(LogicalKeyboardKey.keyE, control: true, shift: true):
      AppCommand.files,
  if (macOS ?? PlatformCapabilities.isMacOS) ...{
    const SingleActivator(LogicalKeyboardKey.keyT, meta: true):
        AppCommand.newTab,
    const SingleActivator(LogicalKeyboardKey.keyW, meta: true):
        AppCommand.closeTab,
    const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
        AppCommand.reconnect,
    const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
        AppCommand.newHost,
    const SingleActivator(LogicalKeyboardKey.comma, meta: true):
        AppCommand.settings,
    const SingleActivator(LogicalKeyboardKey.keyE, meta: true):
        AppCommand.files,
    for (var i = 0; i < _digits.length; i++)
      SingleActivator(_digits[i], meta: true):
          AppCommand.values[AppCommand.tab1.index + i],
  },
  for (var i = 0; i < _digits.length; i++)
    SingleActivator(_digits[i], alt: true):
        AppCommand.values[AppCommand.tab1.index + i],
};
const _digits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];
