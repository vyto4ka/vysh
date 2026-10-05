import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/services/settings_controller.dart';
import 'setting_row.dart';

/// Частота проверки доступности хостов (секция «Хосты»).
class PingSettings extends ConsumerWidget {
  const PingSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    if (!s.pingHosts) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingRow(
          label: 'Интервал',
          child: SettingChoice<int>(
            value: s.pingIntervalSec,
            options: const [(15, '15 с'), (30, '30 с'), (60, '1 мин'), (300, '5 мин')],
            onChanged: ctrl.setPingIntervalSec,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Только пока список хостов на экране'),
          value: s.pingOnlyVisible,
          onChanged: ctrl.setPingOnlyVisible,
        ),
      ],
    );
  }
}

/// Секция «Производительность».
class PerformanceSection extends ConsumerWidget {
  const PerformanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);
    final restart = s.renderer != startupRenderer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingRow(
          label: 'Отрисовка',
          child: Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SettingChoice<Renderer>(
                value: s.renderer,
                options: const [(Renderer.skia, 'Skia'), (Renderer.impeller, 'Impeller')],
                onChanged: ctrl.setRenderer,
              ),
              if (restart)
                Text('после перезапуска',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
            ],
          ),
        ),
        SettingRow(
          label: 'История терминала',
          child: SettingChoice<int>(
            value: s.scrollbackLines,
            options: const [
              (1000, '1 тыс.'),
              (10000, '10 тыс.'),
              (100000, '100 тыс.'),
              (AppSettings.maxScrollback, '1 млн'),
            ],
            onChanged: ctrl.setScrollbackLines,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Пауза анимаций в фоновых вкладках'),
          value: s.pauseHiddenTabs,
          onChanged: ctrl.setPauseHiddenTabs,
        ),
      ],
    );
  }
}
