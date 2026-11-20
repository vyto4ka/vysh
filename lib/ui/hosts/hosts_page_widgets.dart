part of 'hosts_page.dart';

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.strings, required this.onAdd});

  final AppStrings strings;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Icon(
              Icons.dns_rounded,
              size: 44,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          Text(strings.noHostsTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              strings.noHostsDesc,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: Text(strings.newHost),
          ),
        ],
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults({
    required this.query,
    required this.quick,
    required this.strings,
    required this.onQuick,
  });

  final String query;
  final Host? quick;
  final AppStrings strings;
  final ValueChanged<Host> onQuick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              strings.isRu
                  ? 'Ничего не найдено по «$query»'
                  : 'No results for "$query"',
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (quick != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => onQuick(quick!),
                icon: const Icon(Icons.bolt),
                label: Text(
                  strings.isRu
                      ? 'Подключиться к ${quick!.displayAddress}'
                      : 'Connect to ${quick!.displayAddress}',
                ),
              ),
              const SizedBox(height: 6),
              Text(
                strings.isRu
                    ? 'Enter - подключиться без сохранения'
                    : 'Enter to connect without saving',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Заголовок группы: название, число хостов и действия над всей группой.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.name,
    required this.hosts,
    required this.selected,
    required this.onConnectAll,
    required this.onSelectAll,
    required this.onDeleteAll,
  });

  final String name;
  final List<Host> hosts;
  final Set<String> selected;
  final VoidCallback onConnectAll;
  final VoidCallback onSelectAll;
  final VoidCallback onDeleteAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final all = hosts.every((h) => selected.contains(h.id));
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Row(
        children: [
          Flexible(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${hosts.length}',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: context.strings.connectAll(hosts.length),
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: onConnectAll,
          ),
          IconButton(
            tooltip: all ? context.strings.deselectGroup : context.strings.selectGroup,
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: Icon(all ? Icons.check_box : Icons.check_box_outline_blank),
            onPressed: onSelectAll,
          ),
          MenuIconButton(
            tooltip: context.strings.groupActions,
            items: [
              menuItem(
                context.strings.connectAllCount(hosts.length),
                icon: Icons.play_arrow_rounded,
                onPressed: onConnectAll,
              ),
              menuItem(
                all ? context.strings.deselectAll : context.strings.selectAllInGroup,
                icon: Icons.check_box_outlined,
                onPressed: onSelectAll,
              ),
              menuDivider(),
              menuItem(
                context.strings.deleteGroup,
                icon: Icons.delete_outline,
                color: scheme.error,
                onPressed: onDeleteAll,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Панель вместо поиска, пока выбраны хосты.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    super.key,
    required this.count,
    required this.allSelected,
    required this.onSelectAll,
    required this.onClear,
    required this.onConnect,
    required this.onDelete,
  });

  final int count;
  final bool allSelected;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback onConnect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: 4, right: 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(22),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < 480;
          return Row(
            children: [
              IconButton(
                tooltip: context.strings.clearSelectionEsc,
                icon: Icon(Icons.close, color: scheme.onSecondaryContainer),
                onPressed: onClear,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        context.strings.selectedCount(count),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    if (!allSelected) ...[
                      const SizedBox(width: 4),
                      if (narrow)
                        IconButton(
                          tooltip: context.strings.selectEverything,
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            Icons.select_all,
                            size: 20,
                            color: scheme.onSecondaryContainer,
                          ),
                          onPressed: onSelectAll,
                        )
                      else
                        TextButton(
                          onPressed: onSelectAll,
                          child: Text(context.strings.selectEverything),
                        ),
                    ],
                  ],
                ),
              ),
              if (narrow) ...[
                IconButton.filled(
                  tooltip: context.strings.connectAll(count),
                  visualDensity: VisualDensity.compact,
                  onPressed: onConnect,
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
                const SizedBox(width: 4),
                IconButton.filledTonal(
                  tooltip: context.strings.delete,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.errorContainer,
                    foregroundColor: scheme.onErrorContainer,
                  ),
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: onConnect,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(context.strings.connectAll(count)),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.errorContainer,
                    foregroundColor: scheme.onErrorContainer,
                  ),
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(context.strings.delete),
                ),
              ],
              const SizedBox(width: 2),
            ],
          );
        },
      ),
    );
  }
}
