import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_strings.dart';
import '../widgets/strings_context.dart';
import '../../domain/models/host.dart';
import '../../app/controllers/hosts_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/dependencies.dart';
import '../../infra/platform/desktop_env.dart';
import '../shell/ui_state.dart';
import '../widgets/context_menu.dart';
import 'host_card.dart';
import 'host_editor.dart';
part 'hosts_page_widgets.dart';

class HostsPage extends ConsumerStatefulWidget {
  const HostsPage({super.key});

  @override
  ConsumerState<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends ConsumerState<HostsPage> {
  final _search = TextEditingController();
  String _query = '';
  Timer? _pingTimer;
  DateTime _lastPing = DateTime.now();

  /// Хосты видны: открыта главная и окно не свёрнуто
  /// (или в настройках разрешено проверять и в фоне).
  bool get _visible {
    if (!ref.read(settingsProvider).pingOnlyVisible) return true;
    final life = WidgetsBinding.instance.lifecycleState;
    final shown = life == null ||
        life == AppLifecycleState.resumed ||
        life == AppLifecycleState.inactive;
    return shown && ref.read(tabsProvider).isHome;
  }

  void _ping() {
    if (!mounted || !ref.read(settingsProvider).pingHosts) return;
    _lastPing = DateTime.now();
    ref.invalidate(reachabilityProvider);
  }

  /// Вернулись на главную после перерыва - обновим сразу, не дожидаясь таймера.
  void _pingIfStale() {
    final every = Duration(seconds: ref.read(settingsProvider).pingIntervalSec);
    if (DateTime.now().difference(_lastPing) >= every) _ping();
  }

  AppLifecycleListener? _life;

  /// Отмеченные для массовых действий хосты (id).
  final _selected = <String>{};

  /// Фокус для Esc / Delete во время выбора.
  final _keysFocus = FocusNode(debugLabel: 'hosts-selection');

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
    if (_selected.isNotEmpty) _keysFocus.requestFocus();
  }

  void _clearSelection() => setState(_selected.clear);

