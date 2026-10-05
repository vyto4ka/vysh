import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/host.dart';
import '../../domain/services/hosts_controller.dart';
import '../../domain/services/settings_controller.dart';
import '../../domain/services/tabs_controller.dart';
import '../shell/ui_state.dart';
import '../widgets/context_menu.dart';
import 'host_card.dart';
import 'host_editor.dart';

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
          title: Text('Открыть ${hosts.length} вкладок?'),
          content: const Text('Каждый хост откроется в отдельной вкладке.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Подключиться')),
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
    final shown = names.take(8).join(', ');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: Text(hosts.length == 1 ? 'Удалить хост?' : 'Удалить ${hosts.length} хостов?'),
        content: Text(
          '$shown${names.length > 8 ? ' и ещё ${names.length - 8}' : ''}.\n'
          'Сохранённые пароли этих хостов тоже будут удалены.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    ref.read(hostsProvider.notifier).removeMany(hosts.map((h) => h.id));
    _clearSelection();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(hosts.length == 1 ? 'Хост удалён' : 'Удалено хостов: ${hosts.length}')),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    // Пингуем только пока список виден: в терминале и при свёрнутом окне
    // незачем стучаться во все серверы (можно включить в настройках).
    // Интервал задаётся в настройках, поэтому таймер тикает часто (дёшево),
    // а сама проверка - только когда подошло время.
    _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_visible) _pingIfStale();
    });
    // Развернули окно - обновим, если данные устарели.
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
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
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
              // Expanded + Align, а не Flexible + Spacer: иначе на широком окне
              // они делят место пополам и кнопка уезжает от края.
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: SearchBar(
                    controller: _search,
                    focusNode: ref.watch(hostSearchFocusProvider),
                    hintText: 'Поиск или user@host:port',
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
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () => showHostEditor(context),
                icon: const Icon(Icons.add),
                label: const Text('Новый хост'),
              ),
            ],
          ),
                  ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: hosts.isEmpty
                ? _EmptyState(onAdd: () => showHostEditor(context))
                : filtered.isEmpty
                    ? _NoResults(query: _query, quick: quick, onQuick: _connectQuick)
                    : CustomScrollView(
                        slivers: [
                          for (final g in groupNames) ...[
                            if (groupNames.length > 1 || g.isNotEmpty)
                              SliverToBoxAdapter(
                                child: _GroupHeader(
                                  name: g.isEmpty ? 'Без группы' : g,
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
                              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 360,
                                mainAxisExtent: 84,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(28),
            ),
            child: Icon(Icons.dns_rounded, size: 44,
                color: theme.colorScheme.onPrimaryContainer),
          ),
          const SizedBox(height: 20),
          Text('Пока нет ни одного хоста', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Добавьте хост или введите user@host в поиске',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Добавить хост'),
          ),
        ],
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults({required this.query, required this.quick, required this.onQuick});

  final String query;
  final Host? quick;
  final ValueChanged<Host> onQuick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Ничего не найдено по «$query»',
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            if (quick != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => onQuick(quick!),
                icon: const Icon(Icons.bolt),
                label: Text('Подключиться к ${quick!.displayAddress}'),
              ),
              const SizedBox(height: 6),
              Text('Enter: подключиться без сохранения',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Заголовок группы: название, число хостов и действия над всей группой.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.name,
    required this.hosts,
    required this.selected,
    required this.onConnectAll,
    required this.onSelectAll,
    required this.onDeleteAll,
  });

  final String name;
  final List<Host> hosts;
  final Set<String> selected;
  final VoidCallback onConnectAll;
  final VoidCallback onSelectAll;
  final VoidCallback onDeleteAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final all = hosts.every((h) => selected.contains(h.id));
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: Row(
        children: [
          Flexible(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('${hosts.length}',
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: hosts.length == 1 ? 'Подключиться' : 'Подключиться ко всем',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: onConnectAll,
          ),
          IconButton(
            tooltip: all ? 'Снять выбор с группы' : 'Выбрать группу',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: Icon(all ? Icons.check_box : Icons.check_box_outline_blank),
            onPressed: onSelectAll,
          ),
          MenuIconButton(
            tooltip: 'Действия с группой',
            items: [
              menuItem(
                hosts.length == 1 ? 'Подключиться' : 'Подключиться ко всем (${hosts.length})',
                icon: Icons.play_arrow_rounded,
                onPressed: onConnectAll,
              ),
              menuItem(all ? 'Снять выбор' : 'Выбрать все в группе',
                  icon: Icons.check_box_outlined, onPressed: onSelectAll),
              menuDivider(),
              menuItem('Удалить группу…',
                  icon: Icons.delete_outline, color: scheme.error, onPressed: onDeleteAll),
            ],
          ),
        ],
      ),
    );
  }
}

/// Панель вместо поиска, пока выбраны хосты.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    super.key,
    required this.count,
    required this.allSelected,
    required this.onSelectAll,
    required this.onClear,
    required this.onConnect,
    required this.onDelete,
  });

  final int count;
  final bool allSelected;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback onConnect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: 4, right: 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Снять выбор (Esc)',
            icon: Icon(Icons.close, color: scheme.onSecondaryContainer),
            onPressed: onClear,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text('Выбрано: $count',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: scheme.onSecondaryContainer)),
                ),
                const SizedBox(width: 8),
                if (!allSelected)
                  TextButton(onPressed: onSelectAll, child: const Text('Выбрать все')),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: onConnect,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(count == 1 ? 'Подключиться' : 'Подключиться ко всем'),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.errorContainer,
              foregroundColor: scheme.onErrorContainer,
            ),
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Удалить'),
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}
