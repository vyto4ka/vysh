import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/host.dart';
import '../models/session_tab.dart';
import 'hosts_controller.dart';
import 'settings_controller.dart';
import 'known_hosts.dart';
import 'ports_providers.dart';
import 'terminal_session.dart';
import 'transfer_queue.dart';

/// Живые сессии по id вкладки.
final sessionsProvider = Provider<Map<String, TerminalSession>>((ref) {
  final map = <String, TerminalSession>{};
  ref.onDispose(() {
    for (final s in map.values) {
      s.dispose();
    }
  });
  return map;
});

final tabsProvider = NotifierProvider<TabsController, TabsState>(TabsController.new);

class TabsController extends Notifier<TabsState> {
  Map<String, TerminalSession> get _sessions => ref.read(sessionsProvider);

  @override
  TabsState build() => const TabsState();

  TerminalSession? sessionOf(String tabId) => _sessions[tabId];

  /// [password] - введённый в редакторе пароль: используется для этой сессии,
  /// даже если пользователь не стал сохранять его в хранилище.
  void openHost(Host host, {String? password}) {
    final tab = SessionTab(id: newId(), host: host, title: host.title);
    final session = TerminalSession(
      host: host,
      connector: ref.read(sshConnectorProvider),
      prompts: ref.read(sessionPromptsProvider),
      secrets: ref.read(secretStoreProvider),
      knownHosts: ref.read(knownHostsProvider),
      onStatus: (s) => _setStatus(tab.id, s),
      initialPassword: password,
      scrollbackLines: ref.read(settingsProvider).scrollbackLines,
    );
    _sessions[tab.id] = session;
    state = TabsState(tabs: [...state.tabs, tab], active: state.tabs.length + 1);
    ref.read(hostsProvider.notifier).touch(host.id);
    // Даём вкладке отрисоваться (терминал узнает свой размер), потом подключаемся.
    Future<void>.delayed(const Duration(milliseconds: 50), session.connect);
  }

  /// Открыть сразу несколько хостов: каждый в своей вкладке, активной
  /// становится первая из новых. Подключения разнесены на 150 мс, чтобы
  /// не стучаться во все серверы в одну миллисекунду.
  void openHosts(List<Host> hosts) {
    if (hosts.isEmpty) return;
    final first = state.tabs.length + 1;
    for (var i = 0; i < hosts.length; i++) {
      final host = hosts[i];
      Future<void>.delayed(Duration(milliseconds: 150 * i), () {
        if (!ref.mounted) return;
        openHost(host);
        if (i == hosts.length - 1) {
          state = TabsState(tabs: state.tabs, active: first.clamp(1, state.tabs.length));
        }
      });
    }
  }

  void reconnect(String id) {
    final session = _sessions[id];
    if (session == null) return;
    // Хост могли изменить в редакторе - берём свежую версию.
    final fresh = ref.read(hostsProvider).where((h) => h.id == session.host.id).firstOrNull;
    if (fresh != null) session.host = fresh;
    session.connect();
  }

  void _setStatus(String id, SessionStatus status) {
    if (!state.tabs.any((t) => t.id == id)) return;
    state = TabsState(
      tabs: [for (final t in state.tabs) t.id == id ? t.copyWith(status: status) : t],
      active: state.active,
    );
  }

  void duplicate(String id) {
    final tab = state.tabs.where((t) => t.id == id).firstOrNull;
    if (tab != null) openHost(tab.host);
  }

  void close(String id) {
    final index = state.tabs.indexWhere((t) => t.id == id);
    if (index < 0) return;
    ref.read(transferQueueProvider.notifier).cancelAllForTab(id);
    _sessions.remove(id)?.dispose();
    final tabs = [...state.tabs]..removeAt(index);
    var active = state.active;
    final closedPos = index + 1;
    if (active == closedPos) {
      active = closedPos > tabs.length ? tabs.length : closedPos;
    } else if (active > closedPos) {
      active -= 1;
    }
    state = TabsState(tabs: tabs, active: active);
  }

  void closeActive() {
    final tab = state.activeTab;
    if (tab != null) close(tab.id);
  }

  void activate(int index) {
    if (index < 0 || index > state.tabs.length) return;
    state = TabsState(tabs: state.tabs, active: index);
  }

  void next() => activate((state.active + 1) % (state.tabs.length + 1));

  void previous() {
    final count = state.tabs.length + 1;
    activate((state.active - 1 + count) % count);
  }

  void move(int from, int to) {
    if (from == to) return;
    final tabs = [...state.tabs];
    final activeId = state.activeTab?.id;
    final tab = tabs.removeAt(from);
    tabs.insert(to, tab);
    final active = activeId == null ? 0 : tabs.indexWhere((t) => t.id == activeId) + 1;
    state = TabsState(tabs: tabs, active: active);
  }
}
