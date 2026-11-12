import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/controllers/settings_controller.dart';
import 'package:vysh/app/controllers/fonts_controller.dart';
import 'package:flutter/services.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/app/settings/app_settings.dart';
import 'package:vysh/app/windows/window_client.dart';
import 'package:vysh/app/windows/window_protocol.dart';
import 'package:vysh/app/windows/window_remote_session.dart';
import 'package:vysh/app/windows/terminal_mirror.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/models/session_tab.dart';
import 'package:vysh/domain/ports/sftp.dart';
import 'package:vysh/ui/shell/app_shell.dart';
import 'package:vysh/ui/shell/tab_strip.dart';
import 'package:vysh/ui/shell/tab_drag.dart';
import 'package:vysh/ui/shell/ui_state.dart';
import 'package:vysh/ui/sftp/file_workspace.dart';
import 'package:vysh/ui/settings/settings_page.dart';
import 'package:vysh/ui/theme/app_theme.dart';
import 'package:xterm2/core.dart';

Map<String, Object?> tab(String id) => {
  ...encodeTab(
    SessionTab(
      id: id,
      host: Host(id: 'host-$id', label: id, address: 'localhost'),
      title: id,
      isLocal: true,
      status: SessionStatus.ready,
    ),
  ),
  'maxLines': 200,
};

class Owner {
  final calls = <(String, Map<String, Object?>)>[];
  final input = <String>[];
  final terminal = Terminal(maxLines: 200);
  late final encoder = TerminalMirrorEncoder(terminal);
  List<Map<String, Object?>> tabs = [tab('first')];
  Map<String, Object?> settings = const AppSettings(
    checkForUpdates: false,
    pingHosts: false,
    serverStats: false,
    language: AppLanguage.en,
  ).toJson();
  final documents = <String, Object?>{'hosts.json': [], 'known_hosts.json': {}};
  bool denied = false;
  Completer<dynamic>? transfer;
  int nextId = 0;
  Map<String, Object?> metadata() => {
    'tabs': tabs,
    'settings': settings,
    'colors': null,
    'documents': {...documents, 'settings.json': settings},
  };
  Map<String, Object?> frame() => {
    ...metadata(),
    'sessions': {
      for (final t in tabs)
        t['id'] as String: {
          'frame': encoder.capture(full: true),
          'status': 'ready',
          'directory': '/tmp',
          'version': null,
          'failure': null,
          'log': [],
        },
    },
  };
  Future<dynamic> call(String method, Map<String, Object?> data) async {
    calls.add((method, data));
    switch (method) {
      case 'frame':
        return frame();
      case 'openLocal':
      case 'openHost':
      case 'duplicate':
        final id = 'added-${++nextId}';
        tabs = [...tabs, tab(id)];
        return id;
      case 'close':
      case 'attach':
        tabs = tabs.where((t) => t['id'] != data['sessionId']).toList();
        return null;
      case 'document':
        if (data['name'] == 'settings.json') {
          settings = Map<String, Object?>.from(data['data'] as Map);
        } else {
          documents[data['name'] as String] = data['data'];
        }
        return true;
      case 'key':
        return terminal.keyInput(
          TerminalKey.values.byName(data['key'] as String),
          ctrl: data['ctrl'] == true,
          alt: data['alt'] == true,
          shift: data['shift'] == true,
          type: TerminalKeyEventType.values.byName(data['event'] as String),
        );
      case 'paste':
        terminal.paste(data['text'] as String);
        return null;
      case 'text':
        terminal.textInput(data['text'] as String);
        return null;
      case 'sftp':
        if (denied) {
          return {
            'windowError': 'sftp',
            'code': 'permissionDenied',
            'args': {'path': '/private'},
          };
        }
        switch (data['operation']) {
          case 'home':
            return '/tmp';
          case 'list':
            return [
              encodeEntry(
                const RemoteEntry(
                  name: 'notes.txt',
                  path: '/tmp/notes.txt',
                  isDir: false,
                  size: 14,
                ),
              ),
            ];
          case 'upload':
            return transfer!.future;
        }
        return null;
      case 'transferCancel':
        transfer?.complete({'windowError': 'cancelled'});
        return null;
    }
    return null;
  }

