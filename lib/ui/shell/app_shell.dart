import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../infra/platform/capabilities.dart';
import 'dart:async' show unawaited;

import '../../app/controllers/update_controller.dart';
import '../../infra/storage/app_paths.dart';
import '../../infra/storage/json_store.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/windows/detached_windows.dart';
import '../../infra/update/update_service.dart';
import '../dialogs/update_dialog.dart';
import '../hosts/host_editor.dart';
import '../hosts/hosts_page.dart';
import '../settings/settings_page.dart';
import 'session_workspace.dart';
import '../../app/windows/window_scope.dart';
import '../widgets/strings_context.dart';
import 'home_switcher.dart';
import 'tab_strip.dart';
import 'app_shortcuts.dart';
import 'ui_state.dart';

/// Корень интерфейса: полоса вкладок + содержимое активной вкладки.
/// Вкладка 0 - «главная» (боковая навигация + хосты/настройки).
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
    JsonStore.failure.addListener(_onSaveFailure);
    final initError = AppPaths.initError;
    if (initError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showError(
          context.strings.profileUnavailable(initError.path, initError.error),
        );
      });
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    JsonStore.failure.removeListener(_onSaveFailure);
    super.dispose();
  }

  /// Хосты/настройки не записались на диск - пользователь должен об этом знать.
  void _onSaveFailure() {
    final f = JsonStore.failure.value;
    if (f == null || !mounted) return;
    _showError(context.strings.saveFailed(f.fileName, f.message));
  }

  void _showError(String text) {
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
        backgroundColor: scheme.errorContainer,
        duration: const Duration(seconds: 10),
      ),
    );
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    // Открыт диалог или меню - хоткеи вкладок не трогаем.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    for (final entry in _bindings.entries) {
      if (entry.key.accepts(event, HardwareKeyboard.instance)) {
        entry.value();
        return true;
      }
    }
    return false;
  }

  String? get _focusedSessionId {
    final focus = ref.read(workspaceFocusProvider);
    final tabs = ref.read(tabsProvider);
    return focus != null &&
            (focus == tabs.activeTab?.id || focus == ref.read(splitTabProvider))
        ? focus
        : tabs.activeTab?.id;
  }

  void _goHome(int section) {
    ref.read(tabsProvider.notifier).activate(0);
    ref.read(homeSectionProvider.notifier).select(section);
  }

  List<int> get _visibleTabIndices {
    final tabs = ref.read(tabsProvider);
    final external = ref.read(detachedWindowsProvider);
    return [
      0,
      for (var i = 0; i < tabs.tabs.length; i++)
        if (!external.containsKey(tabs.tabs[i].id)) i + 1,
    ];
  }

  void _activateVisibleTab(int index) {
    final indices = _visibleTabIndices;
    if (index < indices.length) {
      ref.read(tabsProvider.notifier).activate(indices[index]);
    }
  }

  void _stepVisibleTab(int delta) {
    final indices = _visibleTabIndices;
    final current = indices.indexOf(ref.read(tabsProvider).active);
    ref
        .read(tabsProvider.notifier)
        .activate(indices[(current + delta) % indices.length]);
  }

  Map<ShortcutActivator, VoidCallback> _buildBindings() {
    final ctrl = ref.read(tabsProvider.notifier);
    return {
      for (final entry in applicationShortcuts().entries)
        entry.key: () {
          final id = _focusedSessionId;
          switch (entry.value) {
            case AppCommand.newTab:
              _goHome(0);
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => ref.read(hostSearchFocusProvider).requestFocus(),
              );
            case AppCommand.closeTab:
              if (id != null) ctrl.close(id);
            case AppCommand.nextTab:
              _stepVisibleTab(1);
            case AppCommand.previousTab:
              _stepVisibleTab(-1);
            case AppCommand.reconnect:
              if (id != null) ctrl.reconnect(id);
            case AppCommand.newHost:
              _goHome(0);
              showHostEditor(context);
            case AppCommand.settings:
              _goHome(1);
            case AppCommand.files:
              if (id != null) ref.read(sftpPaneProvider.notifier).toggle(id);
            default:
              _activateVisibleTab(entry.value.index - AppCommand.tab1.index);
          }
        },
    };
  }

  @override
  Widget build(BuildContext context) {
    // Нашлось обновление - всплывающее окно (с периодичностью из настроек,
    // пропущенная версия не показывается). Первый показ - не в момент
    // подключения, а когда проверка завершится.
    ref.listen<AsyncValue<UpdateInfo?>>(updateInfoProvider, (prev, next) {
      final info = next.value;
      if (info == null) return;
      // Повторная проверка с той же версией не всплывает заново.
      if (prev != null &&
          !prev.isLoading &&
          prev.value?.latestVersion == info.latestVersion) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(autoPromptForUpdate(context, ref, info));
      });
    });

    final window = ref.watch(windowScopeProvider);
    final body = Column(
      children: [
        const TabStrip(),
        if (window != null)
          ValueListenableBuilder<String?>(
            valueListenable: window.failure,
            builder: (context, error, _) => error == null
                ? const SizedBox.shrink()
                : MaterialBanner(
                    content: Text(
                      context.strings.isRu
                          ? 'Не удалось связаться с владельцем сессий: $error'
                          : 'Could not contact the session owner: $error',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => window.returnToMain(),
                        child: Text(
                          context.strings.isRu
                              ? 'Вернуть в главное окно'
                              : 'Return to main window',
                        ),
                      ),
                    ],
                  ),
          ),
        Expanded(child: const SessionWorkspace(home: _HomeView())),
      ],
    );

    // Linux без системной рамки: края окна тянем сами.
    final resizable =
        PlatformCapabilities.selfResizedWindow &&
        ref.watch(customTitleBarProvider);
    // macOS: окно без заголовка (fullSizeContentView), полоса вкладок сама
    // отступает под светофор - SafeArea сверху не нужен.
    return Scaffold(
      body: SafeArea(
        top: !PlatformCapabilities.isMacOS,
        child: resizable
            ? DragToResizeArea(resizeEdgeSize: 6, child: body)
            : body,
      ),
    );
  }
}

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
                  position: Tween(
                    begin: const Offset(0, 0.015),
                    end: Offset.zero,
                  ).animate(anim),
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
