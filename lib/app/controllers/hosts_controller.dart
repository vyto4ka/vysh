import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../infra/platform/net_resolve.dart';
import '../../domain/models/host.dart';
import '../../domain/ports/secret_store.dart';
import '../dependencies.dart';
import '../terminal/terminal_session.dart';

final hostsProvider = NotifierProvider<HostsController, List<Host>>(HostsController.new);

/// Хост сохранён, но с паролем что-то не так (системное хранилище недоступно).
enum HostSaveWarning { passwordNotDeleted, passwordNotSaved }

class HostsController extends Notifier<List<Host>> {
  late final _store = ref.read(documentStoreProvider('hosts.json'));

  @override
  List<Host> build() {
    final raw = _store.readSync();
    if (raw is! List) return const [];
    // Одна испорченная запись не должна стоить всего списка.
    final hosts = <Host>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        final map = item is Map<String, Object?>
            ? item
            : Map<String, Object?>.from(item);
        final h = Host.fromJson(map);
        if (h.address.isNotEmpty) hosts.add(h);
      } catch (e) {
        debugPrint('vysh: пропущена запись hosts.json: $e');
      }
    }
    return hosts;
  }

  void upsert(Host host) {
    final i = state.indexWhere((h) => h.id == host.id);
    state = i < 0
        ? [...state, host]
        : [for (final h in state) h.id == host.id ? host : h];
    _persist();
  }

  void remove(String id) {
    removeMany([id]);
  }

  /// Удалить несколько хостов разом (вместе с их сохранёнными паролями).
  void removeMany(Iterable<String> ids) {
    final set = ids.toSet();
    if (set.isEmpty) return;
    state = state.where((h) => !set.contains(h.id)).toList();
    _persist();
    for (final id in set) {
      // Хост уже удалён из списка; секрет, который не удалось стереть,
      // только логируем - показать его пользователю всё равно негде.
      forgetSecrets(id).catchError((Object e) {
        debugPrint('vysh: не удалось удалить пароль хоста $id: $e');
      });
    }
  }

  /// Сохранить хост из редактора вместе с паролем.
  ///
  /// [password] - то, что введено в поле (пусто - не меняли), [remember] -
  /// хранить ли пароль в системном хранилище, [previous] - хост до правки.
  /// Если пароль сменили или убрали, открытые вкладки забывают старый,
  /// чтобы не переподключаться с ним.
  Future<HostSaveWarning?> saveWithPassword(
    Host host, {
    required String password,
    required bool remember,
    Host? previous,
    required void Function(String hostId) forgetSessionPasswords,
  }) async {
    upsert(host);
    if (previous != null && (password.isNotEmpty || !remember || host.auth != previous.auth)) {
      forgetSessionPasswords(host.id);
    }
    final secrets = ref.read(secretStoreProvider);
    // Хост направили на другой сервер: сохранённый пароль прежнего туда не отдаём.
    final retargeted = previous != null &&
        TerminalSession.targetOf(previous) != TerminalSession.targetOf(host);
    if (host.auth != AuthMethod.password || !remember || (retargeted && password.isEmpty)) {
      // Пароль не нужен или его просили не хранить - убираем сохранённый.
      try {
        await secrets.delete(passwordKey(host.id));
      } catch (_) {
        return HostSaveWarning.passwordNotDeleted;
      }
    } else if (password.isNotEmpty) {
      try {
        await secrets.write(passwordKey(host.id), password);
      } catch (_) {
        return HostSaveWarning.passwordNotSaved;
      }
    }
    return null;
  }

  /// Забыть сохранённые пароль и парольную фразу хоста.
  /// Бросает исключение, если системное хранилище недоступно.
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

/// Доступность хоста: время TCP-подключения к порту SSH в мс
/// или причина, по которой подключиться не удалось.
typedef Reachability = ({int? ms, String? error});

final reachabilityProvider = FutureProvider.autoDispose
    .family<Reachability, (String, int)>((ref, target) async {
  final host = target.$1.trim();
  final port = target.$2;

  // Тот же порядок адресов, что и при SSH-подключении (IPv4 первым).
  List<InternetAddress> addrs;
  try {
    addrs = await resolveHost(host, timeout: const Duration(seconds: 4));
  } catch (e) {
    return (ms: null, error: 'DNS: ${_reason(e)}');
  }

  await _probeSlots.acquire();
  try {
    String? error;
    // Вторая попытка - на случай потерянного пакета или лимита новых
    // подключений на сервере (ufw limit, fail2ban).
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(milliseconds: 700));
      for (final addr in addrs.take(maxAddressAttempts)) {
        final sw = Stopwatch()..start();
        try {
          final socket =
              await Socket.connect(addr, port, timeout: const Duration(seconds: 4));
          socket.destroy();
          return (ms: sw.elapsedMilliseconds, error: null);
        } catch (e) {
          error = '${addr.address}: ${_reason(e)}';
        }
      }
    }
    return (ms: null, error: error);
  } finally {
    _probeSlots.release();
  }
});

/// Не больше 16 проверок доступности одновременно: при сотне хостов
/// иначе разом открывалась сотня сокетов.
final _probeSlots = _Semaphore(16);

class _Semaphore {
  _Semaphore(this._free);
  int _free;
  final _waiting = <Completer<void>>[];

  Future<void> acquire() {
    if (_free > 0) {
      _free--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _free++;
    }
  }
}

String _reason(Object e) => switch (e) {
      SocketException(:final osError?) => osError.message.trim(),
      SocketException(:final message) => message,
      TimeoutException() => 'timeout',
      _ => e.toString(),
    };
