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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Цвета', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<ColorSource>(
          segments: [
            const ButtonSegment(
                value: ColorSource.preset, icon: Icon(Icons.palette_outlined), label: Text('Свои')),
            ButtonSegment(
                value: ColorSource.system,
                icon: const Icon(Icons.computer),
                label: Text(Platform.isWindows ? 'Акцент Windows' : 'Акцент системы')),
            if (Platform.isLinux)
              const ButtonSegment(
                  value: ColorSource.dots, icon: Icon(Icons.wallpaper), label: Text('Из дотов')),
          ],
          selected: {s.colorSource},
          onSelectionChanged: (v) => ctrl.setColorSource(v.first),
        ),
        const SizedBox(height: 12),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: switch (s.colorSource) {
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
            ColorSource.system => _Status(
                ext: ext,
                notFound: notFound,
                hint: Platform.isWindows
                    ? 'Цвет берётся из «Параметры → Персонализация → Цвета». Меняется на лету.'
                    : 'Нужен xdg-desktop-portal с поддержкой accent-color (GNOME 47+, KDE Plasma 6). '
                        'В тайлинговых WM акцента обычно нет, берите «Из дотов».',
              ),
            ColorSource.dots => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Status(
                    ext: ext,
                    notFound: notFound,
                    hint: 'Ищем по порядку: свой путь → ~/.config/vysh/colors.json → '
                        'caelestia → pywal. Файл перечитывается при каждом изменении.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _path,
                    style: monoStyle(context, size: 13),
                    decoration: InputDecoration(
                      labelText: 'Свой путь к файлу цветов (необязательно)',
                      hintText: '~/.config/matugen/vysh.json',
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
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => LocalFiles.openWithSystem(_themesDocUrl),
                      icon: const Icon(Icons.menu_book_outlined, size: 18),
                      label: const Text('Как подключить matugen, wallust, pywal, caelestia'),
                    ),
                  ),
                ],
              ),
          },
        ),
        if (s.colorSource != ColorSource.preset && ext != null) ...[
          const SizedBox(height: 12),
          _Preview(ext: ext, scheme: scheme),
        ],
      ],
    );
  }
}

class _Status extends ConsumerWidget {
  const _Status({required this.ext, required this.notFound, required this.hint});

  final ExternalColors? ext;
  final bool notFound;
  final String hint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = ext;
    final ok = e != null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ok ? scheme.secondaryContainer.withValues(alpha: 0.5) : scheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.help_outline,
              size: 20, color: ok ? scheme.onSecondaryContainer : scheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e != null
                      ? 'Сейчас: ${e.source}'
                      : notFound
                          ? 'Источник не найден, пока свои цвета'
                          : 'Ищем…',
                  style: theme.textTheme.titleSmall,
                ),
                if (e?.path != null)
                  Text(e!.path!, style: monoStyle(context, size: 12, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Перечитать',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () => ref.read(externalColorsProvider.notifier).refresh(),
          ),
        ],
      ),
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

/// «Заголовок окна»: авто / системный / свой.
class TitleBarSection extends ConsumerWidget {
  const TitleBarSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final custom = DesktopEnv.useCustomTitleBar(s.titleBarMode);

    final autoHint = Platform.isWindows
        ? 'Авто: свой заголовок с вкладками.'
        : DesktopEnv.isTiling
            ? 'Авто: тайлинговый WM, окнами управляет он.'
            : DesktopEnv.supportsCustomTitleBar
                ? 'Авто: GNOME / KDE, свой заголовок с вкладками.'
                : 'Авто: рамку рисует оконный менеджер.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Заголовок окна', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<TitleBarMode>(
          segments: const [
            ButtonSegment(value: TitleBarMode.auto, icon: Icon(Icons.auto_awesome), label: Text('Авто')),
            ButtonSegment(
                value: TitleBarMode.custom, icon: Icon(Icons.tab_outlined), label: Text('Свой с вкладками')),
            ButtonSegment(
                value: TitleBarMode.system, icon: Icon(Icons.web_asset), label: Text('Системный')),
          ],
          selected: {s.titleBarMode},
          onSelectionChanged: (v) => ctrl.setTitleBarMode(v.first),
        ),
        const SizedBox(height: 6),
        Text(
          '$autoHint Сейчас: ${custom ? 'свой' : 'системный'}. '
          'Размер и положение окна запоминаются между запусками.',
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
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

