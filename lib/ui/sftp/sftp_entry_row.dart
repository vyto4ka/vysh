import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/ports/sftp.dart';
import '../../infra/platform/desktop_env.dart';
import '../../l10n/app_strings.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import '../motion/pressable_surface.dart';

/// Строки списка панели файлов: запись папки и заглушка пустого состояния.

class SftpPlaceholder extends StatelessWidget {
  const SftpPlaceholder({
    super.key,
    required this.icon,
    required this.text,
    this.action,
  });

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}

class SftpEntryRow extends StatelessWidget {
  const SftpEntryRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
    this.onDoubleTap,
    this.onIconTap,
    required this.onSecondary,
    required this.strings,
    this.onSelect,
    this.showSelection = false,
    this.enabled = true,
  });

  /// null - строка «..».
  final RemoteEntry? entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onIconTap;
  final void Function(Offset globalPosition) onSecondary;
  final AppStrings strings;
  final ValueChanged<bool>? onSelect;
  final bool showSelection;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = entry;
    final dim = scheme.onSurfaceVariant;
    final mobile = DesktopEnv.isMobile;

    final icon = e == null
        ? Icons.subdirectory_arrow_left
        : e.isDir
        ? (e.isLink ? Icons.folder_special_outlined : Icons.folder_rounded)
        : (e.isLink ? Icons.link : _fileIcon(e.name));
    final iconColor = e == null || e.isDir ? scheme.primary : dim;
    final showCheckIcon = selected && !showSelection;
    final separateIconTap = e != null && onIconTap != null;
    final minRowHeight = theme.visualDensity == VisualDensity.compact
        ? 48.0
        : 56.0;

    final badge = _EntryIconBadge(
      icon: showCheckIcon ? Icons.check_circle : icon,
      iconKey: (showCheckIcon, icon),
      isDir: e?.isDir == true,
      selected: selected,
      iconColor: iconColor,
      tooltip: separateIconTap
          ? (selected ? strings.deselectEntry : strings.selectEntry)
          : null,
      onTap: enabled && separateIconTap ? onIconTap : null,
      onSecondary: enabled && separateIconTap ? onSecondary : null,
    );

    return LayoutBuilder(
      builder: (context, box) => Semantics(
        selected: selected,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: PressableSurface(
            enabled: enabled,
            selected: selected,
            pressScale: 0.014,
            borderRadius: BorderRadius.circular(14),
            selectedBorderRadius: BorderRadius.circular(10),
            color: Colors.transparent,
            selectedColor: scheme.secondaryContainer,
            onTap: enabled ? onTap : null,
            // Для папок и на телефоне onDoubleTap == null — тап срабатывает мгновенно без 300 мс ожидания.
            onDoubleTap: enabled && !mobile ? onDoubleTap : null,
            onSecondaryTapUp: enabled
                ? (d) => onSecondary(d.globalPosition)
                : null,
            onLongPressStart: enabled && mobile && e != null
                ? (d) {
                    HapticFeedback.mediumImpact();
                    onSecondary(d.globalPosition);
                  }
                : null,
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExpandSection(
                  expanded: showSelection,
                  axis: Axis.horizontal,
                  spring: AppMotion.spatialFast,
                  child: Checkbox(
                    value: selected,
                    onChanged: enabled && onSelect != null
                        ? (v) => onSelect!(v!)
                        : null,
                  ),
                ),
                if (separateIconTap)
                  Padding(
                    padding: EdgeInsets.only(
                      left: showSelection ? 2 : 10,
                      right: 4,
                      top: 4,
                      bottom: 4,
                    ),
                    child: badge,
                  ),
              ],
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minRowHeight),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  separateIconTap ? 6 : 12,
                  4,
                  mobile && e != null ? 4 : 12,
                  4,
                ),
                child: Row(
                  children: [
                    if (!separateIconTap) ...[badge, const SizedBox(width: 12)],
                    Expanded(
                      child: Text(
                        e?.name ?? '..',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: selected
                              ? scheme.onSecondaryContainer
                              : e != null && e.isHidden
                              ? dim
                              : scheme.onSurface,
                        ),
                      ),
                    ),
                    if (e != null) ...[
                      if (!e.isDir)
                        SizedBox(
                          width: 68,
                          child: Text(
                            strings.bytes(e.size),
                            textAlign: TextAlign.end,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: dim,
                            ),
                          ),
                        ),
                      if (box.maxWidth > 500) ...[
                        const SizedBox(width: 12),
                        Tooltip(
                          message: e.permissions,
                          child: SizedBox(
                            width: 112,
                            child: Text(
                              _date(e.modified, strings),
                              textAlign: TextAlign.end,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: dim,
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (mobile)
                        Builder(
                          builder: (btnCtx) => IconButton(
                            visualDensity: VisualDensity.compact,
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            icon: Icon(Icons.more_vert, color: dim),
                            onPressed: enabled
                                ? () {
                                    final box =
                                        btnCtx.findRenderObject() as RenderBox?;
                                    final pos = box != null
                                        ? box.localToGlobal(
                                            box.size.center(Offset.zero),
                                          )
                                        : Offset.zero;
                                    onSecondary(pos);
                                  }
                                : null,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _date(DateTime? d, AppStrings strings) {
    if (d == null) return '';
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return strings.todayAt('${_two(d.hour)}:${_two(d.minute)}');
    }
    return '${_two(d.day)}.${_two(d.month)}.${d.year % 100} ${_two(d.hour)}:${_two(d.minute)}';
  }

  static IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'sh' ||
      'bash' ||
      'zsh' ||
      'py' ||
      'js' ||
      'ts' ||
      'go' ||
      'rs' ||
      'c' ||
      'cpp' ||
      'h' ||
      'java' ||
      'php' ||
      'rb' ||
      'pl' ||
      'lua' => Icons.code,
      'conf' ||
      'cfg' ||
      'ini' ||
      'yaml' ||
      'yml' ||
      'toml' ||
      'json' ||
      'xml' ||
      'env' => Icons.settings_outlined,
      'log' || 'txt' || 'md' => Icons.description_outlined,
      'zip' ||
      'gz' ||
      'tgz' ||
      'xz' ||
      'bz2' ||
      'zst' ||
      '7z' ||
      'rar' ||
      'tar' ||
      'deb' ||
      'rpm' ||
      'ipk' => Icons.inventory_2_outlined,
      'iso' || 'img' || 'qcow2' || 'vmdk' => Icons.album_outlined,
      'png' ||
      'jpg' ||
      'jpeg' ||
      'gif' ||
      'svg' ||
      'webp' => Icons.image_outlined,
      'pem' || 'crt' || 'key' || 'pub' => Icons.key_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}

class _EntryIconBadge extends StatefulWidget {
  const _EntryIconBadge({
    required this.icon,
    required this.iconKey,
    required this.isDir,
    required this.selected,
    required this.iconColor,
    this.tooltip,
    this.onTap,
    this.onSecondary,
  });

  final IconData icon;
  final Object iconKey;
  final bool isDir;
  final bool selected;
  final Color iconColor;
  final String? tooltip;
  final VoidCallback? onTap;
  final void Function(Offset globalPosition)? onSecondary;

  @override
  State<_EntryIconBadge> createState() => _EntryIconBadgeState();
}

class _EntryIconBadgeState extends State<_EntryIconBadge> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fastDur = AppMotion.duration(context, AppMotion.durationFast);
    final interactive = widget.onTap != null;

    Widget box = AnimatedContainer(
      duration: fastDur,
      curve: Curves.easeOutCubic,
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: widget.selected || widget.isDir || (_hover && interactive)
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(widget.selected ? 12 : 10),
        border: Border.all(
          color: _hover && interactive
              ? scheme.primary.withValues(alpha: 0.65)
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: AnimatedSwitcher(
        duration: fastDur,
        switchInCurve: AppMotion.fastSpringCurve,
        switchOutCurve: AppMotion.emphasizedAccelerate,
        transitionBuilder: (child, anim) => ScaleTransition(
          scale: Tween<double>(begin: 0.75, end: 1.0).animate(anim),
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: Icon(
          widget.icon,
          key: ValueKey(widget.iconKey),
          size: 20,
          color: widget.selected || widget.isDir
              ? scheme.onSecondaryContainer
              : widget.iconColor,
        ),
      ),
    );

    if (!interactive) return box;

    box = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onSecondaryTapUp: widget.onSecondary == null
            ? null
            : (d) => widget.onSecondary!(d.globalPosition),
        child: Padding(padding: const EdgeInsets.all(2), child: box),
      ),
    );

    if (widget.tooltip != null) {
      box = Tooltip(message: widget.tooltip!, child: box);
    }
    return box;
  }
}
