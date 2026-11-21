import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/controllers/fonts_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/settings/terminal_font.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import '../../infra/platform/font_files.dart' show FontFiles;
import '../../infra/platform/local_files.dart';
import '../../l10n/app_strings.dart';
import '../motion/app_motion.dart';
import '../widgets/strings_context.dart';
import 'setting_row.dart';

const _nerdFontsUrl = 'https://www.nerdfonts.com/font-downloads';

/// Строка предпросмотра: приглашение, рамки, галочка и значки Nerd Font
/// (ветка git, папка, Linux) - сразу видно, есть ли они в шрифте.
const _previewText = 'user@host:~\$ ls -la ├─ ✓ \u{E0A0} \u{F07B} \u{F17C}';

/// Терминал: шрифт, размер, межстрочный интервал и предпросмотр.
class TerminalFontSection extends ConsumerWidget {
  const TerminalFontSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final strings = context.strings;
    final scheme = Theme.of(context).colorScheme;
    final userFonts = ref.watch(userFontsProvider);
    final fastDur = AppMotion.duration(context, AppMotion.durationFast);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingRow(
          label: strings.terminalFontTitle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _FontPicker(),
                const SizedBox(height: 8),
                AnimatedSize(
                  duration: fastDur,
                  curve: AppMotion.spatialCurve,
                  alignment: AlignmentDirectional.topStart,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final f in userFonts)
                        InputChip(
                          key: ValueKey(f.fileName),
                          label: Text(f.family),
                          selected:
                              s.terminalFont == TerminalFont.file(f.fileName),
                          avatar: const Icon(
                            Icons.insert_drive_file_outlined,
                            size: 18,
                          ),
                          deleteButtonTooltipMessage: strings.removeFont,
                          onDeleted: () =>
                              ref.read(userFontsProvider.notifier).remove(f),
                          onPressed: () =>
                              ref.read(userFontsProvider.notifier).select(f),
                        ),
                      TextButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(strings.addFont),
                        onPressed: () => _addFont(context, ref),
                      ),
                      if (PlatformCapabilities.openLinks)
                        TextButton.icon(
                          icon: const Icon(Icons.open_in_new, size: 18),
                          label: Text(strings.nerdFontsLink),
                          onPressed: () => LocalFiles.openUrl(
                            _nerdFontsUrl,
                          ).catchError((_) {}),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SettingRow(
          label: strings.fontSizeTitle,
          child: _SliderWithValue(
            min: 8,
            max: 32,
            divisions: 24,
            value: s.terminalFontSize.clamp(8, 32).toDouble(),
            format: (v) => '${v.round()}',
            onChanged: ctrl.setTerminalFontSize,
          ),
        ),
        SettingRow(
          label: strings.lineHeightTitle,
          child: _SliderWithValue(
            min: TerminalFont.minLineHeight,
            max: TerminalFont.maxLineHeight,
            divisions: 12,
            value: s.terminalLineHeight
                .clamp(TerminalFont.minLineHeight, TerminalFont.maxLineHeight)
                .toDouble(),
            format: (v) => v.toStringAsFixed(2),
            onChanged: ctrl.setTerminalLineHeight,
          ),
        ),
        const SizedBox(height: 8),
        AnimatedSize(
          duration: fastDur,
          curve: AppMotion.spatialCurve,
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: AnimatedDefaultTextStyle(
              duration: fastDur,
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontFamily: TerminalFont.familyOf(s.terminalFont),
                fontFamilyFallback: TerminalFont.fallbackOf(s.terminalFont),
                fontSize: s.terminalFontSize,
                height: s.terminalLineHeight,
                color: scheme.onSurface,
                // Как в терминале: без лигатур.
                fontFeatures: const [
                  FontFeature.disable('liga'),
                  FontFeature.disable('calt'),
                ],
              ),
              child: const Text(
                _previewText,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static Future<void> _addFont(BuildContext context, WidgetRef ref) async {
    final strings = context.strings;
    final messenger = ScaffoldMessenger.of(context);
    final file = await openFile(
      confirmButtonText: strings.choose,
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'TTF / OTF',
          extensions: FontFiles.extensions,
          // Android выбирает по MIME, а файловые менеджеры часто отдают
          // шрифт как octet-stream. На ПК лишние MIME показали бы всё подряд.
          mimeTypes: DesktopEnv.isMobile
              ? const ['font/ttf', 'font/otf', 'font/sfnt', 'application/x-font-ttf',
                  'application/x-font-otf', 'application/font-sfnt', 'application/octet-stream']
              : null,
          uniformTypeIdentifiers: const ['public.truetype-ttf-font', 'public.opentype-font'],
        ),
      ],
    );
    if (file == null || !context.mounted) return;
    try {
      final font = await ref.read(userFontsProvider.notifier).add(file.path);
      messenger.showSnackBar(SnackBar(
        content: Text(font.monospace
            ? strings.fontAdded(font.family)
            : strings.fontNotMonospace(font.family)),
      ));
    } on AddFontException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(strings.fontAddFailed(e.error, FontFiles.maxFileBytes >> 20, e.detail)),
      ));
    }
  }
}

