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

    final style = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final status = switch (tab.status) {
      SessionStatus.connecting =>
        tab.isLocal
            ? strings.localShellStarting
            : (strings.isRussian ? 'Подключение…' : 'Connecting…'),
      SessionStatus.ready =>
        tab.isLocal
            ? strings.localShellRunning
            : (strings.isRussian ? 'Подключено' : 'Connected'),
      SessionStatus.lost =>
        tab.isLocal
            ? strings.localShellFailed
            : (strings.isRussian ? 'Нет соединения' : 'Connection lost'),
      SessionStatus.closed =>
        strings.isRussian ? 'Сессия завершена' : 'Session closed',
    };
    final statusColor = switch (tab.status) {
      SessionStatus.connecting => scheme.tertiary,
      SessionStatus.lost => scheme.error,
      SessionStatus.closed => scheme.outline,
      SessionStatus.ready => scheme.onSurfaceVariant,
    };
    final location = tab.isLocal
        ? strings.localTerminal
        : tab.host.displayAddress;

    return LayoutBuilder(
      builder: (context, box) {
        final showMetrics = box.maxWidth > 620 && !DesktopEnv.isMobile;
        return Material(
          color: scheme.surfaceContainerLow,
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Tooltip(
                  message: [location, ?serverVersion].join('\n'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (tab.status != SessionStatus.ready) ...[
                        Icon(Icons.info_outline, size: 14, color: statusColor),
                        const SizedBox(width: 6),
                      ],
                      Text(status, style: style),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child:
                      showMetrics &&
                          !tab.isLocal &&
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
                if (!tab.isLocal && showMetrics)
                  IconButton(
                    tooltip: showStats
                        ? (strings.isRu
                              ? 'Скрыть нагрузку сервера'
                              : 'Hide server stats')
                        : (strings.isRu
                              ? 'Показать нагрузку сервера'
                              : 'Show server stats'),
                    isSelected: showStats,
                    selectedIcon: const Icon(Icons.monitor_heart),
                    icon: const Icon(Icons.monitor_heart_outlined),
                    onPressed: onToggleStats,
                  ),
                if (onToggleFiles != null)
                  IconButton(
                    tooltip: filesOpen
                        ? (strings.isRu
                              ? 'Вернуться в терминал'
                              : 'Return to terminal')
                        : (strings.isRu ? 'Открыть файлы' : 'Open files'),
                    isSelected: filesOpen,
                    selectedIcon: const Icon(Icons.folder_open),
                    icon: const Icon(Icons.folder_outlined),
                    onPressed: onToggleFiles,
                  ),
                if (tab.status == SessionStatus.lost ||
                    tab.status == SessionStatus.closed)
                  IconButton(
                    tooltip: strings.reconnect,
                    onPressed: onReconnect,
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
