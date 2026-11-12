import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import '../../domain/models/host.dart';
import '../../domain/models/session_tab.dart';
import '../../domain/models/external_colors.dart';
import '../../domain/ports/document_store.dart';
import '../../domain/ports/secret_store.dart';
import '../../domain/ports/sftp.dart';
import '../dependencies.dart';
import '../settings/app_settings.dart';
import '../controllers/hosts_controller.dart';
import '../controllers/settings_controller.dart';
import '../controllers/external_colors_controller.dart';
import 'detached_windows.dart';
import '../controllers/tabs_controller.dart';
import 'window_appearance.dart';
import 'window_protocol.dart';
import 'window_remote_session.dart';
import 'window_scope.dart';
import 'tab_transfer.dart';
import 'package:window_manager/window_manager.dart';

/// A per-engine view of the owner. No SSH connections, secrets or profile files
/// are opened here. The normal AppShell/SessionView/SettingsPage use these ports.
class WindowClient implements WindowScope {
  WindowClient({
    required this.request,
    required Map initial,
    required this.closeWindow,
    List<Override> overrides = const [],
  }) {
    documents = Map<String, Object?>.from(initial['documents']);
    settings = Map<String, Object?>.from(initial['settings']);
    colors = initial['colors'];
    initialTabs = (initial['tabs'] as List).cast<Map>();
    container = ProviderContainer(
      overrides: [
        windowScopeProvider.overrideWithValue(this),
        documentStoreProvider.overrideWith(
          (ref, name) => _WindowDocument(this, name),
        ),
        secretStoreProvider.overrideWithValue(_WindowSecrets(this)),
        settingsProvider.overrideWith(() => _WindowSettings(this)),
        externalColorsProvider.overrideWith(() => _WindowColors(this)),
        tabsProvider.overrideWith(() => _WindowTabs(this)),
        detachedWindowsProvider.overrideWith(() => _WindowDetached(this)),
        ...overrides,
      ],
    );
    container.read(tabsProvider);
  }
  final WindowRpc request;
  final Future<void> Function() closeWindow;
  late final ProviderContainer container;
  late Map<String, Object?> documents, settings;
  late List<Map> initialTabs;
  Map? colors;
  final _pendingDocuments = <String, int>{};
  final _documentKeys = <String, String>{};
  String? _settingsKey, _colorsKey;
  Timer? _timer;
  bool _busy = false, _closed = false, _needsFull = true;
  @override
  final ValueNotifier<String?> failure = ValueNotifier<String?>(null);

  Future<dynamic> call(String method, Map<String, Object?> data) async {
    if (_closed) throw const SftpFailure(SftpFailureCode.connectionClosed);
    try {
      final result = await request(method, data);
      if (result is Map && result['windowError'] != null) {
        switch (result['windowError']) {
          case 'sftp':
            throw SftpFailure(
              SftpFailureCode.values.byName(result['code']),
              Map<String, String>.from(result['args']),
            );
          case 'cancelled':
            throw const TransferCancelled();
          case 'secret':
            throw SecretStoreUnavailable(result['detail']);
        }
      }
      return result;
    } on SftpFailure {
      rethrow;
    } on TransferCancelled {
      rethrow;
    } on SecretStoreUnavailable {
      rethrow;
    } catch (e) {
      if (!_closed) failure.value = '$e';
      rethrow;
    }
  }

  Future<dynamic> sessionCall(
    String id,
    String method,
    Map<String, Object?> data,
  ) => call(method, {'sessionId': id, ...data});

  void start() {
    _timer = Timer.periodic(const Duration(milliseconds: 40), (_) => poll());
    unawaited(poll());
  }

  void stop() => _timer?.cancel();
  Future<void> poll() async {
    if (_closed || _busy) return;
    _busy = true;
    try {
      final force = _needsFull;
      _needsFull = false;
      final result = await call('frame', {'force': force});
      if (_closed || result == null) return;
      apply(result);
      failure.value = null;
    } catch (e) {
      _needsFull = true;
    } finally {
      _busy = false;
    }
  }

