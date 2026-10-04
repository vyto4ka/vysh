import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:xterm2/core.dart';

import '../models/host.dart';
import '../models/session_tab.dart';
import '../ports/secret_store.dart';
import '../ports/session_prompts.dart';
import '../ports/sftp.dart';
import '../ports/ssh_transport.dart';
import 'known_hosts.dart';

/// Живая сессия одной вкладки: эмулятор терминала + SSH-соединение.
///
/// Жизненный цикл: connecting → ready → (lost | closed).
/// В состояниях lost/closed Enter в терминале переподключает.
/// Строка журнала подключения.
class ConnLogEntry {
  ConnLogEntry(this.text, {this.debug = false, this.error = false}) : time = DateTime.now();
  final DateTime time;
  final String text;
  final bool debug;
  final bool error;
}

class TerminalSession extends ChangeNotifier {
  TerminalSession({
    required this.host,
    required this.connector,
    required this.prompts,
    required this.secrets,
    required this.knownHosts,
    required this.onStatus,
    String? initialPassword,
    int scrollbackLines = 10000,
  })  : _memPassword = initialPassword,
        terminal = Terminal(maxLines: scrollbackLines);

  /// Пароль, введённый в этой сессии (в редакторе хоста или в диалоге).
  /// Живёт только в памяти - чтобы переподключение не спрашивало его заново.
  String? _memPassword;

  /// Хост; обновляется перед переподключением, если его отредактировали.
  Host host;
  final SshConnector connector;
  final SessionPrompts prompts;
  final SecretStore secrets;
  final KnownHosts knownHosts;
  final void Function(SessionStatus status) onStatus;

  /// Эмулятор терминала; размер истории задаётся в настройках.
  final Terminal terminal;

  SessionStatus _status = SessionStatus.connecting;
  SessionStatus get status => _status;

  String? _serverVersion;
  String? get serverVersion => _serverVersion;

  /// Журнал последней попытки подключения.
  final connLog = <ConnLogEntry>[];

  /// Ошибка последней попытки (null - подключились или ещё подключаемся).
  SshFailure? lastFailure;

  /// Соединение оборвалось уже после успешного входа.
  bool droppedAfterReady = false;

  void _log(String text, {bool debug = false, bool error = false}) {
    connLog.add(ConnLogEntry(text, debug: debug, error: error));
    if (connLog.length > 2000) connLog.removeRange(0, connLog.length - 2000);
  }

  SshTransport? _transport;
  SshShell? _shell;
  Future<SftpSession>? _sftp;

  /// Подписки на файлы, открытые «локально» (автозагрузка при сохранении).
  final editWatchers = <StreamSubscription<Object?>>[];
  StreamSubscription<String>? _outputSub;
  bool _connecting = false;
  bool _disposed = false;

  // ─── Публичное API ────────────────────────────────────────────────

  Future<void> connect() async {
    if (_connecting || _disposed) return;
    _connecting = true;
    _teardown();
    connLog.clear();
    lastFailure = null;
    droppedAfterReady = false;
    _log('Подключение к ${host.displayAddress} (${host.auth.name})');
    _setStatus(SessionStatus.connecting);
    terminal.onOutput = null;
    _info('Подключение к ${host.displayAddress}…');

    try {
      final transport = await _connectWithRetries();
      if (_disposed) {
        await transport.close();
        return;
      }
      _transport = transport;
      _serverVersion = transport.serverVersion;

      final shell = await transport.openShell(
        columns: max(terminal.viewWidth, 20),
        rows: max(terminal.viewHeight, 5),
      );
      _shell = shell;

      terminal.onOutput = (data) => shell.write(utf8.encode(data));
      terminal.onResize = (w, h, _, _) => shell.resize(w, h);
      _outputSub = shell.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(terminal.write);

      _setStatus(SessionStatus.ready);

      shell.done.then((_) => _onEnded(clean: true));
      transport.done.then((_) => _onEnded(clean: false));
    } on SshFailure catch (e) {
      if (_disposed) return;
      if (e.kind == SshFailureKind.cancelled) {
        _info('Подключение отменено.');
      } else {
        _error(e.message);
      }
      lastFailure = e;
      _setStatus(SessionStatus.lost);
      _offerReconnect();
    } catch (e) {
      if (_disposed) return;
      _error('Неожиданная ошибка: $e');
      lastFailure = SshFailure(SshFailureKind.other, 'Неожиданная ошибка: $e');
      _setStatus(SessionStatus.lost);
      _offerReconnect();
    } finally {
      _connecting = false;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final w in editWatchers) {
      w.cancel();
    }
    editWatchers.clear();
    _teardown();
    super.dispose();
  }

