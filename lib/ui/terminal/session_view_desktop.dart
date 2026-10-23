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
    _menu.currentState?.open(globalPosition, [
      menuItem(
        ru ? 'Копировать' : 'Copy',
        icon: Icons.content_copy,
        shortcut: mac ? Keys.macCopy : Keys.copy,
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
        shortcut: mac ? Keys.macPaste : Keys.paste,
        onPressed: _paste,
      ),
      menuDivider(),
      if (!widget.tab.isLocal)
        menuItem(
          ru ? 'Файлы (SFTP)' : 'Files (SFTP)',
          icon: Icons.folder_outlined,
          shortcut: mac ? Keys.macFiles : Keys.files,
          onPressed: () => ref.read(sftpPaneProvider.notifier).toggle(widget.tab.id),
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
    return <ShortcutActivator, Intent>{
      for (final entry in defaultTerminalShortcuts.entries)
        if (entry.value is! PasteTextIntent) entry.key: entry.value,
      const SingleActivator(
        LogicalKeyboardKey.keyV,
        control: true,
        shift: true,
      ): const _PasteIntent(),
      const SingleActivator(LogicalKeyboardKey.insert, shift: true):
          const _PasteIntent(),
      if (ref.read(settingsProvider).ctrlVPaste)
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            const _PasteIntent(),
      // macOS: привычная вставка через ⌘V.
      if (PlatformCapabilities.isMacOS)
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            const _PasteIntent(),
    };
  }
}
