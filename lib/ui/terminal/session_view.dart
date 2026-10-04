import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/models/session_tab.dart';
import '../../domain/services/external_colors_controller.dart';
import '../../domain/services/settings_controller.dart';
import '../../domain/services/tabs_controller.dart';
import '../shell/ui_state.dart';
import '../sftp/sftp_pane.dart';
import '../theme/app_theme.dart';
import '../widgets/context_menu.dart';
import 'connection_failure_view.dart';
import 'terminal_theme.dart';

/// Вкладка сессии: терминал + строка состояния.
class SessionView extends ConsumerStatefulWidget {
  const SessionView({super.key, required this.tab, required this.active});

  final SessionTab tab;
  final bool active;

  @override
  ConsumerState<SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends ConsumerState<SessionView> {
  final _controller = TerminalController();
  final _focus = FocusNode(debugLabel: 'terminal');
  double _paneWidth = 420;
  bool _failureDismissed = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(SessionView old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
    // Новая попытка подключения — экран ошибки снова можно показывать.
    if (widget.tab.status == SessionStatus.connecting &&
        old.tab.status != SessionStatus.connecting) {
      _failureDismissed = false;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onSelectionChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Terminal? get _terminal =>
      ref.read(tabsProvider.notifier).sessionOf(widget.tab.id)?.terminal;

  void _onSelectionChanged() {
    if (!ref.read(settingsProvider).copyOnSelect) return;
    _copySelection();
  }

  bool _copySelection() {
    final sel = _controller.selection;
    final terminal = _terminal;
    if (sel == null || terminal == null) return false;
    final text = terminal.buffer.getText(sel);
    if (text.isEmpty) return false;
    Clipboard.setData(ClipboardData(text: text));
    return true;
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    var text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;

    final lines = text.trimRight().split(RegExp(r'\r?\n'));
    if (lines.length > 1 && ref.read(settingsProvider).confirmMultilinePaste) {
      final ok = await _confirmPaste(lines);
      if (ok == null) {
        _focus.requestFocus();
        return;
      }
      if (ok == false) text = lines.join(' '); // «одной строкой»
    }
    _terminal?.paste(text);
    _controller.clearSelection();
    _focus.requestFocus();
  }

  /// true — вставить как есть, false — одной строкой, null — отмена.
  Future<bool?> _confirmPaste(List<String> lines) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final preview = lines.take(12).join('\n') + (lines.length > 12 ? '\n…' : '');
        return AlertDialog(
          icon: Icon(Icons.content_paste_go, color: scheme.primary),
          title: Text('Вставить ${lines.length} строк?'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Каждая строка выполнится как отдельная команда.'),
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
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Одной строкой'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Вставить'),
            ),
          ],
        );
      },
    );
  }

  void _onSecondaryClick(Offset position) {
    final action = ref.read(settingsProvider).rightClick;
    // Shift + правый клик всегда открывает меню.
    if (HardwareKeyboard.instance.isShiftPressed || action == RightClickAction.menu) {
      _showMenu(position);
      return;
    }
    if (action == RightClickAction.smart && _controller.selection != null) {
      _copySelection();
      _controller.clearSelection();
      return;
    }
    _paste();
  }

  Map<ShortcutActivator, Intent> _shortcuts(bool ctrlV) {
    final map = <ShortcutActivator, Intent>{
      for (final e in defaultTerminalShortcuts.entries)
        if (e.value is! PasteTextIntent) e.key: e.value,
      const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true): const _PasteIntent(),
      const SingleActivator(LogicalKeyboardKey.insert, shift: true): const _PasteIntent(),
    };
    if (ctrlV) {
      map[const SingleActivator(LogicalKeyboardKey.keyV, control: true)] = const _PasteIntent();
    }
    return map;
  }

  final _menu = GlobalKey<ContextMenuAreaState>();

  void _showMenu(Offset position) {
    final hasSelection = _controller.selection != null;
    _menu.currentState?.open(position, [
      menuItem('Копировать',
          icon: Icons.content_copy,
          shortcut: Keys.copy,
          onPressed: hasSelection
              ? () {
                  _copySelection();
                  _controller.clearSelection();
                }
              : null),
      menuItem('Вставить', icon: Icons.content_paste, shortcut: Keys.paste, onPressed: _paste),
      menuDivider(),
      menuItem('Файлы (SFTP)',
          icon: Icons.folder_outlined,
          shortcut: Keys.files,
          onPressed: () => ref.read(sftpPaneProvider.notifier).toggle(widget.tab.id)),
      menuItem('Журнал и диагностика',
          icon: Icons.receipt_long_outlined,
          onPressed: () => setState(() => _showLogManually = true)),
      menuItem('Переподключить',
          icon: Icons.refresh, shortcut: Keys.reconnect, onPressed: _reconnect),
    ]);
  }

  bool _showLogManually = false;

  void _reconnect() {
    setState(() => _showLogManually = false);
    ref.read(tabsProvider.notifier).reconnect(widget.tab.id);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.read(tabsProvider.notifier).sessionOf(widget.tab.id);
    final settings = ref.watch(settingsProvider);
    final scheme = Theme.of(context).colorScheme;
    final paneOpen = ref.watch(sftpPaneProvider).contains(widget.tab.id);
    final ext = ref.watch(externalColorsProvider);

    if (session == null) return const SizedBox.shrink();

    final showFailure = _showLogManually ||
        (widget.tab.status == SessionStatus.lost &&
            session.lastFailure != null &&
            !_failureDismissed);

    final terminalView = Listener(
      // Средняя кнопка — вставка (если включено).
      onPointerDown: (e) {
        if (settings.middleClickPaste && (e.buttons & kMiddleMouseButton) != 0) _paste();
      },
      child: Actions(
        actions: {
          _PasteIntent: CallbackAction<_PasteIntent>(onInvoke: (_) {
            _paste();
            return null;
          }),
        },
        child: TerminalView(
          session.terminal,
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          shortcuts: _shortcuts(settings.ctrlVPaste),
          theme: terminalThemeFor(scheme, ext),
          textStyle: TerminalStyle(
            fontSize: settings.terminalFontSize,
            fontFamily: monoFontFamily,
            fontFamilyFallback: monoFontFallback,
          ),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          onSecondaryTapDown: (details, _) => _onSecondaryClick(details.globalPosition),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 2,
          child: widget.tab.status == SessionStatus.connecting
              ? const LinearProgressIndicator(minHeight: 2)
              : null,
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ColoredBox(
                  color: terminalBackgroundFor(scheme, ext),
                  child: ContextMenuArea(
                    key: _menu,
                    onClose: () => _focus.requestFocus(),
                    child: Stack(
                    children: [
                      Positioned.fill(child: terminalView),
                      if (showFailure)
                        Positioned.fill(
                          child: ConnectionFailureView(
                            session: session,
                            onReconnect: _reconnect,
                            onDismiss: () {
                              setState(() {
                                _failureDismissed = true;
                                _showLogManually = false;
                              });
                              _focus.requestFocus();
                            },
                          ),
                        ),
                    ],
                  ),
                  ),
                ),
              ),
              if (paneOpen) ...[
                MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) => setState(() {
                      final max = MediaQuery.sizeOf(context).width * 0.7;
                      _paneWidth =
                          (_paneWidth - d.delta.dx).clamp(260, max < 260 ? 260 : max).toDouble();
                    }),
                    child: Container(width: 5, color: scheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                ),
                SizedBox(
                  width: _paneWidth,
                  child: SftpPane(tab: widget.tab, active: widget.active),
                ),
              ],
            ],
          ),
        ),
        _StatusBar(
          tab: widget.tab,
          serverVersion: session.serverVersion,
          filesOpen: paneOpen,
          onToggleFiles: () => ref.read(sftpPaneProvider.notifier).toggle(widget.tab.id),
          onReconnect: _reconnect,
        ),
      ],
    );
  }
}

