import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/host.dart';
import '../../domain/models/session_tab.dart';
import 'hosts_controller.dart';
import 'settings_controller.dart';
import '../../l10n/app_strings.dart';
import '../dependencies.dart';
import '../terminal/terminal_session.dart';
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
    _open(host, password: password);
    ref.read(hostsProvider.notifier).touch(host.id);
  }

  void openLocal() {
    final strings = AppStrings.forLanguage(ref.read(settingsProvider).language);
    final host = Host(
      id: newId(),
      label: strings.localTerminal,
      address: 'localhost',
      username: 'local',
    );
    _open(host, local: true, title: strings.localTerminal);
  }

  void _open(Host host, {String? password, bool local = false, String? title}) {
    final tab = SessionTab(
      id: newId(),
      host: host,
      title: title ?? host.title,
      isLocal: local,
    );
    final session = TerminalSession(
      host: host,
      connector: ref.read(sshConnectorProvider),
      prompts: ref.read(sessionPromptsProvider),
      secrets: ref.read(secretStoreProvider),
      knownHosts: ref.read(knownHostsProvider),
      localShells: local ? ref.read(localShellLauncherProvider) : null,
      local: local,
      onStatus: (s) => _setStatus(tab.id, s),
      strings: () => AppStrings.forLanguage(ref.read(settingsProvider).language),
      defaultKeepAliveSeconds: ref.read(settingsProvider).keepAliveSeconds,
      initialPassword: password,
      scrollbackLines: ref.read(settingsProvider).scrollbackLines,
    );
    session.onReconnect = () => reconnect(tab.id);
    _sessions[tab.id] = session;
    state = TabsState(tabs: [...state.tabs, tab], active: state.tabs.length + 1);
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
    if (!session.isLocal) {
      // Хост могли изменить в редакторе - берём свежую версию.
      final fresh = ref.read(hostsProvider).where((h) => h.id == session.host.id).firstOrNull;
      if (fresh != null) session.host = fresh;
    }
    session.connect();
  }

  /// Открытые вкладки хоста забывают пароль, введённый в сессии.
  void forgetSessionPasswords(String hostId) {
    for (final s in _sessions.values) {
      if (s.host.id == hostId) s.forgetPassword();
    }
  }

  void _setStatus(String id, SessionStatus status) {
    if (!state.tabs.any((t) => t.id == id)) return;
    final nextTabs = [for (final t in state.tabs) t.id == id ? t.copyWith(status: status) : t];
    state = TabsState(
      tabs: nextTabs,
      active: state.active,
    );
    final activeTab = nextTabs.firstWhere(
      (t) => t.status == SessionStatus.ready || t.status == SessionStatus.connecting,
      orElse: () => nextTabs.first,
    );
    final hasActive = nextTabs.any(
      (t) => t.status == SessionStatus.ready || t.status == SessionStatus.connecting,
    );
    if (hasActive) {
      final title = activeTab.isLocal
          ? AppStrings.forLanguage(ref.read(settingsProvider).language).localTerminal
          : activeTab.host.displayAddress;
      ref.read(backgroundSessionsProvider).active(title);
    } else {
      ref.read(backgroundSessionsProvider).idle();
    }
  }

  void duplicate(String id) {
    final tab = state.tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null) return;
    if (tab.isLocal) {
      openLocal();
    } else {
      openHost(tab.host);
    }
  }

  void close(String id) {
    final index = state.tabs.indexWhere((t) => t.id == id);
    if (index < 0) return;
    ref.read(transferQueueProvider.notifier).closeTab(id);
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
    final hasActive = tabs.any(
      (t) => t.status == SessionStatus.ready || t.status == SessionStatus.connecting,
    );
    if (!hasActive) {
      ref.read(backgroundSessionsProvider).idle();
    }
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
