import '../ports/document_store.dart';
import '../models/json_read.dart';

class KnownHostKey {
  const KnownHostKey({required this.type, required this.fingerprint, required this.addedAt});

  final String type;
  final String fingerprint;
  final DateTime addedAt;

  Map<String, Object?> toJson() => {
        'type': type,
        'fingerprint': fingerprint,
        'addedAt': addedAt.toIso8601String(),
      };

  factory KnownHostKey.fromJson(Map<String, Object?> j) => KnownHostKey(
        type: j.str('type') ?? '',
        fingerprint: j.str('fingerprint') ?? '',
        addedAt: DateTime.tryParse(j.str('addedAt') ?? '') ?? DateTime.now(),
      );
}

/// Отпечатки ключей серверов (`known_hosts.json`), ключ - `адрес:порт`.
class KnownHosts {
  KnownHosts(this._store) {
    final raw = _store.readSync();
    if (raw is Map) {
      raw.forEach((k, v) {
        if (k is String && v is Map) {
          _entries[k] = KnownHostKey.fromJson(
            v is Map<String, Object?> ? v : Map<String, Object?>.from(v),
          );
        }
      });
    }
  }

  final DocumentStore _store;
  final _entries = <String, KnownHostKey>{};

  static String _id(String address, int port) => '${address.toLowerCase()}:$port';

  KnownHostKey? lookup(String address, int port) => _entries[_id(address, port)];

  void remember(String address, int port, String type, String fingerprint) {
    _entries[_id(address, port)] =
        KnownHostKey(type: type, fingerprint: fingerprint, addedAt: DateTime.now());
    _store.write(_entries.map((k, v) => MapEntry(k, v.toJson())));
  }

  void forget(String address, int port) {
    if (_entries.remove(_id(address, port)) != null) {
      _store.write(_entries.map((k, v) => MapEntry(k, v.toJson())));
    }
  }
}
