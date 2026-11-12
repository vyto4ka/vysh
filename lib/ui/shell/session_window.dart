import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import '../../app/windows/window_client.dart';
import '../../app/windows/window_prompts.dart';
import '../../app/windows/window_transport.dart';
import '../dialogs/session_prompt_dialogs.dart';
import '../vysh_app.dart';

/// A native window runs the exact same application widget tree. Only its ports
/// differ: sessions and profile writes are handled by the connection owner.
class SessionWindowApp extends StatefulWidget {
  const SessionWindowApp({
    super.key,
    required this.window,
    required this.arguments,
  });
  final SessionWindowController window;
  final Map<String, dynamic> arguments;
  @override
  State<SessionWindowApp> createState() => _SessionWindowAppState();
}

class _SessionWindowAppState extends State<SessionWindowApp>
    with WindowListener {
  late final WindowClient client;
  bool closing = false;
  Future<void>? _parking;
  @override
  void initState() {
    super.initState();
    client = WindowClient(
      initial: widget.arguments['initial'],
      closeWindow: _park,
      request: (method, data) => widget.window.requestOwner(method, {
        'windowKey': widget.arguments['windowKey'],
        'token': widget.arguments['token'],
        ...data,
      }),
    );
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
    unawaited(
      widget.window.setWindowMethodHandler((call) async {
        switch (call.method) {
          case 'close':
            await _park();
          case 'focus':
            await windowManager.show();
            await windowManager.focus();
          case 'prompt':
            return answerWindowPrompt(
              DialogSessionPrompts(rootNavigatorKey),
              call.arguments as Map,
            );
        }
        return null;
      }),
    );
    client.start();
  }

  Future<void> _park() => _parking ??= _doPark();
  Future<void> _doPark() async {
    closing = true;
    client.stop();
    if (mounted) setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    client.dispose();
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    if (!closing) {
      unawaited(client.returnToMain().catchError((Object _) => _park()));
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => closing
      ? const SizedBox.shrink()
      : UncontrolledProviderScope(
          container: client.container,
          child: const VyshApp(),
        );
}
