import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/settings/app_settings.dart';
import '../../l10n/app_strings.dart';
import '../../app/controllers/settings_controller.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import 'setting_row.dart';
import '../terminal/clipboard_shortcut.dart';
import 'package:flutter/services.dart';

/// Буфер обмена в терминале: стиль (две карточки) и пара переключателей.
class ClipboardSection extends ConsumerWidget {
  const ClipboardSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final isRu = AppStrings.of(context, s.language).isRu;
    final linux = s.copyOnSelect;
    final rmbPaste = s.rightClick != RightClickAction.menu;
    // macOS: подписи клавиш под местные привычки (⌘ вместо Ctrl+Shift).
    final mac = PlatformCapabilities.isMacOS;

    final confirm = SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        isRu
            ? 'Спрашивать перед вставкой нескольких строк'
            : 'Confirm multi-line paste',
      ),
      value: s.confirmMultilinePaste,
      onChanged: ctrl.setConfirmMultilinePaste,
    );

    // На телефоне мыши нет: копирование и вставка идут через меню выделения.
    if (DesktopEnv.isMobile) return confirm;

    // Галочка «правый клик» внутри карточки относится к её стилю.
    // Клик по галочке в невыбранной карточке заодно выбирает её.
    void setRmb(bool linuxCard, bool on) {
      if (linux != linuxCard) ctrl.setLinuxClipboard(linuxCard);
      ctrl.setRightClickPaste(on);
    }

    final cards = [
      _StyleCard(
        selected: linux && !s.customClipboard,
        icon: Icons.mouse_outlined,
        title: isRu
            ? (mac ? 'Выделением' : 'Как в Linux')
            : (mac ? 'Selection' : 'Linux style'),
        copyKeys: [isRu ? 'Выделение' : 'Selection'],
        pasteKeys: [
          isRu ? 'Средняя кнопка' : 'Middle click',
          if (linux && rmbPaste) isRu ? 'ПКМ' : 'RMB',
        ],
        rmbLabel: isRu ? 'ПКМ тоже вставляет' : 'Right click pastes too',
        rmbValue: linux && rmbPaste,
        onRmb: (v) => setRmb(true, v),
        onTap: () => ctrl.setLinuxClipboard(true),
        copyTooltip: AppStrings.of(context, s.language).copy,
        pasteTooltip: AppStrings.of(context, s.language).paste,
      ),
      _StyleCard(
        selected: !linux && !s.customClipboard,
        icon: Icons.keyboard_outlined,
        title: isRu
            ? (mac ? 'Как в Mac' : 'Клавишами')
            : (mac ? 'Mac style' : 'Keyboard'),
        copyKeys: [
          if (mac) ...['⌘', 'C'] else ...['Ctrl', 'Shift', 'C'],
          if (!linux && rmbPaste) isRu ? 'ПКМ' : 'RMB',
        ],
        pasteKeys: [
          if (mac) ...['⌘', 'V'] else ...['Ctrl', 'Shift', 'V'],
          if (!linux && rmbPaste) isRu ? 'ПКМ' : 'RMB',
        ],
        rmbLabel: isRu
            ? 'ПКМ копирует и вставляет'
            : 'Right click copies and pastes',
        rmbValue: !linux && rmbPaste,
        onRmb: (v) => setRmb(false, v),
        onTap: () => ctrl.setLinuxClipboard(false),
        copyTooltip: AppStrings.of(context, s.language).copy,
        pasteTooltip: AppStrings.of(context, s.language).paste,
      ),
      _StyleCard(
        selected: s.customClipboard,
        icon: Icons.tune,
        title: isRu ? 'Своя' : 'Custom',
        copyKeys: s.copyShortcut.split('+'),
        pasteKeys: s.pasteShortcut.split('+'),
        rmbLabel: '',
        rmbValue: false,
        onRmb: (_) {},
        showRmb: false,
        onTap: ctrl.setCustomClipboard,
        copyTooltip: AppStrings.of(context, s.language).copy,
        pasteTooltip: AppStrings.of(context, s.language).paste,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingRow(
          label: isRu ? 'Буфер обмена' : 'Clipboard',
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: LayoutBuilder(
              builder: (context, c) => c.maxWidth < 420
                  ? Column(
                      children: [
                        cards[0],
                        const SizedBox(height: 8),
                        cards[1],
                        const SizedBox(height: 8),
                        cards[2],
                      ],
                    )
                  : Column(
                      children: [
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: cards[0]),
                              const SizedBox(width: 8),
                              Expanded(child: cards[1]),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        cards[2],
                      ],
                    ),
            ),
          ),
        ),
        if (!s.customClipboard)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            // Переключатель только про Ctrl+V: ⌘V на macOS вставляет всегда.
            title: Text(isRu ? 'Ctrl+V тоже вставляет' : 'Ctrl+V pastes too'),
            value: s.ctrlVPaste,
            onChanged: ctrl.setCtrlVPaste,
          ),
        if (s.customClipboard) ...[
          for (final copy in [true, false])
            ListTile(
              title: Text(
                copy
                    ? (isRu ? 'Копирование' : 'Copy')
                    : (isRu ? 'Вставка' : 'Paste'),
              ),
              trailing: Text(copy ? s.copyShortcut : s.pasteShortcut),
              onTap: () async {
                final shortcut = await _recordShortcut(
                  context,
                  isRu,
                  copy ? s.pasteShortcut : s.copyShortcut,
                );
                if (shortcut != null) {
                  ctrl.setClipboardShortcut(copy: copy, shortcut: shortcut);
                }
              },
            ),
          TextButton(
            onPressed: () {
              ctrl.setClipboardShortcut(
                copy: true,
                shortcut: mac ? 'meta+C' : 'ctrl+shift+C',
              );
              ctrl.setClipboardShortcut(
                copy: false,
                shortcut: mac ? 'meta+V' : 'ctrl+shift+V',
              );
            },
            child: Text(isRu ? 'Сбросить сочетания' : 'Reset shortcuts'),
          ),
        ],
        confirm,
      ],
    );
  }
}

