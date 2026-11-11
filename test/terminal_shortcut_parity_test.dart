import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/app/terminal/terminal_session.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/models/session_tab.dart';
import 'package:vysh/ui/terminal/session_view.dart';
import 'directory_tracking_test.dart' as fixture;

class Tabs extends TabsController {
  Tabs(this.session, this.local);
  final TerminalSession session;
  final bool local;
  @override
  TabsState build() => TabsState(
    tabs: [
      SessionTab(
        id: 'test',
        title: 'test',
        isLocal: local,
        status: SessionStatus.ready,
        host: const Host(id: 'h', label: '', address: 'test'),
      ),
    ],
    active: 1,
  );
  @override
  TerminalSession? sessionOf(String tabId) => session;
}

class Settings extends fixture.Store {
  Settings(this.custom);
  final bool custom;
  @override
  Object? readSync() => {
    'serverStats': false,
    'copyOnSelect': false,
    'customClipboard': custom,
    'copyShortcut': 'alt+C',
    'pasteShortcut': 'alt+V',
  };
}

void main() {
  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    for (final custom in [false, true]) {
      testWidgets(
        'local and SSH clipboard + shell keys match on $platform, custom=$custom',
        (tester) async {
          String clipboard = '';
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            (call) async {
              if (call.method == 'Clipboard.setData') {
                clipboard = (call.arguments as Map)['text'];
              }
              if (call.method == 'Clipboard.getData') {
                return {'text': clipboard};
              }
              return null;
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
          Future<void> chord(
            LogicalKeyboardKey key,
            List<LogicalKeyboardKey> modifiers,
          ) async {
            for (final modifier in modifiers) {
              await tester.sendKeyDownEvent(modifier);
            }
            await tester.sendKeyEvent(key);
            for (final modifier in modifiers.reversed) {
              await tester.sendKeyUpEvent(modifier);
            }
            await tester.pump();
          }

          for (final local in [false, true]) {
            final s = fixture.session(
              launcher: local ? fixture.Launcher() : null,
            );
            final output = <String>[];
            s.terminal.onOutput = output.add;
            s.terminal.write('hello');
            final tabs = Tabs(s, local);
            await tester.pumpWidget(
              ProviderScope(
                key: UniqueKey(),
                overrides: [
                  tabsProvider.overrideWith(() => tabs),
                  documentStoreProvider.overrideWith(
                    (ref, name) => Settings(custom),
                  ),
                ],
                child: MaterialApp(
                  home: Scaffold(
                    body: SessionView(
                      tab: tabs.build().tabs.single,
                      active: true,
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final apple = platform == TargetPlatform.macOS;
            await chord(LogicalKeyboardKey.keyA, [
              apple
                  ? LogicalKeyboardKey.metaLeft
                  : LogicalKeyboardKey.controlLeft,
            ]);
            final view = tester.widget<TerminalView>(find.byType(TerminalView));
            expect(view.controller!.selection, isNotNull);
            await chord(
              LogicalKeyboardKey.keyC,
              custom
                  ? [LogicalKeyboardKey.altLeft]
                  : apple
                  ? [LogicalKeyboardKey.metaLeft]
                  : [
                      LogicalKeyboardKey.controlLeft,
                      LogicalKeyboardKey.shiftLeft,
                    ],
            );
            expect(clipboard.trim(), 'hello');
            clipboard = 'paste';
            await chord(
              LogicalKeyboardKey.keyV,
              custom
                  ? [LogicalKeyboardKey.altLeft]
                  : apple
                  ? [LogicalKeyboardKey.metaLeft]
                  : [
                      LogicalKeyboardKey.controlLeft,
                      LogicalKeyboardKey.shiftLeft,
                    ],
            );
            expect(output.join(), contains('paste'));
            output.clear();
            await chord(LogicalKeyboardKey.keyC, [
              LogicalKeyboardKey.controlLeft,
            ]);
            expect(
              output.join(),
              contains('\x03'),
            ); // Interrupt is not stolen by clipboard defaults.
            await tester.pumpWidget(const SizedBox());
            s.dispose();
          }
        },
        variant: TargetPlatformVariant({platform}),
      );
    }
  }
}
