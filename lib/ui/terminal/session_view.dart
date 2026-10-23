import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm2/xterm.dart';

import '../../l10n/app_strings.dart';
import '../../app/settings/app_settings.dart';
import '../../app/settings/terminal_font.dart';
import '../../domain/models/session_tab.dart';
import '../../app/controllers/external_colors_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../infra/platform/local_files.dart';
import '../../app/terminal/terminal_session.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import '../sftp/sftp_pane.dart';
import '../shell/ui_state.dart';
import '../theme/app_theme.dart';
import '../widgets/context_menu.dart';
import '../widgets/modifiers.dart';
import 'connection_failure_view.dart';
import 'stable_selection.dart';
import 'terminal_accessory_bar.dart';
import 'terminal_geometry.dart';
import 'terminal_theme.dart';
import 'selection_menu.dart';
import 'server_stats_view.dart';

part 'session_view_clipboard.dart';
part 'session_view_desktop.dart';
part 'session_view_gestures.dart';
part 'session_view_status_bar.dart';

/// Вкладка сессии: терминал и контекстное меню keyboard.
class SessionView extends ConsumerStatefulWidget {
  const SessionView({super.key, required this.tab, required this.active});

  final SessionTab tab;
  final bool active;

  @override
  ConsumerState<SessionView> createState() => _SessionViewState();
}

/// Состояние экрана вкладки: поля и общие операции. Поведение разнесено
/// по mixin-ам в part-файлах: буфер обмена, выделение и жесты, меню ПК.
abstract class _SessionViewBase extends ConsumerState<SessionView> {
  final _controller = StableSelectionController();
  final _focus = FocusNode(debugLabel: 'terminal');
  final _terminalViewKey = GlobalKey<TerminalViewState>();
  final _terminalStackKey = GlobalKey();
  final _scrollController = ScrollController();
  late final _dragFix = DragSelectionFix(
    controller: _controller,
    viewKey: _terminalViewKey,
    scroll: _scrollController,
    terminal: () => _terminal,
  );

  double _paneWidth = 420;

  bool _failureDismissed = false;
  bool _showLogManually = false;

  Timer? _longPressTimer;
  Offset? _touchStartLocal;
  Offset? _touchStartGlobal;
  final Set<int> _activePointerIds = <int>{};
  double? _pinchBaseFontSize;
  int? _lastPinchFontSize;
  double _sessionFontSize = 14;
  bool? _lastRememberFontSize;

  bool _isSelecting = false;
  bool _selectionIsEmptiness = false;

  /// Выделение сейчас меняет пользователь (мышь или палец над терминалом).
  /// «Копировать при выделении» срабатывает только тогда: иначе любое
  /// уведомление контроллера (возврат в окно, перерисовка) снова клало
  /// старое выделение в буфер поверх скопированного в другой программе.
  bool _userSelecting = false;

  bool _isDraggingHandle = false;
  bool? _draggingStartHandle;
  CellOffset? _dragFixedCell;
  Offset? _dragTouchDeltaToTextPoint;

  Offset? _selectionMenuPosition;

  final _menu = GlobalKey<ContextMenuAreaState>();

  Terminal? get _terminal {
    return ref.read(tabsProvider.notifier).sessionOf(widget.tab.id)?.terminal;
  }

  TerminalGeometry? get _geometry => TerminalGeometry.of(_terminalViewKey);

  // Реализуются в mixin-ах; объявлены здесь, чтобы mixin-ы видели друг друга.
  bool _copySelection();
  Future<void> _paste();
  void _showselectionMenu(Offset position);
  void _dismissselectionMenu();
  void _onSecondaryClick(Offset position, [Offset? localPosition]);
  void _reconnect();
}