/// Выпадающий список: по умолчанию, свои файлы, системные моноширинные.
class _FontPicker extends ConsumerWidget {
  const _FontPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Язык смотрим явно: виджет const и сам по себе не перестроится.
    ref.watch(settingsProvider.select((s) => s.language));
    final strings = context.strings;
    final current = ref.watch(settingsProvider.select((s) => s.terminalFont));
    final userFonts = ref.watch(userFontsProvider);
    final system = ref.watch(systemFontsProvider);
    final systemList = system.value ?? const <String>[];

    final entries = <DropdownMenuEntry<String>>[
      DropdownMenuEntry(
        value: '',
        label: strings.fontDefault,
        leadingIcon: const Icon(Icons.auto_awesome_outlined, size: 18),
      ),
      for (final f in userFonts)
        DropdownMenuEntry(
          value: TerminalFont.file(f.fileName),
          label: f.family,
          leadingIcon: const Icon(Icons.insert_drive_file_outlined, size: 18),
        ),
      for (final f in systemList)
        DropdownMenuEntry(
          value: TerminalFont.system(f),
          label: f,
          leadingIcon: const SizedBox(width: 18),
        ),
    ];

    // Выбранный шрифт удалили из системы или из профиля: показываем как есть.
    if (current.isNotEmpty && !entries.any((e) => e.value == current) && !system.isLoading) {
      final name = TerminalFont.systemFamily(current) ?? TerminalFont.fileName(current) ?? current;
      entries.insert(
        1,
        DropdownMenuEntry(
          value: current,
          label: '$name (${strings.fontNotFound})',
          leadingIcon: const Icon(Icons.warning_amber_rounded, size: 18),
        ),
      );
    }

    final known = entries.any((e) => e.value == current);
    return LayoutBuilder(builder: (context, c) => DropdownMenu<String>(
      // Пересоздаём при внешней смене (выбор чипом, удаление файла):
      // DropdownMenu держит текст поля сам.
      key: ValueKey('$current|${entries.length}|${strings.isRu}'),
      width: c.maxWidth < 320 ? c.maxWidth : 320,
      menuHeight: 360,
      initialSelection: known ? current : '',
      enableSearch: true,
      enableFilter: false,
      requestFocusOnTap: !DesktopEnv.isMobile,
      trailingIcon: system.isLoading
          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : null,
      dropdownMenuEntries: entries,
      onSelected: (v) {
        if (v == null || v == current) return;
        final file = TerminalFont.fileName(v);
        if (file != null) {
          for (final f in userFonts) {
            if (f.fileName == file) {
              ref.read(userFontsProvider.notifier).select(f);
              return;
            }
          }
        }
        ref.read(settingsProvider.notifier).setTerminalFont(v);
      },
    ));
  }
}

class _SliderWithValue extends StatelessWidget {
  const _SliderWithValue({
    required this.min,
    required this.max,
    required this.divisions,
    required this.value,
    required this.format,
    required this.onChanged,
  });

  final double min;
  final double max;
  final int divisions;
  final double value;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) => SizedBox(
      width: c.maxWidth < 320 ? c.maxWidth : 320,
      child: Row(
        children: [
          Expanded(
            child: Slider(
              min: min,
              max: max,
              divisions: divisions,
              value: value,
              label: format(value),
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(format(value), textAlign: TextAlign.end),
          ),
        ],
      ),
    ));
  }
}