class _PasteIntent extends Intent {
  const _PasteIntent();
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.tab,
    required this.serverVersion,
    required this.onReconnect,
    required this.filesOpen,
    required this.onToggleFiles,
  });

  final SessionTab tab;
  final String? serverVersion;
  final VoidCallback onReconnect;
  final bool filesOpen;
  final VoidCallback onToggleFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final (status, color) = switch (tab.status) {
      SessionStatus.connecting => ('Подключение…', scheme.tertiary),
      SessionStatus.ready => ('Подключено', Colors.green.shade500),
      SessionStatus.lost => ('Нет соединения', scheme.error),
      SessionStatus.closed => ('Сессия завершена', scheme.outline),
    };

    return Container(
      height: 28,
      color: scheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(status, style: style),
          const SizedBox(width: 16),
          Text(tab.host.displayAddress, style: style),
          const SizedBox(width: 16),
          // Expanded, а не Flexible + Spacer: иначе они делят место пополам
          // и кнопки справа уезжают в середину широкого окна.
          Expanded(
            child: serverVersion != null && tab.status == SessionStatus.ready
                ? Text(serverVersion!,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: style?.copyWith(color: scheme.outline))
                : const SizedBox.shrink(),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              textStyle: theme.textTheme.bodySmall,
              foregroundColor: filesOpen ? scheme.primary : scheme.onSurfaceVariant,
            ),
            onPressed: onToggleFiles,
            icon: Icon(filesOpen ? Icons.folder_open : Icons.folder_outlined, size: 14),
            label: const Text('Файлы  Ctrl+Shift+E'),
          ),
          if (tab.status != SessionStatus.connecting)
            TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.bodySmall,
              ),
              onPressed: onReconnect,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Переподключить'),
            ),
        ],
      ),
    );
  }
}
