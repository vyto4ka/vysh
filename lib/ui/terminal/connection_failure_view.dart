import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/host.dart';
import '../../domain/ports/ssh_transport.dart';
import '../../domain/services/hosts_controller.dart';
import '../../domain/services/terminal_session.dart';
import '../../infra/platform/net_diag.dart';
import '../hosts/host_editor.dart';
import '../theme/app_theme.dart';

/// Экран неудачного подключения: что случилось, журнал, диагностика сети.
class ConnectionFailureView extends ConsumerStatefulWidget {
  const ConnectionFailureView({
    super.key,
    required this.session,
    required this.onReconnect,
    required this.onDismiss,
  });

  final TerminalSession session;
  final VoidCallback onReconnect;
  final VoidCallback onDismiss;

  @override
  ConsumerState<ConnectionFailureView> createState() => _ConnectionFailureViewState();
}

class _ConnectionFailureViewState extends ConsumerState<ConnectionFailureView> {
  bool _verbose = false;
  NetDiag? _diag;
  DiagKind? _diagKind;
  final _diagLines = <String>[];
  StreamSubscription<String>? _diagSub;
  bool _diagRunning = false;

  @override
  void dispose() {
    _diagSub?.cancel();
    _diag?.stop();
    super.dispose();
  }

  Host get _host => widget.session.host;

  void _runDiag(DiagKind kind) {
    _diag?.stop();
    _diagSub?.cancel();
    final diag = NetDiag(kind, _host.address, _host.port);
    setState(() {
      _diag = diag;
      _diagKind = kind;
      _diagLines.clear();
      _diagRunning = true;
    });
    _diagSub = diag.output.listen(
      (line) => setState(() => _diagLines.add(line)),
      onDone: () {
        if (mounted) setState(() => _diagRunning = false);
      },
    );
    diag.start();
  }

  void _stopDiag() => _diag?.stop();

  String _two(int v, [int w = 2]) => v.toString().padLeft(w, '0');

  String _logText({bool withDebug = true}) {
    final b = StringBuffer()
      ..writeln('vysh: журнал подключения к ${_host.displayAddress}');
    for (final e in widget.session.connLog) {
      if (e.debug && !withDebug) continue;
      final t = e.time;
      b.writeln('${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${_two(t.millisecond, 3)}'
          '${e.error ? ' ✗' : e.debug ? ' ·' : '  '} ${e.text}');
    }
    if (_diagLines.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Диагностика (${_diagKind?.name}):')
        ..writeAll(_diagLines, '\n');
    }
    return b.toString();
  }

