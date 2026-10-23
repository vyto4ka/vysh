import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:xterm2/core.dart';

import '../../domain/models/host.dart';
import '../../domain/models/session_tab.dart';
import '../../domain/ports/local_shell.dart';
import '../../domain/ports/secret_store.dart';
import '../../domain/ports/session_prompts.dart';
import '../../domain/ports/sftp.dart';
import '../../domain/ports/ssh_transport.dart';
import '../../domain/ports/terminal_shell.dart';
import '../../infra/platform/desktop_env.dart';
import '../../domain/services/known_hosts.dart';
import 'session_auth.dart';
import 'terminal_input.dart';
import '../../l10n/app_strings.dart';
import '../settings/app_settings.dart';

/// Строка журнала подключения. Текст строится при показе - на том языке,
/// который выбран в интерфейсе сейчас.
class ConnLogEntry {
  ConnLogEntry(this._render, {this.debug = false, this.error = false})
    : time = DateTime.now();
  final DateTime time;
  final String Function(AppStrings s) _render;
  final bool debug;
  final bool error;

  String text(AppStrings s) => _render(s);
}

/// Живая сессия одной вкладки: эмулятор терминала + SSH-соединение.
///
/// Жизненный цикл: connecting → ready → (lost | closed).
/// В состояниях lost/closed Enter в терминале переподключает.
class TerminalSession extends ChangeNotifier {
  TerminalSession({
    required Host host,
    required this.connector,
    required this.prompts,
    required this.secrets,
    required this.knownHosts,
    required this.onStatus,
    this.localShells,
    this.local = false,
    AppStrings Function()? strings,
    this.defaultKeepAliveSeconds = 60,
    String? initialPassword,
    int scrollbackLines = 10000,
  })  : _host = host,
        _strings = strings ?? (() => AppStrings.forLanguage(AppLanguage.auto)),
        _memPassword = initialPassword,
        terminal = Terminal(maxLines: scrollbackLines);

  /// Строки на текущем языке интерфейса (для сообщений в терминале).
  final AppStrings Function() _strings;

  /// Пароль, введённый в этой сессии (в редакторе хоста или в диалоге).
  /// Живёт только в памяти - чтобы переподключение не спрашивало его заново.
  /// Действует только для той цели, для которой его ввели (см. [host]).
  String? _memPassword;

  /// Интервал KeepAlive по умолчанию из настроек (в секундах).
  final int defaultKeepAliveSeconds;

  /// Хост; обновляется перед переподключением, если его отредактировали.
  Host get host => _host;
  Host _host;
  set host(Host next) {
    if (targetOf(next) != targetOf(_host) || next.auth != _host.auth) {
      // Сменился сервер, порт, логин или способ входа: пароль прежней цели
      // не годится, а открытые «локально» файлы больше не должны заливаться
      // по новому адресу.
      _memPassword = null;
      _closeLocalEdits();
    }
    _host = next;
  }

  /// Куда именно подключаемся: `user@address:port`.
  static String targetOf(Host h) =>
      '${h.username.trim()}@${h.address.trim().toLowerCase()}:${h.port}';

  /// Цель текущего подключения (для привязки локального редактирования).
  String get target => targetOf(_host);

  /// Забыть пароль, введённый в этой сессии («Забыть пароль», смена пароля).
  void forgetPassword() => _memPassword = null;

  final SshConnector connector;
  final SessionPrompts prompts;
  final SecretStore secrets;
  final KnownHosts knownHosts;
  final LocalShellLauncher? localShells;
  final bool local;
  final void Function(SessionStatus status) onStatus;

  bool get isLocal => local;

  /// Переподключение по Enter - тем же путём, что и кнопка (со свежим хостом).
  VoidCallback? onReconnect;

  /// Эмулятор терминала; размер истории задаётся в настройках.
  final Terminal terminal;

  SessionStatus _status = SessionStatus.connecting;
  SessionStatus get status => _status;

  String? _serverVersion;
  String? get serverVersion => _serverVersion;

