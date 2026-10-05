import 'package:flutter/material.dart';

/// Строка настроек: подпись слева, управление справа.
/// Одинаковая для всех секций, чтобы элементы стояли в одну колонку.
class SettingRow extends StatelessWidget {
  const SettingRow({super.key, required this.label, required this.child});

  /// Ширина колонки подписей.
  static const labelWidth = 160.0;

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(label, style: Theme.of(context).textTheme.titleSmall),
          ),
          child,
        ],
      ),
    );
  }
}

/// Сегментированный выбор из готовых значений.
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
    return SegmentedButton<T>(
      showSelectedIcon: false,
      emptySelectionAllowed: !known,
      segments: [
        for (final o in options) ButtonSegment(value: o.$1, label: Text(o.$2)),
      ],
      selected: known ? {value} : <T>{},
      onSelectionChanged: (v) {
        if (v.isNotEmpty) onChanged(v.first);
      },
    );
  }
}
