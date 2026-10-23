part of 'session_view.dart';

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.tab,
    required this.session,
    required this.active,
    required this.showStats,
    required this.onToggleStats,
    required this.serverVersion,
    required this.onReconnect,
    required this.filesOpen,
    this.onToggleFiles,
    required this.strings,
  });

  final SessionTab tab;
  final TerminalSession session;
  final bool active;
  final bool showStats;
  final VoidCallback onToggleStats;
  final String? serverVersion;
  final VoidCallback onReconnect;
  final bool filesOpen;
  final VoidCallback? onToggleFiles;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final isCompact =
        MediaQuery.sizeOf(context).width < 650 || DesktopEnv.isMobile;

    final style = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    final (status, color) = switch (tab.status) {
      SessionStatus.connecting => (
        tab.isLocal
            ? strings.localShellStarting
            : (strings.isRussian ? 'Подключение…' : 'Connecting…'),
        scheme.tertiary,
      ),
      SessionStatus.ready => (
        tab.isLocal
            ? strings.localShellRunning
            : (strings.isRussian ? 'Подключено' : 'Connected'),
        Colors.green.shade500,
      ),
      SessionStatus.lost => (
        tab.isLocal
            ? strings.localShellFailed
            : (strings.isRussian ? 'Нет соединения' : 'Connection lost'),
        scheme.error,
      ),
      SessionStatus.closed => (
        strings.isRussian ? 'Сессия завершена' : 'Session closed',
        scheme.outline,
      ),
    };
    final location = tab.isLocal ? strings.localTerminal : tab.host.displayAddress;

    return Container(
      height: 32,
      color: scheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(status, style: style),
          const SizedBox(width: 10),
          if (isCompact) ...[
            Expanded(
              child: Text(
                location,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          ] else ...[
            if (serverVersion == null || tab.isLocal)
              Text(location, style: style)
            else
              Tooltip(
                message: serverVersion!,
                child: Text(location, style: style),
              ),
            const SizedBox(width: 16),
            Expanded(
              child: !tab.isLocal &&
                      showStats &&
                      tab.status == SessionStatus.ready
                  ? ServerStatsView(
                      session: session,
                      active: active,
                      ru: strings.isRussian,
                      fallback: serverVersion,
                    )
                  : const SizedBox.shrink(),
            ),
            if (!tab.isLocal)
              IconButton(
                tooltip: showStats
                    ? (strings.isRussian ? 'Скрыть нагрузку сервера' : 'Hide server stats')
                    : (strings.isRussian ? 'Показать нагрузку сервера' : 'Show server stats'),
                visualDensity: VisualDensity.compact,
                iconSize: 15,
                color: showStats ? scheme.primary : scheme.onSurfaceVariant,
                onPressed: onToggleStats,
                icon: Icon(
                  showStats ? Icons.monitor_heart_rounded : Icons.monitor_heart_outlined,
                ),
              ),
          ],
          const SizedBox(width: 6),
          if (onToggleFiles != null)
            TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.bodySmall,
                foregroundColor: filesOpen
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              onPressed: onToggleFiles,
              icon: Icon(
                filesOpen
                    ? (isCompact ? Icons.terminal_rounded : Icons.folder_open)
                    : Icons.folder_outlined,
                size: 14,
              ),
              label: Text(
                isCompact
                    ? (filesOpen
                          ? (strings.isRussian ? 'Консоль' : 'Console')
                          : (strings.isRussian ? 'Файлы' : 'Files'))
                    : (DesktopEnv.isDesktop
                          ? (PlatformCapabilities.isMacOS
                                ? (strings.isRussian ? 'Файлы  ⌘E' : 'Files  ⌘E')
                                : (strings.isRussian
                                      ? 'Файлы  Ctrl+Shift+E'
                                      : 'Files  Ctrl+Shift+E'))
                          : (strings.isRussian ? 'Файлы' : 'Files')),
              ),
            ),
          if (tab.status != SessionStatus.connecting) ...[
            const SizedBox(width: 4),
            TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.bodySmall,
              ),
              onPressed: onReconnect,
              icon: const Icon(Icons.refresh, size: 14),
              label: Text(
                isCompact
                    ? (strings.isRussian ? 'Переподкл.' : 'Reconnect')
                    : (strings.isRussian ? 'Переподключить' : 'Reconnect'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
