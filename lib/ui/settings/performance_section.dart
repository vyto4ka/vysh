import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/app_settings.dart';
import '../../domain/services/settings_controller.dart';

/// Частота проверки доступности хостов (секция «Хосты»).
class PingSettings extends ConsumerWidget {
  const PingSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    if (!s.pingHosts) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          _Choice<int>(
            label: 'Как часто',
            value: s.pingIntervalSec,
            options: const [(15, '15 с'), (30, '30 с'), (60, '1 мин'), (300, '5 мин')],
            onChanged: ctrl.setPingIntervalSec,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Только пока список хостов на экране'),
            subtitle: const Text('Не проверять из терминала и при свёрнутом окне'),
            value: s.pingOnlyVisible,
            onChanged: ctrl.setPingOnlyVisible,
          ),
        ],
      ),
    );
  }
}

/// Секция «Производительность»: всё, что влияет на память и фоновую работу.
class PerformanceSection extends ConsumerWidget {
  const PerformanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final restart = s.renderer != startupRenderer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Choice<Renderer>(
          label: 'Отрисовка',
          value: s.renderer,
          options: const [
            (Renderer.skia, 'Skia'),
            (Renderer.impeller, 'Impeller'),
          ],
          onChanged: ctrl.setRenderer,
        ),
        const SizedBox(height: 4),
        Text(
          'Skia тратит в 2-3 раза меньше памяти. Impeller плавнее на первых '
          'анимациях. Меняется после перезапуска.',
          style: hint,
        ),
        if (restart) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.restart_alt, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text('Перезапустите vysh, чтобы применить',
                    style: hint?.copyWith(color: theme.colorScheme.primary)),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        _Choice<int>(
          label: 'История терминала',
          value: s.scrollbackLines,
          options: const [
            (1000, '1 тыс.'),
            (10000, '10 тыс.'),
            (100000, '100 тыс.'),
            (AppSettings.maxScrollback, '1 млн'),
          ],
          onChanged: ctrl.setScrollbackLines,
        ),
        const SizedBox(height: 4),
        Text(
          'Сколько строк можно прокрутить назад, для новых вкладок. '
          '1000 строк занимают около 2 МБ. 1 млн: почти без ограничения.',
          style: hint,
        ),
        const SizedBox(height: 16),
        _Choice<int>(
          label: 'Проверка цветов',
          value: s.colorPollSec,
          options: const [(0, 'Выкл.'), (10, '10 с'), (60, '1 мин'), (300, '5 мин')],
          onChanged: ctrl.setColorPollSec,
        ),
        const SizedBox(height: 4),
        Text(
          'Для акцента системы и дотов. Изменения и так подхватываются сразу, '
          'это страховка на случай пропуска. При свёрнутом окне не работает.',
          style: hint,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.pause_circle_outline),
          title: const Text('Пауза анимаций в фоновых вкладках'),
          subtitle: const Text('Сессии и передачи файлов продолжают работать'),
          value: s.pauseHiddenTabs,
          onChanged: ctrl.setPauseHiddenTabs,
        ),
      ],
    );
  }
}

/// Подпись + сегментированный выбор; на узком окне переносится вниз.
class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    // Значение из старых настроек может не совпасть ни с одним вариантом.
    final known = options.any((o) => o.$1 == value);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 8,
      children: [
        SizedBox(
          width: 160,
          child: Text(label, style: Theme.of(context).textTheme.titleSmall),
        ),
        SegmentedButton<T>(
          showSelectedIcon: false,
          emptySelectionAllowed: !known,
          segments: [
            for (final o in options) ButtonSegment(value: o.$1, label: Text(o.$2)),
          ],
          selected: known ? {value} : <T>{},
          onSelectionChanged: (v) {
            if (v.isNotEmpty) onChanged(v.first);
          },
        ),
      ],
    );
  }
}
