import 'sftp.dart';
import 'terminal_shell.dart';

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

/// Что именно не получилось. Текст для пользователя собирает слой
/// локализации (`l10n`) по коду и [SshFailure.args].
enum SshError {
  /// args: host.
  dnsFailed(SshFailureKind.network),

  /// args: target.
  tcpTimeout(SshFailureKind.network),

  /// args: target, detail.
  tcpFailed(SshFailureKind.network),

  /// args: seconds.
  authTimeout(SshFailureKind.network),

  /// args: detail (может отсутствовать).
  abortedBeforeAuth(SshFailureKind.network),
  connectionLost(SshFailureKind.network),
  authRejected(SshFailureKind.auth),
  tooManyAttempts(SshFailureKind.auth),
  hostKeyRejected(SshFailureKind.hostKey),

  /// args: key.
  wrongPassphrase(SshFailureKind.keyPassphrase),

  /// args: key.
  passphraseRequired(SshFailureKind.keyPassphrase),

  /// args: key, detail.
  keyUnreadable(SshFailureKind.config),

  /// args: path.
  keyFileMissing(SshFailureKind.config),
  puttyKey(SshFailureKind.config),
  noDefaultKeys(SshFailureKind.config),
  cancelled(SshFailureKind.cancelled),

  /// args: detail.
  shellFailed(SshFailureKind.other),

  /// args: detail.
  protocol(SshFailureKind.other),

  /// args: detail.
  unexpected(SshFailureKind.other);

  const SshError(this.kind);
  final SshFailureKind kind;
}

class SshFailure implements Exception {
  const SshFailure(this.error, [this.args = const {}]);

  final SshError error;

  /// Подробности для текста: адрес, путь к ключу, сообщение ОС…
  final Map<String, String> args;

  SshFailureKind get kind => error.kind;

  @override
  String toString() => args.isEmpty ? 'SshFailure(${error.name})' : 'SshFailure(${error.name}, $args)';
}

/// Шаг журнала подключения; текст строки собирает `l10n`.
enum SshStep {
  /// args: key.
  key,

  /// args: host.
  dnsLookup,

  /// args: addresses.
  dnsResult,

  /// args: detail.
  dnsError,

  /// args: address, port.
  tcpConnect,

  /// args: address, ms.
  tcpConnected,

  /// args: address, detail.
  tcpError,

  /// args: seconds.
  serverSilent,

  /// args: user.
  passwordAuth,

  /// args: prompts.
  keyboardInteractive,

  /// args: version.
  serverVersion,

  /// args: type, fingerprint.
  hostKey,
  hostKeyAccepted,
  hostKeyRejected,
  authenticated,

  /// args: detail.
  authFailed,

  /// args: detail.
  aborted,

  /// args: detail.
  sshError,

  /// Отладочная строка dartssh2 как есть. args: text.
  debug,
}

class SshLogEvent {
  const SshLogEvent(this.step, [this.args = const {}]);

  final SshStep step;
  final Map<String, String> args;

  bool get debug => step == SshStep.debug;
  bool get error => switch (step) {
        SshStep.dnsError || SshStep.tcpError || SshStep.authFailed || SshStep.sshError => true,
        _ => false,
      };
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
    this.cancelled,
    this.timeout = const Duration(seconds: 10),
    this.authTimeout = const Duration(seconds: 30),
    this.keepAliveInterval = const Duration(seconds: 60),
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
  final void Function(SshLogEvent event)? onLog;

  /// Завершается, когда попытку нужно прервать (закрыли вкладку):
  /// коннектор сразу закрывает сокет и бросает [SshFailureKind.cancelled].
  final Future<void>? cancelled;

  /// Таймаут сети: DNS и TCP-подключение к одному адресу.
  final Duration timeout;

  /// Сколько ждать сервер на этапах обмена ключами и входа. Время, пока
  /// пользователь вводит пароль или смотрит на ключ сервера, не считается.
  final Duration authTimeout;
  final Duration keepAliveInterval;
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

  /// Выполнить команду в отдельном канале и вернуть её stdout.
  /// Не уложилась в [timeout] - канал закрывается, бросается TimeoutException.
  Future<String> exec(String command, {Duration timeout = const Duration(seconds: 10)});

  /// Завершается, когда соединение закрыто (штатно или по ошибке).
  Future<void> get done;

  /// Версия сервера, например `SSH-2.0-OpenSSH_9.6`.
  String? get serverVersion;

  Future<void> close();
}

abstract interface class SshShell implements TerminalShell {}
