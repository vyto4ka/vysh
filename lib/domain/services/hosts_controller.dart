import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infra/storage/json_store.dart';
import '../models/host.dart';
import '../ports/secret_store.dart';
import 'ports_providers.dart';

final hostsProvider = NotifierProvider<HostsController, List<Host>>(HostsController.new);

class HostsController extends Notifier<List<Host>> {
  final _store = JsonStore('hosts.json');

  @override
  List<Host> build() {
    final raw = _store.readSync();
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, Object?>>()
        .map(Host.fromJson)
        .where((h) => h.address.isNotEmpty)
        .toList();
  }

  void upsert(Host host) {
    final i = state.indexWhere((h) => h.id == host.id);
    state = i < 0
        ? [...state, host]
        : [for (final h in state) h.id == host.id ? host : h];
    _persist();
  }

  void remove(String id) {
    state = state.where((h) => h.id != id).toList();
    _persist();
    final secrets = ref.read(secretStoreProvider);
    secrets.delete(passwordKey(id));
    secrets.delete(passphraseKey(id));
  }

  /// Удалить несколько хостов разом (вместе с их сохранёнными паролями).
  void removeMany(Iterable<String> ids) {
    final set = ids.toSet();
    if (set.isEmpty) return;
    state = state.where((h) => !set.contains(h.id)).toList();
    _persist();
    final secrets = ref.read(secretStoreProvider);
    for (final id in set) {
      secrets.delete(passwordKey(id));
      secrets.delete(passphraseKey(id));
    }
  }

  /// Забыть сохранённые пароль и парольную фразу хоста.
  Future<void> forgetSecrets(String id) async {
    final secrets = ref.read(secretStoreProvider);
    await secrets.delete(passwordKey(id));
    await secrets.delete(passphraseKey(id));
  }

  void touch(String id) {
    if (!state.any((h) => h.id == id)) return;
    final now = DateTime.now();
    state = [for (final h in state) h.id == id ? h.withLastConnected(now) : h];
    _persist();
  }

  void _persist() => _store.write(state.map((h) => h.toJson()).toList());
}

/// Список существующих групп (для подсказок в редакторе).
final hostGroupsProvider = Provider<List<String>>((ref) {
  final groups = ref.watch(hostsProvider).map((h) => h.group.trim()).where((g) => g.isNotEmpty).toSet().toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return groups;
});

/// Доступность хоста: время TCP-подключения к порту SSH в мс, или null.
final reachabilityProvider =
    FutureProvider.autoDispose.family<int?, (String, int)>((ref, target) async {
  final sw = Stopwatch()..start();
  try {
    final socket = await Socket.connect(target.$1, target.$2,
        timeout: const Duration(seconds: 3));
    socket.destroy();
    return sw.elapsedMilliseconds;
  } catch (_) {
    return null;
  }
});
