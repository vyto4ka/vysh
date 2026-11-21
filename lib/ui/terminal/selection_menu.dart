import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';

/// Что именно будет вставлено в терминал.
class PastePlan {
  PastePlan(String text)
      : lines = text.split(RegExp(r'\r\n|\r|\n')),
        hasLineBreaks = text.contains(RegExp(r'[\r\n]'));

  /// Строки текста (CR, LF и CRLF - всё разделители, как их видит shell).
  final List<String> lines;

  /// Есть ли в тексте символы, которые shell выполнит как Enter.
  /// Именно это решает, нужно ли подтверждение, - а не число строк после
  /// обрезки: `command\n` и `a\rb` тоже выполняются сразу.
  final bool hasLineBreaks;

  /// Строки без пустых хвостов - для предпросмотра.
  List<String> get visibleLines {
    final l = [...lines];
    while (l.length > 1 && l.last.trim().isEmpty) {
      l.removeLast();
    }
    return l;
  }

  /// Только один перевод строки, в самом конце.
  bool get onlyTrailingEnter => visibleLines.length == 1 && hasLineBreaks;

  /// «Одной строкой»: без единого Enter.
  String get singleLine =>
      lines.map((l) => l.trim()).where((l) => l.isNotEmpty).join(' ');

  /// Текст с нормализованными переводами строк (`\r\n` → `\n`).
  ///
  /// В буфере обмена Windows переводы строк — `\r\n`. В `xterm2` метод
  /// `paste()` вне bracketed paste заменяет только `\n` на `\r`, из-за чего
  /// `\r\n` превращается в `\r\r`, а в bracketed paste оболочки/редакторы
  /// на удалённом сервере также могут трактовать оба символа `\r` и `\n`
  /// как два отдельных нажатия Enter, добавляя пустые строки между строками.
  String get normalized => lines.join('\n');
}

/// Контекстное всплывающее меню в стиле keyboard.
class SelectionMenu extends StatefulWidget {
  const SelectionMenu({
    super.key,
    required this.position,
    required this.hasSelection,
    required this.isEmptySpace,
    required this.selectedCharCount,
    required this.strings,
    required this.onCopy,
    required this.onPaste,
    required this.onCut,
    required this.onSelectAll,
    this.onErase,
    required this.onShare,
    required this.onReset,
    required this.onClear,
    this.onSftp,
    this.onLog,
    required this.onReconnect,
    required this.onDismiss,
  });

  final Offset position;
  final bool hasSelection;
  final bool isEmptySpace;
  final int selectedCharCount;
  final AppStrings strings;

  final VoidCallback onCopy;
  final VoidCallback onPaste;
  final VoidCallback onCut;
  final VoidCallback onSelectAll;
  final VoidCallback? onErase;
  final VoidCallback onShare;
  final VoidCallback onReset;
  final VoidCallback onClear;
  final VoidCallback? onSftp;
  final VoidCallback? onLog;
  final VoidCallback onReconnect;
  final VoidCallback onDismiss;

  @override
  State<SelectionMenu> createState() => _SelectionMenuState();
}

