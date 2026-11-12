import 'dart:convert';

/// Одноразовое разрешение владельца сессии на перенос между окнами.
class TabTransfer {
  const TabTransfer(this.id, this.token);
  final String id;
  final String token;

  Map<String, String> toJson() => {
    'type': 'vysh-tab',
    'id': id,
    'token': token,
  };

  static TabTransfer? decode(Object? data) {
    try {
      if (data is List<int>) data = utf8.decode(data);
      if (data is String) data = jsonDecode(data);
      if (data is! Map || data['type'] != 'vysh-tab') return null;
      final id = data['id'], token = data['token'];
      if (id is! String || id.isEmpty || token is! String || token.isEmpty) {
        return null;
      }
      return TabTransfer(id, token);
    } on FormatException {
      return null;
    }
  }
}
