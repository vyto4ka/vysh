import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/services/settings_controller.dart';

/// «Копирование и вставка»: две карточки-стиля и пара переключателей.
class ClipboardSection extends ConsumerWidget {
  const ClipboardSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final linux = s.copyOnSelect;
    final rmbPaste = s.rightClick != RightClickAction.menu;

    // Галочка «правый клик» живёт внутри карточки стиля: она меняет, что
    // делает правый клик именно в этом стиле. Клик по галочке в невыбранной
    // карточке заодно выбирает её.
    void setRmb(bool linuxCard, bool on) {
      if (linux != linuxCard) ctrl.setLinuxClipboard(linuxCard);
      ctrl.setRightClickPaste(on);
    }

    final cards = [
      _StyleCard(
        selected: linux,
        icon: Icons.mouse_outlined,
        title: 'Как в Linux',
        description: 'Выделил — уже скопировано. Средняя кнопка вставляет.',
        copyKeys: const ['Выделение'],
        pasteKeys: [
          'Средняя кнопка',
          if (linux && rmbPaste) 'Правый клик',
        ],
        rmbLabel: 'Правый клик тоже вставляет',
        rmbHint: 'Не нужно тянуться до колёсика',
        rmbValue: linux && rmbPaste,
        onRmb: (v) => setRmb(true, v),
        onTap: () => ctrl.setLinuxClipboard(true),
      ),
      _StyleCard(
        selected: !linux,
        icon: Icons.keyboard_outlined,
        title: 'Клавишами',
        description: 'Копирование и вставка сочетаниями клавиш.',
        copyKeys: [
          'Ctrl', 'Shift', 'C',
          if (!linux && rmbPaste) 'или правый клик по выделению',
        ],
        pasteKeys: [
          'Ctrl', 'Shift', 'V',
          if (!linux && rmbPaste) 'или правый клик',
        ],
        rmbLabel: 'Правый клик копирует и вставляет',
        rmbHint: 'Есть выделение — копирует, нет — вставляет',
        rmbValue: !linux && rmbPaste,
        onRmb: (v) => setRmb(false, v),
        onTap: () => ctrl.setLinuxClipboard(false),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Копирование и вставка', style: theme.textTheme.titleSmall),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, c) => c.maxWidth < 520
              ? Column(children: [cards[0], const SizedBox(height: 8), cards[1]])
              : IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: cards[0]),
                      const SizedBox(width: 8),
                      Expanded(child: cards[1]),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 6),
        Text(
          [
            if (linux) 'Ctrl+Shift+C / Ctrl+Shift+V тоже работают.',
            rmbPaste
                ? 'Меню терминала — Shift + правый клик.'
                : 'Правый клик открывает меню терминала.',
          ].join(' '),
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.keyboard_command_key),
          title: const Text('Ctrl+V тоже вставляет'),
          subtitle: const Text('Выключено — Ctrl+V уходит в терминал (нужно, например, в vim)'),
          value: s.ctrlVPaste,
          onChanged: ctrl.setCtrlVPaste,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.warning_amber_rounded),
          title: const Text('Спрашивать перед вставкой нескольких строк'),
          subtitle: const Text('Защита от случайного запуска пачки команд на сервере'),
          value: s.confirmMultilinePaste,
          onChanged: ctrl.setConfirmMultilinePaste,
        ),
      ],
    );
  }
}

class _StyleCard extends StatelessWidget {
  const _StyleCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.description,
    required this.copyKeys,
    required this.pasteKeys,
    required this.rmbLabel,
    required this.rmbHint,
    required this.rmbValue,
    required this.onRmb,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String description;

  final List<String> copyKeys;
  final List<String> pasteKeys;
  final String rmbLabel;
  final String rmbHint;
  final bool rmbValue;
  final ValueChanged<bool> onRmb;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onSecondaryContainer : scheme.onSurface;
    final muted = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;

    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: selected ? scheme.primary : muted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(title,
                        style: theme.textTheme.titleSmall?.copyWith(color: fg)),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: selected
                        ? Icon(Icons.check_circle, key: const ValueKey(1), size: 20, color: scheme.primary)
                        : Icon(Icons.radio_button_unchecked,
                            key: const ValueKey(0), size: 20, color: scheme.outline),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(description, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              const SizedBox(height: 10),
              _KeyRow(label: 'Копировать', keys: copyKeys, selected: selected),
              const SizedBox(height: 6),
              _KeyRow(label: 'Вставить', keys: pasteKeys, selected: selected),
              const SizedBox(height: 8),
              Divider(height: 1, color: (selected ? scheme.onSecondaryContainer : scheme.outlineVariant)
                  .withValues(alpha: 0.2)),
              const SizedBox(height: 4),
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onRmb(!rmbValue),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Checkbox(
                        value: rmbValue,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) => onRmb(v ?? false),
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(rmbLabel, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
                            Text(rmbHint, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.label, required this.keys, required this.selected});

  final String label;
  final List<String> keys;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Row(
      children: [
        SizedBox(
          width: 86,
          child: Text(label, style: theme.textTheme.labelMedium?.copyWith(color: muted)),
        ),
        Flexible(
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final k in keys)
                if (k.startsWith('или '))
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(k, style: theme.textTheme.labelSmall?.copyWith(color: muted)),
                  )
                else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.surface.withValues(alpha: selected ? 0.7 : 1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Text(k,
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurface)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
