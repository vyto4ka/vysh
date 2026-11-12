import '../../domain/models/host.dart';
import '../../domain/ports/session_prompts.dart';
import '../../domain/ports/ssh_transport.dart';
import 'window_protocol.dart';

/// Authentication stays in the owner; its questions appear in the session's UI.
class WindowPrompts implements SessionPrompts {
  WindowPrompts(this.request);
  final WindowRpc request;
  Future<dynamic> _ask(String kind, Host host, Map<String, Object?> data) =>
      request('prompt', {'kind': kind, 'host': host.toJson(), ...data});
  Future<SecretAnswer?> _secret(
    String kind,
    Host host,
    Map<String, Object?> data,
  ) async {
    final answer = await _ask(kind, host, data);
    return answer == null
        ? null
        : (
            value: answer['value'] as String,
            remember: answer['remember'] == true,
          );
  }

  @override
  Future<bool> confirmHostKey(
    Host host, {
    required String type,
    required String fingerprint,
    String? previous,
  }) async =>
      await _ask('hostKey', host, {
        'type': type,
        'fingerprint': fingerprint,
        'previous': previous,
      }) ==
      true;
  @override
  Future<SecretAnswer?> askPassword(
    Host host, {
    bool retry = false,
    bool canRemember = true,
  }) => _secret('password', host, {'retry': retry, 'canRemember': canRemember});
  @override
  Future<SecretAnswer?> askPassphrase(
    Host host,
    String keyLabel, {
    bool retry = false,
  }) => _secret('passphrase', host, {'keyLabel': keyLabel, 'retry': retry});
  @override
  Future<List<String>?> askInteractive(
    Host host,
    String name,
    String instruction,
    List<SshPrompt> prompts,
  ) async {
    final answer = await _ask('interactive', host, {
      'name': name,
      'instruction': instruction,
      'prompts': [
        for (final p in prompts) {'text': p.text, 'echo': p.echo},
      ],
    });
    return answer == null ? null : (answer as List).cast<String>();
  }
}

Future<dynamic> answerWindowPrompt(SessionPrompts prompts, Map data) async {
  final host = Host.fromJson(Map<String, Object?>.from(data['host']));
  SecretAnswer? answer;
  switch (data['kind']) {
    case 'hostKey':
      return prompts.confirmHostKey(
        host,
        type: data['type'],
        fingerprint: data['fingerprint'],
        previous: data['previous'],
      );
    case 'password':
      answer = await prompts.askPassword(
        host,
        retry: data['retry'] == true,
        canRemember: data['canRemember'] == true,
      );
    case 'passphrase':
      answer = await prompts.askPassphrase(
        host,
        data['keyLabel'],
        retry: data['retry'] == true,
      );
    case 'interactive':
      return prompts.askInteractive(host, data['name'], data['instruction'], [
        for (final p in data['prompts'])
          (text: p['text'] as String, echo: p['echo'] == true),
      ]);
  }
  return answer == null
      ? null
      : {'value': answer.value, 'remember': answer.remember};
}
