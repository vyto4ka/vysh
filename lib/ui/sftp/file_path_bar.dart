import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/settings/app_settings.dart';
import '../../app/sftp/sftp_directory.dart';
import '../../l10n/app_strings.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import '../widgets/context_menu.dart';

/// Адресная строка проводника: Назад/Вперёд/Вверх, путь, поиск, сортировка,
/// обновление и полоска кликабельных «хлебных крошек» (breadcrumbs).
class FilePathBar extends StatelessWidget {
  const FilePathBar({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onOpen,
    required this.onUp,
    required this.onRefresh,
    required this.isRu,
    this.pathFocusNode,
    this.onBack,
    this.onForward,
    this.cwd,
    this.windowsPaths = false,
    this.showFilter = false,
    this.filterController,
    this.filterFocusNode,
    this.onToggleFilter,
    this.onCloseFilter,
    this.sortField,
    this.sortAscending = true,
    this.onSortSelected,
    this.trailing,
  });

  final TextEditingController controller;
  final FocusNode? pathFocusNode;
  final bool enabled;
  final ValueChanged<String> onOpen;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final VoidCallback? onUp;
  final VoidCallback? onRefresh;
  final bool isRu;
  final String? cwd;
  final bool windowsPaths;
  final bool showFilter;
  final TextEditingController? filterController;
  final FocusNode? filterFocusNode;
  final VoidCallback? onToggleFilter;
  final VoidCallback? onCloseFilter;
  final SftpSortField? sortField;
  final bool sortAscending;
  final ValueChanged<SftpSortField>? onSortSelected;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings(isRu: isRu);
    final scheme = Theme.of(context).colorScheme;
    const compactBtn = BoxConstraints(minWidth: 34, minHeight: 34);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 6, 4),
          child: Row(
            children: [
              if (onBack != null || onForward != null) ...[
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: compactBtn,
                  padding: EdgeInsets.zero,
                  iconSize: 19,
                  tooltip: '${s.backFolder} (Alt+←)',
                  onPressed: enabled ? onBack : null,
                  icon: const Icon(Icons.arrow_back),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: compactBtn,
                  padding: EdgeInsets.zero,
                  iconSize: 19,
                  tooltip: '${s.forwardFolder} (Alt+→)',
                  onPressed: enabled ? onForward : null,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
              IconButton.filledTonal(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                iconSize: 19,
                tooltip: isRu ? 'На уровень выше' : 'Parent folder',
                onPressed: enabled ? onUp : null,
                icon: const Icon(Icons.arrow_upward),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: pathFocusNode,
                  enabled: enabled,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.bodyMedium,
                  onSubmitted: (v) => onOpen(
                    v.trim().isEmpty ? (windowsPaths ? r'\' : '/') : v.trim(),
                  ),
                  decoration: InputDecoration(
                    hintText: isRu ? 'Путь к папке' : 'Folder path',
                    filled: true,
                    isDense: true,
                    fillColor: scheme.surfaceContainer,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: scheme.outlineVariant),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: scheme.primary, width: 2),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              if (onToggleFilter != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: compactBtn,
                  iconSize: 20,
                  isSelected: showFilter,
                  tooltip: '${s.filterFiles} (Ctrl+F)',
                  onPressed: enabled ? onToggleFilter : null,
                  icon: const Icon(Icons.search),
                ),
              if (sortField != null && onSortSelected != null)
                MenuIconButton(
                  enabled: enabled,
                  icon: Icons.sort,
                  tooltip: s.sortTitle,
                  isSelected: sortField != SftpSortField.name || !sortAscending,
                  items: [
                    for (final (field, label) in [
                      (SftpSortField.name, s.sortByName),
                      (SftpSortField.size, s.sortBySize),
                      (SftpSortField.modified, s.sortByModified),
                      (SftpSortField.type, s.sortByType),
                    ])
                      MenuItemButton(
                        leadingIcon: Icon(
                          sortField == field
                              ? (sortAscending
                                    ? Icons.arrow_upward
                                    : Icons.arrow_downward)
                              : null,
                          size: 18,
                          color: scheme.primary,
                        ),
                        onPressed: () => onSortSelected!(field),
                        child: Text(label),
                      ),
                  ],
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: compactBtn,
                iconSize: 20,
                tooltip: isRu ? 'Обновить папку' : 'Refresh folder',
                onPressed: enabled ? onRefresh : null,
                icon: const Icon(Icons.refresh),
              ),
              ?trailing,
            ],
          ),
        ),
        if (cwd != null && cwd!.isNotEmpty)
          _BreadcrumbsBar(
            cwd: cwd!,
            windowsPaths: windowsPaths,
            enabled: enabled,
            drivesLabel: s.drivesList,
            onOpen: onOpen,
          ),
        if (filterController != null)
          ExpandSection(
            expanded: showFilter,
            spring: AppMotion.spatialFast,
            child: showFilter
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                    child: CallbackShortcuts(
                      bindings: {
                        const SingleActivator(LogicalKeyboardKey.escape): () =>
                            onCloseFilter?.call(),
                      },
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: filterController!,
                        builder: (context, val, _) => TextField(
                          controller: filterController,
                          focusNode: filterFocusNode,
                          autofocus: true,
                          maxLines: 1,
                          style: Theme.of(context).textTheme.bodySmall,
                          decoration: InputDecoration(
                            hintText: s.filterFiles,
                            prefixIcon: const Icon(Icons.filter_list, size: 18),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 32,
                            ),
                            suffixIcon: IconButton(
                              visualDensity: VisualDensity.compact,
                              iconSize: 18,
                              tooltip: s.clearFilter,
                              onPressed: () {
                                if (val.text.isNotEmpty) {
                                  filterController!.clear();
                                } else {
                                  onCloseFilter?.call();
                                }
                              },
                              icon: const Icon(Icons.close),
                            ),
                            isDense: true,
                            filled: true,
                            fillColor: scheme.surfaceContainerHigh,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
      ],
    );
  }
}

