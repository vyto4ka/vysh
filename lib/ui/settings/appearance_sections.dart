import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infra/platform/capabilities.dart';
import '../../app/settings/app_settings.dart';
import '../../l10n/app_strings.dart';
import '../../domain/models/catppuccin.dart';
import '../../domain/models/external_colors.dart';
import '../../app/controllers/external_colors_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/settings/window_chrome.dart';
import '../../infra/platform/desktop_env.dart';
import '../../infra/platform/local_files.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import '../motion/expressive_segments.dart';
import '../motion/layered_switcher.dart';
import '../motion/pressable_surface.dart';
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
  ExternalColors? _lastExt;

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
    if (ext != null) _lastExt = ext;
    final notFound = ref.read(externalColorsProvider.notifier).notFound;
    final strings = AppStrings.of(context, s.language);
    final scheme = Theme.of(context).colorScheme;
    final error = TextStyle(color: scheme.error, fontSize: 13);

    final mobile = DesktopEnv.isMobile;
    // Android: только Monet (хранится как preset) или Catppuccin.
    final selected = mobile && s.colorSource != ColorSource.catppuccin
        ? ColorSource.preset
        : s.colorSource;

    final details = switch (selected) {
      ColorSource.preset when mobile => const SizedBox.shrink(
          key: ValueKey('monet'),
        ),
      ColorSource.preset => Wrap(
          key: const ValueKey('preset'),
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final (i, color) in seedPresets.indexed)
              _SeedSwatch(
                name: strings.accentNames[i],
                color: Color(color),
                selected: s.seedColor == color,
                onTap: () => ctrl.setSeedColor(color),
              ),
          ],
        ),
      ColorSource.system => ext == null && notFound
          ? Text(
              key: const ValueKey('system-err'),
              PlatformCapabilities.registryAccent
                  ? (strings.isRu
                        ? 'Акцент Windows не найден'
                        : 'Windows accent not found')
                  : (strings.isRu
                        ? 'Акцент не найден: нужен xdg-desktop-portal с accent-color'
                        : 'Accent not found: requires xdg-desktop-portal with accent-color'),
              style: error,
            )
          : const SizedBox.shrink(key: ValueKey('system-ok')),
      ColorSource.catppuccin => _CatppuccinPicker(
          key: const ValueKey('catppuccin'),
          flavor: s.catppuccinFlavor,
          accent: s.catppuccinAccent,
          onFlavor: ctrl.setCatppuccinFlavor,
          onAccent: ctrl.setCatppuccinAccent,
        ),
      ColorSource.dots => Column(
          key: const ValueKey('dots'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (ext != null && ext.path != null)
              Text(
                '${strings.colorSourceName(ext.source)}: ${ext.path}',
                style: monoStyle(
                  context,
                  size: 12,
                  color: scheme.onSurfaceVariant,
                ),
              )
            else if (notFound)
              Text(
                strings.isRu ? 'Файл цветов не найден' : 'Color file not found',
                style: error,
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _path,
              style: monoStyle(context, size: 13),
              decoration: InputDecoration(
                labelText: strings.isRu
                    ? 'Свой путь к файлу'
                    : 'Custom file path',
                hintText: '~/.config/vysh/colors.json',
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: IconButton(
                  tooltip: strings.isRu ? 'Применить' : 'Apply',
                  icon: const Icon(Icons.check),
                  onPressed: () => ctrl.setDotsPath(_path.text.trim()),
                ),
              ),
              onSubmitted: (v) => ctrl.setDotsPath(v.trim()),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    LocalFiles.openWithSystem(_themesDocUrl).catchError((_) {}),
                icon: const Icon(Icons.menu_book_outlined, size: 18),
                label: const Text('matugen, wallust, pywal, caelestia'),
              ),
            ),
          ],
        ),
    };

    final showPreview =
        s.colorSource != ColorSource.preset &&
        s.colorSource != ColorSource.catppuccin &&
        ext != null;
    final previewExt = ext ?? _lastExt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingRow(
          label: strings.colorSourceTitle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExpressiveSegments<ColorSource>(
                  segments: [
                    ExpressiveSegment(
                      value: ColorSource.preset,
                      icon: mobile
                          ? Icons.auto_awesome_outlined
                          : Icons.palette_outlined,
                      label: mobile ? 'Monet' : strings.colorSourcePreset,
                    ),
                    if (PlatformCapabilities.registryAccent ||
                        PlatformCapabilities.portalAccent)
                      ExpressiveSegment(
                        value: ColorSource.system,
                        icon: Icons.computer,
                        label: PlatformCapabilities.registryAccent
                            ? strings.colorSourceSystemWin
                            : strings.colorSourceSystemSys,
                      ),
                    if (PlatformCapabilities.dotfileColors)
                      ExpressiveSegment(
                        value: ColorSource.dots,
                        icon: Icons.wallpaper,
                        label: strings.colorSourceDots,
                      ),
                    const ExpressiveSegment(
                      value: ColorSource.catppuccin,
                      icon: Icons.coffee_outlined,
                      label: 'Catppuccin',
                    ),
                  ],
                  selected: selected,
                  onChanged: ctrl.setColorSource,
                ),
                const SizedBox(height: 12),
                AnimatedSize(
                  duration: AppMotion.duration(
                    context,
                    const Duration(milliseconds: 300),
                  ),
                  curve: AppMotion.spatialCurve,
                  alignment: AlignmentDirectional.topStart,
                  child: FadeSlideSwitcher(
                    alignment: AlignmentDirectional.topStart,
                    child: details,
                  ),
                ),
                ExpandSection(
                  expanded: showPreview,
                  child: previewExt == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _Preview(ext: previewExt, scheme: scheme),
                        ),
                ),
              ],
            ),
          ),
        ),
        if (!DesktopEnv.isMobile)
          ExpandSection(
            expanded:
                s.colorSource != ColorSource.preset &&
                s.colorSource != ColorSource.catppuccin,
            child: SettingRow(
              label: strings.isRu ? 'Проверка цветов' : 'Color polling',
              child: SettingChoice<int>(
                value: s.colorPollSec,
                options: [
                  (0, strings.isRu ? 'Выкл.' : 'Off'),
                  (10, strings.isRu ? '10 с' : '10s'),
                  (60, strings.isRu ? '1 мин' : '1 min'),
                  (300, strings.isRu ? '5 мин' : '5 min'),
                ],
                onChanged: ctrl.setColorPollSec,
              ),
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
    final fastDur = AppMotion.duration(context, AppMotion.durationFast);
    Widget dot(Color c, [double size = 22]) => AnimatedContainer(
          duration: fastDur,
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
    if (DesktopEnv.isMobile) return const SizedBox.shrink();
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final strings = AppStrings.of(context, s.language);
    // «Авто» в интерфейсе не показываем: пока пользователь не выбрал сам,
    // отмечен тот вариант, который сейчас действует.
    final custom = useCustomTitleBar(s.titleBarMode);
    return SettingRow(
      label: strings.titleBarTitle,
      child: ExpressiveSegments<bool>(
        segments: [
          ExpressiveSegment(
            value: true,
            icon: Icons.tab_outlined,
            label: strings.titleBarCustom,
          ),
          ExpressiveSegment(
            value: false,
            icon: Icons.web_asset,
            label: strings.titleBarSystem,
          ),
        ],
        selected: custom,
        onChanged: (v) => ctrl.setTitleBarMode(
          v ? TitleBarMode.custom : TitleBarMode.system,
        ),
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
      child: PressableSurface(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        pressScale: 0.05,
        borderRadius: BorderRadius.circular(18),
        selectedBorderRadius: BorderRadius.circular(22),
        selected: selected,
        side: BorderSide.none,
        selectedSide: BorderSide(color: outline, width: 2),
        child: SizedBox(
          width: 64,
          height: 64,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(selected ? 16 : 12),
              child: Column(
                children: [
                  Expanded(child: Container(color: scheme.primary)),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: Container(color: scheme.secondaryContainer),
                        ),
                        Expanded(
                          child: Container(color: scheme.tertiaryContainer),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Catppuccin: четыре варианта и 14 акцентов.
class _CatppuccinPicker extends StatelessWidget {
  const _CatppuccinPicker({
    super.key,
    required this.flavor,
    required this.accent,
    required this.onFlavor,
    required this.onAccent,
  });

  final String flavor;
  final String accent;
  final ValueChanged<String> onFlavor;
  final ValueChanged<String> onAccent;

  @override
  Widget build(BuildContext context) {
    final current = catppuccinFlavor(flavor);
    final outline = Theme.of(context).colorScheme.onSurface;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final f in catppuccinFlavors)
              _FlavorCard(
                flavor: f,
                accent: accent,
                selected: f.id == current.id,
                onTap: () => onFlavor(f.id),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final a in catppuccinAccents)
              Tooltip(
                message: a,
                child: PressableSurface(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onAccent(a);
                  },
                  pressScale: 0.08,
                  borderRadius: BorderRadius.circular(15),
                  selectedBorderRadius: BorderRadius.circular(10),
                  selected: a == accent,
                  side: BorderSide.none,
                  selectedSide: BorderSide(color: outline, width: 2),
                  child: SizedBox(
                    width: 30,
                    height: 30,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: current[a],
                          borderRadius: BorderRadius.circular(
                            a == accent ? 7 : 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _FlavorCard extends StatelessWidget {
  const _FlavorCard({
    required this.flavor,
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final CatppuccinFlavor flavor;
  final String accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final f = flavor;
    final outline = Theme.of(context).colorScheme.onSurface;
    Widget dot(String k) => Container(
          width: 10,
          height: 10,
          margin: const EdgeInsets.only(right: 4),
          decoration: BoxDecoration(color: f[k], shape: BoxShape.circle),
        );
    return PressableSurface(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      pressScale: 0.035,
      borderRadius: BorderRadius.circular(14),
      selectedBorderRadius: BorderRadius.circular(18),
      selected: selected,
      color: f['base'],
      selectedColor: f['base'],
      side: BorderSide(color: f['surface0'], width: 2),
      selectedSide: BorderSide(color: outline, width: 2),
      child: SizedBox(
        width: 120,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                f.name,
                style: TextStyle(
                  color: f['text'],
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  dot(catppuccinAccents.contains(accent) ? accent : 'mauve'),
                  dot('red'),
                  dot('green'),
                  dot('yellow'),
                  dot('blue'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
