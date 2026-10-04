import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/settings_controller.dart';
import '../../infra/platform/desktop_env.dart';

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
final sftpPaneProvider = NotifierProvider<SftpPaneState, Set<String>>(SftpPaneState.new);

class SftpPaneState extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void toggle(String tabId) => state =
      state.contains(tabId) ? ({...state}..remove(tabId)) : {...state, tabId};
}

/// Используется ли сейчас свой заголовок окна (с кнопками свернуть/закрыть).
final customTitleBarProvider = Provider<bool>((ref) {
  final mode = ref.watch(settingsProvider.select((s) => s.titleBarMode));
  return DesktopEnv.useCustomTitleBar(mode);
});