  (IconData, String, String) _describe(SshFailure? f) {
    if (widget.session.droppedAfterReady) {
      return (
        Icons.link_off,
        'Соединение потеряно',
        'Сервер перестал отвечать или сеть пропала. Проверьте связь и переподключитесь.',
      );
    }
    if (f == null) {
      return (
        Icons.receipt_long_outlined,
        'Журнал подключения',
        'Шаги последнего подключения и сетевая диагностика.',
      );
    }
    return switch (f.kind) {
      SshFailureKind.network => (
          Icons.wifi_off_rounded,
          'Не удалось подключиться',
          'Проверьте адрес и порт, включён ли сервер, VPN и фаервол. '
              'Пинг и трассировка ниже помогут понять, где теряется связь.',
        ),
      SshFailureKind.auth => (
          Icons.no_accounts_outlined,
          'Ошибка входа',
          'Сервер не принял логин, пароль или ключ. Проверьте данные хоста. '
              'На многих серверах вход root по паролю запрещён (PermitRootLogin).',
        ),
      SshFailureKind.hostKey => (
          Icons.gpp_bad_outlined,
          'Ключ сервера отклонён',
          'Подключение остановлено, потому что ключ сервера не подтверждён.',
        ),
      SshFailureKind.keyPassphrase || SshFailureKind.config => (
          Icons.key_off_outlined,
          'Проблема с ключом',
          'Проверьте путь к ключу и парольную фразу в настройках хоста.',
        ),
      SshFailureKind.cancelled => (
          Icons.cancel_outlined,
          'Подключение отменено',
          'Вы отменили ввод пароля или подтверждение.',
        ),
      SshFailureKind.other => (
          Icons.error_outline,
          'Не удалось подключиться',
          'Подробности в журнале ниже.',
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failure = widget.session.lastFailure;
    final (icon, title, hint) = _describe(failure);
    final entries = widget.session.connLog.where((e) => _verbose || !e.debug).toList();

    return Container(
      color: scheme.surface.withValues(alpha: 0.97),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter): widget.onReconnect,
          const SingleActivator(LogicalKeyboardKey.escape): widget.onDismiss,
        },
        child: Focus(
          autofocus: true,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.all(28),
                shrinkWrap: true,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: failure == null && !widget.session.droppedAfterReady
                              ? scheme.primaryContainer
                              : scheme.errorContainer,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Icon(icon,
                            color: failure == null && !widget.session.droppedAfterReady
                                ? scheme.onPrimaryContainer
                                : scheme.onErrorContainer,
                            size: 28),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: theme.textTheme.headlineSmall),
                            const SizedBox(height: 2),
                            Text(_host.displayAddress,
                                style: monoStyle(context, size: 13, color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (failure != null && failure.kind != SshFailureKind.cancelled)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: SelectableText(failure.message,
                          style: TextStyle(color: scheme.onErrorContainer, fontWeight: FontWeight.w500)),
                    ),
                  const SizedBox(height: 10),
                  Text(hint, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: widget.onReconnect,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Переподключить  ⏎'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _runDiag(DiagKind.ping),
                        icon: const Icon(Icons.network_ping),
                        label: const Text('Пинг'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _runDiag(DiagKind.traceroute),
                        icon: const Icon(Icons.route_outlined),
                        label: const Text('Трассировка'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _runDiag(DiagKind.port),
                        icon: const Icon(Icons.settings_ethernet),
                        label: Text('Порт ${_host.port}'),
                      ),
                      OutlinedButton.icon(
                          onPressed: () {
                            final saved = ref
                                .read(hostsProvider)
                                .where((h) => h.id == _host.id)
                                .firstOrNull;
                            showHostEditor(context, host: saved ?? _host);
                          },
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Изменить хост'),
                        ),
                      TextButton(
                        onPressed: widget.onDismiss,
                        child: const Text('Показать терминал  Esc'),
                      ),
                    ],
                  ),
                  if (_diagKind != null) ...[
                    const SizedBox(height: 20),
                    _Panel(
                      title: switch (_diagKind!) {
                        DiagKind.ping => 'Пинг ${_host.address}',
                        DiagKind.traceroute => 'Трассировка до ${_host.address}',
                        DiagKind.port => 'Проверка порта ${_host.address}:${_host.port}',
                      },
                      trailing: _diagRunning
                          ? TextButton.icon(
                              onPressed: _stopDiag,
                              icon: const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              label: const Text('Остановить'),
                            )
                          : null,
                      child: SelectableText(
                        _diagLines.isEmpty ? 'Запуск…' : _diagLines.join('\n'),
                        style: monoStyle(context, size: 12.5, color: scheme.onSurface),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  _Panel(
                    title: 'Журнал подключения',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Подробно', style: theme.textTheme.labelMedium),
                        Switch(
                          value: _verbose,
                          onChanged: (v) => setState(() => _verbose = v),
                        ),
                        IconButton(
                          tooltip: 'Скопировать журнал',
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _logText()));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Журнал скопирован')),
                            );
                          },
                        ),
                      ],
                    ),
                    child: SelectableText.rich(
                      TextSpan(children: [
                        for (final e in entries)
                          TextSpan(
                            text: '${_two(e.time.hour)}:${_two(e.time.minute)}:${_two(e.time.second)}.'
                                '${_two(e.time.millisecond, 3)}  ${e.text}\n',
                            style: monoStyle(
                              context,
                              size: 12,
                              color: e.error
                                  ? scheme.error
                                  : e.debug
                                      ? scheme.outline
                                      : scheme.onSurface,
                            ),
                          ),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                ?trailing,
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
