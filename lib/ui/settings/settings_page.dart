import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infra/platform/capabilities.dart';
import '../widgets/strings_context.dart';
import '../../app/version.dart';
import '../../app/settings/app_settings.dart';
import '../../l10n/app_strings.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/update_controller.dart';
import '../../infra/platform/desktop_env.dart';
import '../../infra/platform/local_files.dart';
import '../../infra/storage/app_paths.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import '../motion/expressive_segments.dart';
import '../motion/smooth_scroll.dart';
import '../theme/app_theme.dart';
import '../widgets/app_icon.dart';
import 'appearance_sections.dart';
import 'backup_section.dart';
import 'clipboard_section.dart';
import 'performance_section.dart';
import 'setting_row.dart';
import 'terminal_font_section.dart';
import 'update_section.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final strings = AppStrings.of(context, s.language);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isMobile = DesktopEnv.isMobile;

    return ScrollEdgeFade(
      child: SmoothScroll(
        builder: (context, controller) => ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(
            isMobile ? 16 : 28,
            20,
            isMobile ? 16 : 28,
            28,
          ),
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section(
                      icon: Icons.palette_outlined,
                      title: strings.appearanceSection,
                      children: [
                        // На Android цвета: Monet (или фиолетовый fallback) либо Catppuccin.
                        // У Catppuccin режим задаёт сам вариант (Latte светлый).
                        ExpandSection(
                          expanded: s.colorSource != ColorSource.catppuccin,
                          child: SettingRow(
                            label: strings.themeTitle,
                            // Сегменты занимают всю ширину на телефоне и аккуратный
                            // блок справа от подписи на широком экране.
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: isMobile ? double.infinity : 420,
                              ),
                              child: ExpressiveSegments<ThemeMode>(
                                expand: true,
                                segments: [
                                  ExpressiveSegment(
                                    value: ThemeMode.system,
                                    label: strings.themeSystem,
                                    icon: Icons.brightness_auto,
                                  ),
                                  ExpressiveSegment(
                                    value: ThemeMode.light,
                                    label: strings.themeLight,
                                    icon: Icons.light_mode_outlined,
                                  ),
                                  ExpressiveSegment(
                                    value: ThemeMode.dark,
                                    label: strings.themeDark,
                                    icon: Icons.dark_mode_outlined,
                                  ),
                                ],
                                selected: s.themeMode,
                                onChanged: ctrl.setThemeMode,
                              ),
                            ),
                          ),
                        ),
                        const ColorSourceSection(),
                        const TitleBarSection(),
                        // На Android язык берётся из системы.
                        if (!isMobile)
                          SettingRow(
                            label: strings.languageTitle,
                            child: SettingChoice<AppLanguage>(
                              value: s.language,
                              options: [
                                (AppLanguage.auto, strings.languageAuto),
                                (AppLanguage.ru, strings.languageRu),
                                (AppLanguage.en, strings.languageEn),
                              ],
                              onChanged: ctrl.setLanguage,
                            ),
                          ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(strings.compactUi),
                          value: s.compact,
                          onChanged: ctrl.setCompact,
                        ),
                      ],
                    ),
                    _Section(
                      icon: Icons.dns_outlined,
                      title: strings.hostsSection,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(strings.pingHostsTitle),
                          value: s.pingHosts,
                          onChanged: ctrl.setPingHosts,
                        ),
                        const PingSettings(),
                        const SizedBox(height: 8),
                        SettingRow(
                          label: strings.keepAliveGlobalTitle,
                          child: SettingChoice<int>(
                            value: s.keepAliveSeconds,
                            options: [
                              (0, strings.isRu ? 'Выкл.' : 'Off'),
                              (15, strings.isRu ? '15 с' : '15s'),
                              (30, strings.isRu ? '30 с' : '30s'),
                              (60, strings.isRu ? '1 мин' : '1 min'),
                              (120, strings.isRu ? '2 мин' : '2 min'),
                              (300, strings.isRu ? '5 мин' : '5 min'),
                            ],
                            onChanged: ctrl.setKeepAliveSeconds,
                          ),
                        ),
                      ],
                    ),
                    _Section(
                      icon: Icons.terminal,
                      title: strings.terminalSection,
                      children: [
                        const TerminalFontSection(),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(strings.rememberTerminalFontSizeTitle),
                          value: s.rememberTerminalFontSize,
                          onChanged: ctrl.setRememberTerminalFontSize,
                        ),
                        // Строка Ctrl/Esc/стрелок над экранной клавиатурой - только телефон.
                        if (isMobile)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(strings.accessoryBarTitle),
                            value: s.showAccessoryBar,
                            onChanged: ctrl.setShowAccessoryBar,
                          ),
                        const SizedBox(height: 8),
                        const ClipboardSection(),
                      ],
                    ),
                    _Section(
                      icon: Icons.speed,
                      title: strings.isRu
                          ? 'Производительность'
                          : 'Performance',
                      children: const [PerformanceSection()],
                    ),
                    // Бэкап - на всех платформах: на Android он не менее нужен,
                    // а выбор файла там работает через системные интенты.
                    _Section(
                      icon: Icons.backup_outlined,
                      title: strings.isRu ? 'Резервная копия' : 'Backup',
                      children: const [BackupSection()],
                    ),
                    // Папки - только на компьютере: на Android файлы идут в системную Download.
                    if (!isMobile)
                      _Section(
                        icon: Icons.folder_outlined,
                        title: strings.isRu ? 'Данные' : 'Data',
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              strings.isRu
                                  ? 'Папка для скачанных файлов'
                                  : 'Downloads folder',
                            ),
                            subtitle: Text(
                              s.downloadsDir.isEmpty
                                  ? LocalFiles.defaultDownloadsDir()
                                  : s.downloadsDir,
                              style: monoStyle(
                                context,
                                size: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: Wrap(
                              spacing: 4,
                              children: [
                                if (s.downloadsDir.isNotEmpty)
                                  IconButton(
                                    tooltip: strings.isRu
                                        ? 'По умолчанию'
                                        : 'Default',
                                    icon: const Icon(Icons.restart_alt),
                                    onPressed: () => ctrl.setDownloadsDir(''),
                                  ),
                                IconButton(
                                  tooltip: strings.isRu
                                      ? 'Выбрать папку'
                                      : 'Choose folder',
                                  icon: const Icon(Icons.folder_open),
                                  onPressed: () async {
                                    final dir = await getDirectoryPath();
                                    if (dir != null) ctrl.setDownloadsDir(dir);
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              strings.isRu ? 'Папка с данными' : 'Data folder',
                            ),
                            subtitle: Text(
                              AppPaths.configDir.path,
                              style: monoStyle(
                                context,
                                size: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: IconButton(
                              tooltip: strings.isRu
                                  ? 'Скопировать путь'
                                  : 'Copy path',
                              icon: const Icon(Icons.copy),
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: AppPaths.configDir.path),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      strings.isRu
                                          ? 'Путь скопирован'
                                          : 'Path copied',
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    _Section(
                      icon: Icons.system_update_outlined,
                      title: strings.updatesSection,
                      dot: ref.watch(
                        updateInfoProvider.select((u) => u.value != null),
                      ),
                      children: const [UpdateSection()],
                    ),
                    _Section(
                      icon: Icons.info_outline,
                      title: strings.aboutApp,
                      children: [
                        Row(
                          children: [
                            const AppIcon(size: 56),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'vysh $appVersion',
                                    style: theme.textTheme.titleMedium,
                                  ),
                                  if (buildDate.isNotEmpty)
                                    Text(
                                      'build $vyshBuildNumber · $buildDate',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                  const SizedBox(height: 4),
                                  if (PlatformCapabilities.memoryInfo)
                                    const _MemoryUsage(),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            icon: const Icon(Icons.gavel_outlined, size: 18),
                            label: Text(strings.thirdPartyLicenses),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (context) => _MacSafeLicensePage(
                                  applicationVersion: appVersion,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    this.dot = false,
    required this.children,
  });

  final IconData icon;
  final String title;
  final bool dot;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Text(title, style: theme.textTheme.titleMedium),
                  AnimatedSwitcher(
                    duration: AppMotion.duration(
                      context,
                      AppMotion.durationFast,
                    ),
                    switchInCurve: AppMotion.fastSpringCurve,
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: dot
                        ? Padding(
                            key: const ValueKey('dot'),
                            padding: const EdgeInsets.only(left: 8),
                            child: Badge(
                              smallSize: 8,
                              backgroundColor: theme.colorScheme.primary,
                            ),
                          )
                        : const SizedBox.shrink(key: ValueKey('no-dot')),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// Сколько памяти занимает процесс - чтобы сравнивать сборки и версии.
class _MemoryUsage extends StatefulWidget {
  const _MemoryUsage();

  @override
  State<_MemoryUsage> createState() => _MemoryUsageState();
}

class _MemoryUsageState extends State<_MemoryUsage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    int mb = 0;
    try {
      mb = (ProcessInfo.currentRss / (1024 * 1024)).round();
    } catch (_) {}
    final style = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Row(
      children: [
        Icon(Icons.memory, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            kDebugMode
                ? context.strings.memoryUsage(mb, debug: true)
                : context.strings.memoryUsage(mb, debug: false),
            style: style,
          ),
        ),
        IconButton(
          tooltip: context.strings.refresh,
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          icon: const Icon(Icons.refresh),
          onPressed: () => setState(() {}),
        ),
      ],
    );
  }
}

/// [LicensePage] с отступом сверху на macOS: окно vysh без системного
/// заголовка, полоса вкладок уходит под нативный светофор, а у LicensePage
/// своя панель с back-стрелкой на y=0 - без отступа она залезает под
/// светофор (штатный showLicensePage отступа задать не позволяет).
class _MacSafeLicensePage extends StatelessWidget {
  const _MacSafeLicensePage({required this.applicationVersion});

  final String applicationVersion;

  @override
  Widget build(BuildContext context) {
    final page = LicensePage(
      applicationName: 'vysh',
      applicationVersion: applicationVersion,
      applicationLegalese: 'GNU GPL v3 or later (GPL-3.0-or-later)\n'
          '© vyto4ka and contributors',
      applicationIcon: Padding(
        padding: const EdgeInsets.all(8),
        child: const AppIcon(size: 48),
      ),
    );
    if (!PlatformCapabilities.isMacOS) return page;
    return Padding(
      padding: const EdgeInsets.only(top: 46),
      child: page,
    );
  }
}
