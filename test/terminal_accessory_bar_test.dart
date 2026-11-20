import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/settings/app_settings.dart';
import 'package:vysh/app/terminal/terminal_session.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/ui/terminal/terminal_accessory_bar.dart';
import 'package:vysh/ui/theme/app_theme.dart';
import 'package:xterm2/xterm.dart';

class _TestSession extends TerminalSession {
  _TestSession(List<String> output)
    : super.view(
        host: const Host(
          id: 'test',
          label: 'test',
          address: '127.0.0.1',
          username: 'user',
        ),
        terminal: Terminal(onOutput: output.add),
      );
}

Future<void> _pumpBar(
  WidgetTester tester,
  TerminalSession session,
  FocusNode focusNode, {
  Size size = const Size(360, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(seed: Colors.blue, brightness: Brightness.dark),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: TerminalAccessoryBar(
            session: session,
            focusNode: focusNode,
            language: AppLanguage.ru,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('TAB расположен в основной строке между ESC и CTRL', (
    tester,
  ) async {
    final output = <String>[];
    final session = _TestSession(output);
    final focusNode = FocusNode();
    addTearDown(() {
      focusNode.dispose();
      session.dispose();
    });

    await _pumpBar(tester, session, focusNode);

    final escRect = tester.getRect(find.text('ESC'));
    final tabRect = tester.getRect(find.text('TAB'));
    final ctrlRect = tester.getRect(find.text('CTRL'));

    expect(escRect.right, lessThan(tabRect.left));
    expect(tabRect.right, lessThan(ctrlRect.left));
    // Вся основная строка помещается на экране 360dp без переполнения.
    expect(tester.takeException(), isNull);
  });

  testWidgets('на кнопках панели нет Tooltip, мешающего зажатию', (
    tester,
  ) async {
    final output = <String>[];
    final session = _TestSession(output);
    final focusNode = FocusNode();
    addTearDown(() {
      focusNode.dispose();
      session.dispose();
    });

    await _pumpBar(tester, session, focusNode);
    expect(find.byType(Tooltip), findsNothing);

    // Открываем расширенную панель и проверяем, что там тоже нет Tooltip.
    final moreButton = find.byIcon(Icons.more_horiz);
    await tester.ensureVisible(moreButton);
    await tester.pump();
    await tester.tap(moreButton);
    await tester.pump();
    expect(find.byType(Tooltip), findsNothing);
    expect(find.text('S-TAB'), findsOneWidget);
  });

  testWidgets('удержание стрелки запускает автоповтор без всплывающих подсказок', (
    tester,
  ) async {
    final output = <String>[];
    final session = _TestSession(output);
    final focusNode = FocusNode();
    addTearDown(() {
      focusNode.dispose();
      session.dispose();
    });

    await _pumpBar(tester, session, focusNode);

    final upArrow = find.byIcon(Icons.arrow_upward);
    expect(upArrow, findsOneWidget);

    // Одиночный тап отправляет одну последовательность.
    await tester.tap(upArrow);
    await tester.pump();
    expect(output, ['\x1b[A']);
    output.clear();

    // Удержание: первый тик при нажатии + несколько повторов после задержки.
    final gesture = await tester.startGesture(tester.getCenter(upArrow));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 240));
    final countWhileHeld = output.length;
    expect(countWhileHeld, greaterThan(2));
    expect(output.every((s) => s == '\x1b[A'), isTrue);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 200));
    // После отпускания автоповтор останавливается.
    expect(output.length, countWhileHeld);
  });

  testWidgets('TAB отправляет \\t, а долгое нажатие — Shift+Tab', (
    tester,
  ) async {
    final output = <String>[];
    final session = _TestSession(output);
    final focusNode = FocusNode();
    addTearDown(() {
      focusNode.dispose();
      session.dispose();
    });

    await _pumpBar(tester, session, focusNode);

    await tester.tap(find.text('TAB'));
    await tester.pump();
    expect(output, ['\t']);
    output.clear();

    await tester.longPress(find.text('TAB'));
    await tester.pump();
    expect(output, ['\x1b[Z']);
  });

  testWidgets('ALT + стрелка сбрасывает модификатор до отправки без двойного ESC', (
    tester,
  ) async {
    final output = <String>[];
    final session = _TestSession(output);
    final focusNode = FocusNode();
    addTearDown(() {
      focusNode.dispose();
      session.dispose();
    });

    await _pumpBar(tester, session, focusNode);

    await tester.tap(find.text('ALT'));
    await tester.pump();
    expect(session.altModifier, isTrue);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();

    expect(session.altModifier, isFalse);
    expect(output, isNotEmpty);
    expect(output.join().startsWith('\x1b\x1b'), isFalse);
  });
}
