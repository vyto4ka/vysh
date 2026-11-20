import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_strings.dart';
import '../../domain/models/host.dart';
import '../../domain/ports/ssh_transport.dart';
import '../../app/controllers/hosts_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/terminal/terminal_session.dart';
import '../../infra/platform/desktop_env.dart';
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
  final _diagLines = <DiagLine>[];
  StreamSubscription<DiagLine>? _diagSub;
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

  String _logText(AppStrings strings, {bool withDebug = true}) {
    final b = StringBuffer()
      ..writeln('vysh: connection log for ${_host.displayAddress}');
    for (final e in widget.session.connLog) {
      if (e.debug && !withDebug) continue;
      final t = e.time;
      b.writeln('${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}.${_two(t.millisecond, 3)}'
          '${e.error ? ' ✗' : e.debug ? ' ·' : '  '} ${e.text(strings)}');
    }
    if (_diagLines.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Diagnostics (${_diagKind?.name}):')
        ..writeAll(_diagLines.map((l) => _diagText(l, strings)), '\n');
    }
    return b.toString();
  }

  (IconData, String, String) _describe(SshFailure? f, AppStrings strings) {
    if (widget.session.droppedAfterReady) {
      return (
        Icons.link_off,
        strings.isRu ? 'Соединение потеряно' : 'Connection lost',
        strings.isRu
            ? 'Сервер перестал отвечать или сеть пропала. Проверьте связь и переподключитесь.'
            : 'Server stopped responding or network was disconnected. Check connection and retry.',
      );
    }
    if (f == null) {
      return (
        Icons.receipt_long_outlined,
        strings.sessionLog,
        strings.isRu
            ? 'Шаги последнего подключения и сетевая диагностика.'
            : 'Last connection log and network diagnostics.',
      );
    }
    return switch (f.kind) {
      SshFailureKind.network => (
          Icons.wifi_off_rounded,
          strings.isRu ? 'Не удалось подключиться' : 'Failed to connect',
          strings.isRu
              ? 'Проверьте адрес и порт, включён ли сервер, VPN и фаервол.'
              : 'Verify address and port, whether the server is running, VPN and firewall.',
        ),
      SshFailureKind.auth => (
          Icons.no_accounts_outlined,
          strings.isRu ? 'Ошибка входа' : 'Authentication error',
          strings.isRu
              ? 'Сервер не принял логин, пароль или ключ. Проверьте данные хоста.'
              : 'Server rejected credentials or key. Check host settings.',
        ),
      SshFailureKind.hostKey => (
          Icons.gpp_bad_outlined,
          strings.isRu ? 'Ключ сервера отклонён' : 'Host key rejected',
          strings.isRu
              ? 'Подключение остановлено, потому что ключ сервера не подтверждён.'
              : 'Connection halted because host key was not verified.',
        ),
      SshFailureKind.keyPassphrase || SshFailureKind.config => (
          Icons.key_off_outlined,
          strings.isRu ? 'Проблема с ключом' : 'Key issue',
          strings.isRu
              ? 'Проверьте путь к ключу и парольную фразу в настройках хоста.'
              : 'Check private key path and passphrase in host settings.',
        ),
      SshFailureKind.cancelled => (
          Icons.cancel_outlined,
          strings.isRu ? 'Подключение отменено' : 'Connection cancelled',
          strings.isRu
              ? 'Вы отменили ввод пароля или подтверждение.'
              : 'Password input or confirmation was cancelled.',
        ),
      SshFailureKind.other => (
          Icons.error_outline,
          strings.isRu ? 'Не удалось подключиться' : 'Failed to connect',
          strings.isRu
              ? 'Подробности в журнале ниже.'
              : 'Details are in the log below.',
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lang = ref.watch(settingsProvider.select((s) => s.language));
    final strings = AppStrings.of(context, lang);
    final failure = widget.session.lastFailure;
    final (icon, title, hint) = _describe(failure, strings);
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
                      child: SelectableText(strings.sshFailure(failure),
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
                        label: Text(DesktopEnv.isDesktop ? '${strings.reconnect}  ⏎' : strings.reconnect),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _runDiag(DiagKind.ping),
                        icon: const Icon(Icons.network_ping),
                        label: Text(strings.isRu ? 'Пинг' : 'Ping'),
                      ),
                      if (!DesktopEnv.isMobile)
                        FilledButton.tonalIcon(
                          onPressed: () => _runDiag(DiagKind.traceroute),
                          icon: const Icon(Icons.route_outlined),
                          label: Text(strings.isRu ? 'Трассировка' : 'Traceroute'),
                        ),
                      FilledButton.tonalIcon(
                        onPressed: () => _runDiag(DiagKind.port),
                        icon: const Icon(Icons.settings_ethernet),
                        label: Text(strings.isRu ? 'Порт ${_host.port}' : 'Port ${_host.port}'),
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
                          label: Text(strings.isRu ? 'Изменить хост' : 'Edit host'),
                        ),
                      TextButton(
                        onPressed: widget.onDismiss,
                        child: Text(
                          DesktopEnv.isDesktop
                              ? (strings.isRu ? 'Показать терминал  Esc' : 'Show terminal  Esc')
                              : (strings.isRu ? 'Показать терминал' : 'Show terminal'),
                        ),
                      ),
                    ],
                  ),
                  if (_diagKind != null) ...[
                    const SizedBox(height: 20),
                    _Panel(
                      title: switch (_diagKind!) {
                        DiagKind.ping => strings.isRu ? 'Пинг ${_host.address}' : 'Ping ${_host.address}',
                        DiagKind.traceroute => strings.isRu ? 'Трассировка до ${_host.address}' : 'Traceroute to ${_host.address}',
                        DiagKind.port => strings.isRu ? 'Проверка порта ${_host.address}:${_host.port}' : 'Port check ${_host.address}:${_host.port}',
                      },
                      trailing: _diagRunning
                          ? TextButton.icon(
                              onPressed: _stopDiag,
                              icon: const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              label: Text(strings.isRu ? 'Остановить' : 'Stop'),
                            )
                          : null,
                      child: SelectableText(
                        _diagLines.isEmpty ? (strings.isRu ? 'Запуск…' : 'Running…') : _diagLines.map((l) => _diagText(l, strings)).join('\n'),
                        style: monoStyle(context, size: 12.5, color: scheme.onSurface),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  _Panel(
                    title: strings.sessionLog,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(strings.isRu ? 'Подробно' : 'Verbose', style: theme.textTheme.labelMedium),
                        Switch(
                          value: _verbose,
                          onChanged: (v) => setState(() => _verbose = v),
                        ),
                        IconButton(
                          tooltip: strings.isRu ? 'Скопировать журнал' : 'Copy log',
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _logText(strings)));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(strings.isRu ? 'Журнал скопирован' : 'Log copied')),
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
                                '${_two(e.time.millisecond, 3)}  ${e.text(strings)}\n',
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

/// Строка сетевой диагностики на языке интерфейса.
String _diagText(DiagLine l, AppStrings s) {
  final m = l.message;
  if (m == null) return l.raw ?? '';
  String a(String k) => l.args[k] ?? '';
  final ru = s.isRu;
  return switch (m) {
    DiagMessage.unavailable => ru
        ? 'Сетевая диагностика через системные утилиты недоступна в веб-версии.'
        : 'Network diagnostics with system tools are not available in the web version.',
    DiagMessage.badAddress => ru ? 'Недопустимый адрес: ${a('host')}' : 'Invalid address: ${a('host')}',
    DiagMessage.noTraceroute => ru
        ? 'Не найден ни traceroute, ни tracepath. Установите пакет traceroute.'
        : 'Neither traceroute nor tracepath found. Install the traceroute package.',
    DiagMessage.failed => ru ? 'Ошибка диагностики: ${a('detail')}' : 'Diagnostics error: ${a('detail')}',
    DiagMessage.portOpen => ru
        ? 'TCP ${a('target')}: открыт, ${a('ms')} мс'
        : 'TCP ${a('target')}: open, ${a('ms')} ms',
    DiagMessage.stopped => ru ? '[остановлено]' : '[stopped]',
    DiagMessage.exitCode => ru ? '[завершено с кодом ${a('code')}]' : '[exited with code ${a('code')}]',
    DiagMessage.cannotRun =>
      ru ? 'Не удалось запустить команду: ${a('detail')}' : 'Could not run the command: ${a('detail')}',
  };
}
