library;

import 'dart:convert';
import 'dart:typed_data';

/// Бэкап данных профиля: хосты, настройки, known_hosts и сохранённые пароли
/// в одном файле. С паролем файл шифруется целиком (AES-256-GCM + PBKDF2).
///
/// Домен не зависит от других слоёв и от сторонних библиотек: криптографию
/// делает `infra` (`BackupCrypto`), здесь только формат и проверки.

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => 'BackupException($message)';
}

/// Формат бэкапа. Открытый файл - JSON, шифрованный - байтовый контейнер
/// `vyshbackup1` (см. [BackupCrypto]). Формат версия 1.
class BackupData {
  const BackupData({
    required this.hosts,
    required this.settings,
    required this.knownHosts,
    required this.secrets,
    required this.createdAt,
  });

  final List<Map<String, Object?>> hosts;
  final Object? settings;
  final Object? knownHosts;
  /// Ключи SecretStore -> значения (пароли и парольные фразы хостов).
  final Map<String, String> secrets;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'format': 'vysh-backup',
        'version': 1,
        'createdAt': createdAt.toIso8601String(),
        'hosts': hosts,
        'settings': settings,
        'knownHosts': knownHosts,
        'secrets': secrets,
      };

  static BackupData fromJson(Object? raw) {
    if (raw is! Map) throw const BackupException('not a JSON object');
    if (raw['format'] != 'vysh-backup') {
      throw const BackupException('not a vysh backup');
    }
    final version = raw['version'];
    if (version is! int || version > 1) {
      throw BackupException('unsupported backup version: $version');
    }
    final hosts = (raw['hosts'] as List? ?? [])
        .whereType<Map>()
        .map((m) => <String, Object?>{for (final e in m.entries) e.key: e.value})
        .toList();
    final secrets = <String, String>{};
    final rawSecrets = raw['secrets'];
    if (rawSecrets is Map) {
      for (final e in rawSecrets.entries) {
        if (e.value is String) secrets['${e.key}'] = e.value as String;
      }
    }
    DateTime? created;
    final c = raw['createdAt'];
    if (c is String) created = DateTime.tryParse(c);
    return BackupData(
      hosts: hosts,
      settings: raw['settings'],
      knownHosts: raw['knownHosts'],
      secrets: secrets,
      createdAt: created ?? DateTime.now(),
    );
  }

  /// Открытый файл - читаемо и сравнимо; шифрованный - в [BackupCrypto].
  String encodeJson() =>
      const JsonEncoder.withIndent('  ').convert(toJson());
}

/// Распознанный файл бэкапа.
class ParsedBackup {
  const ParsedBackup({required this.encrypted, required this.data});
  final bool encrypted;
  final BackupData? data;
}

/// Заголовок шифрованного файла: магические байты + версия формата.
final magic = Uint8List.fromList(utf8.encode('vyshbackup1'));

/// Разобрать байты файла бэкапа: JSON или шифрованный контейнер.
/// Возвращает `encrypted: true`, если нужен пароль ([data] == null).
ParsedBackup parseBackup(Uint8List bytes) {
  if (bytes.length < magic.length) throw const BackupException('too short');
  var looksMagic = true;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) {
      looksMagic = false;
      break;
    }
  }
  if (looksMagic) return const ParsedBackup(encrypted: true, data: null);
  // Пробуем JSON: текст «взят не из головы», но ошибки читаемы.
  try {
    final text = utf8.decode(bytes, allowMalformed: false);
    return ParsedBackup(encrypted: false, data: BackupData.fromJson(jsonDecode(text)));
  } catch (e) {
    throw BackupException('unreadable file: $e');
  }
}
