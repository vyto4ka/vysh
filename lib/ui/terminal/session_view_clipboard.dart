part of 'session_view.dart';

/// Буфер обмена и команды меню выделения: копировать, вырезать,
/// вставить (с подтверждением), выделить ввод, поделиться, ^C, ^L.
mixin _ClipboardActions on _SessionViewBase {
  @override
  bool _copySelection() {
    final selection = _controller.selection;
    final terminal = _terminal;

    if (selection == null || terminal == null) {
      return false;
    }

    final text = terminal.buffer.getText(selection);

    if (text.isEmpty) {
      return false;
    }

    Clipboard.setData(ClipboardData(text: text));

    return true;
  }

  int _getSelectedCharCount() {
    final selection = _controller.selection;
    final terminal = _terminal;

    if (selection == null || terminal == null) {
      return 0;
    }

    return terminal.buffer.getText(selection).length;
  }

  void _showToast(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).removeCurrentSnackBar();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: DesktopEnv.isMobile
            ? const EdgeInsets.only(bottom: 40, left: 20, right: 20)
            : null,
      ),
    );
  }

  void _copy() {
    final selection = _controller.selection;
    final terminal = _terminal;
    final strings = AppStrings.of(
      context,
      ref.read(settingsProvider).language,
    );

    if (selection == null || terminal == null) {
      _showToast(strings.nothingToCopy);
      _dismissselectionMenu();
      return;
    }

    final text = terminal.buffer.getText(selection);

    if (text.isEmpty) {
      _showToast(strings.nothingToCopy);
      _dismissselectionMenu();
      return;
    }

    Clipboard.setData(ClipboardData(text: text));

    _controller.clearSelection();
    _dismissselectionMenu();
  }

  void _cut() {
    final selection = _controller.selection;
    final terminal = _terminal;
    final strings = AppStrings.of(
      context,
      ref.read(settingsProvider).language,
    );

    if (selection == null || terminal == null) {
      _showToast(strings.nothingToCopy);
      _dismissselectionMenu();
      return;
    }

    final text = terminal.buffer.getText(selection);

    if (text.isEmpty) {
      _showToast(strings.nothingToCopy);
      _dismissselectionMenu();
      return;
    }

    Clipboard.setData(ClipboardData(text: text));

    // Стираем только то, что пользователь сам набрал в конце строки ввода.
    // Выделенный вывод программ или середину команды не трогаем: Backspace
    // по длине выделения стёр бы совсем другие символы. Тогда «Вырезать»
    // работает как «Копировать».
    final typed = ref
            .read(tabsProvider.notifier)
            .sessionOf(widget.tab.id)
            ?.clientTypedCommand ??
        '';
    if (text.isNotEmpty && !text.contains(RegExp(r'[\r\n]')) && typed.endsWith(text)) {
      terminal.textInput(String.fromCharCodes(List.filled(text.length, 0x7f)));
    }

    _controller.clearSelection();
    _dismissselectionMenu();
  }

  void _eraseCurrentSelectionOrLine() {
    final session = ref.read(tabsProvider.notifier).sessionOf(widget.tab.id);

    final terminal = session?.terminal;

    if (session == null || terminal == null) {
      _dismissselectionMenu();
      return;
    }

    _controller.clearSelection();

    // Ctrl+U очищает текущий пользовательский ввод shell.
    terminal.textInput('\x15');

    _dismissselectionMenu();

    if (mounted) {
      setState(() {});
    }
  }

  @override
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    var text = data?.text;

    if (text == null || text.isEmpty || !mounted) {
      return;
    }

    // Проверяем ровно то, что уйдёт в терминал: любой CR или LF.
    final plan = PastePlan(text);
    var toPaste = plan.normalized;

    if (plan.hasLineBreaks && ref.read(settingsProvider).confirmMultilinePaste) {
      final ok = await _confirmPaste(plan);

      if (ok == null) {
        _focus.requestFocus();
        return;
      }

      if (ok == false) {
        toPaste = plan.singleLine;
      }
    }

    _terminal?.paste(toPaste);
    _controller.clearSelection();
    _focus.requestFocus();

    if (!mounted) {
      return;
    }

    // На ПК вставку и так видно, уведомление только на телефоне.
    if (!DesktopEnv.isMobile) return;

    final strings = AppStrings.of(
      context,
      ref.read(settingsProvider).language,
    );

    _showToast(strings.pastedToast);
  }

  /// true - вставить как есть, false - одной строкой, null - отмена.
  Future<bool?> _confirmPaste(PastePlan plan) {
    final strings = AppStrings.of(
      context,
      ref.read(settingsProvider).language,
    );
    final lines = plan.visibleLines;
    final trailing = plan.onlyTrailingEnter;

    return showDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;

        final preview =
            lines.take(12).join('\n') + (lines.length > 12 ? '\n…' : '');

        return AlertDialog(
          icon: Icon(Icons.content_paste_go, color: scheme.primary),
          title: Text(trailing
              ? strings.trailingEnterTitle
              : strings.multilineTitle(lines.length)),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(trailing ? strings.trailingEnterDesc : strings.multilineDesc),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(preview, style: monoStyle(context, size: 12.5)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(strings.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(strings.pasteSingleLine),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: Text(strings.pasteConfirm),
            ),
          ],
        );
      },
    );
  }

  /// Выделяет только клиентский ввод пользователя.
  ///
  /// Никакого поиска текста в терминальном буфере нет.
  /// Prompt, вывод shell и ранее выполненные команды не выделяются.
  void _selectAll() {
    final session = ref.read(tabsProvider.notifier).sessionOf(widget.tab.id);

    final terminal = session?.terminal;

    if (session == null || terminal == null) {
      _dismissselectionMenu();
      return;
    }

    final clientTypedCommand = session.clientTypedCommand;

    if (clientTypedCommand.isEmpty) {
      _controller.clearSelection();
      _selectionIsEmptiness = false;
      _dismissselectionMenu();
      return;
    }

    final buffer = terminal.buffer;
    final lines = buffer.lines;

    if (lines.length == 0) {
      _controller.clearSelection();
      _selectionIsEmptiness = false;
      _dismissselectionMenu();
      return;
    }

    final cursorY = buffer.absoluteCursorY.clamp(0, lines.length - 1).toInt();

    final cursorX = buffer.cursorX;

    // Клиентский ввод находится непосредственно перед курсором.
    // Текст prompt и вывод терминала здесь не анализируются.
    final startX = (cursorX - clientTypedCommand.length)
        .clamp(0, cursorX)
        .toInt();

    if (startX >= cursorX) {
      _controller.clearSelection();
      _selectionIsEmptiness = false;
      _dismissselectionMenu();
      return;
    }

    _controller.setSelection(
      buffer.createAnchor(startX, cursorY),
      buffer.createAnchor(cursorX, cursorY),
    );

    _selectionIsEmptiness = false;
    _dismissselectionMenu();
  }

  void _share() {
    final selection = _controller.selection;
    final terminal = _terminal;

    final strings = AppStrings.of(
      context,
      ref.read(settingsProvider).language,
    );

    final text = selection != null && terminal != null
        ? terminal.buffer.getText(selection)
        : '';

    if (text.isNotEmpty) {
      // Системное «Поделиться»; где его нет - хотя бы в буфер обмена.
      LocalFiles.shareText(text).then((shared) {
        if (!shared) Clipboard.setData(ClipboardData(text: text));
      });
    } else {
      _showToast(strings.nothingToCopy);
    }

    _dismissselectionMenu();
  }

  void _reset() {
    final session = ref.read(tabsProvider.notifier).sessionOf(widget.tab.id);

    final strings = AppStrings.of(
      context,
      ref.read(settingsProvider).language,
    );

    session?.sendCtrlChar('C');

    _controller.clearSelection();
    _showToast(strings.resetToast);
    _dismissselectionMenu();
  }

  void _clear() {
    final terminal = _terminal;

    final strings = AppStrings.of(
      context,
      ref.read(settingsProvider).language,
    );

    terminal?.keyInput(TerminalKey.keyL, ctrl: true);

    _controller.clearSelection();
    _showToast(strings.clearToast);
    _dismissselectionMenu();
  }
}