  WindowClient client({List<Override> overrides = const []}) {
    terminal.onOutput = input.add;
    return WindowClient(
      request: call,
      initial: metadata(),
      overrides: overrides,
      closeWindow: () async {},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a window mirrors history while the owner encodes paste and application keys',
    () async {
      final owner = Owner();
      owner.terminal.write('history kept\r\n\x1b[?2004h\x1b[?1h');
      final client = owner.client();
      addTearDown(client.dispose);
      client.apply(owner.frame());
      final session = client.container
          .read(tabsProvider.notifier)
          .sessionOf('first')!;
      expect(
        session.terminal.buffer.lines[0].getText(),
        contains('history kept'),
      );
      session.terminal.paste('one\ntwo');
      session.terminal.keyInput(TerminalKey.arrowUp);
      await Future<void>.delayed(Duration.zero);
      expect(owner.input, contains('\x1b[200~one\ntwo\x1b[201~'));
      expect(owner.input, contains('\x1bOA'));
      expect(
        owner.calls.where((c) => c.$1 == 'resize'),
        isEmpty,
        reason: 'Applying an owner frame must not send a resize back',
      );
    },
  );

  test(
    'new tabs stay usable after the original detached tab closes; home focus is preserved',
    () async {
      final owner = Owner();
      final client = owner.client();
      addTearDown(client.dispose);
      final ctrl = client.container.read(tabsProvider.notifier);
      ctrl.duplicate('first');
      await Future<void>.delayed(Duration.zero);
      expect(client.container.read(tabsProvider).activeTab?.id, 'added-1');
      ctrl.close('first');
      await Future<void>.delayed(Duration.zero);
      final tabs = client.container.read(tabsProvider);
      expect(tabs.tabs.map((t) => t.id), ['added-1']);
      ctrl.sessionOf('added-1')!.terminal.textInput('still alive');
      await Future<void>.delayed(Duration.zero);
      expect(owner.input.last, 'still alive');
      ctrl.activate(0);
      client.apply(owner.frame());
      expect(client.container.read(tabsProvider).isHome, isTrue);
    },
  );

  test(
    'a stale metadata response cannot consume the pending new-tab focus',
    () async {
      final owner = Owner();
      final stale = owner.frame();
      var sendStale = true;
      final client = WindowClient(
        initial: owner.metadata(),
        closeWindow: () async {},
        request: (method, data) async {
          if (method == 'frame' && sendStale) {
            sendStale = false;
            return stale;
          }
          return owner.call(method, data);
        },
      );
      addTearDown(client.dispose);
      client.container.read(tabsProvider.notifier).openLocal();
      await Future<void>.delayed(Duration.zero);
      await client.poll();
      expect(client.container.read(tabsProvider).activeTab?.id, 'added-1');
    },
  );

  test(
    'settings use owner persistence and changes from the main window are received',
    () async {
      final owner = Owner();
      final client = owner.client();
      addTearDown(client.dispose);
      client.container
          .read(settingsProvider.notifier)
          .setThemeMode(ThemeMode.dark);
      await Future<void>.delayed(Duration.zero);
      expect(
        owner.calls.where((c) => c.$1 == 'document').single.$2['name'],
        'settings.json',
      );
      expect(AppSettings.fromJson(owner.settings).themeMode, ThemeMode.dark);
      owner.settings = AppSettings.fromJson(
        owner.settings,
      ).copyWith(themeMode: ThemeMode.light).toJson();
      client.apply(owner.frame());
      expect(
        client.container.read(settingsProvider).themeMode,
        ThemeMode.light,
      );
    },
  );

  test(
    'file operations use the original session and preserve localized errors and cancellation',
    () async {
      final owner = Owner();
      final client = owner.client();
      addTearDown(client.dispose);
      final session = client.container
          .read(tabsProvider.notifier)
          .sessionOf('first')!;
      final files = await session.sftp();
      expect(await files.home(), '/tmp');
      expect((await files.list('/tmp')).single.name, 'notes.txt');
      expect(owner.calls.last.$2['sessionId'], 'first');
      owner.denied = true;
      await expectLater(
        files.list('/private'),
        throwsA(
          isA<SftpFailure>().having(
            (e) => e.code,
            'code',
            SftpFailureCode.permissionDenied,
          ),
        ),
      );
      owner.denied = false;
      owner.transfer = Completer<dynamic>();
      final cancel = CancelToken();
      final upload = files.upload(
        File('/tmp/source'),
        '/tmp/destination',
        cancel: cancel,
        onProgress: (_) {},
      );
      final check = expectLater(upload, throwsA(isA<TransferCancelled>()));
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      await check;
      expect(owner.calls.any((c) => c.$1 == 'transferCancel'), isTrue);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'the full window shell exposes tabs, menus, files and settings in ${brightness.name}',
      (tester) async {
        final owner = Owner();
        final client = owner.client(
          overrides: [
            nativeTabDragProvider.overrideWithValue(false),
            systemFontsProvider.overrideWith((ref) async => const []),
            localFileSessionProvider.overrideWithValue(
              WindowSftpSession((method, data) => owner.call(method, data)),
            ),
            customTitleBarProvider.overrideWithValue(false),
          ],
        );
        client.apply(owner.frame());
        addTearDown(() {
          client.dispose();
        });
        await tester.binding.setSurfaceSize(const Size(1100, 760));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: client.container,
            child: MaterialApp(
              theme: buildTheme(
                seed: const Color(0xFF6750A4),
                brightness: brightness,
              ),
              home: const AppShell(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(TabStrip), findsOneWidget);
        owner.calls.clear();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(
          owner.calls.where(
            (c) => c.$1 == 'key' && c.$2['key'] == TerminalKey.keyE.name,
          ),
          isEmpty,
          reason: 'App shortcuts must not leak into the shell',
        );
        client.container.read(sftpPaneProvider.notifier).toggle('first');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Layout and session actions'));
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(MenuItemButton, 'Move to separate window'),
          findsOneWidget,
        );
        await tester.tapAt(const Offset(900, 600));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Files: two panes'));
        await tester.pumpAndSettle();
        expect(find.byType(FileWorkspace), findsOneWidget);
        Navigator.of(tester.element(find.byType(FileWorkspace))).pop();
        await tester.pumpAndSettle();
        client.container.read(tabsProvider.notifier).activate(0);
        client.container.read(homeSectionProvider.notifier).select(1);
        await tester.pumpAndSettle();
        expect(find.byType(SettingsPage), findsOneWidget);
        await tester.binding.setSurfaceSize(const Size(540, 700));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        client.dispose();
      },
    );
  }
}
