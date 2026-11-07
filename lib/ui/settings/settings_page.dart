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
import '../../infra/platform/desktop_env.dart';
import '../../infra/platform/local_files.dart';
import '../../infra/storage/app_paths.dart';
import '../theme/app_theme.dart';
import 'appearance_sections.dart';
import 'backup_section.dart';
import 'clipboard_section.dart';
import 'performance_section.dart';
import 'setting_row.dart';
import 'terminal_font_section.dart';

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

    return ListView(
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
                    if (s.colorSource != ColorSource.catppuccin)
                    SettingRow(
                      label: strings.themeTitle,
                      // Сегменты должны занять всю ширину карточки, а подпись
                      // сжиматься, а не резаться многоточием.
                      child: SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<ThemeMode>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            padding: WidgetStatePropertyAll(
                              EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            ),
                            textStyle: WidgetStatePropertyAll(
                              TextStyle(fontSize: 13),
                            ),
                          ),
                          segments: [
                            ButtonSegment(
                              value: ThemeMode.system,
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(strings.themeSystem),
                              ),
                              icon: const Icon(Icons.brightness_auto, size: 18),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(strings.themeLight),
                              ),
                              icon: const Icon(Icons.light_mode_outlined, size: 18),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(strings.themeDark),
                              ),
                              icon: const Icon(Icons.dark_mode_outlined, size: 18),
                            ),
                          ],
                          selected: {s.themeMode},
                          onSelectionChanged: (v) => ctrl.setThemeMode(v.first),
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
                  title: strings.isRu ? 'Производительность' : 'Performance',
                  children: const [PerformanceSection()],
                ),
                // Папки - только на компьютере: на Android файлы идут в системную Download.
                if (!isMobile)
                  _Section(
                    icon: Icons.folder_outlined,
                    title: strings.isRu ? 'Данные' : 'Data',
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(strings.isRu ? 'Папка для скачанных файлов' : 'Downloads folder'),
                        subtitle: Text(
                            s.downloadsDir.isEmpty ? LocalFiles.defaultDownloadsDir() : s.downloadsDir,
                            style: monoStyle(context, size: 12, color: scheme.onSurfaceVariant)),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            if (s.downloadsDir.isNotEmpty)
                              IconButton(
                                tooltip: strings.isRu ? 'По умолчанию' : 'Default',
                                icon: const Icon(Icons.restart_alt),
                                onPressed: () => ctrl.setDownloadsDir(''),
                              ),
                            IconButton(
                              tooltip: strings.isRu ? 'Выбрать папку' : 'Choose folder',
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
                      const BackupSection(),
                      const SizedBox(height: 8),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(strings.isRu ? 'Папка с данными' : 'Data folder'),
                        subtitle: Text(AppPaths.configDir.path,
                            style: monoStyle(context, size: 12, color: scheme.onSurfaceVariant)),
                        trailing: IconButton(
                          tooltip: strings.isRu ? 'Скопировать путь' : 'Copy path',
                          icon: const Icon(Icons.copy),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: AppPaths.configDir.path));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(strings.isRu ? 'Путь скопирован' : 'Path copied')),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                _Section(
                  icon: Icons.info_outline,
                  title: strings.aboutApp,
                  children: [
                    Row(
                      children: [
                        Image.asset(
                          'assets/icon/vysh_256.png',
                          width: 56,
                          height: 56,
                          errorBuilder: (_, _, _) => const Icon(Icons.dns_rounded, size: 56),
                        ),
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
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              const SizedBox(height: 4),
                              if (PlatformCapabilities.memoryInfo) const _MemoryUsage(),
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
                        // Тексты лицензий всех пакетов Flutter собирает в сборку сам
                        // (NOTICES); палитра Catppuccin добавлена в main.dart.
                        //
                        // macOS: окно без системного заголовка (вкладки под
                        // светофором), а у LicensePage своя панель с кнопкой
                        // «назад» на самом верху - без отступа она попадает
                        // под светофор. Отступ сверху на высоту полосы вкладок.
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
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
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
        child: Image.asset('assets/icon/vysh_256.png', width: 48, height: 48),
      ),
    );
    if (!PlatformCapabilities.isMacOS) return page;
    return Padding(
      padding: const EdgeInsets.only(top: 46),
      child: page,
    );
  }
}
