import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/models/external_colors.dart';
import '../../domain/services/external_colors_controller.dart';
import '../../domain/services/settings_controller.dart';
import '../../infra/platform/desktop_env.dart';
import '../../infra/platform/local_files.dart';
import '../theme/app_theme.dart';
import 'setting_row.dart';

const _themesDocUrl = 'https://github.com/vyto4ka/vysh/blob/main/docs/THEMES.md';

/// «Откуда брать цвета»: свой акцент, системный, доты.
class ColorSourceSection extends ConsumerStatefulWidget {
  const ColorSourceSection({super.key});

  @override
  ConsumerState<ColorSourceSection> createState() => _ColorSourceSectionState();
}

class _ColorSourceSectionState extends ConsumerState<ColorSourceSection> {
  late final TextEditingController _path;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController(text: ref.read(settingsProvider).dotsPath);
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final ext = ref.watch(externalColorsProvider);
    final notFound = ref.read(externalColorsProvider.notifier).notFound;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final error = theme.textTheme.bodySmall?.copyWith(color: scheme.error);

    final details = switch (s.colorSource) {
      ColorSource.preset => Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (name, color) in seedPresets)
              _SeedSwatch(
                name: name,
                color: Color(color),
                selected: s.seedColor == color,
                onTap: () => ctrl.setSeedColor(color),
              ),
          ],
        ),
      ColorSource.system => ext == null && notFound
          ? Text(
              Platform.isWindows
                  ? 'Акцент Windows не найден'
                  : 'Акцент не найден: нужен xdg-desktop-portal с accent-color',
              style: error)
          : const SizedBox.shrink(),
      ColorSource.dots => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (ext != null && ext.path != null)
              Text('${ext.source}: ${ext.path}', style: monoStyle(context, size: 12, color: scheme.onSurfaceVariant))
            else if (notFound)
              Text('Файл цветов не найден', style: error),
            const SizedBox(height: 10),
            TextField(
              controller: _path,
              style: monoStyle(context, size: 13),
              decoration: InputDecoration(
                labelText: 'Свой путь к файлу',
                hintText: '~/.config/vysh/colors.json',
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: IconButton(
                  tooltip: 'Применить',
                  icon: const Icon(Icons.check),
                  onPressed: () => ctrl.setDotsPath(_path.text.trim()),
                ),
              ),
              onSubmitted: (v) => ctrl.setDotsPath(v.trim()),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => LocalFiles.openWithSystem(_themesDocUrl),
                icon: const Icon(Icons.menu_book_outlined, size: 18),
                label: const Text('matugen, wallust, pywal, caelestia'),
              ),
            ),
          ],
        ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingRow(
          label: 'Цвета',
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<ColorSource>(
                  segments: [
                    const ButtonSegment(
                        value: ColorSource.preset,
                        icon: Icon(Icons.palette_outlined),
                        label: Text('Свои')),
                    ButtonSegment(
                        value: ColorSource.system,
                        icon: const Icon(Icons.computer),
                        label: Text(Platform.isWindows ? 'Акцент Windows' : 'Акцент системы')),
                    if (Platform.isLinux)
                      const ButtonSegment(
                          value: ColorSource.dots,
                          icon: Icon(Icons.wallpaper),
                          label: Text('Из дотов')),
                  ],
                  selected: {s.colorSource},
                  onSelectionChanged: (v) => ctrl.setColorSource(v.first),
                ),
                const SizedBox(height: 12),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.topCenter,
                  child: details,
                ),
                if (s.colorSource != ColorSource.preset && ext != null) ...[
                  const SizedBox(height: 8),
                  _Preview(ext: ext, scheme: scheme),
                ],
              ],
            ),
          ),
        ),
        if (s.colorSource != ColorSource.preset)
          SettingRow(
            label: 'Проверка цветов',
            child: SettingChoice<int>(
              value: s.colorPollSec,
              options: const [(0, 'Выкл.'), (10, '10 с'), (60, '1 мин'), (300, '5 мин')],
              onChanged: ctrl.setColorPollSec,
            ),
          ),
      ],
    );
  }
}

/// Предпросмотр: акцент и 16 цветов терминала из источника.
class _Preview extends StatelessWidget {
  const _Preview({required this.ext, required this.scheme});

  final ExternalColors ext;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    Widget dot(Color c, [double size = 22]) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(color: scheme.outlineVariant),
          ),
        );
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        dot(ext.seed, 30),
        const SizedBox(width: 8),
        dot(scheme.primary),
        dot(scheme.secondary),
        dot(scheme.tertiary),
        dot(scheme.primaryContainer),
        if (ext.ansi != null) ...[
          const SizedBox(width: 12),
          for (final c in ext.ansi!) dot(c, 16),
        ],
      ],
    );
  }
}

/// «Заголовок окна»: свой с вкладками или системный.
class TitleBarSection extends ConsumerWidget {
  const TitleBarSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    // «Авто» в интерфейсе не показываем: пока пользователь не выбрал сам,
    // отмечен тот вариант, который сейчас действует.
    final custom = DesktopEnv.useCustomTitleBar(s.titleBarMode);

    return SettingRow(
      label: 'Заголовок окна',
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, icon: Icon(Icons.tab_outlined), label: Text('Свой с вкладками')),
          ButtonSegment(value: false, icon: Icon(Icons.web_asset), label: Text('Системный')),
        ],
        selected: {custom},
        onSelectionChanged: (v) =>
            ctrl.setTitleBarMode(v.first ? TitleBarMode.custom : TitleBarMode.system),
      ),
    );
  }
}

class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: color,
      brightness: Theme.of(context).brightness,
    );
    final outline = Theme.of(context).colorScheme.onSurface;

    return Tooltip(
      message: name,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 64,
          height: 64,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? outline : Colors.transparent,
              width: 2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(
              children: [
                Expanded(child: Container(color: scheme.primary)),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: Container(color: scheme.secondaryContainer)),
                      Expanded(child: Container(color: scheme.tertiaryContainer)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

