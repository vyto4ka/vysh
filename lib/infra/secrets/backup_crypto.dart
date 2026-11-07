import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../../domain/services/backup.dart';

/// Шифрование бэкапа: AES-256-GCM, ключ - PBKDF2-HMAC-SHA256
/// из пароля и случайной соли, 310 000 итераций (OWASP 2024 для SHA-256),
/// случайный IV. Заголовок и параметры хранятся в файле.
///
/// Формат: `vyshbackup1` (16 байт) | 32 байта соли | 12 байт IV | шифртекст
/// (вместе с GCM-тегом).
class BackupCrypto {
  BackupCrypto._();

  static const _iterations = 310000;

  static Uint8List _key(String password, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _iterations, 32));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }

  /// Зашифровать JSON-байты бэкапа паролем.
  static Uint8List encrypt(Uint8List plain, String password) {
    final random = Random.secure();
    final salt = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)));
    final iv = Uint8List.fromList(
        List<int>.generate(12, (_) => random.nextInt(256)));
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(
          KeyParameter(_key(password, salt)),
          128, // размер GCM-тега в битах
          iv,
          Uint8List(0),
        ),
      );
    final secret = cipher.process(plain);
    final out = BytesBuilder()
      ..add(magic)
      ..add(salt)
      ..add(iv)
      ..add(secret);
    return out.takeBytes();
  }

  /// Расшифровать контейнер `vyshbackup1`. При неверном пароле -FormatException
  /// от GCM; превращаем её в [BackupException], чтобы UI показал «неверный
  /// пароль», а не байты мусора.
  static Uint8List decrypt(Uint8List bytes, String password) {
    if (bytes.length < magic.length) throw const BackupException('too short');
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) throw const BackupException('not encrypted');
    }
    var o = magic.length;
    const saltLen = 32, ivLen = 12;
    if (bytes.length < o + saltLen + ivLen) {
      throw const BackupException('truncated header');
    }
    final salt = Uint8List.sublistView(bytes, o, o + saltLen);
    o += saltLen;
    final iv = Uint8List.sublistView(bytes, o, o + ivLen);
    o += ivLen;
    final secret = Uint8List.sublistView(bytes, o);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(KeyParameter(_key(password, salt)), 128, iv, Uint8List(0)),
      );
    try {
      return cipher.process(secret);
    } on FormatException {
      throw const BackupException('wrong password');
    } on ArgumentError {
      // Вскрытый tag при коротком/пустом шифртексте - тоже неверный пароль.
      throw const BackupException('wrong password');
    } on InvalidCipherTextException {
      // Основной случай: GCM-тег не сошёлся - неверный пароль (или битый файл).
      throw const BackupException('wrong password');
    }
  }
}
