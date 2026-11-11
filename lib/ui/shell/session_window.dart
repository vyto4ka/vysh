import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../infra/platform/font_files.dart';
import '../../app/windows/window_appearance.dart';
import '../../domain/models/external_colors.dart';
import '../theme/app_theme.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xterm2/xterm.dart';
// Use the same key mapping as the vendored TerminalView; encode in the owner.
// ignore: implementation_imports
import 'package:xterm2/src/ui/input_map.dart' show keyToTerminalKey;
import '../../app/settings/app_settings.dart';
import '../../app/settings/terminal_font.dart';
import '../../app/windows/detached_windows.dart';
import '../../app/windows/terminal_mirror.dart';
import '../../infra/platform/capabilities.dart';
import '../terminal/terminal_shortcuts.dart';
import '../terminal/terminal_theme.dart';

/// A native window displays a shared session. It never owns credentials, an SSH
/// connection, a PTY or writable profile state.
class SessionWindowApp extends StatefulWidget {
  const SessionWindowApp({
    super.key,
    required this.window,
    required this.arguments,
  });
  final WindowController window;
  final Map<String, dynamic> arguments;
  @override
  State<SessionWindowApp> createState() => _SessionWindowAppState();
}

class _SessionWindowAppState extends State<SessionWindowApp>
    with WindowListener {
  late final terminal = Terminal(maxLines: widget.arguments['maxLines']);
  late final mirror = TerminalMirrorDecoder(terminal);
  final selection = TerminalController();
  final focus = FocusNode();
  final navigator = GlobalKey<NavigatorState>();
  late AppSettings settings = AppSettings.fromJson(
    Map<String, Object?>.from(widget.arguments['settings']),
  );
  Timer? timer;
  bool busy = false, applying = false, closing = false;
  String? error;
  String status = 'connecting';
  String? _copied;
  String _settingsKey = '';
  ExternalColors? colors;
  bool _needsFull = true;
  bool get isRu =>
      settings.language == AppLanguage.ru ||
      settings.language == AppLanguage.auto &&
          WidgetsBinding.instance.platformDispatcher.locale.languageCode ==
              'ru';
  Future<dynamic> send(String method, [Map<String, Object?> data = const {}]) =>
      sessionWindowChannel.invokeMethod(method, {
        'tabId': widget.arguments['tabId'],
        'token': widget.arguments['token'],
        ...data,
      });
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
    unawaited(
      widget.window.setWindowMethodHandler((call) async {
        if (call.method == 'bind') {
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          await windowManager.setTitle('${arguments['title']} — vysh');
          await windowManager.setPosition(
            Offset(
              (arguments['x'] as num).toDouble(),
              (arguments['y'] as num).toDouble(),
            ),
          );
          runApp(
            SessionWindowApp(
              key: UniqueKey(),
              window: widget.window,
              arguments: arguments,
            ),
          );
        }
        if (call.method == 'close') await _parkOrDestroy();
        if (call.method == 'focus') {
          await windowManager.show();
          await windowManager.focus();
        }
        return null;
      }),
    );
    terminal.onOutput = (text) =>
        _input(text.startsWith('\x1b') ? 'raw' : 'text', {'text': text});
    terminal.onResize = (w, h, pw, ph) {
      if (!applying) {
        _input('resize', {
          'width': w,
          'height': h,
          'pixelWidth': pw,
          'pixelHeight': ph,
        });
      }
    };
    selection.addListener(() {
      if (settings.copyOnSelect) _copy(clear: false);
    });
    timer = Timer.periodic(const Duration(milliseconds: 40), (_) => _poll());
    _poll(force: true);
  }

  void _input(String method, Map<String, Object?> data) {
    unawaited(
      send(method, data).catchError((Object e) {
        if (mounted) setState(() => error = '$e');
        return null;
      }),
    );
  }

  Future<void> _poll({bool force = false}) async {
    if (busy || closing) return;
    busy = true;
    try {
      final data = await send('frame', {'force': force || _needsFull});
      if (!mounted || data == null) return;
      applying = true;
      mirror.apply(data['frame']);
      applying = false;
      _needsFull = false;
      final settingsKey = jsonEncode([data['settings'], data['colors']]);
      if (settingsKey != _settingsKey ||
          status != data['status'] ||
          error != null) {
        final next = AppSettings.fromJson(
          Map<String, Object?>.from(data['settings']),
        );
        if (next.terminalFont != settings.terminalFont) {
          final name = TerminalFont.fileName(next.terminalFont);
          if (name != null && name.isNotEmpty) {
            await FontFiles.loadByFileName(name);
          }
        }
        if (!mounted) return;
        setState(() {
          status = data['status'];
          error = null;
          settings = next;
          colors = decodeWindowColors(data['colors']);
          _settingsKey = settingsKey;
        });
      }
    } catch (e) {
      _needsFull = true;
      if (mounted && !closing && error == null) {
        setState(
          () => error = isRu
              ? 'Связь с главным окном потеряна. Сессия остаётся в главном окне.'
              : 'Main window unavailable. The session remains in the main window.',
        );
      }
    } finally {
      applying = false;
      busy = false;
    }
  }

  Future<void> _return() async {
    if (closing) return;
    closing = true;
    timer?.cancel();
    try {
      await send('attach');
    } catch (_) {}
    await _parkOrDestroy();
  }

  Future<void> _parkOrDestroy() async {
    closing = true;
    timer?.cancel();
    if (Platform.isLinux) {
      await windowManager.hide();
    } else {
      await windowManager.destroy();
    }
  }

  @override
  void onWindowClose() {
    unawaited(_return());
  }

  void _copy({bool clear = true}) {
    final range = selection.selection;
    if (range == null) return;
    final text = terminal.buffer.getText(range);
    if (text.isNotEmpty && (clear || text != _copied)) {
      _copied = text;
      unawaited(Clipboard.setData(ClipboardData(text: text)));
    }
    if (clear) selection.clearSelection();
  }

  Future<void> _paste() async {
    var text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted || text == null || text.isEmpty) return;
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (settings.confirmMultilinePaste && text.contains('\n')) {
      final ok = await showDialog<bool>(
        context: navigator.currentContext!,
        builder: (context) => AlertDialog(
          title: Text(
            isRu ? 'Вставить несколько строк?' : 'Paste multiple lines?',
          ),
          content: SingleChildScrollView(
            child: SelectableText(text!.split('\n').take(12).join('\n')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(isRu ? 'Отмена' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(isRu ? 'Вставить' : 'Paste'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    await send('paste', {'text': text});
    selection.clearSelection();
    focus.requestFocus();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final kb = HardwareKeyboard.instance;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (const SingleActivator(
            LogicalKeyboardKey.keyW,
            control: true,
            shift: true,
          ).accepts(event, kb) ||
          PlatformCapabilities.isMacOS &&
              const SingleActivator(
                LogicalKeyboardKey.keyW,
                meta: true,
              ).accepts(event, kb)) {
        unawaited(_return());
        return KeyEventResult.handled;
      }
      if (const SingleActivator(
            LogicalKeyboardKey.keyR,
            control: true,
            shift: true,
          ).accepts(event, kb) ||
          PlatformCapabilities.isMacOS &&
              const SingleActivator(
                LogicalKeyboardKey.keyR,
                meta: true,
              ).accepts(event, kb)) {
        _input('reconnect', {});
        return KeyEventResult.handled;
      }
      if (const SingleActivator(
            LogicalKeyboardKey.keyE,
            control: true,
            shift: true,
          ).accepts(event, kb) ||
          PlatformCapabilities.isMacOS &&
              const SingleActivator(
                LogicalKeyboardKey.keyE,
                meta: true,
              ).accepts(event, kb)) {
        _input('files', {});
        return KeyEventResult.handled;
      }
      if (terminalShortcuts(
        settings,
        pasteIntent: const _WindowPasteIntent(),
      ).keys.any((a) => a.accepts(event, kb))) {
        return KeyEventResult
            .ignored; // TerminalView runs the same actions as the owner.
      }
    }

    final key = keyToTerminalKey(event.logicalKey);
    if (key == null) return KeyEventResult.ignored;
    _input('key', {
      'key': key.name,
      'text': event.character,
      'ctrl': kb.isControlPressed,
      'alt': kb.isAltPressed,
      'shift': kb.isShiftPressed,
      'meta': kb.isMetaPressed,
      'event': event is KeyUpEvent
          ? 'release'
          : event is KeyRepeatEvent
          ? 'repeat'
          : 'press',
    });
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    timer?.cancel();
    windowManager.removeListener(this);
    terminal.dispose();
    selection.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seed = colors?.seed ?? Color(settings.seedColor);
    var mode = settings.themeMode;
    if (colors?.brightness != null &&
        (mode == ThemeMode.system ||
            settings.colorSource == ColorSource.catppuccin)) {
      mode = colors!.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light;
    }
    return MaterialApp(
      navigatorKey: navigator,
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: buildTheme(
        seed: seed,
        brightness: Brightness.light,
        compact: settings.compact,
        roles: colors?.roles[Brightness.light],
      ),
      darkTheme: buildTheme(
        seed: seed,
        brightness: Brightness.dark,
        compact: settings.compact,
        roles: colors?.roles[Brightness.dark],
      ),
      locale: Locale(isRu ? 'ru' : 'en'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              if (error != null)
                MaterialBanner(
                  content: Text(error!),
                  actions: [
                    TextButton(
                      onPressed: _return,
                      child: Text(isRu ? 'Вернуться' : 'Return'),
                    ),
                  ],
                ),
              Expanded(
                child: Listener(
                  onPointerDown: (e) {
                    if (e.buttons == kMiddleMouseButton &&
                        settings.middleClickPaste) {
                      unawaited(_paste());
                    }
                  },
                  child: Actions(
                    actions: {
                      _WindowPasteIntent: CallbackAction<_WindowPasteIntent>(
                        onInvoke: (_) {
                          _paste();
                          return null;
                        },
                      ),
                    },
                    child: TerminalView(
                      terminal,
                      controller: selection,
                      focusNode: focus,
                      autofocus: true,
                      shortcuts: terminalShortcuts(
                        settings,
                        pasteIntent: const _WindowPasteIntent(),
                      ),
                      onKeyEvent: _key,
                      onSecondaryTapUp: (d, _) async {
                        if (settings.rightClick == RightClickAction.paste) {
                          await _paste();
                          return;
                        }
                        if (settings.rightClick == RightClickAction.smart) {
                          selection.selection == null
                              ? await _paste()
                              : _copy();
                          return;
                        }
                        final action = await showMenu<String>(
                          context: context,
                          position: RelativeRect.fromLTRB(
                            d.globalPosition.dx,
                            d.globalPosition.dy,
                            0,
                            0,
                          ),
                          items: [
                            PopupMenuItem(
                              value: 'copy',
                              child: Text(isRu ? 'Копировать' : 'Copy'),
                            ),
                            PopupMenuItem(
                              value: 'paste',
                              child: Text(isRu ? 'Вставить' : 'Paste'),
                            ),
                          ],
                        );
                        if (action == 'copy') _copy();
                        if (action == 'paste') await _paste();
                      },
                      theme: terminalThemeFor(
                        Theme.of(context).colorScheme,
                        colors,
                      ),
                      textStyle: TerminalStyle(
                        fontFamily: TerminalFont.familyOf(
                          settings.terminalFont,
                        ),
                        fontFamilyFallback: TerminalFont.fallbackOf(
                          settings.terminalFont,
                        ),
                        fontSize: settings.terminalFontSize,
                        height: settings.terminalLineHeight,
                      ),
                      padding: const EdgeInsets.all(10),
                    ),
                  ),
                ),
              ),
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(
                        status == 'ready'
                            ? Icons.check_circle_outline
                            : Icons.info_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(switch (status) {
                          'ready' => isRu ? 'Подключено' : 'Connected',
                          'connecting' => isRu ? 'Подключение…' : 'Connecting…',
                          'lost' =>
                            isRu ? 'Соединение потеряно' : 'Connection lost',
                          _ => isRu ? 'Сессия завершена' : 'Session ended',
                        }, style: Theme.of(context).textTheme.labelMedium),
                      ),
                      IconButton(
                        tooltip: isRu
                            ? 'Файлы в главном окне'
                            : 'Files in main window',
                        onPressed: () => _input('files', {}),
                        icon: const Icon(Icons.folder_outlined),
                      ),
                      PopupMenuButton<String>(
                        tooltip: isRu ? 'Действия сессии' : 'Session actions',
                        onSelected: (v) {
                          switch (v) {
                            case 'copy':
                              _copy();
                            case 'paste':
                              _paste();
                            case 'reconnect':
                              _input('reconnect', {});
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'copy',
                            child: Text(isRu ? 'Копировать' : 'Copy'),
                          ),
                          PopupMenuItem(
                            value: 'paste',
                            child: Text(isRu ? 'Вставить' : 'Paste'),
                          ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'reconnect',
                            child: Text(isRu ? 'Переподключить' : 'Reconnect'),
                          ),
                        ],
                      ),
                      TextButton.icon(
                        onPressed: _return,
                        icon: const Icon(Icons.tab),
                        label: Text(isRu ? 'Во вкладки' : 'Return to tabs'),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowPasteIntent extends Intent {
  const _WindowPasteIntent();
}
