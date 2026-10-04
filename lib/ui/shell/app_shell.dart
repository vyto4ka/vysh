import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../domain/services/settings_controller.dart';
import '../../domain/services/tabs_controller.dart';
import '../hosts/host_editor.dart';
import '../hosts/hosts_page.dart';
import '../settings/settings_page.dart';
import '../terminal/session_view.dart';
import 'home_switcher.dart';
import 'tab_strip.dart';
import 'ui_state.dart';

/// Корень интерфейса: полоса вкладок + содержимое активной вкладки.
/// Вкладка 0 — «главная» (боковая навигация + хосты/настройки).
///
/// Хоткеи приложения перехватываются глобально (до терминала),
/// иначе терминал отправил бы их на сервер.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late final Map<ShortcutActivator, VoidCallback> _bindings = _buildBindings();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    // Открыт диалог или меню — хоткеи вкладок не трогаем.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    for (final entry in _bindings.entries) {
      if (entry.key.accepts(event, HardwareKeyboard.instance)) {
        entry.value();
        return true;
      }
    }
    return false;
  }

  void _goHome(int section) {
    ref.read(tabsProvider.notifier).activate(0);
    ref.read(homeSectionProvider.notifier).select(section);
  }

  Map<ShortcutActivator, VoidCallback> _buildBindings() {
    final ctrl = ref.read(tabsProvider.notifier);
    return {
      // Новая вкладка → главная + фокус в поиск (быстрое подключение).
      const SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true): () {
        _goHome(0);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => ref.read(hostSearchFocusProvider).requestFocus(),
        );
      },
      const SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true):
          ctrl.closeActive,
      const SingleActivator(LogicalKeyboardKey.tab, control: true): ctrl.next,
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true):
          ctrl.previous,
      const SingleActivator(LogicalKeyboardKey.keyR, control: true, shift: true): () {
        final tab = ref.read(tabsProvider).activeTab;
        if (tab != null) ctrl.reconnect(tab.id);
      },
      const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): () {
        _goHome(0);
        showHostEditor(context);
      },
      const SingleActivator(LogicalKeyboardKey.comma, control: true): () => _goHome(1),
      const SingleActivator(LogicalKeyboardKey.keyE, control: true, shift: true): () {
        final tab = ref.read(tabsProvider).activeTab;
        if (tab != null) ref.read(sftpPaneProvider.notifier).toggle(tab.id);
      },
      for (var i = 1; i <= 9; i++)
        SingleActivator(_digitKeys[i - 1], alt: true): () => ctrl.activate(i - 1),
    };
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ref.watch(tabsProvider);
    final pause = ref.watch(settingsProvider.select((s) => s.pauseHiddenTabs));

    final body = Column(
        children: [
          const TabStrip(),
          Expanded(
            child: IndexedStack(
              index: tabs.active,
              // Скрытые вкладки живут (сессии не рвутся), но их анимации
              // и таймеры-тикеры выключены — не тратим кадры на невидимое.
              children: [
                TickerMode(enabled: !pause || tabs.active == 0, child: const _HomeView()),
                for (var i = 0; i < tabs.tabs.length; i++)
                  TickerMode(
                    key: ValueKey(tabs.tabs[i].id),
                    enabled: !pause || tabs.active == i + 1,
                    child: SessionView(
                      tab: tabs.tabs[i],
                      active: tabs.active == i + 1,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );

    // Linux без системной рамки: края окна тянем сами.
    final resizable = Platform.isLinux && ref.watch(customTitleBarProvider);
    return Scaffold(
      body: resizable ? DragToResizeArea(resizeEdgeSize: 6, child: body) : body,
    );
  }
}

const _digitKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

class _HomeView extends ConsumerWidget {
  const _HomeView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final section = ref.watch(homeSectionProvider);
    final scheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 12, top: 4),
            child: HomeTabs(),
          ),
          Expanded(
            child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(anim),
            child: child,
          ),
        ),
        child: section == 0
            ? const HostsPage(key: ValueKey('hosts'))
            : const SettingsPage(key: ValueKey('settings')),
      ),
          ),
        ],
      ),
    );
  }
}
