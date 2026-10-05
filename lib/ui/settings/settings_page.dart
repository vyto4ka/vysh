import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/version.dart';
import '../../domain/services/settings_controller.dart';
import '../../infra/platform/local_files.dart';
import '../../infra/storage/app_paths.dart';
import '../theme/app_theme.dart';
import 'appearance_sections.dart';
import 'clipboard_section.dart';
import 'performance_section.dart';
import 'setting_row.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
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
                  title: 'Внешний вид',
                  children: [
                    SettingRow(
                      label: 'Тема',
                      child: SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(value: ThemeMode.system, label: Text('Системная'),
                              icon: Icon(Icons.brightness_auto)),
                          ButtonSegment(value: ThemeMode.light, label: Text('Светлая'),
                              icon: Icon(Icons.light_mode_outlined)),
                          ButtonSegment(value: ThemeMode.dark, label: Text('Тёмная'),
                              icon: Icon(Icons.dark_mode_outlined)),
                        ],
                        selected: {s.themeMode},
                        onSelectionChanged: (v) => ctrl.setThemeMode(v.first),
                      ),
                    ),
                    const ColorSourceSection(),
                    const TitleBarSection(),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Компактный интерфейс'),
                      value: s.compact,
                      onChanged: ctrl.setCompact,
                    ),
                  ],
                ),
                _Section(
                  icon: Icons.dns_outlined,
                  title: 'Хосты',
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Проверять доступность хостов'),
                      value: s.pingHosts,
                      onChanged: ctrl.setPingHosts,
                    ),
                    const PingSettings(),
                  ],
                ),
                _Section(
                  icon: Icons.terminal,
                  title: 'Терминал',
                  children: [
                    SettingRow(
                      label: 'Размер шрифта',
                      child: SizedBox(
                        width: 320,
                        child: Row(
                          children: [
                            Expanded(
                              child: Slider(
                                min: 9,
                                max: 24,
                                divisions: 15,
                                value: s.terminalFontSize.clamp(9, 24).toDouble(),
                                label: s.terminalFontSize.round().toString(),
                                onChanged: ctrl.setTerminalFontSize,
                              ),
                            ),
                            SizedBox(
                              width: 32,
                              child: Text('${s.terminalFontSize.round()}',
                                  textAlign: TextAlign.end),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'root@server:~\$ htop',
                        style: monoStyle(context,
                            size: s.terminalFontSize, color: scheme.onSurface),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const ClipboardSection(),
                  ],
                ),
                const _Section(
                  icon: Icons.speed,
                  title: 'Производительность',
                  children: [PerformanceSection()],
                ),
                _Section(
                  icon: Icons.folder_outlined,
                  title: 'Данные',
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Папка для скачанных файлов'),
                      subtitle: Text(
                          s.downloadsDir.isEmpty ? LocalFiles.defaultDownloadsDir() : s.downloadsDir,
                          style: monoStyle(context, size: 12, color: scheme.onSurfaceVariant)),
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          if (s.downloadsDir.isNotEmpty)
                            IconButton(
                              tooltip: 'По умолчанию',
                              icon: const Icon(Icons.restart_alt),
                              onPressed: () => ctrl.setDownloadsDir(''),
                            ),
                          IconButton(
                            tooltip: 'Выбрать папку',
                            icon: const Icon(Icons.folder_open),
                            onPressed: () async {
                              final dir = await getDirectoryPath();
                              if (dir != null) ctrl.setDownloadsDir(dir);
                            },
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Папка с данными'),
                      subtitle: Text(AppPaths.configDir.path,
                          style: monoStyle(context, size: 12, color: scheme.onSurfaceVariant)),
                      trailing: IconButton(
                        tooltip: 'Скопировать путь',
                        icon: const Icon(Icons.copy),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: AppPaths.configDir.path));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Путь скопирован')),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                _Section(
                  icon: Icons.info_outline,
                  title: 'О программе',
                  children: [
                    Row(
                      children: [
                        Image.asset(
                          'assets/icon/vysh_256.png',
                          width: 56,
                          height: 56,
                          cacheWidth: (56 * MediaQuery.devicePixelRatioOf(context)).ceil(),
                          filterQuality: FilterQuality.medium,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('vysh $appVersion', style: theme.textTheme.titleMedium),
                              const _MemoryUsage(),
                            ],
                          ),
                        ),
                      ],
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
  const _Section({required this.icon, required this.title, required this.children});

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
    final mb = (ProcessInfo.currentRss / (1024 * 1024)).round();
    final style = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Row(
      children: [
        Icon(Icons.memory, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            kDebugMode
                ? 'Память: $mb МБ (отладочная сборка)'
                : 'Память: $mb МБ',
            style: style,
          ),
        ),
        IconButton(
          tooltip: 'Обновить',
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          icon: const Icon(Icons.refresh),
          onPressed: () => setState(() {}),
        ),
      ],
    );
  }
}
