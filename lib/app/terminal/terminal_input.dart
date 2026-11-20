/// Ввод в терминал без SSH и виджетов: Ctrl-комбинации с экранной
/// клавиатуры и отслеживание того, что пользователь набрал сам.
abstract final class TerminalInput {
  /// Буква Ctrl-комбинации для клавиши: латиница как есть (в верхнем
  /// регистре), русская раскладка - по положению клавиши (с → C).
  static String? ctrlLetter(String input) {
    if (input.isEmpty) return null;
    final ch = input[0];
    final code = ch.codeUnitAt(0);
    if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
      return ch.toUpperCase();
    }
    const cyrillicToEn = <String, String>{
      'ф': 'A',
      'Ф': 'A',
      'и': 'B',
      'И': 'B',
      'с': 'C',
      'С': 'C',
      'в': 'D',
      'В': 'D',
      'у': 'E',
      'У': 'E',
      'а': 'F',
      'А': 'F',
      'п': 'G',
      'П': 'G',
      'р': 'H',
      'Р': 'H',
      'ш': 'I',
      'Ш': 'I',
      'о': 'J',
      'О': 'J',
      'л': 'K',
      'Л': 'K',
      'д': 'L',
      'Д': 'L',
      'ь': 'M',
      'Ь': 'M',
      'т': 'N',
      'Т': 'N',
      'щ': 'O',
      'Щ': 'O',
      'з': 'P',
      'З': 'P',
      'й': 'Q',
      'Й': 'Q',
      'к': 'R',
      'К': 'R',
      'ы': 'S',
      'Ы': 'S',
      'е': 'T',
      'Е': 'T',
      'г': 'U',
      'Г': 'U',
      'м': 'V',
      'М': 'V',
      'ц': 'W',
      'Ц': 'W',
      'ч': 'X',
      'Ч': 'X',
      'н': 'Y',
      'Н': 'Y',
      'я': 'Z',
      'Я': 'Z',
      'х': '[',
      'Х': '[',
      'ъ': ']',
      'Ъ': ']',
    };
    if (cyrillicToEn.containsKey(ch)) {
      return cyrillicToEn[ch];
    }
    if (ch == '[' ||
        ch == ']' ||
        ch == '\\' ||
        ch == '^' ||
        ch == '_' ||
        ch == '@' ||
        ch == ' ') {
      return ch;
    }
    return null;
  }

  /// Управляющий байт Ctrl+[char] (Ctrl+C → 3); null - такой комбинации нет.
  static int? ctrlByte(String char) {
    final mapped = ctrlLetter(char) ?? char.toUpperCase();
    final code = mapped.codeUnitAt(0);
    if (code >= 65 && code <= 90) return code - 64;
    if (code >= 97 && code <= 122) return code - 96;
    return switch (code) {
      91 => 27, // ESC / ^[
      92 => 28, // ^\
      93 => 29, // ^]
      94 => 30, // ^^
      95 => 31, // ^_
      32 || 64 => 0, // ^@ или пробел
      _ => null,
    };
  }
}

/// Текст, который пользователь набрал в текущей строке (без prompt и
/// вывода shell): Enter, ^C и ^U очищают, ^W стирает слово, Backspace - символ.
class TypedCommand {
  String text = '';

  void feed(String data) {
    var i = 0;
    while (i < data.length) {
      final code = data.codeUnitAt(i);
      if (code == 0x1b) {
        i = _skipEscape(data, i);
        continue;
      }
      if (code == 13 || code == 10 || code == 3 || code == 21) {
        // Enter, ^C, ^U.
        text = '';
      } else if (code == 23) {
        // ^W - слово назад.
        final trimmed = text.trimRight();
        final lastSpace = trimmed.lastIndexOf(' ');
        text = lastSpace >= 0 ? trimmed.substring(0, lastSpace + 1) : '';
      } else if (code == 127 || code == 8) {
        if (text.isNotEmpty) text = text.substring(0, text.length - 1);
      } else if (code >= 32) {
        text += String.fromCharCode(code);
      }
      i++;
    }
  }

  /// Пропускает ANSI escape-последовательность, начинающуюся с `\x1b` на [start].
  static int _skipEscape(String data, int start) {
    final next = start + 1;
    if (next >= data.length) return next;
    final c = data.codeUnitAt(next);
    if (c == 0x5b /* [ CSI */) {
      var j = next + 1;
      while (j < data.length) {
        final b = data.codeUnitAt(j);
        j++;
        if (b >= 0x40 && b <= 0x7e) break;
      }
      return j;
    }
    if (c == 0x4f /* O SS3 */) {
      return next + 2 <= data.length ? next + 2 : data.length;
    }
    if (c == 0x5d /* ] OSC */) {
      var j = next + 1;
      while (j < data.length) {
        final b = data.codeUnitAt(j);
        if (b == 0x07) return j + 1;
        if (b == 0x1b && j + 1 < data.length && data.codeUnitAt(j + 1) == 0x5c) {
          return j + 2;
        }
        j++;
      }
      return j;
    }
    // Alt+символ (ESC + 1 символ).
    return next + 1;
  }
}