class _SelectionMenuState extends State<SelectionMenu>
    with TickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _enter = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _expandCtrl = AnimationController.unbounded(
    vsync: this,
  );
  bool _enterStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_enterStarted) {
      _enterStarted = true;
      if (AppMotion.reduced(context)) {
        _enter.value = 1;
      } else {
        AppMotion.springTo(_enter, 1, spring: AppMotion.spatialFast);
      }
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _expandCtrl.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
    AppMotion.springTo(
      _expandCtrl,
      _expanded ? 1 : 0,
      spring: AppMotion.spatialDefault,
      instant: AppMotion.reduced(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = widget.strings;

    final hasValidSelection =
        widget.hasSelection &&
        widget.selectedCharCount > 0 &&
        !widget.isEmptySpace;

    final surfaceColor = ElevationOverlay.applySurfaceTint(
      scheme.surfaceContainerHighest,
      scheme.surfaceTint,
      6,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxMenuWidth = math.max(0.0, constraints.maxWidth - 20);

        return AnimatedBuilder(
          animation: Listenable.merge([_enter, _expandCtrl]),
          builder: (context, menuContent) {
            final expandT = _expandCtrl.value.clamp(0.0, 1.0);
            final menuWidth = math.min(
              lerpDouble(300.0, 320.0, expandT)!,
              maxMenuWidth,
            );
            final halfWidth = menuWidth / 2;

            var left = widget.position.dx - halfWidth;
            final maxLeft = math.max(
              10.0,
              constraints.maxWidth - menuWidth - 10,
            );
            left = left.clamp(10.0, maxLeft).toDouble();

            final estimatedHeight = lerpDouble(110.0, 210.0, expandT)!;
            final top = (widget.position.dy - estimatedHeight - 8)
                .clamp(
                  10.0,
                  math.max(10.0, constraints.maxHeight - estimatedHeight - 10),
                )
                .toDouble();

            final enterT = _enter.value;
            final scale = lerpDouble(0.90, 1.0, enterT)!;
            final opacity = enterT.clamp(0.0, 1.0);

            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onDismiss,
                    child: const SizedBox.expand(),
                  ),
                ),
                Positioned(
                  left: left,
                  top: top,
                  width: menuWidth,
                  child: Opacity(
                    opacity: opacity,
                    child: Transform.scale(
                      scale: scale,
                      alignment: Alignment.bottomCenter,
                      child: menuContent,
                    ),
                  ),
                ),
              ],
            );
          },
          child: Material(
            elevation: 10,
            shadowColor: Colors.black.withValues(alpha: 0.6),
            color: surfaceColor,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                  width: 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh.withValues(alpha: 0.8),
                      border: Border(
                        bottom: BorderSide(
                          color: scheme.outlineVariant.withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          hasValidSelection
                              ? Icons.text_fields_rounded
                              : Icons.terminal_rounded,
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            hasValidSelection
                                ? '${strings.selectedText} '
                                      '(${strings.charCount(widget.selectedCharCount)})'
                                : strings.terminal,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: widget.onDismiss,
                          child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.copy_rounded,
                            label: strings.copy,
                            onTap: widget.onCopy,
                          ),
                        ),
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.paste_rounded,
                            label: strings.paste,
                            onTap: widget.onPaste,
                          ),
                        ),
                        Expanded(
                          child: _ActionButton(
                            icon: Icons.content_cut_rounded,
                            label: strings.cut,
                            onTap: widget.onCut,
                          ),
                        ),
                        Expanded(
                          child: _ActionButton(
                            icon: _expanded
                                ? Icons.expand_less_rounded
                                : Icons.more_horiz_rounded,
                            label: strings.more,
                            onTap: _toggleExpanded,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ExpandSection(
                    expanded: _expanded,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Divider(
                          height: 1,
                          color: scheme.outlineVariant.withValues(alpha: 0.25),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            alignment: WrapAlignment.spaceEvenly,
                            children: [
                              _SecondaryButton(
                                icon: Icons.select_all_rounded,
                                label: strings.selectAll,
                                onTap: widget.onSelectAll,
                              ),
                              if (widget.onErase != null)
                                _SecondaryButton(
                                  icon: Icons.backspace_outlined,
                                  label: strings.eraseLine,
                                  onTap: widget.onErase!,
                                ),
                              _SecondaryButton(
                                icon: Icons.share_rounded,
                                label: strings.share,
                                onTap: widget.onShare,
                              ),
                              _SecondaryButton(
                                icon: Icons.restart_alt_rounded,
                                label: strings.reset,
                                onTap: widget.onReset,
                              ),
                              _SecondaryButton(
                                icon: Icons.cleaning_services_rounded,
                                label: strings.clear,
                                onTap: widget.onClear,
                              ),
                              if (widget.onLog != null)
                                _SecondaryButton(
                                  icon: Icons.receipt_long_outlined,
                                  label: strings.log,
                                  onTap: widget.onLog!,
                                ),
                              _SecondaryButton(
                                icon: Icons.refresh_rounded,
                                label: strings.reconnect,
                                onTap: widget.onReconnect,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: SizedBox(
        width: double.infinity,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: scheme.onSurface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ],
        ),
      ),
    );
  }
}
