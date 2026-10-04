import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infra/storage/json_store.dart';

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
        type: j['type'] as String? ?? '',
        fingerprint: j['fingerprint'] as String? ?? '',
        addedAt: DateTime.tryParse(j['addedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

final knownHostsProvider = Provider<KnownHosts>((ref) => KnownHosts());

/// Отпечатки ключей серверов (`known_hosts.json`), ключ - `адрес:порт`.
class KnownHosts {
  KnownHosts() {
    final raw = _store.readSync();
    if (raw is Map<String, Object?>) {
      raw.forEach((k, v) {
        if (v is Map<String, Object?>) _entries[k] = KnownHostKey.fromJson(v);
      });
    }
  }

  final _store = JsonStore('known_hosts.json');
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
