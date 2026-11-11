import 'package:flutter/material.dart';

/// The same path navigation in the workspace and the terminal's file pane.
class FilePathBar extends StatelessWidget {
  const FilePathBar({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onOpen,
    required this.onUp,
    required this.onRefresh,
    required this.isRu,
    this.trailing,
  });
  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onOpen;
  final VoidCallback? onUp;
  final VoidCallback? onRefresh;
  final bool isRu;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Row(
      children: [
        IconButton(
          tooltip: isRu ? 'На уровень выше' : 'Parent folder',
          onPressed: enabled ? onUp : null,
          icon: const Icon(Icons.arrow_upward),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            maxLines: 1,
            style: Theme.of(context).textTheme.bodyMedium,
            onSubmitted: (v) => onOpen(v.trim().isEmpty ? '/' : v.trim()),
            decoration: InputDecoration(
              hintText: isRu ? 'Путь к папке' : 'Folder path',
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: isRu ? 'Обновить папку' : 'Refresh folder',
          onPressed: enabled ? onRefresh : null,
          icon: const Icon(Icons.refresh),
        ),
        ?trailing,
      ],
    ),
  );
}