class _StyleCard extends StatelessWidget {
  const _StyleCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.copyKeys,
    required this.pasteKeys,
    required this.rmbLabel,
    required this.rmbValue,
    required this.onRmb,
    required this.onTap,
    required this.copyTooltip,
    required this.pasteTooltip,
    this.showRmb = true,
  });

  final bool showRmb;
  final String copyTooltip;
  final String pasteTooltip;
  final bool selected;
  final IconData icon;
  final String title;
  final List<String> copyKeys;
  final List<String> pasteKeys;
  final String rmbLabel;
  final bool rmbValue;
  final ValueChanged<bool> onRmb;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurface;
    final muted = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;

    return Material(
      color: selected
          ? scheme.secondaryContainer
          : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? scheme.primary : Colors.transparent,
          width: 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: selected ? scheme.primary : muted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(color: fg),
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected ? scheme.primary : scheme.outline,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _KeyRow(
                icon: Icons.content_copy,
                tooltip: copyTooltip,
                keys: copyKeys,
                muted: muted,
              ),
              const SizedBox(height: 6),
              _KeyRow(
                icon: Icons.content_paste,
                tooltip: pasteTooltip,
                keys: pasteKeys,
                muted: muted,
              ),
              const SizedBox(height: 4),
              if (showRmb)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onRmb(!rmbValue),
                  child: Row(
                    children: [
                      Checkbox(
                        value: rmbValue,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) => onRmb(v ?? false),
                      ),
                      Expanded(
                        child: Text(
                          rmbLabel,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: fg,
                          ),
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
  }
}

/// Значок действия и его клавиши.
class _KeyRow extends StatelessWidget {
  const _KeyRow({
    required this.icon,
    required this.tooltip,
    required this.keys,
    required this.muted,
  });

  final IconData icon;
  final String tooltip;
  final List<String> keys;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Tooltip(
          message: tooltip,
          child: Icon(icon, size: 16, color: muted),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final k in keys)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Text(
                    k,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurface,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<String?> _recordShortcut(BuildContext context, bool isRu, String other) {
  String? error;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            return KeyEventResult.ignored;
          }
          final value = recordClipboardShortcut(event);
          if (value != null) {
            if (value == other || reservedClipboardShortcut(value)) {
              setState(
                () => error = isRu
                    ? 'Сочетание занято или зарезервировано системой'
                    : 'Shortcut is already used or reserved',
              );
            } else {
              Navigator.pop(context, value);
            }
          }
          return KeyEventResult.handled;
        },
        child: AlertDialog(
          title: Text(isRu ? 'Нажмите сочетание клавиш' : 'Press a shortcut'),
          content: Text(
            error ??
                (isRu
                    ? 'Используйте Ctrl, Alt или ⌘ вместе с клавишей. Системные сочетания могут быть недоступны.'
                    : 'Use Ctrl, Alt or ⌘ with a key. System shortcuts may be unavailable.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(isRu ? 'Отмена' : 'Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
}
