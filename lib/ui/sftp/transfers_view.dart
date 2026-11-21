import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/controllers/transfer_queue.dart';
import '../../app/controllers/settings_controller.dart';
import '../../infra/platform/local_files.dart';
import '../../l10n/app_strings.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import '../motion/smooth_scroll.dart';

/// Список передач вкладки внизу SFTP-панели.
class TransfersView extends ConsumerStatefulWidget {
  const TransfersView({super.key, required this.tabId});

  final String tabId;

  @override
  ConsumerState<TransfersView> createState() => _TransfersViewState();
}

class _TransfersViewState extends ConsumerState<TransfersView> {
  bool _expanded = false;
  List<Transfer> _lastAll = const [];
  String get tabId => widget.tabId;

  @override
  Widget build(BuildContext context) {
    final all = ref
        .watch(transferQueueProvider)
        .where((t) => t.tabId == tabId)
        .toList();
    if (all.isNotEmpty) _lastAll = all;

    final s = AppStrings.of(
      context,
      ref.watch(settingsProvider.select((s) => s.language)),
    );
    final effective = all.isNotEmpty ? all : _lastAll;

    return ExpandSection(
      expanded: all.isNotEmpty,
      child: effective.isEmpty ? const SizedBox.shrink() : _buildBar(context, effective, s),
    );
  }

  Widget _buildBar(BuildContext context, List<Transfer> all, AppStrings s) {
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
                  icon: AnimatedRotation(
                    turns: _expanded ? 0.25 : 0.0,
                    duration: AppMotion.duration(
                      context,
                      AppMotion.durationDefault,
                    ),
                    curve: AppMotion.spatialCurve,
                    child: const Icon(Icons.chevron_right),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: active > 0
                              ? s.transfersActive(active)
                              : s.transfersDone,
                        ),
                        if (failed > 0)
                          TextSpan(
                            text: ' · ${s.transfersFailed(failed)}',
                            style: TextStyle(color: scheme.error),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
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
          Flexible(
            child: ExpandSection(
              expanded: _expanded,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 168),
                child: SmoothScroll(
                  builder: (context, controller) => ListView.builder(
                    controller: controller,
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
    final fastDur = AppMotion.duration(context, AppMotion.durationFast);

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
        key: const ValueKey('cancel'),
        tooltip: strings.cancel,
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        onPressed: onCancel,
        icon: const Icon(Icons.close),
      ),
      TransferStatus.done => IconButton(
        key: const ValueKey('done'),
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
        key: const ValueKey('failed'),
        padding: const EdgeInsets.all(8),
        child: Icon(Icons.error_outline, size: 16, color: scheme.error),
      ),
      TransferStatus.cancelled => const SizedBox(
        key: ValueKey('cancelled'),
        width: 32,
      ),
    };

    final progress = t.progress;

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
                ExpandSection(
                  expanded: t.status == TransferStatus.running,
                  spring: AppMotion.spatialFast,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: progress == null
                        ? LinearProgressIndicator(
                            minHeight: 3,
                            borderRadius: BorderRadius.circular(2),
                          )
                        : TweenAnimationBuilder<double>(
                            tween: Tween<double>(end: progress.clamp(0.0, 1.0)),
                            duration: AppMotion.duration(
                              context,
                              const Duration(milliseconds: 150),
                            ),
                            curve: Curves.easeOut,
                            builder: (context, val, _) =>
                                LinearProgressIndicator(
                                  value: val,
                                  minHeight: 3,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                          ),
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
          AnimatedSwitcher(duration: fastDur, child: trailing),
        ],
      ),
    );
  }
}
