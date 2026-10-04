import 'dart:typed_data';

import 'sftp.dart';

/// Порт SSH-подключения. Домен знает только эти типы;
/// реализация на dartssh2 живёт в `infra/ssh/`.

enum SshFailureKind {
  /// Сеть: хост недоступен, таймаут, отказ в соединении.
  network,

  /// Неверный логин/пароль/ключ.
  auth,

  /// Пользователь отклонил ключ сервера.
  hostKey,

  /// Неверная парольная фраза приватного ключа.
  keyPassphrase,

  /// Ошибка конфигурации: нет файла ключа, ключ не читается.
  config,

  /// Пользователь отменил ввод.
  cancelled,

  other,
}

class SshFailure implements Exception {
  const SshFailure(this.kind, this.message);

  final SshFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// Приватный ключ для входа.
class SshKeySource {
  const SshKeySource({required this.label, required this.pem, this.passphrase});

  final String label;
  final String pem;
  final String? passphrase;
}

/// Вопрос keyboard-interactive: текст и показывать ли ввод.
typedef SshPrompt = ({String text, bool echo});

class SshConnectRequest {
  const SshConnectRequest({
    required this.address,
    required this.port,
    required this.username,
    required this.verifyHostKey,
    this.keys = const [],
    this.password,
    this.interactive,
    this.onBanner,
    this.onLog,
    this.timeout = const Duration(seconds: 10),
  });

  final String address;
  final int port;
  final String username;
  final List<SshKeySource> keys;

  /// Пароль. null - способ не используется; функция вернула null - отмена.
  final Future<String?> Function()? password;

  /// keyboard-interactive (PAM, 2FA).
  final Future<List<String>?> Function(
      String name, String instruction, List<SshPrompt> prompts)? interactive;

  /// Проверка ключа сервера: тип и отпечаток `SHA256:...`.
  final Future<bool> Function(String type, String fingerprint) verifyHostKey;

  final void Function(String banner)? onBanner;

  /// Журнал подключения: шаг и признак «отладочная строка».
  final void Function(String line, bool debug)? onLog;
  final Duration timeout;
}

abstract interface class SshConnector {
  /// Подключиться и пройти аутентификацию. Бросает [SshFailure].
  Future<SshTransport> connect(SshConnectRequest request);

  /// Зашифрован ли приватный ключ (нужна ли парольная фраза).
  bool isKeyEncrypted(String pem);
}

abstract interface class SshTransport {
  /// Открыть интерактивную оболочку с PTY.
  Future<SshShell> openShell({required int columns, required int rows});

  /// Открыть SFTP-канал поверх этого же соединения.
  Future<SftpSession> openSftp();

  /// Завершается, когда соединение закрыто (штатно или по ошибке).
  Future<void> get done;

  /// Версия сервера, например `SSH-2.0-OpenSSH_9.6`.
  String? get serverVersion;

  Future<void> close();
}

abstract interface class SshShell {
  /// stdout и stderr вместе.
  Stream<Uint8List> get output;
  void write(Uint8List data);
  void resize(int columns, int rows);
  Future<void> get done;
  void close();
}
