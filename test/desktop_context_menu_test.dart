import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/ui/terminal/session_view.dart';
import 'package:vysh/ui/widgets/modifiers.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'directory_tracking_test.dart' as fixture;
import 'terminal_shortcut_parity_test.dart' show Tabs;

class _Settings extends fixture.Store {
  @override
  Object? readSync() => {
    'language': 'en',
    'rightClick': 'paste',
    'copyOnSelect': false,
    'serverStats': false,
  };
}

void main() {
  testWidgets(
    'Shift+right click menu dismisses inside the terminal while plain right click pastes',
    (tester) async {
      Modifiers.init();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') return {'text': 'clipboard'};
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final session = fixture.session(launcher: fixture.Launcher());
      addTearDown(session.dispose);
      final output = <String>[];
      session.terminal.onOutput = output.add;
      final tabs = Tabs(session, true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tabsProvider.overrideWith(() => tabs),
            documentStoreProvider.overrideWith((ref, name) => _Settings()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SessionView(tab: tabs.build().tabs.single, active: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(
        const Offset(120, 100),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(output.join(), contains('clipboard'));
      output.clear();
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.tapAt(
          const Offset(120, 100),
          buttons: kSecondaryMouseButton,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(MenuItemButton, 'Paste'), findsOneWidget);
        expect(output, isEmpty);
        await tester.tapAt(const Offset(650, 350));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNothing);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(output.join(), 'a');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
