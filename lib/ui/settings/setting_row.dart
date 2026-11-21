import 'package:flutter/material.dart';

import '../../infra/platform/desktop_env.dart';
import '../motion/expressive_segments.dart';

/// Строка настроек: подпись слева, управление справа.
/// На широком экране подписи стоят в одну колонку одинаковой ширины,
/// на узком (телефон) управление уходит под подпись.
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.label, required this.child});

  /// Ширина колонки подписей.
  static const labelWidth = 160.0;

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < 450) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: style),
                const SizedBox(height: 8),
                child,
              ],
            );
          }
          return Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 8,
            children: [
              SizedBox(width: labelWidth, child: Text(label, style: style)),
              child,
            ],
          );
        },
      ),
    );
  }
}

/// Выбор из готовых значений: на компьютере - сегменты,
/// на телефоне - выпадающий список (сегменты не помещаются по ширине).
class SettingChoice<T> extends StatelessWidget {
  const SettingChoice({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    // Значение из старых настроек может не совпасть ни с одним вариантом.
    final known = options.any((o) => o.$1 == value);

    if (DesktopEnv.isMobile) {
      return DropdownButton<T>(
        value: known ? value : null,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(12),
        items: [
          for (final (v, label) in options)
            DropdownMenuItem<T>(value: v, child: Text(label)),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      );
    }

    return ExpressiveSegments<T>(
      segments: [
        for (final o in options) ExpressiveSegment(value: o.$1, label: o.$2),
      ],
      selected: known ? value : null,
      onChanged: onChanged,
    );
  }
}
