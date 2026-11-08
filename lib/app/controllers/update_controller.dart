import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/version.dart';
import '../../infra/update/update_service.dart';

/// Как часто провайдер сам перепроверяет GitHub (6 часов).
const updateRecheckInterval = Duration(hours: 6);

/// Найденное обновление: null - установлен последний релиз.
///
/// Провайдер сам перепроверяется каждые 6 часов и после возврата из фона
/// (в замороженном процессе таймеры стоят). Ошибки не роняют провайдер:
/// без retry riverpod повторял бы упавшую проверку до 10 раз подряд и
/// жёг лимит GitHub API (60 запросов в час) - ошибка остаётся в AsyncValue.
final updateInfoProvider = FutureProvider<UpdateInfo?>((ref) async {
  UpdateService.currentVersion = appVersion;

  final timer = Timer(updateRecheckInterval, ref.invalidateSelf);
  ref.onDispose(timer.cancel);

  final lifecycle = AppLifecycleListener(
    onResume: () {
      final last = UpdateService.lastAutoCheckAt;
      if (last == null ||
          DateTime.now().difference(last) >= updateRecheckInterval) {
        ref.invalidateSelf();
      }
    },
  );
  ref.onDispose(lifecycle.dispose);

  await Future<void>.value();
  return UpdateService.checkForUpdate(force: false);
});
