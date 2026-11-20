import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/ports/sftp.dart';
import '../../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/strings_context.dart';

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
  return showDialog<String>(
    context: context,
    builder: (_) => _AskTextDialog(title: title, label: label, initial: initial),
  );
}

class _AskTextDialog extends StatefulWidget {
  const _AskTextDialog({
    required this.title,
    required this.label,
    required this.initial,
  });

  final String title;
  final String label;
  final String initial;

  @override
  State<_AskTextDialog> createState() => _AskTextDialogState();
}

class _AskTextDialogState extends State<_AskTextDialog> {
  late final TextEditingController _c;

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.initial);
    // Выделяем имя без расширения - как в файловых менеджерах.
    final dot = widget.initial.lastIndexOf('.');
    _c.selection = TextSelection(
      baseOffset: 0,
      extentOffset: dot > 0 ? dot : widget.initial.length,
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _c,
          autofocus: true,
          decoration: _dec(widget.label),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.strings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _c.text.trim()),
          child: Text(context.strings.ok),
        ),
      ],
    );
  }
}

Future<bool> confirmDelete(BuildContext context, List<RemoteEntry> entries) async {
  final dirs = entries.where((e) => e.isDir && !e.isLink).length;
  final strings = context.strings;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: Text(strings.deleteWhatTitle([for (final e in entries) e.name])),
        content: Text(dirs > 0
            ? strings.deleteFoldersDesc
            : strings.deleteFilesDesc),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.strings.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.delete),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}

/// Файлы с такими именами уже есть на сервере.
/// true - заменить, false - пропустить их, null - отменить загрузку.
Future<bool?> askOverwrite(BuildContext context, List<String> names) {
  final strings = context.strings;
  final shown = names.take(8).join('\n') + (names.length > 8 ? '\n…' : '');
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.file_copy_outlined),
      title: Text(strings.replaceWhatTitle(names)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(strings.replaceDesc),
            const SizedBox(height: 8),
            Text(shown, style: monoStyle(context, size: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(strings.skip),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(strings.replace),
        ),
      ],
    ),
  );
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
  // 12 бит: rwx и специальные setuid/setgid/sticky - их не теряем.
  late int _mode = (widget.entry.mode ?? 0x1A4 /* 644 */) & 0xFFF;
  late final _octal = TextEditingController(text: _octalText(_mode));

  static String _octalText(int mode) =>
      mode.toRadixString(8).padLeft(mode > 0x1FF ? 4 : 3, '0');

  @override
  void dispose() {
    _octal.dispose();
    super.dispose();
  }

  void _setBit(int bit, bool on) {
    setState(() {
      _mode = on ? _mode | (1 << bit) : _mode & ~(1 << bit);
      _octal.text = _octalText(_mode);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.strings;
    final who = strings.permissionWho;
    final what = strings.permissionWhat;
    return AlertDialog(
      title: Text(strings.permissions),
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
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final (bit, label) in const [
                  (11, 'setuid'),
                  (10, 'setgid'),
                  (9, 'sticky'),
                ])
                  FilterChip(
                    label: Text(label),
                    selected: (_mode & (1 << bit)) != 0,
                    onSelected: (v) => _setBit(bit, v),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _octal,
              style: monoStyle(context, size: 14),
              decoration: _dec(strings.octalHint),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[0-7]')),
                LengthLimitingTextInputFormatter(4),
              ],
              onChanged: (v) {
                final m = int.tryParse(v, radix: 8);
                if (m != null) setState(() => _mode = m & 0xFFF);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, _mode), child: Text(strings.apply)),
      ],
    );
  }
}