  /// Журнал последней попытки подключения.
  final connLog = <ConnLogEntry>[];

  /// Ошибка последней попытки (null - подключились или ещё подключаемся).
  SshFailure? lastFailure;

  /// Соединение оборвалось уже после успешного входа.
  bool droppedAfterReady = false;

  /// Модификаторы для виртуальной клавиатуры (как в keyboard).
  bool ctrlModifier = false;
  bool altModifier = false;
  VoidCallback? onModifiersChanged;

  /// Текст текущего ввода пользователя без prompt и вывода shell.
  final _typed = TypedCommand();
  String get clientTypedCommand => _typed.text;

  void toggleCtrl() {
    ctrlModifier = !ctrlModifier;
    onModifiersChanged?.call();
  }

  void toggleAlt() {
    altModifier = !altModifier;
    onModifiersChanged?.call();
  }

  void resetModifiers() {
    if (ctrlModifier || altModifier) {
      ctrlModifier = false;
      altModifier = false;
      onModifiersChanged?.call();
    }
  }

  /// Отправляет комбинацию Ctrl (например, \x03 для Ctrl+C) сразу в терминал/shell.
  void sendCtrlChar(String char) {
    ctrlModifier = false;
    onModifiersChanged?.call();

    final byte = TerminalInput.ctrlByte(char);
    if (byte != null) {
      _updateClientTypedCommand(String.fromCharCode(byte));
      _shell?.write(Uint8List.fromList([byte]));
    }
  }

  /// Буква Ctrl-комбинации для клавиши (см. [TerminalInput.ctrlLetter]).
  static String? mapToCtrlChar(String input) => TerminalInput.ctrlLetter(input);

  void _updateClientTypedCommand(String text) => _typed.feed(text);

  void _log(String Function(AppStrings s) text, {bool debug = false, bool error = false}) {
    connLog.add(ConnLogEntry(text, debug: debug, error: error));
    if (connLog.length > 2000) connLog.removeRange(0, connLog.length - 2000);
  }

  SshTransport? _transport;
  TerminalShell? _shell;
  Future<SftpSession>? _sftp;

  /// Файлы, открытые «локально» (автозагрузка при сохранении).
  final _localEdits = <LocalEditHandle>[];
  StreamSubscription<String>? _outputSub;
  bool _connecting = false;
  bool _disposed = false;

  /// Поколение подключения. Всё, что относится к прежней попытке
  /// (поздний shell, завершение старого транспорта), сверяется с ним
  /// и не трогает новое соединение.
  int _gen = 0;

  /// Отмена текущей попытки подключения (закрытие вкладки).
  Completer<void>? _cancelAttempt;

  bool get isDisposed => _disposed;

  /// Зарегистрировать локальное редактирование: оно закроется вместе
  /// с сессией или при смене цели подключения.
  void addLocalEdit(LocalEditHandle edit) {
    if (_disposed) {
      edit.close();
      return;
    }
    _localEdits.add(edit);
  }

  void removeLocalEdit(LocalEditHandle edit) => _localEdits.remove(edit);

  void _closeLocalEdits() {
    final edits = [..._localEdits];
    _localEdits.clear();
    for (final e in edits) {
      e.close();
    }
  }

  // ─── Публичное API ────────────────────────────────────────────────

