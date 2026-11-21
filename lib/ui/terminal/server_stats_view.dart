import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../../domain/services/server_stats.dart';
import '../../app/terminal/terminal_session.dart';
import '../motion/app_motion.dart';

/// Нагрузка сервера в строке состояния: CPU, память, диск, сеть, аптайм.
/// Опрашивает сервер, только пока вкладка на экране и окно не свёрнуто.
class ServerStatsView extends StatefulWidget {
  const ServerStatsView({
    super.key,
    required this.session,
    required this.active,
    required this.ru,
    this.fallback,
  });

  final TerminalSession session;
  final bool active;
  final bool ru;

  /// Что показать, если сервер не Linux и статистики нет (версия SSH).
  final String? fallback;

  @override
  State<ServerStatsView> createState() => _ServerStatsViewState();
}

class _ServerStatsViewState extends State<ServerStatsView> {
  static const _every = Duration(seconds: 3);

  final _sampler = ServerStatsSampler();
  ServerStats? _stats;
  bool _unsupported = false;
  bool _busy = false;
  Timer? _timer;
  AppLifecycleListener? _life;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onStateChange: (s) {
      _visible = s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;
      if (_visible) _poll();
    });
    _restart();
  }

  @override
  void didUpdateWidget(ServerStatsView old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      _stats = null;
      _unsupported = false;
    }
    if (old.active != widget.active || old.session != widget.session) _restart();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _life?.dispose();
    super.dispose();
  }

  void _restart() {
    _timer?.cancel();
    _timer = null;
    if (!widget.active || _unsupported) return;
    _poll();
    _timer = Timer.periodic(_every, (_) => _poll());
  }

  Future<void> _poll() async {
    if (_busy || !_visible || !widget.active || _unsupported) return;
    _busy = true;
    try {
      final raw = await widget.session
          .exec(serverStatsCommand, timeout: const Duration(seconds: 5));
      final s = _sampler.parse(raw, DateTime.now());
      if (!mounted) return;
      setState(() {
        if (s == null) {
          _unsupported = true;
          _timer?.cancel();
        } else {
          _stats = s;
        }
      });
    } catch (_) {
      // Обрыв или медленный сервер: оставляем прошлые цифры до следующего раза.
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final dim = base?.copyWith(color: scheme.outline);
    final s = _stats;
    final fadeDur = AppMotion.duration(context, AppMotion.durationDefault);

    Widget content;
    if (s == null) {
      final text = _unsupported ? widget.fallback : null;
      content = text == null
          ? const SizedBox.shrink(key: ValueKey('loading'))
          : Text(
              text,
              key: const ValueKey('fallback'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: dim,
            );
    } else {
      final ru = widget.ru;
      final strings = AppStrings(isRu: ru);
      String pct(double v) => '${(v * 100).round()}%';
      Color load(double v) => v >= 0.9
          ? scheme.error
          : (v >= 0.75 ? scheme.tertiary : scheme.onSurfaceVariant);

      Widget item(IconData icon, String text, {Color? color, String? tip}) {
        final effectiveStyle = (base ?? const TextStyle()).copyWith(
          color: color ?? scheme.onSurfaceVariant,
        );
        final w = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: color ?? scheme.outline),
            const SizedBox(width: 4),
            AnimatedDefaultTextStyle(
              duration: fadeDur,
              style: effectiveStyle,
              child: Text(text),
            ),
          ],
        );
        return Padding(
          padding: const EdgeInsets.only(right: 14),
          child: tip == null ? w : Tooltip(message: tip, child: w),
        );
      }

      String rate(double? v) =>
          v == null ? '…' : '${strings.bytes(v)}/${ru ? 'с' : 's'}';

      content = ClipRect(
        key: const ValueKey('metrics'),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Row(
            children: [
              item(
                Icons.speed_rounded,
                s.cpu == null ? 'CPU …' : 'CPU ${pct(s.cpu!)}',
                color: s.cpu == null ? null : load(s.cpu!),
              ),
              item(
                Icons.memory_rounded,
                '${ru ? 'ОЗУ' : 'RAM'} ${strings.bytes(s.memUsed)} / ${strings.bytes(s.memTotal)}',
                color: load(s.mem),
              ),
              if (s.disk != null)
                item(
                  Icons.storage_rounded,
                  '${ru ? 'Диск' : 'Disk'} ${pct(s.disk!)}',
                  color: load(s.disk!),
                  tip:
                      '/  ${strings.bytes(s.diskUsed!)} / ${strings.bytes(s.diskTotal!)}',
                ),
              item(Icons.arrow_downward_rounded, rate(s.rxPerSec)),
              item(Icons.arrow_upward_rounded, rate(s.txPerSec)),
              item(
                Icons.schedule_rounded,
                strings.uptime(s.uptime),
                tip: ru ? 'Аптайм' : 'Uptime',
              ),
            ],
          ),
        ),
      );
    }

    return AnimatedSwitcher(
      duration: fadeDur,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [...previousChildren, ?currentChild],
      ),
      child: content,
    );
  }
}
