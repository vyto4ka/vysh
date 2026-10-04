import 'host.dart';

enum SessionStatus { connecting, ready, lost, closed }

/// Вкладка с сессией. Пока без реального SSH - он приходит на этапе 2.
class SessionTab {
  const SessionTab({
    required this.id,
    required this.host,
    required this.title,
    this.status = SessionStatus.connecting,
  });

  final String id;
  final Host host;
  final String title;
  final SessionStatus status;

  SessionTab copyWith({String? title, SessionStatus? status}) => SessionTab(
        id: id,
        host: host,
        title: title ?? this.title,
        status: status ?? this.status,
      );
}

class TabsState {
  const TabsState({this.tabs = const [], this.active = 0});

  final List<SessionTab> tabs;

  /// 0 - главная вкладка, 1..n - сессии.
  final int active;

  bool get isHome => active == 0;
  SessionTab? get activeTab => isHome ? null : tabs[active - 1];
}
