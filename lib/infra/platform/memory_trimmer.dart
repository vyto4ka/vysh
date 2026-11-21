import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

typedef _GetCurrentProcessNative = ffi.IntPtr Function();
typedef _GetCurrentProcessDart = int Function();

typedef _SetProcessWorkingSetSizeExNative =
    ffi.Int32 Function(
      ffi.IntPtr hProcess,
      ffi.Size dwMinimumWorkingSetSize,
      ffi.Size dwMaximumWorkingSetSize,
      ffi.Uint32 flags,
    );
typedef _SetProcessWorkingSetSizeExDart =
    int Function(
      int hProcess,
      int dwMinimumWorkingSetSize,
      int dwMaximumWorkingSetSize,
      int flags,
    );

typedef _MallocTrimNative = ffi.Int32 Function(ffi.Size pad);
typedef _MallocTrimDart = int Function(int pad);

/// Управление лимитами кэшей Flutter/Skia и возврат неиспользуемой памяти ОС
/// при сворачивании окна или уходе приложения в фон.
class MemoryTrimmer {
  MemoryTrimmer._();

  /// Потолок кэша текстур Skia для активного главного окна (24 МБ).
  /// Для векторно-текстового SSH-клиента 64 МБ избыточны.
  static const int mainSkiaCacheBytes = 24 << 20;

  /// Потолок кэша текстур Skia для вынесенного окна терминала (16 МБ).
  static const int childSkiaCacheBytes = 16 << 20;

  /// Потолок растрового ImageCache (8 МБ / 50 изображений вместо 100 МБ / 1000).
  static const int maxImageCacheBytes = 8 << 20;
  static const int maxImageCacheCount = 50;

  static int _activeSkiaCacheBytes = mainSkiaCacheBytes;
  static bool _useSkia = false;
  static bool _trimmed = false;

  static _GetCurrentProcessDart? _winGetCurrentProcess;
  static _SetProcessWorkingSetSizeExDart? _winSetWorkingSetSizeEx;
  static _MallocTrimDart? _linuxMallocTrim;
  static bool _nativeResolved = false;

  /// Применяет экономные лимиты ImageCache и Skia ResourceCache при старте.
  static void configureStartupLimits({
    bool childWindow = false,
    bool useSkia = false,
  }) {
    _useSkia = useSkia;
    _activeSkiaCacheBytes = childWindow
        ? childSkiaCacheBytes
        : mainSkiaCacheBytes;
    final images = PaintingBinding.instance.imageCache;
    images.maximumSizeBytes = maxImageCacheBytes;
    images.maximumSize = maxImageCacheCount;
    _setSkiaCacheBytes(_activeSkiaCacheBytes);
  }

  /// Освобождает кэши и отдаёт неиспользуемые страницы ОС при сворачивании.
  static void trimOnBackground() {
    if (_trimmed) return;
    _trimmed = true;

    final images = PaintingBinding.instance.imageCache;
    images.clear();
    images.clearLiveImages();

    // Временный сброс лимита Skia до 0 заставляет движок выгрузить кэш текстур
    // и атласов; при возврате окна лимит восстанавливается.
    _setSkiaCacheBytes(0);
    trimProcessMemory();
  }

  /// Восстанавливает рабочий лимит кэша Skia при возврате окна из фона.
  static void restoreOnForeground() {
    if (!_trimmed) return;
    _trimmed = false;
    _setSkiaCacheBytes(_activeSkiaCacheBytes);
  }

  /// Возвращает свободные страницы кучи/рабочего множества операционной системе.
  static void trimProcessMemory() {
    if (kIsWeb) return;
    _resolveNative();
    try {
      if (Platform.isWindows) {
        final getProc = _winGetCurrentProcess;
        final trimWs = _winSetWorkingSetSizeEx;
        if (getProc != null && trimWs != null) {
          trimWs(getProc(), -1, -1, 0);
        }
      } else if (Platform.isLinux) {
        _linuxMallocTrim?.call(0);
      }
    } catch (_) {
      // Отсутствие системного символа (например, musl libc) не критично.
    }
  }

  static void _setSkiaCacheBytes(int bytes) {
    if (!_useSkia) return;
    SystemChannels.skia
        .invokeMethod<void>('Skia.setResourceCacheMaxBytes', bytes)
        .catchError((_) {});
  }

  static void _resolveNative() {
    if (_nativeResolved) return;
    _nativeResolved = true;
    try {
      if (Platform.isWindows) {
        final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
        _winGetCurrentProcess = kernel32
            .lookupFunction<_GetCurrentProcessNative, _GetCurrentProcessDart>(
              'GetCurrentProcess',
            );
        _winSetWorkingSetSizeEx = kernel32
            .lookupFunction<
              _SetProcessWorkingSetSizeExNative,
              _SetProcessWorkingSetSizeExDart
            >('SetProcessWorkingSetSizeEx');
      } else if (Platform.isLinux) {
        final self = ffi.DynamicLibrary.process();
        _linuxMallocTrim = self
            .lookupFunction<_MallocTrimNative, _MallocTrimDart>('malloc_trim');
      }
    } catch (_) {
      // На платформах без этих символов тримминг кучи ОС просто пропускается.
    }
  }
}