  /// Подключиться к нескольким хостам; больше шести - переспрашиваем.
  Future<void> _connectMany(List<Host> hosts) async {
    if (hosts.isEmpty) return;
    if (hosts.length > 6) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.tab_outlined),
          title: Text(context.strings.openTabsTitle(hosts.length)),
          content: Text(context.strings.openTabsDesc),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.strings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.strings.connect),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    ref.read(tabsProvider.notifier).openHosts(hosts);
    _clearSelection();
  }

  Future<void> _deleteMany(List<Host> hosts) async {
    if (hosts.isEmpty) return;
    final scheme = Theme.of(context).colorScheme;
    final names = hosts.map((h) => h.title).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: Text(context.strings.deleteHostsTitle(hosts.length)),
        content: Text(context.strings.deleteHostsDesc(names)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    ref.read(hostsProvider.notifier).removeMany(hosts.map((h) => h.id));
    _clearSelection();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.strings.hostsDeleted(hosts.length)),
        ),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_visible) _pingIfStale();
    });
    _life = AppLifecycleListener(onShow: () {
      if (_visible) _pingIfStale();
    });
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _life?.dispose();
    _search.dispose();
    _keysFocus.dispose();
    super.dispose();
  }

  bool _matches(Host h) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return h.title.toLowerCase().contains(q) ||
        h.address.toLowerCase().contains(q) ||
        h.username.toLowerCase().contains(q) ||
        h.group.toLowerCase().contains(q);
  }

  void _connectQuick(Host host) {
    ref.read(tabsProvider.notifier).openHost(host);
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final hosts = ref.watch(hostsProvider);
    final lang = ref.watch(settingsProvider.select((s) => s.language));
    final strings = AppStrings.of(context, lang);

    ref.listen(tabsProvider.select((t) => t.isHome), (_, home) {
      if (home) _pingIfStale();
    });

    final filtered = hosts.where(_matches).toList();
    final quick = filtered.isEmpty ? Host.tryParseQuick(_query) : null;

    // Группировка: сначала именованные группы по алфавиту, затем «без группы».
    final groups = <String, List<Host>>{};
    for (final h in filtered) {
      groups.putIfAbsent(h.group.trim(), () => []).add(h);
    }
    final groupNames = groups.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return 1;
        if (b.isEmpty) return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    for (final list in groups.values) {
      list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    // Хосты могли удалить или изменить - берём только живые.
    final selectedHosts = hosts.where((h) => _selected.contains(h.id)).toList();
    final selecting = selectedHosts.isNotEmpty;

    final isCompact = MediaQuery.sizeOf(context).width < 600 || DesktopEnv.isMobile;
    final localSupported = ref.watch(localShellLauncherProvider).supported;

    return CallbackShortcuts(
      bindings: {
        if (selecting)
          const SingleActivator(LogicalKeyboardKey.escape): _clearSelection,
        if (selecting)
          const SingleActivator(LogicalKeyboardKey.delete): () => _deleteMany(selectedHosts),
      },
      child: Focus(
        focusNode: _keysFocus,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            isCompact ? 16 : 28,
            isCompact ? 12 : 20,
            isCompact ? 16 : 28,
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: selecting
                    ? _SelectionBar(
                        key: const ValueKey('sel'),
                        count: selectedHosts.length,
                        allSelected: filtered.every((h) => _selected.contains(h.id)),
                        onSelectAll: () => setState(() => _selected.addAll(filtered.map((h) => h.id))),
                        onClear: _clearSelection,
                        onConnect: () => _connectMany(selectedHosts),
                        onDelete: () => _deleteMany(selectedHosts),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('search'),
                        child: Row(
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: isCompact ? double.infinity : 360,
                                  ),
                                  child: SearchBar(
                                    controller: _search,
                                    focusNode: ref.watch(hostSearchFocusProvider),
                                    hintText: isCompact
                                        ? strings.searchHostsHintMobile
                                        : strings.searchHostsHintDesktop,
                                    elevation: const WidgetStatePropertyAll(0),
                                    constraints: const BoxConstraints(minHeight: 44),
                                    leading: const Icon(Icons.search),
                                    trailing: [
                                      if (_query.isNotEmpty)
                                        IconButton(
                                          icon: const Icon(Icons.close),
                                          onPressed: () {
                                            _search.clear();
                                            setState(() => _query = '');
                                          },
                                        ),
                                    ],
                                    onChanged: (v) => setState(() => _query = v.trim()),
                                    onSubmitted: (_) {
                                      if (filtered.length == 1) {
                                        ref.read(tabsProvider.notifier).openHost(filtered.first);
                                      } else if (quick != null) {
                                        _connectQuick(quick);
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(width: isCompact ? 10 : 12),
                            if (localSupported) ...[
                              if (isCompact)
                                IconButton.outlined(
                                  onPressed: () => ref.read(tabsProvider.notifier).openLocal(),
                                  tooltip: strings.localTerminal,
                                  icon: const Icon(Icons.terminal),
                                )
                              else
                                OutlinedButton.icon(
                                  onPressed: () => ref.read(tabsProvider.notifier).openLocal(),
                                  icon: const Icon(Icons.terminal),
                                  label: Text(strings.localTerminal),
                                ),
                              SizedBox(width: isCompact ? 10 : 12),
                            ],
                            if (isCompact)
                              IconButton.filled(
                                onPressed: () => showHostEditor(context),
                                tooltip: strings.newHost,
                                icon: const Icon(Icons.add),
                              )
                            else
                              FilledButton.icon(
                                onPressed: () => showHostEditor(context),
                                icon: const Icon(Icons.add),
                                label: Text(strings.newHost),
                              ),
                          ],
                        ),
                      ),
              ),
              SizedBox(height: isCompact ? 14 : 20),
              Expanded(
                child: hosts.isEmpty
                    ? _EmptyState(strings: strings, onAdd: () => showHostEditor(context))
                    : filtered.isEmpty
                        ? _NoResults(
                            query: _query,
                            quick: quick,
                            strings: strings,
                            onQuick: _connectQuick,
                          )
                        : CustomScrollView(
                            slivers: [
                              for (final g in groupNames) ...[
                                if (groupNames.length > 1 || g.isNotEmpty)
                                  SliverToBoxAdapter(
                                    child: _GroupHeader(
                                      name: g.isEmpty ? strings.noGroup : g,
                                      hosts: groups[g]!,
                                      selected: _selected,
                                      onConnectAll: () => _connectMany(groups[g]!),
                                      onSelectAll: () => setState(() {
                                        final ids = groups[g]!.map((h) => h.id);
                                        if (groups[g]!.every((h) => _selected.contains(h.id))) {
                                          _selected.removeAll(ids);
                                        } else {
                                          _selected.addAll(ids);
                                        }
                                        if (_selected.isNotEmpty) _keysFocus.requestFocus();
                                      }),
                                      onDeleteAll: () => _deleteMany(groups[g]!),
                                    ),
                                  ),
                                SliverGrid(
                                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: isCompact ? 600 : 380,
                                    mainAxisExtent: 84,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 10,
                                  ),
                                  delegate: SliverChildBuilderDelegate(
                                    (context, i) {
                                      final h = groups[g]![i];
                                      return HostCard(
                                        host: h,
                                        selected: _selected.contains(h.id),
                                        selecting: selecting,
                                        onToggleSelect: () => _toggle(h.id),
                                      );
                                    },
                                    childCount: groups[g]!.length,
                                  ),
                                ),
                                const SliverToBoxAdapter(child: SizedBox(height: 24)),
                              ],
                            ],
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
