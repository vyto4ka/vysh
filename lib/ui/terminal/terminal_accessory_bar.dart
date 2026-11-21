import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import '../../app/settings/app_settings.dart';
import '../../l10n/app_strings.dart';
import '../../app/terminal/terminal_session.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import '../motion/smooth_scroll.dart';
import '../theme/app_theme.dart';

/// Однострочная панель горячих клавиш терминала для мобильных устройств.
/// Размещается над клавиатурой:
/// - Основная строка: ESC, TAB, CTRL, ALT, стрелки ↑ ↓ ← → и кнопка «Расширенной панели».
/// - Расширенная панель: S-TAB, /, -, ~, |, Home, End, PgUp, PgDn, ^U, Backspace, ^D, ^Z.
class TerminalAccessoryBar extends StatefulWidget {
  const TerminalAccessoryBar({
    super.key,
    required this.session,
    required this.focusNode,
    this.onToggleFiles,
    this.filesOpen = false,
    this.language = AppLanguage.auto,
  });

  final TerminalSession session;
  final FocusNode focusNode;
  final VoidCallback? onToggleFiles;
  final bool filesOpen;
  final AppLanguage language;

  @override
  State<TerminalAccessoryBar> createState() => _TerminalAccessoryBarState();
}

class _TerminalAccessoryBarState extends State<TerminalAccessoryBar> {
  bool _isExpanded = false;
  final _extScroll = ScrollController();
  final _mainScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.session.onModifiersChanged = _onModifiersChanged;
  }

  @override
  void didUpdateWidget(covariant TerminalAccessoryBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      if (oldWidget.session.onModifiersChanged == _onModifiersChanged) {
        oldWidget.session.onModifiersChanged = null;
      }
      widget.session.onModifiersChanged = _onModifiersChanged;
    }
  }

  @override
  void dispose() {
    if (widget.session.onModifiersChanged == _onModifiersChanged) {
      widget.session.onModifiersChanged = null;
    }
    _extScroll.dispose();
    _mainScroll.dispose();
    super.dispose();
  }

  void _onModifiersChanged() {
    if (mounted) setState(() {});
  }

  void _emitKey(
    TerminalKey key, {
    required bool ctrl,
    required bool alt,
    bool shift = false,
    TerminalKeyEventType type = TerminalKeyEventType.press,
  }) {
    if (alt && !ctrl && !shift && key == TerminalKey.tab) {
      if (type != TerminalKeyEventType.release) {
        widget.session.terminal.textInput('\x1b\t');
      }
      return;
    }
    widget.session.terminal.keyInput(
      key,
      shift: shift,
      ctrl: ctrl,
      alt: alt,
      type: type,
    );
  }

  void _sendKey(TerminalKey key, {bool shift = false}) {
    HapticFeedback.lightImpact();
    final ctrl = widget.session.ctrlModifier;
    final alt = widget.session.altModifier;
    // Сбрасываем модификаторы ДО keyInput: иначе terminal.onOutput увидит
    // ещё активный altModifier и добавит второй ESC (\x1b\x1b...).
    widget.session.resetModifiers();
    _emitKey(key, ctrl: ctrl, alt: alt, shift: shift);
    _refocus();
  }

  void _sendText(String text) {
    HapticFeedback.lightImpact();
    final ctrl = widget.session.ctrlModifier;
    if (ctrl) {
      final mapped = TerminalSession.mapToCtrlChar(text);
      if (mapped != null) {
        widget.session.sendCtrlChar(mapped);
        _refocus();
        return;
      }
      widget.session.resetModifiers();
    }
    widget.session.terminal.textInput(text);
    _refocus();
  }

  void _refocus() {
    if (!widget.focusNode.hasFocus) {
      widget.focusNode.requestFocus();
    }
  }

  void _showCtrlMenu(BuildContext context) {
    HapticFeedback.selectionClick();
    final scheme = Theme.of(context).colorScheme;
    final strings = AppStrings.of(context, widget.language);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: scheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Text(
                  strings.ctrlQuickTitle,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Divider(height: 12),
              _ctrlMenuItem(
                ctx,
                'Ctrl+C',
                strings.ctrlCSigint,
                () => widget.session.sendCtrlChar('C'),
              ),
              _ctrlMenuItem(
                ctx,
                'Ctrl+U',
                strings.isRu ? 'Стереть строку ввода' : 'Erase input line',
                () => widget.session.sendCtrlChar('U'),
              ),
              _ctrlMenuItem(
                ctx,
                'Ctrl+D',
                strings.ctrlDEof,
                () => widget.session.sendCtrlChar('D'),
              ),
              _ctrlMenuItem(
                ctx,
                'Ctrl+Z',
                strings.ctrlZSuspend,
                () => widget.session.sendCtrlChar('Z'),
              ),
              _ctrlMenuItem(
                ctx,
                'Ctrl+L',
                strings.ctrlLClear,
                () => widget.session.sendCtrlChar('L'),
              ),
              _ctrlMenuItem(
                ctx,
                'Ctrl+A',
                strings.ctrlABeginning,
                () => widget.session.sendCtrlChar('A'),
              ),
              _ctrlMenuItem(
                ctx,
                'Ctrl+E',
                strings.ctrlEEnd,
                () => widget.session.sendCtrlChar('E'),
              ),
              _ctrlMenuItem(
                ctx,
                'Ctrl+R',
                strings.ctrlRSearch,
                () => widget.session.sendCtrlChar('R'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ctrlMenuItem(
    BuildContext ctx,
    String shortcut,
    String desc,
    VoidCallback onTap,
  ) {
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      leading: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(ctx).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          shortcut,
          style: monoStyle(
            ctx,
            size: 12.5,
            color: Theme.of(ctx).colorScheme.onPrimaryContainer,
          ).copyWith(fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(desc, style: const TextStyle(fontSize: 13.5)),
      onTap: () {
        Navigator.pop(ctx);
        onTap();
      },
    );
  }

  Widget _repeatableChip({
    String? label,
    IconData? icon,
    required String semanticLabel,
    required TerminalKey terminalKey,
  }) {
    return _KeyChip(
      label: label,
      icon: icon,
      semanticLabel: semanticLabel,
      repeatable: true,
      onTap: () => _sendKey(terminalKey),
      onRepeatStart: () {
        HapticFeedback.lightImpact();
        final ctrl = widget.session.ctrlModifier;
        final alt = widget.session.altModifier;
        widget.session.resetModifiers();
        _emitKey(
          terminalKey,
          ctrl: ctrl,
          alt: alt,
          type: TerminalKeyEventType.press,
        );
        return (ctrl: ctrl, alt: alt);
      },
      onRepeatTick: (mods) {
        _emitKey(
          terminalKey,
          ctrl: mods.ctrl,
          alt: mods.alt,
          type: TerminalKeyEventType.repeat,
        );
      },
      onRepeatEnd: (mods) {
        _emitKey(
          terminalKey,
          ctrl: mods.ctrl,
          alt: mods.alt,
          type: TerminalKeyEventType.release,
        );
        _refocus();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = AppStrings.of(context, widget.language);
    final ctrlActive = widget.session.ctrlModifier;
    final altActive = widget.session.altModifier;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.35),
            width: 0.7,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Расширенная панель (скрыта по умолчанию, открывается по кнопке ...)
          ExpandSection(
            expanded: _isExpanded,
            spring: AppMotion.spatialFast,
            child: Container(
              height: 36,
              decoration: BoxDecoration(
                color: scheme.surfaceContainer.withValues(alpha: 0.6),
                border: Border(
                  bottom: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: 0.2),
                    width: 0.7,
                  ),
                ),
              ),
              child: HorizontalWheelScroll(
                controller: _extScroll,
                child: SingleChildScrollView(
                  controller: _extScroll,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _KeyChip(
                        label: 'S-TAB',
                        semanticLabel: 'Shift+Tab',
                        onTap: () => _sendKey(TerminalKey.tab, shift: true),
                      ),
                      _KeyChip(label: '/', onTap: () => _sendText('/')),
                      _KeyChip(label: '-', onTap: () => _sendText('-')),
                      _KeyChip(label: '~', onTap: () => _sendText('~')),
                      _KeyChip(label: '|', onTap: () => _sendText('|')),
                      const _Divider(),
                      _KeyChip(
                        label: 'HOME',
                        onTap: () => _sendKey(TerminalKey.home),
                      ),
                      _KeyChip(
                        label: 'END',
                        onTap: () => _sendKey(TerminalKey.end),
                      ),
                      _repeatableChip(
                        label: 'PGUP',
                        semanticLabel: 'Page Up',
                        terminalKey: TerminalKey.pageUp,
                      ),
                      _repeatableChip(
                        label: 'PGDN',
                        semanticLabel: 'Page Down',
                        terminalKey: TerminalKey.pageDown,
                      ),
                      const _Divider(),
                      _KeyChip(
                        label: '^U',
                        semanticLabel: strings.isRu
                            ? 'Стереть строку (^U)'
                            : 'Erase line (^U)',
                        onTap: () => widget.session.sendCtrlChar('U'),
                      ),
                      _repeatableChip(
                        icon: Icons.backspace_outlined,
                        semanticLabel: 'Backspace',
                        terminalKey: TerminalKey.backspace,
                      ),
                      _KeyChip(
                        label: '^D',
                        semanticLabel: strings.eofExit,
                        onTap: () => widget.session.sendCtrlChar('D'),
                      ),
                      _KeyChip(
                        label: '^Z',
                        semanticLabel: strings.isRu
                            ? 'Фон (SIGTSTP)'
                            : 'Background (SIGTSTP)',
                        onTap: () => widget.session.sendCtrlChar('Z'),
                      ),
                      if (widget.onToggleFiles != null) ...[
                        const _Divider(),
                        _KeyChip(
                          icon: widget.filesOpen
                              ? Icons.terminal_rounded
                              : Icons.folder_outlined,
                          label: 'SFTP',
                          semanticLabel: widget.filesOpen
                              ? strings.console
                              : strings.sftpPaneTitle,
                          active: widget.filesOpen,
                          onTap: widget.onToggleFiles!,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Основная однострочная панель: ESC, TAB, CTRL, ALT, стрелки и переключатель
          SizedBox(
            height: 38,
            child: HorizontalWheelScroll(
              controller: _mainScroll,
              child: SingleChildScrollView(
                controller: _mainScroll,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _KeyChip(
                      label: 'ESC',
                      onTap: () => _sendKey(TerminalKey.escape),
                    ),
                    _KeyChip(
                      label: 'TAB',
                      semanticLabel: 'Tab',
                      onTap: () => _sendKey(TerminalKey.tab),
                      onLongPress: () => _sendKey(TerminalKey.tab, shift: true),
                    ),
                    _KeyChip(
                      label: 'CTRL',
                      active: ctrlActive,
                      semanticLabel: strings.isRu
                          ? 'CTRL (нажмите, затем нужную клавишу)'
                          : 'CTRL (tap, then press key)',
                      onTap: () {
                        HapticFeedback.selectionClick();
                        widget.session.toggleCtrl();
                        _refocus();
                      },
                      onLongPress: () => _showCtrlMenu(context),
                    ),
                    _KeyChip(
                      label: 'ALT',
                      active: altActive,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        widget.session.toggleAlt();
                        _refocus();
                      },
                    ),
                    const _Divider(),
                    _repeatableChip(
                      icon: Icons.arrow_upward,
                      semanticLabel: strings.isRu ? 'Вверх' : 'Up',
                      terminalKey: TerminalKey.arrowUp,
                    ),
                    _repeatableChip(
                      icon: Icons.arrow_downward,
                      semanticLabel: strings.isRu ? 'Вниз' : 'Down',
                      terminalKey: TerminalKey.arrowDown,
                    ),
                    _repeatableChip(
                      icon: Icons.arrow_back,
                      semanticLabel: strings.isRu ? 'Влево' : 'Left',
                      terminalKey: TerminalKey.arrowLeft,
                    ),
                    _repeatableChip(
                      icon: Icons.arrow_forward,
                      semanticLabel: strings.isRu ? 'Вправо' : 'Right',
                      terminalKey: TerminalKey.arrowRight,
                    ),
                    const _Divider(),
                    // Кнопка переключения расширенной панели
                    _KeyChip(
                      icon: _isExpanded ? Icons.expand_more : Icons.more_horiz,
                      semanticLabel: _isExpanded
                          ? (strings.isRu ? 'Скрыть панель' : 'Hide panel')
                          : (strings.isRu
                                ? 'Расширенная панель (/, Home, PgUp…)'
                                : 'Expanded panel (/, Home, PgUp…)'),
                      active: _isExpanded,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _isExpanded = !_isExpanded);
                        _refocus();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

typedef _LatchedMods = ({bool ctrl, bool alt});

class _KeyChip extends StatefulWidget {
  const _KeyChip({
    this.label,
    this.icon,
    this.semanticLabel,
    this.active = false,
    this.repeatable = false,
    required this.onTap,
    this.onLongPress,
    this.onRepeatStart,
    this.onRepeatTick,
    this.onRepeatEnd,
  });

  final String? label;
  final IconData? icon;
  final String? semanticLabel;
  final bool active;
  final bool repeatable;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final _LatchedMods Function()? onRepeatStart;
  final void Function(_LatchedMods mods)? onRepeatTick;
  final void Function(_LatchedMods mods)? onRepeatEnd;

  @override
  State<_KeyChip> createState() => _KeyChipState();
}

class _KeyChipState extends State<_KeyChip> {
  static const _initialDelay = Duration(milliseconds: 300);
  static const _repeatInterval = Duration(milliseconds: 60);

  Timer? _delayTimer;
  Timer? _repeatTimer;
  bool _repeated = false;
  bool _pressed = false;
  _LatchedMods? _latchedMods;

  void _startHold() {
    if (!widget.repeatable) return;
    _cancelTimers();
    _repeated = false;
    _latchedMods = null;
    _delayTimer = Timer(_initialDelay, () {
      if (!mounted) return;
      _repeated = true;
      final mods = widget.onRepeatStart?.call() ?? (ctrl: false, alt: false);
      _latchedMods = mods;
      _repeatTimer = Timer.periodic(_repeatInterval, (_) {
        if (!mounted) {
          _stopHold();
          return;
        }
        widget.onRepeatTick?.call(mods);
      });
    });
  }

  void _stopHold({bool sendRelease = true}) {
    _cancelTimers();
    final mods = _latchedMods;
    _latchedMods = null;
    if (_repeated && sendRelease && mods != null) {
      widget.onRepeatEnd?.call(mods);
    }
  }

  void _cancelTimers() {
    _delayTimer?.cancel();
    _delayTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  @override
  void deactivate() {
    _stopHold(sendRelease: false);
    super.deactivate();
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reduced = AppMotion.reduced(context);

    final bg = widget.active
        ? scheme.primary
        : scheme.surfaceContainerHighest.withValues(alpha: 0.6);
    final fg = widget.active ? scheme.onPrimary : scheme.onSurface;
    final borderColor = widget.active
        ? scheme.primary
        : scheme.outlineVariant.withValues(alpha: 0.4);
    final radius = BorderRadius.circular(widget.active ? 9 : 6);

    Widget content = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!_pressed) setState(() => _pressed = true);
      },
      onPointerUp: (_) {
        if (_pressed) setState(() => _pressed = false);
      },
      onPointerCancel: (_) {
        if (_pressed) setState(() => _pressed = false);
      },
      child: AnimatedScale(
        scale: (_pressed && !reduced) ? 0.93 : 1.0,
        duration: reduced ? Duration.zero : const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTapDown: widget.repeatable ? (_) => _startHold() : null,
            onTapUp: widget.repeatable ? (_) => _stopHold() : null,
            onTapCancel: widget.repeatable ? () => _stopHold() : null,
            onTap: () {
              if (widget.repeatable) {
                final wasRepeated = _repeated;
                _stopHold();
                _repeated = false;
                if (wasRepeated) return;
              }
              widget.onTap();
            },
            onLongPress: widget.repeatable ? null : widget.onLongPress,
            borderRadius: radius,
            splashColor: scheme.primary.withValues(alpha: 0.2),
            child: AnimatedContainer(
              duration: AppMotion.duration(context, AppMotion.durationFast),
              curve: AppMotion.fastSpringCurve,
              constraints: const BoxConstraints(minWidth: 32),
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: radius,
                border: Border.all(color: borderColor, width: 0.8),
              ),
              child: widget.icon != null
                  ? Icon(widget.icon, size: 15, color: fg)
                  : Text(
                      widget.label!,
                      style: monoStyle(
                        context,
                        size: 11.5,
                        color: fg,
                      ).copyWith(fontWeight: FontWeight.bold),
                    ),
            ),
          ),
        ),
      ),
    );

    if (widget.semanticLabel != null) {
      content = Semantics(
        label: widget.semanticLabel,
        button: true,
        child: content,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1.5),
      child: content,
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: Theme.of(
        context,
      ).colorScheme.outlineVariant.withValues(alpha: 0.35),
    );
  }
}
