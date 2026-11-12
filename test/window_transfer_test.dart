import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'package:vysh/app/controllers/external_colors_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/app/windows/detached_windows.dart';
import 'package:vysh/app/windows/window_client.dart';
import 'package:vysh/app/windows/tab_transfer.dart';
import 'package:vysh/domain/models/external_colors.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/models/session_tab.dart';
import 'directory_tracking_test.dart' as fixture;

class _Tabs extends TabsController {
  @override
  TabsState build() => TabsState(
    tabs: [
      for (final id in ['one', 'two', 'three'])
        SessionTab(
          id: id,
          title: id,
          host: Host(id: id, label: id, address: id),
          isLocal: true,
          status: SessionStatus.ready,
        ),
    ],
    active: 1,
  );
}

class _Colors extends ExternalColorsController {
  @override
  ExternalColors? build() => null;
}

void main() {
  test(
    'native byte payload survives the operating system drag-and-drop codec',
    () {
      const transfer = TabTransfer('session-id', 'grant-token');
      final payload = utf8.encode(jsonEncode(transfer.toJson()));
      expect(TabTransfer.decode(payload)?.id, transfer.id);
      expect(TabTransfer.decode(payload)?.token, transfer.token);
      expect(TabTransfer.decode(<int>[0xff]), isNull);
    },
  );
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  const channels = 'mixin.one/desktop_multi_window/channels';
  late ProviderContainer container;
  late List<Map<String, dynamic>> windows;

  Future<dynamic> rpc(
    Map window,
    String method,
    Map<String, Object?> data,
  ) async {
    final reply = Completer<dynamic>();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channels,
      codec.encodeMethodCall(
        MethodCall('methodCall', {
          'channel': 'vysh/session-owner',
          'method': method,
          'arguments': {
            'windowKey': window['windowKey'],
            'token': window['token'],
            ...data,
          },
        }),
      ),
      (bytes) {
        try {
          reply.complete(codec.decodeEnvelope(bytes!));
        } catch (error, stack) {
          reply.completeError(error, stack);
        }
      },
    );
    return reply.future;
  }

  WindowClient client(int index) => WindowClient(
    initial: windows[index]['initial'],
    closeWindow: () async {},
    request: (method, data) => rpc(windows[index], method, data),
  );

  setUp(() {
    windows = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        if (call.method == 'getBounds') {
          return {'x': 10.0, 'y': 10.0, 'width': 1100.0, 'height': 740.0};
        }
        if (call.method == 'isMinimized') return false;
        return null;
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.leanflutter.plugins/screen_retriever'),
      (call) async {
        if (call.method == 'getCursorScreenPoint') {
          return {'dx': 200.0, 'dy': 200.0};
        }
        return {'displays': []};
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(channels),
      (call) async => null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('mixin.one/desktop_multi_window'),
      (call) async {
        if (call.method == 'createWindow') {
          windows.add(
            Map<String, dynamic>.from(
              jsonDecode((call.arguments as Map)['arguments']),
            ),
          );
          return 'native-${windows.length}';
        }
        return null;
      },
    );
    container = ProviderContainer(
      overrides: [
        processSessionWindowsProvider.overrideWithValue(false),
        tabsProvider.overrideWith(_Tabs.new),
        documentStoreProvider.overrideWith((ref, name) => fixture.Store()),
        sessionPromptsProvider.overrideWithValue(fixture.Unused()),
        externalColorsProvider.overrideWith(_Colors.new),
      ],
    );
    for (final tab in container.read(tabsProvider).tabs) {
      container.read(sessionsProvider)[tab.id] = fixture.session(
        launcher: fixture.Launcher(),
      );
    }
  });
  tearDown(() async {
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    for (final name in [
      'window_manager',
      'dev.leanflutter.plugins/screen_retriever',
      channels,
      'mixin.one/desktop_multi_window',
    ]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        null,
      );
    }
  });

  test(
    'a live session moves main → child → another child → main without reconnecting',
    () async {
      final owner = container.read(detachedWindowsProvider.notifier);
      final original = container.read(tabsProvider.notifier).sessionOf('one')!;
      original.terminal.write('history remains');
      final input = <String>[];
      original.terminal.onOutput = input.add;
      await owner.detach('two');
      await owner.detach('three');
      final first = client(0), second = client(1);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final firstOwner = first.container.read(detachedWindowsProvider.notifier);
      final secondOwner = second.container.read(
        detachedWindowsProvider.notifier,
      );
      final fromMain = await owner.beginDrag('one');
      await owner.finishDrag(fromMain, accepted: true);
      expect(
        await owner.canAcceptDrag(fromMain),
        isTrue,
        reason: 'Source completion must allow the target to finish an OS drop',
      );
      await firstOwner.acceptDrag(fromMain);
      expect(first.container.read(tabsProvider).activeTab?.id, 'one');
      expect(container.read(detachedWindowsProvider)['one'], 'native-1');
      final between = await firstOwner.beginDrag('one');
      await secondOwner.acceptDrag(between);
      await first.poll();
      expect(first.container.read(tabsProvider).tabs.map((tab) => tab.id), [
        'two',
      ]);
      expect(second.container.read(tabsProvider).activeTab?.id, 'one');
      final mirror = second.container
          .read(tabsProvider.notifier)
          .sessionOf('one')!;
      expect(
        mirror.terminal.buffer.lines[0].getText(),
        contains('history remains'),
      );
      mirror.terminal.textInput('still alive');
      await Future<void>.delayed(Duration.zero);
      expect(input, contains('still alive'));
      final back = await secondOwner.beginDrag('one');
      await owner.acceptDrag(back);
      await second.poll();
      expect(
        container.read(detachedWindowsProvider).containsKey('one'),
        isFalse,
      );
      expect(container.read(tabsProvider).activeTab?.id, 'one');
      expect(
        container.read(tabsProvider.notifier).sessionOf('one'),
        same(original),
      );
      expect(original.isDisposed, isFalse);
      expect(await owner.canAcceptDrag(back), isFalse);
      await expectLater(
        owner.acceptDrag(back),
        throwsA(isA<PlatformException>()),
      );
      expect(windows.length, 2);
    },
  );

  test(
    'every detach creates a fresh native window with the source dimensions',
    () async {
      final owner = container.read(detachedWindowsProvider.notifier);
      await owner.detach('one');
      final first = client(0);
      addTearDown(first.dispose);
      await first.returnToMain();
      await owner.detach('one');
      expect(windows.length, 2);
      expect(windows[0]['windowKey'], isNot(windows[1]['windowKey']));
      expect(windows[1]['width'], 1100.0);
      expect(windows[1]['height'], 740.0);
    },
  );

  test('cancelled and foreign drag grants cannot move a session', () async {
    final owner = container.read(detachedWindowsProvider.notifier);
    final grant = await owner.beginDrag('one');
    expect(await owner.canAcceptDrag(TabTransfer('two', grant.token)), isFalse);
    expect(
      await owner.canAcceptDrag(const TabTransfer('one', 'another instance')),
      isFalse,
    );
    await owner.finishDrag(grant);
    expect(await owner.canAcceptDrag(grant), isFalse);
    expect(container.read(tabsProvider).tabs.length, 3);
  });
}
