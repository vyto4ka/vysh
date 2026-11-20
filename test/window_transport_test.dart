import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/windows/window_transport.dart';
import 'package:vysh/app/windows/window_client.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'window_client_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'binary unix-socket RPC preserves terminal frames, supports push and authenticates peers',
    () async {
      final owner = fixture.Owner();
      owner.terminal.onOutput = owner.input.add;
      owner.terminal.write('process history Привет\r\n');

      final tempDir = await Directory.systemTemp.createTemp('vysh-ipc-test-');
      addTearDown(() async {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });
      final sockPath = '${tempDir.path}/w-test.sock';
      final server = await ServerSocket.bind(
        InternetAddress(sockPath, type: InternetAddressType.unix),
        0,
      );
      addTearDown(() => server.close());

      const token = 'window-test-token';
      const key = 'window-test-key';
      BinarySocketPeer? acceptedPeer;
      final peers = <BinarySocketPeer>[];
      addTearDown(() async {
        for (final p in peers) {
          await p.close();
        }
      });

      server.listen((socket) {
        var authed = false;
        late final BinarySocketPeer peer;
        peer = BinarySocketPeer(
          socket,
          onRequest: (method, rawArgs) async {
            final args = rawArgs is Map
                ? Map<String, Object?>.from(rawArgs)
                : <String, Object?>{};
            if (!authed) {
              if (args['token'] != token || args['windowKey'] != key) {
                throw PlatformException(code: 'stale_window');
              }
              authed = true;
              acceptedPeer = peer;
            }
            if (method == '_bootstrap') return owner.metadata();
            if (method == '_ready') return null;
            return owner.call(method, args);
          },
        );
        peers.add(peer);
      });

      // Wrong token must be rejected before bootstrap.
      await expectLater(
        ProcessSessionWindow.connect({
          'windowKey': key,
          'token': 'wrong-token',
          'socketPath': sockPath,
        }),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'stale_window'),
        ),
      );

      final arguments = <String, dynamic>{
        'windowKey': key,
        'token': token,
        'socketPath': sockPath,
      };
      final window = await ProcessSessionWindow.connect(arguments);
      addTearDown(window.close);

      final controls = <String>[];
      final client = WindowClient(
        initial: arguments['initial'],
        request: window.requestOwner,
        closeWindow: () async {},
      );
      addTearDown(client.dispose);

      await window.setWindowMethodHandler((call) async {
        controls.add(call.method);
        if (call.method == 'push') {
          client.apply(call.arguments as Map);
          return null;
        }
        return 'handled';
      });

      // Owner pushes a frame directly over the persistent binary socket.
      await acceptedPeer!.call('push', owner.frame());
      final session = client.container
          .read(tabsProvider.notifier)
          .sessionOf('first')!;
      expect(
        session.terminal.buffer.lines[0].getText(),
        contains('process history Привет'),
      );

      await client.sessionCall('first', 'text', {
        'text': 'input after transfer',
      });
      expect(owner.input, contains('input after transfer'));

      expect(await acceptedPeer!.call('focus'), 'handled');
      expect(controls, ['push', 'focus']);
    },
    skip: !Platform.isLinux && !Platform.isMacOS,
  );
}
