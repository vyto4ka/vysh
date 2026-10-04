import '../models/host.dart';
import 'ssh_transport.dart';

/// Ответ на запрос секрета: значение и «запомнить».
typedef SecretAnswer = ({String value, bool remember});

/// Вопросы пользователю во время подключения. Реализация - диалоги в UI.
abstract interface class SessionPrompts {
  /// Новый или изменившийся ключ сервера. [previous] - прежний отпечаток,
  /// если ключ изменился (возможна атака «человек посередине»).
  Future<bool> confirmHostKey(
    Host host, {
    required String type,
    required String fingerprint,
    String? previous,
  });

  /// Пароль. null - отмена.
  Future<SecretAnswer?> askPassword(Host host, {bool retry = false, bool canRemember = true});

  /// Парольная фраза ключа. null - отмена.
  Future<SecretAnswer?> askPassphrase(Host host, String keyLabel, {bool retry = false});

  /// keyboard-interactive (например, одноразовый код). null - отмена.
  Future<List<String>?> askInteractive(
    Host host,
    String name,
    String instruction,
    List<SshPrompt> prompts,
  );
}
