part of 'session_view.dart';

/// ПК: контекстное меню, действие правого клика и сочетания клавиш.
mixin _DesktopMenu on _SessionViewBase {
  /// Контекстное меню на ПК: обычное меню M3, а не телефонная плашка.
  void _showDesktopMenu(Offset globalPosition) {
    final ru = AppStrings.of(
      context,
      ref.read(settingsProvider).language,
    ).isRussian;
    final mac = PlatformCapabilities.isMacOS;
    final hasSelection = _controller.selection != null;
    final clipboard = ref.read(settingsProvider);
    _menu.currentState?.open(globalPosition, [
      menuItem(
        ru ? 'Копировать' : 'Copy',
        icon: Icons.content_copy,
        shortcut: clipboard.customClipboard
            ? clipboardActivator(clipboard.copyShortcut)
            : mac
            ? Keys.macCopy
            : Keys.copy,
        onPressed: hasSelection
            ? () {
                _copySelection();
                _controller.clearSelection();
              }
            : null,
      ),
      menuItem(
        ru ? 'Вставить' : 'Paste',
        icon: Icons.content_paste,
        shortcut: clipboard.customClipboard
            ? clipboardActivator(clipboard.pasteShortcut)
            : mac
            ? Keys.macPaste
            : Keys.paste,
        onPressed: _paste,
      ),
      menuDivider(),
      menuItem(
        widget.tab.isLocal
            ? (ru ? 'Файлы' : 'Files')
            : (ru ? 'Файлы (SFTP)' : 'Files (SFTP)'),
        icon: Icons.folder_outlined,
        shortcut: mac ? Keys.macFiles : Keys.files,
        onPressed: () =>
            ref.read(sftpPaneProvider.notifier).toggle(widget.tab.id),
      ),
      if (!widget.tab.isLocal)
        menuItem(
          ru ? 'Журнал и диагностика' : 'Log and diagnostics',
          icon: Icons.receipt_long_outlined,
          onPressed: () => setState(() => _showLogManually = true),
        ),
      menuItem(
        ru ? 'Переподключить' : 'Reconnect',
        icon: Icons.refresh,
        shortcut: mac ? Keys.macReconnect : Keys.reconnect,
        onPressed: _reconnect,
      ),
    ]);
  }

  @override
  void _onSecondaryClick(Offset position, [Offset? localPosition]) {
    final action = ref.read(settingsProvider).rightClick;

    if (Modifiers.instance.shift || action == RightClickAction.menu) {
      if (DesktopEnv.isDesktop) {
        _showDesktopMenu(position);
      } else {
        _showselectionMenu(localPosition ?? position);
      }
      return;
    }

    if (action == RightClickAction.smart && _controller.selection != null) {
      _copySelection();
      _controller.clearSelection();
      return;
    }

    _paste();
  }

  Map<ShortcutActivator, Intent> _shortcuts() {
    return terminalShortcuts(
      ref.read(settingsProvider),
      pasteIntent: const _PasteIntent(),
    );
  }
}
