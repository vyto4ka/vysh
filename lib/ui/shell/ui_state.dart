import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/settings/window_chrome.dart';

/// Раздел главной вкладки: 0 - хосты, 1 - настройки.
final homeSectionProvider = NotifierProvider<HomeSection, int>(HomeSection.new);

class HomeSection extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

/// Фокус поля поиска хостов - нужен для хоткея «новая вкладка».
final hostSearchFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'host-search');
  ref.onDispose(node.dispose);
  return node;
});

/// Вкладки, у которых открыта SFTP-панель.
final sftpPaneProvider = NotifierProvider<SftpPaneState, Set<String>>(
  SftpPaneState.new,
);

class SftpPaneState extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    // Закрытые вкладки забываем, чтобы набор не рос всю жизнь приложения.
    ref.listen(tabsProvider, (_, tabs) {
      final alive = tabs.tabs.map((t) => t.id).toSet();
      if (!alive.containsAll(state)) {
        state = state.where(alive.contains).toSet();
      }
    });
    return const {};
  }

  void open(String tabId) => state = {...state, tabId};

  void toggle(String tabId) {
    final tab = ref
        .read(tabsProvider)
        .tabs
        .where((t) => t.id == tabId)
        .firstOrNull;
    if (tab == null) return;
    state = state.contains(tabId)
        ? ({...state}..remove(tabId))
        : {...state, tabId};
  }
}

/// Используется ли сейчас свой заголовок окна (с кнопками свернуть/закрыть).
final customTitleBarProvider = Provider<bool>((ref) {
  final mode = ref.watch(settingsProvider.select((s) => s.titleBarMode));
  return useCustomTitleBar(mode);
});

/// A session can be visible beside the active tab without creating a second connection.
final splitTabProvider = NotifierProvider<SplitTabState, String?>(
  SplitTabState.new,
);

class SplitTabState extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(tabsProvider, (_, tabs) {
      if (state != null && !tabs.tabs.any((t) => t.id == state)) state = null;
    });
    return null;
  }

  void select(String? id) => state = id;
}

final splitLayoutProvider =
    NotifierProvider<SplitLayout, ({Axis axis, bool reverse})>(SplitLayout.new);

class SplitLayout extends Notifier<({Axis axis, bool reverse})> {
  @override
  ({Axis axis, bool reverse}) build() =>
      (axis: Axis.horizontal, reverse: false);
  void select(Axis axis, {bool reverse = false}) =>
      state = (axis: axis, reverse: reverse);
}

final draggedTabProvider = NotifierProvider<DraggedTab, String?>(
  DraggedTab.new,
);

class DraggedTab extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) {
    if (ref.mounted) state = id;
  }
}

final workspaceFocusProvider = NotifierProvider<WorkspaceFocus, String?>(
  WorkspaceFocus.new,
);

class WorkspaceFocus extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(
      tabsProvider.select((tabs) => tabs.activeTab?.id),
      (_, id) => state = id,
    );
    return null;
  }

  void select(String? id) => state = id;
}
