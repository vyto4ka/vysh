// Локализация: у каждого кода ошибки и шага журнала есть текст на обоих
// языках, а вне lib/l10n не появляются русские строки мимо выбора языка.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/domain/models/local_file_failure.dart';
import 'package:vysh/domain/ports/local_shell.dart';
import 'package:vysh/domain/ports/sftp.dart';
import 'package:vysh/domain/ports/ssh_transport.dart';
import 'package:vysh/l10n/app_strings.dart';

final _cyrillic = RegExp('[А-Яа-яЁё]');

void main() {
  const ru = AppStrings(isRu: true);
  const en = AppStrings(isRu: false);

  void checkBoth(String Function(AppStrings s) text, String what) {
    expect(text(ru), isNotEmpty, reason: what);
    expect(text(en), isNotEmpty, reason: what);
    expect(_cyrillic.hasMatch(text(en)), isFalse, reason: '$what (en): ${text(en)}');
  }

  test('ошибки SSH', () {
    for (final e in SshError.values) {
      checkBoth((s) => s.sshFailure(SshFailure(e)), e.name);
    }
  });

  test('шаги журнала', () {
    for (final step in SshStep.values.where((s) => s != SshStep.debug)) {
      checkBoth((s) => s.sshStep(SshLogEvent(step)), step.name);
    }
  });

  test('ошибки SFTP и локальных файлов', () {
    for (final c in SftpFailureCode.values) {
      checkBoth((s) => s.sftpFailure(SftpFailure(c, const {'code': '9'})), c.name);
    }
    for (final e in LocalFileError.values) {
      checkBoth((s) => s.localFileFailure(LocalFileFailure(e)), e.name);
    }
    for (final e in LocalShellError.values) {
      checkBoth((s) => s.localShellFailure(LocalShellFailure(e)), e.name);
    }
  });

  test('вне lib/l10n нет русских строк без выбора языка', () {
    final literal = RegExp(r"'[^'\n]*[А-Яа-яЁё][^'\n]*'");
    final localized = RegExp(r'\bisRu\b|\bisRussian\b|\bru \?|\bru\b\s*$');
    final keyMap = RegExp(r"^\s*'.': '.',?$"); // раскладка для Ctrl+буква
    final bad = <String>[];
    for (final e in Directory('lib').listSync(recursive: true)) {
      final path = e.path.replaceAll('\\', '/');
      if (e is! File || !path.endsWith('.dart') || path.contains('/l10n/')) continue;
      final lines = e.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (l.trimLeft().startsWith('//') || !literal.hasMatch(l) || keyMap.hasMatch(l)) continue;
        if (l.contains('debugPrint') || l.contains('RegExp(')) continue;
        final context = lines.sublist(i < 3 ? 0 : i - 3, i + 1).join('\n');
        if (!localized.hasMatch(context)) bad.add('$path:${i + 1}: ${l.trim()}');
      }
    }
    expect(bad, isEmpty);
  });
}