class _BreadcrumbsBar extends StatefulWidget {
  const _BreadcrumbsBar({
    required this.cwd,
    required this.windowsPaths,
    required this.enabled,
    required this.drivesLabel,
    required this.onOpen,
  });

  final String cwd;
  final bool windowsPaths;
  final bool enabled;
  final String drivesLabel;
  final ValueChanged<String> onOpen;

  @override
  State<_BreadcrumbsBar> createState() => _BreadcrumbsBarState();
}

class _BreadcrumbsBarState extends State<_BreadcrumbsBar> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToEnd();
  }

  @override
  void didUpdateWidget(covariant _BreadcrumbsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cwd != widget.cwd) {
      _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final segments = sftpBreadcrumbs(widget.cwd, windows: widget.windowsPaths);
    if (segments.length <= 1 && !widget.windowsPaths) {
      return const SizedBox(height: 4);
    }
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SizedBox(
      height: 28,
      child: SingleChildScrollView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            for (var i = 0; i < segments.length; i++) ...[
              if (i > 0)
                Icon(Icons.chevron_right, size: 15, color: scheme.outline),
              _BreadcrumbChip(
                label: i == 0 && widget.windowsPaths
                    ? widget.drivesLabel
                    : segments[i].label,
                isRootDriveIcon: i == 0,
                windowsRoot: i == 0 && widget.windowsPaths,
                active: i == segments.length - 1,
                enabled: widget.enabled && i < segments.length - 1,
                textTheme: textTheme,
                scheme: scheme,
                onTap: () => widget.onOpen(segments[i].path),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BreadcrumbChip extends StatelessWidget {
  const _BreadcrumbChip({
    required this.label,
    required this.isRootDriveIcon,
    required this.windowsRoot,
    required this.active,
    required this.enabled,
    required this.textTheme,
    required this.scheme,
    required this.onTap,
  });

  final String label;
  final bool isRootDriveIcon;
  final bool windowsRoot;
  final bool active;
  final bool enabled;
  final TextTheme textTheme;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = textTheme.labelSmall?.copyWith(
      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
      color: active ? scheme.primary : scheme.onSurfaceVariant,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isRootDriveIcon) ...[
                Icon(
                  windowsRoot ? Icons.storage_outlined : Icons.dns_outlined,
                  size: 13,
                  color: active ? scheme.primary : scheme.onSurfaceVariant,
                ),
                if (windowsRoot) const SizedBox(width: 4),
              ],
              if (!isRootDriveIcon || windowsRoot) Text(label, style: style),
            ],
          ),
        ),
      ),
    );
  }
}
