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
            title: const Text('Только когда список хостов на экране'),
            subtitle: const Text(
                'Не проверять, пока открыт терминал или окно свёрнуто'),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
          'Сколько строк можно пролистать назад. Действует на новые вкладки. '
          'Память расходуется по мере вывода: около 2 МБ на 1000 строк шириной 120 символов. '
          '«1 млн» — практически без ограничения.',
          style: hint,
        ),
        const SizedBox(height: 16),
        _Choice<int>(
          label: 'Проверка цветов',
          value: s.colorPollSec,
          options: const [(0, 'Только события'), (10, '10 с'), (60, '1 мин'), (300, '5 мин')],
          onChanged: ctrl.setColorPollSec,
        ),
        const SizedBox(height: 4),
        Text(
          'Для режимов «Акцент системы» и «Из дотов». Смену файла дотов, сигнал портала '
          'и возврат в окно vysh ловит сразу — это запасная проверка на случай, '
          'если событие потерялось. Пока окно свёрнуто, не работает.',
          style: hint,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.pause_circle_outline),
          title: const Text('Останавливать анимации в фоновых вкладках'),
          subtitle: const Text('Сессии и передачи работают как обычно, не тратятся только кадры'),
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