  /// Сбросить SFTP-канал (после ошибки), следующий [sftp] откроет новый.
  void resetSftp() {
    final old = _sftp;
    _sftp = null;
    old?.then((s) => s.close()).catchError((_) {});
  }

  /// SFTP поверх текущего соединения (открывается один раз и переиспользуется).
  Future<SftpSession> sftp() {
    final transport = _transport;
    if (transport == null || _status != SessionStatus.ready) {
      return Future.error(const SftpFailure('Нет соединения с сервером'));
    }
    return _sftp ??= transport.openSftp().timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw const SftpFailure(
          'Сервер не ответил по SFTP. Возможно, на нём нет sftp-server '
          '(на OpenWrt: opkg install openssh-sftp-server).'),
    ).catchError((Object e) {
      _sftp = null;
      throw e;
    });
  }

  // ─── Подключение ──────────────────────────────────────────────────

  Future<SshTransport> _connectWithRetries() async {
    var keys = await _loadKeys();

    String? password;
    var passwordFromStore = false;
    var rememberPassword = false;
    var cancelled = false;

    if (host.auth == AuthMethod.password) {
      password = _memPassword;
      if (password == null) {
        password = await secrets.read(passwordKey(host.id));
        passwordFromStore = password != null;
      }
    }

    Future<String?> providePassword(bool retry) async {
      if (password != null) return password;
      final answer = await prompts.askPassword(host, retry: retry);
      if (answer == null) {
        cancelled = true;
        return null;
      }
      password = answer.value;
      rememberPassword = answer.remember;
      return password;
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      final retry = attempt > 0;
      try {
        final transport = await connector.connect(SshConnectRequest(
          address: host.address,
          port: host.port,
          username: host.username,
          keys: keys,
          password: host.auth == AuthMethod.password ? () => providePassword(retry) : null,
          interactive: (name, instruction, list) async {
            // Обычный «Password:» через keyboard-interactive - отвечаем паролем.
            if (host.auth == AuthMethod.password && list.length == 1 && !list.first.echo) {
              final p = await providePassword(retry);
              return p == null ? null : [p];
            }
            final answers = await prompts.askInteractive(host, name, instruction, list);
            if (answers == null) cancelled = true;
            return answers;
          },
          verifyHostKey: _verifyHostKey,
          onBanner: (b) => terminal.write('${b.replaceAll('\n', '\r\n')}\r\n'),
          onLog: (line, debug) => _log(line, debug: debug),
        ));

        _memPassword = password;
        if (rememberPassword && password != null) {
          try {
            await secrets.write(passwordKey(host.id), password!);
          } catch (_) {
            _info('Не удалось сохранить пароль: системное хранилище недоступно.');
          }
        }
        return transport;
      } on SshFailure catch (e) {
        if (cancelled) throw const SshFailure(SshFailureKind.cancelled, 'Отменено');
        switch (e.kind) {
          case SshFailureKind.auth when host.auth == AuthMethod.password:
            if (passwordFromStore) {
              passwordFromStore = false;
              await secrets.delete(passwordKey(host.id));
            }
            password = null;
            _memPassword = null;
            _error('Неверный логин или пароль.');
          case SshFailureKind.keyPassphrase:
            await secrets.delete(passphraseKey(host.id));
            _error(e.message);
            keys = await _loadKeys(retry: true);
          default:
            rethrow;
        }
      }
    }
    throw const SshFailure(SshFailureKind.auth, 'Не удалось войти после трёх попыток.');
  }

  Future<bool> _verifyHostKey(String type, String fingerprint) async {
    final known = knownHosts.lookup(host.address, host.port);
    if (known != null && known.fingerprint == fingerprint) return true;

    final ok = await prompts.confirmHostKey(
      host,
      type: type,
      fingerprint: fingerprint,
      previous: known?.fingerprint,
    );
    if (ok) knownHosts.remember(host.address, host.port, type, fingerprint);
    return ok;
  }

  Future<List<SshKeySource>> _loadKeys({bool retry = false}) async {
    switch (host.auth) {
      case AuthMethod.password:
        return const [];

      case AuthMethod.key:
        final raw = (host.keyPath?.trim().isNotEmpty ?? false) ? host.keyPath!.trim() : '~/.ssh/id_ed25519';
        final path = expandHome(raw);
        final file = File(path);
        if (!await file.exists()) {
          throw SshFailure(SshFailureKind.config, 'Файл ключа не найден: $path');
        }
        final pem = await file.readAsString();
        if (pem.contains('PuTTY-User-Key-File')) {
          throw const SshFailure(SshFailureKind.config,
              'Ключи PuTTY (.ppk) пока не поддерживаются, экспортируйте ключ в формат OpenSSH в PuTTYgen.');
        }
        String? passphrase;
        if (connector.isKeyEncrypted(pem)) {
          passphrase = retry ? null : await secrets.read(passphraseKey(host.id));
          if (passphrase == null) {
            final answer = await prompts.askPassphrase(host, raw, retry: retry);
            if (answer == null) throw const SshFailure(SshFailureKind.cancelled, 'Отменено');
            passphrase = answer.value;
            if (answer.remember) {
              try {
                await secrets.write(passphraseKey(host.id), passphrase);
              } catch (_) {}
            }
          }
        }
        return [SshKeySource(label: raw, pem: pem, passphrase: passphrase)];

      case AuthMethod.agent:
        // Пока без ssh-agent: берём стандартные незашифрованные ключи из ~/.ssh.
        final result = <SshKeySource>[];
        for (final name in const ['id_ed25519', 'id_ecdsa', 'id_rsa']) {
          final file = File(expandHome('~/.ssh/$name'));
          if (!await file.exists()) continue;
          final pem = await file.readAsString();
          if (connector.isKeyEncrypted(pem)) continue;
          result.add(SshKeySource(label: '~/.ssh/$name', pem: pem));
        }
        if (result.isEmpty) {
          throw const SshFailure(SshFailureKind.config,
              'В ~/.ssh не найдено незашифрованных ключей (id_ed25519, id_ecdsa, id_rsa).');
        }
        return result;
    }
  }

  // ─── Завершение ───────────────────────────────────────────────────

  void _onEnded({required bool clean}) {
    if (_disposed || _status != SessionStatus.ready) return;
    _teardown();
    if (clean) {
      _info('Сессия завершена.');
      _setStatus(SessionStatus.closed);
    } else {
      _error('Соединение потеряно.');
      droppedAfterReady = true;
      lastFailure = const SshFailure(SshFailureKind.network, 'Соединение с сервером потеряно');
      _setStatus(SessionStatus.lost);
    }
    _offerReconnect();
  }

  void _offerReconnect() {
    _info('Нажмите Enter, чтобы переподключиться.');
    terminal.onOutput = (data) {
      if (data.contains('\r') || data.contains('\n')) connect();
    };
  }

  void _teardown() {
    final sftp = _sftp;
    _sftp = null;
    sftp?.then((s) => s.close()).catchError((_) {});
    _outputSub?.cancel();
    _outputSub = null;
    _shell?.close();
    _shell = null;
    _transport?.close();
    _transport = null;
    terminal.onResize = null;
  }

  void _setStatus(SessionStatus s) {
    _status = s;
    if (_disposed) return;
    onStatus(s);
    notifyListeners();
  }

  // Служебные сообщения: тусклый текст с новой строки.
  void _info(String text) => terminal.write('\r\n\x1b[2m$text\x1b[0m\r\n');
  void _error(String text) {
    _log(text, error: true);
    terminal.write('\r\n\x1b[31m✗ $text\x1b[0m\r\n');
  }
}

/// `~/...` → домашняя папка (на Windows - %USERPROFILE%).
String expandHome(String path) {
  if (!path.startsWith('~')) return path;
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
  final rest = path.substring(1).replaceAll('/', Platform.pathSeparator);
  return '$home$rest';
}