  void apply(Map data) {
    if (_closed) return;
    if (data['documents'] case final Map docs) {
      for (final entry in docs.entries) {
        final name = entry.key as String;
        if ((_pendingDocuments[name] ?? 0) > 0) continue;
        final key = jsonEncode(entry.value);
        if (_documentKeys[name] != key) {
          _documentKeys[name] = key;
          documents[name] = entry.value;
          if (name == 'hosts.json') container.invalidate(hostsProvider);
        }
      }
    }
    if (data['settings'] != null &&
        (_pendingDocuments['settings.json'] ?? 0) == 0) {
      final key = jsonEncode(data['settings']);
      if (_settingsKey != key) {
        _settingsKey = key;
        settings = Map<String, Object?>.from(data['settings']);
        (container.read(settingsProvider.notifier) as _WindowSettings).receive(
          settings,
        );
      }
    }
    if (data.containsKey('colors')) {
      final key = jsonEncode(data['colors']);
      if (_colorsKey != key) {
        _colorsKey = key;
        colors = data['colors'];
        (container.read(externalColorsProvider.notifier) as _WindowColors)
            .receive(colors);
      }
    }
    final tabs = container.read(tabsProvider.notifier) as _WindowTabs;
    if (data['activate'] case final String id) tabs.preferred = id;
    if (data['tabs'] case final List list) tabs.receive(list.cast<Map>());
    if (data['sessions'] case final Map sessions) {
      for (final entry in sessions.entries) {
        final session = tabs.sessionOf(entry.key) as WindowRemoteSession?;
        session?.apply(entry.value);
      }
    }
  }

  Future<void> command(
    String method,
    Map<String, Object?> data, {
    bool activate = false,
  }) async {
    try {
      final result = await call(method, data);
      if (_closed) return;
      if (activate && result is String) {
        (container.read(tabsProvider.notifier) as _WindowTabs).preferred =
            result;
      }
      _needsFull = true;
      await poll();
    } catch (_) {} // The connection banner exposes channel errors.
  }

  @override
  Future<void> returnToMain([String? tabId]) async {
    if (tabId != null) {
      await command('attach', {'sessionId': tabId});
      return;
    }
    await call('returnWindow', {});
    await closeWindow();
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    container.dispose();
    failure.dispose();
  }
}

class _WindowDocument implements DocumentStore {
  _WindowDocument(this.client, this.name);
  final WindowClient client;
  final String name;
  @override
  Object? readSync() => client.documents[name];
  @override
  Future<bool> write(Object? data) async {
    client.documents[name] = data;
    client._pendingDocuments[name] = (client._pendingDocuments[name] ?? 0) + 1;
    try {
      return await client.call('document', {'name': name, 'data': data}) ==
          true;
    } catch (_) {
      return false;
    } finally {
      client._pendingDocuments[name] = client._pendingDocuments[name]! - 1;
      client._needsFull = true;
    }
  }
}

class _WindowSettings extends SettingsController {
  _WindowSettings(this.client);
  final WindowClient client;
  @override
  AppSettings build() => AppSettings.fromJson(client.settings);
  void receive(Map<String, Object?> value) =>
      state = AppSettings.fromJson(value);
}

class _WindowColors extends ExternalColorsController {
  _WindowColors(this.client);
  final WindowClient client;
  @override
  ExternalColors? build() => decodeWindowColors(client.colors);
  void receive(Map? value) => state = decodeWindowColors(value);
}

class _WindowSecrets implements SecretStore {
  _WindowSecrets(this.client);
  final WindowClient client;
  @override
  Future<String?> read(String key) async =>
      await client.call('secret', {'operation': 'read', 'key': key}) as String?;
  @override
  Future<void> write(String key, String value) async {
    await client.call('secret', {
      'operation': 'write',
      'key': key,
      'value': value,
    });
  }

  @override
  Future<void> delete(String key) async {
    await client.call('secret', {'operation': 'delete', 'key': key});
  }
}

