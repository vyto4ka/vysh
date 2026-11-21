import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/settings/app_settings.dart';
import '../../l10n/app_strings.dart';
import '../../app/controllers/settings_controller.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import 'setting_row.dart';

class PingSettings extends ConsumerWidget {
  const PingSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final strings = AppStrings.of(context, s.language);

    return ExpandSection(
      expanded: s.pingHosts,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingRow(
            label: strings.isRu ? 'Интервал проверки' : 'Ping interval',
            child: SettingChoice<int>(
              value: s.pingIntervalSec,
              options: [
                (15, strings.isRu ? '15 с' : '15s'),
                (30, strings.isRu ? '30 с' : '30s'),
                (60, strings.isRu ? '1 мин' : '1 min'),
                (120, strings.isRu ? '2 мин' : '2 min'),
                (300, strings.isRu ? '5 мин' : '5 min'),
              ],
              onChanged: ctrl.setPingIntervalSec,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              strings.isRu
                  ? 'Только пока список хостов на экране'
                  : 'Only while the host list is visible',
            ),
            value: s.pingOnlyVisible,
            onChanged: ctrl.setPingOnlyVisible,
          ),
        ],
      ),
    );
  }
}

class PerformanceSection extends ConsumerWidget {
  const PerformanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final strings = AppStrings.of(context, s.language);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingRow(
          label: strings.isRu ? 'История терминала' : 'Scrollback lines',
          child: SettingChoice<int>(
            value: s.scrollbackLines,
            options: [
              (1000, '1 000'),
              (5000, '5 000'),
              (10000, '10 000'),
              (50000, '50 000'),
              (100000, '100 000'),
              (1000000, strings.isRu ? '1 млн' : '1M'),
            ],
            onChanged: ctrl.setScrollbackLines,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            strings.isRu
                ? 'Пауза анимаций в фоновых вкладках'
                : 'Pause animations in background tabs',
          ),
          value: s.pauseHiddenTabs,
          onChanged: ctrl.setPauseHiddenTabs,
        ),
        // На Android и macOS движок задаётся сборкой, переключатель только для Windows и Linux.
        if (!DesktopEnv.isMobile && !PlatformCapabilities.isMacOS)
          SettingRow(
            label: strings.isRu ? 'Отрисовка' : 'Renderer',
            child: Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SettingChoice<Renderer>(
                  value: s.renderer,
                  options: const [
                    (Renderer.skia, 'Skia'),
                    (Renderer.impeller, 'Impeller'),
                  ],
                  onChanged: ctrl.setRenderer,
                ),
                AnimatedSwitcher(
                  duration: AppMotion.duration(context, AppMotion.durationFast),
                  child: s.renderer != startupRenderer
                      ? Text(
                          strings.isRu ? 'после перезапуска' : 'after restart',
                          key: const ValueKey('restart'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                        )
                      : const SizedBox.shrink(key: ValueKey('same')),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
