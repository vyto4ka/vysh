import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/controllers/transfer_queue.dart';
import '../../app/controllers/settings_controller.dart';
import '../../infra/platform/local_files.dart';
import '../../l10n/app_strings.dart';

/// Список передач вкладки внизу SFTP-панели.
class TransfersView extends ConsumerStatefulWidget {
  const TransfersView({super.key, required this.tabId});

  final String tabId;

  @override
  ConsumerState<TransfersView> createState() => _TransfersViewState();
}

class _TransfersViewState extends ConsumerState<TransfersView> {
  bool _expanded = false;
  String get tabId => widget.tabId;
  @override
  Widget build(BuildContext context) {
    final all = ref
        .watch(transferQueueProvider)
        .where((t) => t.tabId == tabId)
        .toList();
    final s = AppStrings.of(
      context,
      ref.watch(settingsProvider.select((s) => s.language)),
    );
    if (all.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final queue = ref.read(transferQueueProvider.notifier);
    final active = all.where((t) => t.isActive).length;
    final failed = all.where((t) => t.status == TransferStatus.failed).length;
    // Сначала активные, потом последние завершённые.
    final shown = [
      ...all.where((t) => t.isActive),
      ...all.reversed.where((t) => !t.isActive),
    ].take(50).toList();

    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 2),
            child: Row(
              children: [
                IconButton(
                  tooltip: _expanded
                      ? (s.isRu ? 'Свернуть передачи' : 'Collapse transfers')
                      : (s.isRu ? 'Показать передачи' : 'Show transfers'),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  active > 0 ? s.transfersActive(active) : s.transfersDone,
                  style: theme.textTheme.labelMedium,
                ),
                if (failed > 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    s.transfersFailed(failed),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ],
                const Spacer(),
                if (active > 0)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => queue.cancelAllForTab(tabId),
                    child: Text(s.cancelAll),
                  ),
                if (all.length > active)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => queue.clearFinished(tabId),
                    child: Text(s.clearList),
                  ),
              ],
            ),
          ),
          if (_expanded)
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 6),
                itemCount: shown.length,
                itemBuilder: (context, i) => _TransferRow(
                  t: shown[i],
                  onCancel: () => queue.cancel(shown[i].id),
                  strings: s,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({
    required this.t,
    required this.onCancel,
    required this.strings,
  });

  final Transfer t;
  final VoidCallback onCancel;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant);
    final up = t.direction == TransferDirection.upload;

    final String info = switch (t.status) {
      TransferStatus.queued => strings.queued,
      TransferStatus.running =>
        t.total > 0
            ? strings.progressOf(
                strings.bytes(t.done),
                strings.bytes(t.total),
                strings.bytes(t.bytesPerSecond),
              )
            : strings.bytes(t.done),
      TransferStatus.done => strings.bytes(t.total > 0 ? t.total : t.done),
      TransferStatus.failed =>
        t.error == null ? strings.failedLower : strings.errorText(t.error!),
      TransferStatus.cancelled => strings.cancelledLower,
    };

    final Widget trailing = switch (t.status) {
      TransferStatus.queued || TransferStatus.running => IconButton(
        tooltip: strings.cancel,
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        onPressed: onCancel,
        icon: const Icon(Icons.close),
      ),
      TransferStatus.done => IconButton(
        tooltip: up ? strings.done : strings.showInFolder,
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        onPressed: up
            ? null
            : () => LocalFiles.reveal(t.publishedUri ?? t.localPath),
        icon: Icon(
          up ? Icons.check : Icons.folder_open,
          color: Colors.green.shade500,
        ),
      ),
      TransferStatus.failed => Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(Icons.error_outline, size: 16, color: scheme.error),
      ),
      TransferStatus.cancelled => const SizedBox(width: 32),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      child: Row(
        children: [
          Icon(
            up ? Icons.arrow_upward : Icons.arrow_downward,
            size: 16,
            color: scheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
                if (t.status == TransferStatus.running)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: LinearProgressIndicator(
                      value: t.progress,
                      minHeight: 3,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                Text(
                  info,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.status == TransferStatus.failed
                      ? small.copyWith(color: scheme.error)
                      : small,
                ),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}
