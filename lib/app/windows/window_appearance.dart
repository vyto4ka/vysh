import 'dart:ui';
import '../../domain/models/external_colors.dart';

Map<String, Object?>? encodeWindowColors(ExternalColors? colors) =>
    colors == null
    ? null
    : {
        'seed': colors.seed.toARGB32(),
        'source': colors.source,
        'brightness': colors.brightness?.name,
        'ansi': colors.ansi?.map((c) => c.toARGB32()).toList(),
        'background': colors.terminalBackground?.toARGB32(),
        'foreground': colors.terminalForeground?.toARGB32(),
        'roles': {
          for (final entry in colors.roles.entries)
            entry.key.name: {
              for (final role in entry.value.entries)
                role.key: role.value.toARGB32(),
            },
        },
      };
ExternalColors? decodeWindowColors(Map? data) => data == null
    ? null
    : ExternalColors(
        seed: Color(data['seed']),
        source: data['source'],
        brightness: data['brightness'] == null
            ? null
            : Brightness.values.byName(data['brightness']),
        ansi: (data['ansi'] as List?)?.map((v) => Color(v as int)).toList(),
        terminalBackground: data['background'] == null
            ? null
            : Color(data['background']),
        terminalForeground: data['foreground'] == null
            ? null
            : Color(data['foreground']),
        roles: {
          for (final entry in (data['roles'] as Map).entries)
            Brightness.values.byName(entry.key): {
              for (final role in (entry.value as Map).entries)
                role.key: Color(role.value),
            },
        },
      );
