import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Per-window UI state. Connection/profile ownership is independent of it.
abstract interface class WindowScope {
  ValueListenable<String?> get failure;
  Future<void> returnToMain([String? tabId]);
}

final windowScopeProvider = Provider<WindowScope?>((_) => null);