  Future<void> connect() async {
    if (_connecting || _disposed) return;
    _connecting = true;
    final gen = ++_gen;
    final cancel = _cancelAttempt = Completer<void>();
    _teardown();
    connLog.clear();
    lastFailure = null;
    droppedAfterReady = false;
    _setStatus(SessionStatus.connecting);
    terminal.onOutput = null;

    bool stale() => _disposed || gen != _gen;

    if (local) {
      _info(_strings().localShellStarting);
    } else {
      final address = host.displayAddress, auth = host.auth.name;
      _log((s) => s.logConnecting(address, auth));
      _info(_strings().terminalConnecting(address));
    }

    try {
      if (local) {
        await _connectLocal(stale, gen);
      } else {
        await _connectRemote(cancel, stale, gen);
      }
    } on LocalShellFailure catch (e) {
      if (stale()) return;
      _error((s) => s.localShellFailure(e));
      _setStatus(SessionStatus.lost);
      _offerReconnect();
    } on SshFailure catch (e) {
      if (stale()) return;
      if (e.kind == SshFailureKind.cancelled) {
        _info(_strings().terminalCancelled);
      } else {
        _error((s) => s.sshFailure(e));
      }
      lastFailure = e;
      _setStatus(SessionStatus.lost);
      _offerReconnect();
    } catch (e) {
      if (stale()) return;
      final failure = SshFailure(SshError.unexpected, {'detail': '$e'});
      _error((s) => s.sshFailure(failure));
      lastFailure = failure;
      _setStatus(SessionStatus.lost);
      _offerReconnect();
    } finally {
      if (identical(_cancelAttempt, cancel)) _cancelAttempt = null;
      if (gen == _gen) _connecting = false;
    }
  }

  Future<void> _connectLocal(bool Function() stale, int gen) async {
    final launcher = localShells;
    if (launcher == null || !launcher.supported) {
      throw const LocalShellFailure(LocalShellError.unsupported);
    }
    final shell = await launcher.start(
      columns: max(terminal.viewWidth, 20),
      rows: max(terminal.viewHeight, 5),
    );
    if (stale()) {
      shell.close();
      return;
    }
    _shell = shell;
    _attachShell(shell);

    _setStatus(SessionStatus.ready);
    shell.done.then((_) => _onEnded(gen, clean: true));
  }

  Future<void> _connectRemote(
    Completer<void> cancel,
    bool Function() stale,
    int gen,
  ) async {
    final transport = await _authenticate(cancel.future);
    if (stale()) {
      await transport.close();
      return;
    }
    _transport = transport;
    _serverVersion = transport.serverVersion;

    final SshShell shell;
    try {
      shell = await transport.openShell(
        columns: max(terminal.viewWidth, 20),
        rows: max(terminal.viewHeight, 5),
      );
    } catch (_) {
      if (identical(_transport, transport)) _transport = null;
      await transport.close();
      rethrow;
    }
    if (stale()) {
      shell.close();
      if (identical(_transport, transport)) _transport = null;
      await transport.close();
      return;
    }
    _shell = shell;
    _attachShell(shell);

    _setStatus(SessionStatus.ready);

    shell.done.then((_) => _onEnded(gen, clean: true));
    transport.done.then((_) => _onEnded(gen, clean: false));
  }

  void _attachShell(TerminalShell shell) {
    terminal.onOutput = (data) {
      if (ctrlModifier && data.isNotEmpty) {
        if (data == '\x1b') {
          resetModifiers();
          return;
        }
        final mapped = mapToCtrlChar(data);
        if (mapped != null) {
          sendCtrlChar(mapped);
          return;
        }
      }

      _updateClientTypedCommand(data);
      var output = data;
      if (altModifier && output.isNotEmpty) {
        output = '\x1b$output';
        altModifier = false;
        onModifiersChanged?.call();
      }
      shell.write(utf8.encode(output));
    };
    terminal.onResize = (w, h, _, _) {
      if (w >= 10 && h >= 2) shell.resize(w, h);
    };
    _outputSub = shell.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _gen++;
    // Прерываем незавершённую попытку: сокет закроется сразу,
    // а не после таймаута.
    final cancel = _cancelAttempt;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    _closeLocalEdits();
    _teardown();
    super.dispose();
  }

  /// Выполнить команду на сервере отдельным каналом (для статистики).
  Future<String> exec(String command, {Duration timeout = const Duration(seconds: 10)}) {
    final transport = _transport;
    if (transport == null || _status != SessionStatus.ready) {
      return Future.error(StateError('no connection'));
    }
    return transport.exec(command, timeout: timeout);
  }