class _SessionViewState extends _SessionViewBase
    with WidgetsBindingObserver, _ClipboardActions, _PointerGestures, _DesktopMenu {
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onSelectionChanged);
    _scrollController.addListener(_onScrollChanged);
    _scrollController.addListener(_dragFix.onScroll);
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.active) {
      final session = ref.read(tabsProvider.notifier).sessionOf(widget.tab.id);

      if (session != null &&
          widget.tab.status == SessionStatus.lost &&
          session.droppedAfterReady) {
        _reconnect();
      }
    }
  }

  @override
  void didUpdateWidget(SessionView old) {
    super.didUpdateWidget(old);

    if (widget.active && !old.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focus.requestFocus();
        }
      });
    }

    // Новая попытка подключения - экран ошибки снова можно показывать.
    if (widget.tab.status == SessionStatus.connecting &&
        old.tab.status != SessionStatus.connecting) {
      _failureDismissed = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _longPressTimer?.cancel();
    _controller.removeListener(_onSelectionChanged);
    _scrollController.removeListener(_onScrollChanged);
    _scrollController.removeListener(_dragFix.onScroll);

    _dragFix.dispose();
    _scrollController.dispose();
    _controller.dispose();
    _focus.dispose();

    super.dispose();
  }

  void _onSelectionChanged() {
    if (mounted) {
      setState(() {});
    }

    if (_isDraggingHandle) {
      return;
    }

    if (!_userSelecting || !ref.read(settingsProvider).copyOnSelect) {
      return;
    }

    _copySelection();
  }

  void _onScrollChanged() {
    if (_controller.selection != null && mounted) {
      setState(() {});
    }
  }

  @override
  void _reconnect() {
    setState(() {
      _showLogManually = false;
    });

    ref.read(tabsProvider.notifier).reconnect(widget.tab.id);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.read(tabsProvider.notifier).sessionOf(widget.tab.id);

    // Только то, от чего зависит экран вкладки: иначе любая настройка
    // перестраивала бы все открытые терминалы. Размер шрифта читается в
    // _effectiveFontSize, поэтому он тоже здесь.
    final settings = ref.watch(settingsProvider.select((s) => (
          language: s.language,
          showAccessoryBar: s.showAccessoryBar,
          serverStats: s.serverStats,
          fontSize: s.terminalFontSize,
          rememberFontSize: s.rememberTerminalFontSize,
          font: s.terminalFont,
          lineHeight: s.terminalLineHeight,
        )));
    final scheme = Theme.of(context).colorScheme;
    final paneOpen =
        !widget.tab.isLocal && ref.watch(sftpPaneProvider).contains(widget.tab.id);
    final ext = ref.watch(externalColorsProvider);

    final strings = AppStrings.of(context, settings.language);

    if (session == null) {
      return const SizedBox.shrink();
    }

    final showFailure =
        !widget.tab.isLocal &&
        (_showLogManually ||
            (widget.tab.status == SessionStatus.lost &&
                session.lastFailure != null &&
                !_failureDismissed));

    final terminalView = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
        child: Actions(
          actions: {
            _PasteIntent: CallbackAction<_PasteIntent>(
              onInvoke: (_) {
                _paste();
                return null;
              },
            ),
          },
          child: TerminalView(
            session.terminal,
            key: _terminalViewKey,
            scrollController: _scrollController,
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            shortcuts: _shortcuts(),
            theme: terminalThemeFor(scheme, ext),
            textStyle: TerminalStyle(
              fontSize: _effectiveFontSize,
              height: settings.lineHeight,
              fontFamily: TerminalFont.familyOf(settings.font),
              fontFamilyFallback: TerminalFont.fallbackOf(settings.font),
            ),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            keyboardType: TextInputType.text,
            // Иначе Gboard и другие клавиатуры открываются в анонимном режиме
            // (правка в third_party/xterm2, см. PATCHES.md).
            enableIMEPersonalizedLearning: true,
            onKeyEvent: (focusNode, event) {
              if (event is KeyDownEvent) {
                if (session.ctrlModifier) {
                  if (event.logicalKey == LogicalKeyboardKey.escape) {
                    session.resetModifiers();
                    return KeyEventResult.handled;
                  }
                  final keyLabel = event.character ?? event.logicalKey.keyLabel;
                  final mapped = TerminalSession.mapToCtrlChar(keyLabel);
                  if (mapped != null) {
                    session.sendCtrlChar(mapped);
                    return KeyEventResult.handled;
                  }
                }
              }
              return KeyEventResult.ignored;
            },
            onSecondaryTapDown: (details, _) {
              _onSecondaryClick(details.globalPosition, details.localPosition);
            },
          ),
        ),
      ),
    );

    final isCompact =
        MediaQuery.sizeOf(context).width < 650 || DesktopEnv.isMobile;

    final terminalArea = ColoredBox(
      color: terminalBackgroundFor(scheme, ext),
      child: ContextMenuArea(
        key: _menu,
        onClose: () => _focus.requestFocus(),
        child: Stack(
        key: _terminalStackKey,
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
          if (_selectionMenuPosition != null)
            SelectionMenu(
              position: _selectionMenuPosition!,
              hasSelection: _controller.selection != null,
              isEmptySpace: _selectionIsEmptiness,
              selectedCharCount: _getSelectedCharCount(),
              strings: strings,
              onCopy: _copy,
              onPaste: () {
                _dismissselectionMenu();
                _paste();
              },
              onCut: _cut,
              onSelectAll: _selectAll,
              onErase: _eraseCurrentSelectionOrLine,
              onShare: _share,
              onReset: _reset,
              onClear: _clear,
              onLog: () {
                _dismissselectionMenu();

                setState(() {
                  _showLogManually = true;
                });
              },
              onReconnect: () {
                _dismissselectionMenu();
                _reconnect();
              },
              onDismiss: _dismissselectionMenu,
            ),
          // Ручки выделения - для пальца; мышью выделяют и без них.
          if (DesktopEnv.isMobile &&
              _controller.selection != null &&
              !_controller.selection!.isCollapsed) ...[
            _selectionHandle(start: true),
            _selectionHandle(start: false),
          ],
        ],
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
          child: isCompact
              ? IndexedStack(
                  index: paneOpen ? 1 : 0,
                  children: [
                    terminalArea,
                    SftpPane(
                      tab: widget.tab,
                      active: widget.active && paneOpen,
                    ),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: terminalArea),
                    if (paneOpen) ...[
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: (details) {
                            setState(() {
                              final max =
                                  MediaQuery.sizeOf(context).width * 0.7;

                              _paneWidth = (_paneWidth - details.delta.dx)
                                  .clamp(260, max < 260 ? 260 : max)
                                  .toDouble();
                            });
                          },
                          child: Container(
                            width: 5,
                            color: scheme.outlineVariant.withValues(alpha: 0.5),
                          ),
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
        if (DesktopEnv.isMobile &&
            settings.showAccessoryBar &&
            (!isCompact || !paneOpen))
          TerminalAccessoryBar(
            session: session,
            focusNode: _focus,
            language: settings.language,
          ),
        _StatusBar(
          tab: widget.tab,
          session: session,
          active: widget.active,
          showStats: settings.serverStats,
          onToggleStats: () => ref
              .read(settingsProvider.notifier)
              .setServerStats(!settings.serverStats),
          serverVersion: session.serverVersion,
          filesOpen: paneOpen,
          onToggleFiles: widget.tab.isLocal
              ? null
              : () => ref.read(sftpPaneProvider.notifier).toggle(widget.tab.id),
          onReconnect: _reconnect,
          strings: strings,
        ),
      ],
    );
  }
}

class _PasteIntent extends Intent {
  const _PasteIntent();
}
