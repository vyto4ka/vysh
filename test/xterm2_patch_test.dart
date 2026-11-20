// Правка third_party/xterm2 (vysh.patch): флаги клавиатуры TerminalView
// должны доходить до системного ввода. Без неё Gboard на Android
// открывается в анонимном режиме.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

Map<String, dynamic> _lastConfig(WidgetTester tester) {
  final call = tester.testTextInput.log.lastWhere((c) => c.method == 'TextInput.setClient');
  return (call.arguments as List)[1] as Map<String, dynamic>;
}

Future<void> _pumpTerminal(WidgetTester tester, {bool? learning}) async {
  final view = learning == null
      ? TerminalView(Terminal(), autofocus: true, hardwareKeyboardOnly: false)
      : TerminalView(Terminal(),
          autofocus: true, hardwareKeyboardOnly: false, enableIMEPersonalizedLearning: learning);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('по умолчанию поведение оригинала: обучение клавиатуры выключено', (tester) async {
    await _pumpTerminal(tester);
    expect(_lastConfig(tester)['enableIMEPersonalizedLearning'], isFalse);
  });

  testWidgets('vysh включает обучение клавиатуры', (tester) async {
    await _pumpTerminal(tester, learning: true);
    expect(_lastConfig(tester)['enableIMEPersonalizedLearning'], isTrue);
    expect(_lastConfig(tester)['inputType']['name'], isNot('TextInputType.visiblePassword'));
  });

  test('KeytabInputHandler не отправляет shortcut-строки вроде scrollLineUp в терминал', () {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);
    terminal.keyInput(TerminalKey.arrowUp, shift: true);
    terminal.keyInput(TerminalKey.pageUp, shift: true);
    terminal.keyInput(TerminalKey.arrowDown, shift: true);
    terminal.keyInput(TerminalKey.pageDown, shift: true);
    expect(output.join(), isNot(contains('scroll')));
  });
}
