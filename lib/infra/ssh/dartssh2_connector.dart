import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../domain/ports/sftp.dart';
import '../../domain/ports/ssh_transport.dart';
import 'dartssh2_sftp.dart';

/// SSH на чистом Dart (dartssh2).
class DartSsh2Connector implements SshConnector {
  const DartSsh2Connector();

  @override
  bool isKeyEncrypted(String pem) {
    try {
      return SSHKeyPair.isEncryptedPem(pem);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<SshTransport> connect(SshConnectRequest r) async {
    void log(String line, [bool debug = false]) => r.onLog?.call(line, debug);

    final identities = <SSHKeyPair>[];
    for (final key in r.keys) {
      log('Ключ: ${key.label}');
      identities.addAll(await _parseKey(key));
    }

    // DNS отдельно - чтобы в логе было видно, на каком шаге проблема.
    var target = r.address;
    if (InternetAddress.tryParse(r.address) == null) {
      log('Поиск адреса «${r.address}» (DNS)…');
      try {
        final found = await InternetAddress.lookup(r.address).timeout(r.timeout);
        if (found.isEmpty) throw const SocketException('пустой ответ');
        log('DNS: ${found.map((a) => a.address).join(', ')}');
        target = found.first.address;
      } catch (e) {
        log('DNS: ошибка: $e');
        throw SshFailure(SshFailureKind.network,
            'Не удалось найти хост «${r.address}»: имя не разрешается через DNS');
      }
    }

    log('TCP-подключение к $target:${r.port}…');
    final sw = Stopwatch()..start();
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(target, r.port, timeout: r.timeout);
    } catch (e) {
      log('TCP: ошибка: $e');
      throw SshFailure(SshFailureKind.network, _networkMessage(e, r));
    }
    log('TCP-соединение установлено за ${sw.elapsedMilliseconds} мс');

    var hostKeyRejected = false;
    late final SSHClient client;

    client = SSHClient(
      socket,
      username: r.username,
      identities: identities.isEmpty ? null : identities,
      onPasswordRequest: r.password == null
          ? null
          : () {
              log('Вход по паролю для ${r.username}…');
              return r.password!();
            },
      onUserInfoRequest: r.interactive == null
          ? null
          : (req) {
              log('keyboard-interactive: ${req.prompts.map((p) => p.promptText.trim()).join(' | ')}');
              return r.interactive!(
                req.name,
                req.instruction,
                [for (final p in req.prompts) (text: p.promptText, echo: p.echo)],
              );
            },
      onVerifyHostKey: (type, fingerprint) async {
        final fp = utf8.decode(fingerprint);
        log('Сервер: ${client.remoteVersion ?? 'неизвестно'}');
        log('Ключ сервера: $type $fp');
        final ok = await r.verifyHostKey(type, fp);
        log(ok ? 'Ключ сервера принят' : 'Ключ сервера отклонён');
        if (!ok) hostKeyRejected = true;
        return ok;
      },
      onUserauthBanner: r.onBanner,
      onAuthenticated: () => log('Вход выполнен'),
      printDebug: (line) => log(line ?? '', true),
      keepAliveInterval: const Duration(seconds: 15),
      handshakeTimeout: r.timeout,
    );

    try {
      await client.authenticated;
    } on SSHAuthFailError catch (e) {
      log('Аутентификация: ${e.message}');
      client.close();
      throw const SshFailure(SshFailureKind.auth, 'Сервер отклонил логин, пароль или ключ');
    } on SSHAuthAbortError catch (e) {
      log('Прервано: ${e.message}${e.reason == null ? '' : ' (${e.reason})'}');
      client.close();
      if (hostKeyRejected) {
        throw const SshFailure(SshFailureKind.hostKey, 'Ключ сервера отклонён');
      }
      final reason = e.reason;
      throw SshFailure(
        SshFailureKind.network,
        'Соединение прервано до входа${reason == null ? '' : ': $reason'}',
      );
    } on SSHError catch (e) {
      log('Ошибка SSH: $e');
      client.close();
      if (hostKeyRejected) {
        throw const SshFailure(SshFailureKind.hostKey, 'Ключ сервера отклонён');
      }
      throw SshFailure(SshFailureKind.other, 'Ошибка SSH: $e');
    }

    return _Transport(client);
  }

  Future<List<SSHKeyPair>> _parseKey(SshKeySource key) async {
    List<SSHKeyPair> parse() => SSHKeyPair.fromPem(key.pem, key.passphrase);
    try {
      try {
        // Расшифровка ключа (bcrypt) может занять заметное время - в отдельном изоляте.
        return await Isolate.run(parse);
      } catch (_) {
        // Ошибки из изолята приходят «обёрнутыми» - повторяем здесь,
        // чтобы получить настоящий тип исключения.
        return parse();
      }
    } on SSHKeyDecryptError {
      throw SshFailure(SshFailureKind.keyPassphrase,
          'Неверная парольная фраза для ключа ${key.label}');
    } on ArgumentError {
      throw SshFailure(SshFailureKind.keyPassphrase,
          'Для ключа ${key.label} нужна парольная фраза');
    } catch (e) {
      throw SshFailure(SshFailureKind.config, 'Не удалось прочитать ключ ${key.label}: $e');
    }
  }

  String _networkMessage(Object e, SshConnectRequest r) {
    final target = '${r.address}:${r.port}';
    if (e is TimeoutException) return 'Нет ответа от $target (таймаут)';
    if (e is SocketException) {
      final msg = e.osError?.message ?? e.message;
      return 'Не удалось подключиться к $target: $msg';
    }
    return 'Не удалось подключиться к $target: $e';
  }
}

class _Transport implements SshTransport {
  _Transport(this._client);

  final SSHClient _client;

  @override
  Future<void> get done => _client.done.catchError((_) {});

  @override
  String? get serverVersion => _client.remoteVersion;

  @override
  Future<SshShell> openShell({required int columns, required int rows}) async {
    try {
      final session = await _client.shell(
        pty: SSHPtyConfig(width: columns, height: rows),
      );
      return _Shell(session);
    } on SSHError catch (e) {
      throw SshFailure(SshFailureKind.other, 'Сервер не открыл оболочку: $e');
    }
  }

  @override
  Future<SftpSession> openSftp() async {
    try {
      return DartSsh2Sftp(await _client.sftp());
    } on SSHError catch (e) {
      throw SftpFailure('Сервер не поддерживает SFTP: $e');
    }
  }

  @override
  Future<void> close() async {
    try {
      _client.close();
    } catch (_) {}
  }
}

class _Shell implements SshShell {
  _Shell(this._session) {
    var open = 2;
    void onDone() {
      if (--open == 0) _output.close();
    }

    _session.stdout.listen(_output.add, onError: (_) {}, onDone: onDone);
    _session.stderr.listen(_output.add, onError: (_) {}, onDone: onDone);
  }

  final SSHSession _session;
  final _output = StreamController<Uint8List>();

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<void> get done => _session.done.catchError((_) {});

  @override
  void write(Uint8List data) {
    try {
      _session.write(data);
    } catch (_) {}
  }

  @override
  void resize(int columns, int rows) {
    if (columns <= 0 || rows <= 0) return;
    try {
      _session.resizeTerminal(columns, rows);
    } catch (_) {}
  }

  @override
  void close() {
    try {
      _session.close();
    } catch (_) {}
  }
}
