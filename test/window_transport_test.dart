import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/windows/window_transport.dart';
import 'package:vysh/app/windows/window_client.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'window_client_test.dart' as fixture;

class _LoopbackHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'process RPC preserves terminal frames and authenticates owner-to-window calls',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final owner = fixture.Owner();
      owner.terminal.onOutput = owner.input.add;
      owner.terminal.write('process history Привет\r\n');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      const token = 'window-test-token';
      const key = 'window-test-key';
      int? childPort;
      server.listen((request) async {
        final data = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(data['token'], token);
        expect(data['windowKey'], key);
        final method = data['method'] as String;
        final arguments = Map<String, Object?>.from(data['arguments']);
        dynamic value;
        if (method == '_bootstrap') {
          value = owner.metadata();
        } else if (method == '_ready') {
          childPort = arguments['port'] as int;
        } else {
          value = await owner.call(method, arguments);
        }
        request.response.write(jsonEncode({'value': value}));
        await request.response.close();
      });
      final arguments = <String, dynamic>{
        'windowKey': key,
        'token': token,
        'ownerPort': server.port,
      };
      final window = await ProcessSessionWindow.connect(arguments);
      addTearDown(() => window.server.close(force: true));
      final controls = <String>[];
      await window.setWindowMethodHandler((call) async {
        controls.add(call.method);
        return 'handled';
      });
      expect(childPort, window.server.port);
      final client = WindowClient(
        initial: arguments['initial'],
        request: window.requestOwner,
        closeWindow: () async {},
      );
      addTearDown(client.dispose);
      await client.poll();
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

      Future<Map> control(String credential) async {
        final http = HttpClient()..findProxy = (_) => 'DIRECT';
        try {
          final request = await http.postUrl(
            Uri.parse('http://127.0.0.1:$childPort/'),
          );
          request.persistentConnection = false;
          request.write(
            jsonEncode({
              'windowKey': key,
              'token': credential,
              'method': 'focus',
              'arguments': {},
            }),
          );
          final response = await request.close();
          return jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        } finally {
          http.close(force: true);
        }
      }

      expect((await control('wrong token'))['error'], 'stale_window');
      expect(controls, isEmpty);
      expect((await control(token))['value'], 'handled');
      expect(controls, ['focus']);
    }, _LoopbackHttp()),
  );
}
