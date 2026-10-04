import 'dart:math';

enum AuthMethod { password, key, agent }

/// Сохранённый хост. Секретов здесь нет - только ссылки на них.
class Host {
  const Host({
    required this.id,
    required this.label,
    required this.address,
    this.port = 22,
    this.username = 'root',
    this.auth = AuthMethod.password,
    this.keyPath,
    this.group = '',
    this.color = 0xFF6750A4,
    this.lastConnectedAt,
  });

  final String id;
  final String label;
  final String address;
  final int port;
  final String username;
  final AuthMethod auth;
  final String? keyPath;
  final String group;
  final int color;
  final DateTime? lastConnectedAt;

  String get title => label.trim().isEmpty ? address : label;

  String get displayAddress =>
      '$username@$address${port == 22 ? '' : ':$port'}';

  Host withLastConnected(DateTime time) => Host(
        id: id,
        label: label,
        address: address,
        port: port,
        username: username,
        auth: auth,
        keyPath: keyPath,
        group: group,
        color: color,
        lastConnectedAt: time,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'address': address,
        'port': port,
        'username': username,
        'auth': auth.name,
        if (keyPath != null) 'keyPath': keyPath,
        'group': group,
        'color': color,
        if (lastConnectedAt != null)
          'lastConnectedAt': lastConnectedAt!.toIso8601String(),
      };

  factory Host.fromJson(Map<String, Object?> json) => Host(
        id: json['id'] as String? ?? newId(),
        label: json['label'] as String? ?? '',
        address: json['address'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 22,
        username: json['username'] as String? ?? 'root',
        auth: AuthMethod.values.firstWhere(
          (a) => a.name == json['auth'],
          orElse: () => AuthMethod.password,
        ),
        keyPath: json['keyPath'] as String?,
        group: json['group'] as String? ?? '',
        color: (json['color'] as num?)?.toInt() ?? 0xFF6750A4,
        lastConnectedAt: DateTime.tryParse(json['lastConnectedAt'] as String? ?? ''),
      );

  /// Разбор быстрого подключения: `user@host`, `user@host:port`, `host`.
  static Host? tryParseQuick(String input) {
    final m = RegExp(r'^(?:([^@\s]+)@)?([A-Za-z0-9.\-_]+|\[[0-9a-fA-F:]+\])(?::(\d{1,5}))?$')
        .firstMatch(input.trim());
    if (m == null) return null;
    final address = m.group(2)!.replaceAll(RegExp(r'[\[\]]'), '');
    if (!address.contains('.') && !address.contains(':') && address != 'localhost') {
      return null;
    }
    final port = int.tryParse(m.group(3) ?? '') ?? 22;
    if (port < 1 || port > 65535) return null;
    return Host(
      id: newId(),
      label: '',
      address: address,
      port: port,
      username: m.group(1) ?? 'root',
    );
  }
}

String newId() {
  final r = Random.secure();
  return List.generate(12, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
}
