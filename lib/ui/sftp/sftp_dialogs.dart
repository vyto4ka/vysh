import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/ports/sftp.dart';
import '../theme/app_theme.dart';

InputDecoration _dec(String label) => InputDecoration(
      labelText: label,
      filled: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );

/// Запросить строку (имя папки, новое имя файла).
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
}) {
  final c = TextEditingController(text: initial);
  // Выделяем имя без расширения - как в файловых менеджерах.
  final dot = initial.lastIndexOf('.');
  c.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : initial.length);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: c,
          autofocus: true,
          decoration: _dec(label),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
          onPressed: () => Navigator.pop(context, c.text.trim()),
          child: const Text('ОК'),
        ),
      ],
    ),
  );
}

Future<bool> confirmDelete(BuildContext context, List<RemoteEntry> entries) async {
  final dirs = entries.where((e) => e.isDir && !e.isLink).length;
  final what = entries.length == 1 ? '«${entries.first.name}»' : '${entries.length} элементов';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: Text('Удалить $what?'),
        content: Text(dirs > 0
            ? 'Папки будут удалены вместе со всем содержимым. Это нельзя отменить.'
            : 'Файлы будут удалены с сервера. Это нельзя отменить.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}

/// Диалог прав доступа: галочки rwx + восьмеричное поле.
Future<int?> askPermissions(BuildContext context, RemoteEntry e) {
  return showDialog<int>(
    context: context,
    builder: (_) => _PermissionsDialog(entry: e),
  );
}

class _PermissionsDialog extends StatefulWidget {
  const _PermissionsDialog({required this.entry});
  final RemoteEntry entry;

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  late int _mode = (widget.entry.mode ?? 0x1A4 /* 644 */) & 0x1FF;
  late final _octal = TextEditingController(text: _mode.toRadixString(8).padLeft(3, '0'));

  @override
  void dispose() {
    _octal.dispose();
    super.dispose();
  }

  void _setBit(int bit, bool on) {
    setState(() {
      _mode = on ? _mode | (1 << bit) : _mode & ~(1 << bit);
      _octal.text = _mode.toRadixString(8).padLeft(3, '0');
    });
  }

  @override
  Widget build(BuildContext context) {
    const who = ['Владелец', 'Группа', 'Остальные'];
    const what = ['Чтение', 'Запись', 'Выполнение'];
    return AlertDialog(
      title: const Text('Права доступа'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.entry.path, style: monoStyle(context, size: 12)),
            const SizedBox(height: 12),
            Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                TableRow(children: [
                  const SizedBox(),
                  for (final w in what)
                    Center(child: Text(w, style: Theme.of(context).textTheme.labelMedium)),
                ]),
                for (var r = 0; r < 3; r++)
                  TableRow(children: [
                    Text(who[r]),
                    for (var c = 0; c < 3; c++)
                      Checkbox(
                        value: (_mode & (1 << (8 - r * 3 - c))) != 0,
                        onChanged: (v) => _setBit(8 - r * 3 - c, v ?? false),
                      ),
                  ]),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _octal,
              style: monoStyle(context, size: 14),
              decoration: _dec('Восьмерично (например, 755)'),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-7]')),
                LengthLimitingTextInputFormatter(4),
              ],
              onChanged: (v) {
                final m = int.tryParse(v, radix: 8);
                if (m != null) setState(() => _mode = m & 0x1FF);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, _mode), child: const Text('Применить')),
      ],
    );
  }
}
