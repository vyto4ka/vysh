import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/hosts_controller.dart';
import 'ui_state.dart';

/// Вкладки главной (M3 primary tabs): «Хосты» и «Настройки».
class HomeTabs extends ConsumerStatefulWidget {
  const HomeTabs({super.key});

  @override
  ConsumerState<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends ConsumerState<HomeTabs> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: ref.read(homeSectionProvider),
  );

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Раздел могут переключить хоткеем (Ctrl+,) - синхронизируем вкладки.
    ref.listen(homeSectionProvider, (_, next) {
      if (_tabs.index != next) _tabs.animateTo(next);
    });
    final count = ref.watch(hostsProvider.select((h) => h.length));
    final scheme = Theme.of(context).colorScheme;

    Widget tab(IconData icon, String label, [String? badge]) => Tab(
          height: 48,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(label),
              if (badge != null) ...[
                const SizedBox(width: 8),
                Badge(
                  label: Text(badge),
                  backgroundColor: scheme.secondaryContainer,
                  textColor: scheme.onSecondaryContainer,
                ),
              ],
            ],
          ),
        );

    return TabBar(
      controller: _tabs,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      dividerColor: scheme.outlineVariant,
      onTap: ref.read(homeSectionProvider.notifier).select,
      tabs: [
        tab(Icons.dns_outlined, 'Хосты', count > 0 ? '$count' : null),
        tab(Icons.tune, 'Настройки'),
      ],
    );
  }
}
