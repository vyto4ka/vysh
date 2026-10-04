/// Хранилище секретов (пароли, парольные фразы ключей).
/// Реализация по умолчанию - системный keyring.
abstract interface class SecretStore {
  /// null - секрета нет или хранилище недоступно.
  Future<String?> read(String key);

  /// Бросает исключение, если хранилище недоступно.
  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Ключи секретов для хоста.
String passwordKey(String hostId) => 'vysh.password.$hostId';
String passphraseKey(String hostId) => 'vysh.passphrase.$hostId';