  /// Сбросить SFTP-канал (после ошибки), следующий [sftp] откроет новый.
  void resetSftp() {
    final old = _sftp;
    _sftp = null;
    old?.then((s) => s.close()).catchError((_) {});
  }

  /// SFTP поверх текущего соединения (открывается один раз и переиспользуется).
  Future<SftpSession> sftp() {
    final transport = _transport;
    if (transport == null || _status != SessionStatus.ready) {
      return Future.error(const SftpFailure(SftpFailureCode.noConnection));
    }
    final existing = _sftp;
    if (existing != null) return existing;

    final gen = _gen;
    final opening = transport.openSftp();
    late final Future<SftpSession> result;
    result = opening
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            // Канал может всё-таки открыться позже - тогда сразу закрываем.
            opening.then((s) => s.close()).catchError((_) {});
            throw const SftpFailure(SftpFailureCode.noSftpServer);
          },
        )
        .then((s) {
          // Пока канал открывался, соединение сменилось или вкладку закрыли.
          if (_disposed || gen != _gen || !identical(_transport, transport)) {
            s.close();
            throw const SftpFailure(SftpFailureCode.connectionClosed);
          }
          return s;
        })
        .catchError((Object e) {
          if (identical(_sftp, result)) _sftp = null;
          throw e;
        });
    return _sftp = result;
  }

  // ─── Подключение ──────────────────────────────────────────────────

  Future<SshTransport> _authenticate(Future<void> abort) async {
    final keepSec = host.keepAliveSeconds ?? defaultKeepAliveSeconds;
    final auth = SessionAuthenticator(
      host: host,
      connector: connector,
      prompts: prompts,
      secrets: secrets,
      knownHosts: knownHosts,
      keepAlive: keepSec <= 0 ? Duration.zero : Duration(seconds: keepSec),
      memPassword: _memPassword,
      log: _log,
      info: (text) => _info(text(_strings())),
      error: _error,
      banner: (b) => terminal.write('${b.replaceAll('\n', '\r\n')}\r\n'),
    );
    try {
      return await auth.connect(abort);
    } finally {
      _memPassword = auth.memPassword;
    }
  }

  // ─── Завершение ───────────────────────────────────────────────────

  void _onEnded(int gen, {required bool clean}) {
    if (_disposed || gen != _gen || _status != SessionStatus.ready) return;
    _teardown();
    if (clean) {
      _info(_strings().terminalSessionEnded);
      _setStatus(SessionStatus.closed);
    } else {
      _error((s) => s.logConnectionLost);
      droppedAfterReady = true;
      lastFailure = const SshFailure(SshError.connectionLost);
      _setStatus(SessionStatus.lost);
    }
    _offerReconnect();
  }

  void _offerReconnect() {
    final s = _strings();
    _info(DesktopEnv.isDesktop ? s.terminalPressEnter : s.terminalPressReconnect);
    terminal.onOutput = (data) {
      if (!data.contains('\r') && !data.contains('\n')) return;
      final reconnect = onReconnect;
      reconnect != null ? reconnect() : connect();
    };
  }

  void _teardown() {
    final sftp = _sftp;
    _sftp = null;
    sftp?.then((s) => s.close()).catchError((_) {});
    _outputSub?.cancel();
    _outputSub = null;
    _shell?.close();
    _shell = null;
    _transport?.close();
    _transport = null;
    terminal.onResize = null;
  }

  void _setStatus(SessionStatus s) {
    _status = s;
    if (_disposed) return;
    onStatus(s);
    notifyListeners();
  }

  // Служебные сообщения: тусклый текст с новой строки.
  void _info(String text) => terminal.write('\r\n\x1b[2m$text\x1b[0m\r\n');
  void _error(String Function(AppStrings s) text) {
    _log(text, error: true);
    terminal.write('\r\n\x1b[31m✗ ${text(_strings())}\x1b[0m\r\n');
  }
}

/// Локальное редактирование файла, привязанное к сессии.
abstract interface class LocalEditHandle {
  /// Остановить наблюдение и автозагрузку.
  void close();
}