class _WindowTabs extends TabsController {
  _WindowTabs(this.client);
  final WindowClient client;
  String? preferred;
  String _key = '';
  void _install(List<Map> raw) {
    final sessions = ref.read(sessionsProvider);
    final alive = raw.map((t) => t['id']).toSet();
    for (final id in sessions.keys.toList()) {
      if (!alive.contains(id)) sessions.remove(id)!.dispose();
    }
    for (final data in raw) {
      final tab = decodeTab(data);
      sessions.putIfAbsent(
        tab.id,
        () => WindowRemoteSession(
          host: tab.host,
          local: tab.isLocal,
          request: (method, args) => client.sessionCall(tab.id, method, args),
          maxLines:
              data['maxLines'] ?? client.settings['scrollbackLines'] ?? 10000,
        ),
      );
      sessions[tab.id]!.host = tab.host;
    }
  }

  @override
  TabsState build() {
    _install(client.initialTabs);
    return TabsState(
      tabs: client.initialTabs.map(decodeTab).toList(),
      active: client.initialTabs.isEmpty ? 0 : 1,
    );
  }

  void receive(List<Map> raw) {
    final key = jsonEncode(raw);
    if (_key == key && preferred == null) return;
    _key = key;
    _install(raw);
    final tabs = raw.map(decodeTab).toList();
    final activeId = preferred ?? state.activeTab?.id;
    final index = tabs.indexWhere((t) => t.id == activeId);
    final wasHome = state.isHome && preferred == null;
    state = TabsState(
      tabs: tabs,
      active: wasHome
          ? 0
          : index >= 0
          ? index + 1
          : tabs.isEmpty
          ? 0
          : 1,
    );
    if (preferred != null && index >= 0) preferred = null;
  }

  @override
  void activate(int index) {
    preferred = null;
    super.activate(index);
  }

  @override
  void openLocal() =>
      unawaited(client.command('openLocal', {}, activate: true));
  @override
  void openHost(Host host, {String? password}) => unawaited(
    client.command('openHost', {
      'host': host.toJson(),
      'password': password,
    }, activate: true),
  );
  @override
  void duplicate(String id) =>
      unawaited(client.command('duplicate', {'sessionId': id}, activate: true));
  @override
  void reconnect(String id) =>
      unawaited(client.command('reconnect', {'sessionId': id}));
  @override
  void close(String id) =>
      unawaited(client.command('close', {'sessionId': id}));
  @override
  void forgetSessionPasswords(String hostId) {
    for (final tab in state.tabs.where((t) => t.host.id == hostId)) {
      unawaited(client.command('forgetPassword', {'sessionId': tab.id}));
    }
  }

  @override
  void move(int from, int to) {
    super.move(from, to);
    unawaited(
      client.command('move', {'ids': state.tabs.map((t) => t.id).toList()}),
    );
  }
}

class _WindowDetached extends DetachedWindows {
  _WindowDetached(this.client);
  final WindowClient client;
  @override
  Map<String, String> build() => {};
  @override
  Future<void> detach(String id) async {
    final bounds = await windowManager.getBounds();
    await client.command('detach', {
      'sessionId': id,
      'width': bounds.width,
      'height': bounds.height,
    });
  }

  @override
  Future<TabTransfer> beginDrag(String id) async =>
      TabTransfer.decode(await client.call('beginDrag', {'sessionId': id}))!;
  @override
  Future<void> finishDrag(TabTransfer transfer, {bool accepted = false}) async {
    try {
      await client.call('finishDrag', {
        'transfer': transfer.toJson(),
        'accepted': accepted,
      });
    } catch (_) {}
  }

  @override
  Future<bool> canAcceptDrag(TabTransfer transfer) async =>
      await client.call('canAcceptDrag', {'transfer': transfer.toJson()}) ==
      true;
  @override
  Future<void> acceptDrag(TabTransfer transfer) async {
    final metadata = await client.call('acceptDrag', {
      'transfer': transfer.toJson(),
    });
    client.apply(metadata as Map);
    client._needsFull = true;
    await client.poll();
  }

  @override
  Future<void> returnToTabs(String id) => client.returnToMain(id);
  @override
  Future<void> attach(String id) => client.returnToMain(id);
}
