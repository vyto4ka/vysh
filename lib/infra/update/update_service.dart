import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../domain/ports/document_store.dart';
import '../storage/json_store.dart';

/// Почему проверка обновлений не удалась. Текст выбирает интерфейс (l10n).
enum UpdateCheckError {
  /// GitHub вернул пустой или нечитаемый список релизов.
  empty,

  /// Соединение не установилось или оборвалось.
  network,

  /// GitHub не ответил вовремя.
  timeout,

  /// Исчерпан лимит API (60 запросов в час без токена).
  rateLimit,

  /// Неожиданный код ответа.
  httpStatus,
}

/// Ошибка проверки обновления.
class UpdateCheckException implements Exception {
  const UpdateCheckException(this.error, [this.detail]);

  final UpdateCheckError error;

  /// HTTP-код или текст причины.
  final String? detail;

  @override
  String toString() => detail == null
      ? 'UpdateCheckException(${error.name})'
      : 'UpdateCheckException(${error.name}, $detail)';
}

/// Найденное обновление: что, откуда скачать и каким файлом.
class UpdateInfo {
  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    required this.releaseUrl,
    this.releaseNotes,
    required this.assetSize,
    required this.openInBrowser,
    this.assetName = '',
    this.checksumUrl,
  });

  final String currentVersion;
  final String latestVersion;

  /// Прямая ссылка на файл обновления или страница релиза ([openInBrowser]).
  final String downloadUrl;

  /// Страница релиза на GitHub.
  final String releaseUrl;

  /// Текст из CHANGELOG (тело релиза), как есть.
  final String? releaseNotes;

  final int assetSize;

  /// Обновление не ставится само: открываем страницу релиза
  /// (Android, macOS, установщики Linux).
  final bool openInBrowser;

  final String assetName;
  final String? checksumUrl;

  String get formattedSize {
    if (assetSize < 1024) return '$assetSize B';
    if (assetSize < 1024 * 1024) {
      return '${(assetSize / 1024).toStringAsFixed(1)} KB';
    }
    return '${(assetSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get displayLatestVersion => UpdateService.stripTag(latestVersion);

  bool get hasNewVersion =>
      UpdateService.compareVersions(latestVersion, currentVersion) > 0;
}

/// Проверка и установка обновлений с GitHub Releases.
///
/// Логика в духе keqdroid: авто-проверка не чаще раза в 30 минут и не
/// роняет результат ошибки; версии сравниваются по номерам, а при
/// равных номерах - по дате релиза (таг мог быть пере-запушен).
class UpdateService {
  UpdateService._();

  static const _owner = 'vyto4ka';
  static const _repo = 'vysh';

  static const _stateFile = 'update_state.json';

  /// Теги: v0.6.0 и 0.6.0 (в истории встречались оба).
  static final _releaseTagPattern = RegExp(
    r'^v?\d+\.\d+(\.\d+)?(-[\w.]+)?$',
    caseSensitive: false,
  );

  // Найденное обновление не затираем null-ом: карточка в настройках не
  // должна пропадать после неудачной фоновой проверки.
  static UpdateInfo? _cachedAutoResult;
  static DateTime? _lastAutoCheckAt;
  static Future<UpdateInfo?>? _autoCheckInFlight;

  @visibleForTesting
  static Duration minAutoCheckGap = const Duration(minutes: 30);

  static DateTime? get lastAutoCheckAt => _lastAutoCheckAt;

  @visibleForTesting
  static void resetAutoCheck() {
    _cachedAutoResult = null;
    _lastAutoCheckAt = null;
    _autoCheckInFlight = null;
  }

  /// Поставщик состояния (окно проверок, пропущенная версия).
  /// Файл лежит в папке профиля (AppPaths), как settings.json: относительный
  /// путь писал бы в текущую папку процесса (`/` на Android, Program Files
  /// на Windows), где записи нет. Тесты подменяют его на память.
  @visibleForTesting
  static DocumentStore Function() stateStore = () => _fileStateStore;

  static final DocumentStore _fileStateStore = JsonStore(_stateFile);

  static Map<String, Object?> _readState() {
    final raw = stateStore().readSync();
    return raw is Map<String, Object?> ? raw : <String, Object?>{};
  }

  static Future<void> _writeState(Map<String, Object?> data) async {
    await stateStore().write(data);
  }

  /// Проверить обновление. `force` - по кнопке, минуя интервал.
  /// Бросает исключение при сетевой ошибке.
  static Future<UpdateInfo?> checkForUpdate({bool force = false}) async {
    if (force) {
      // Удачная ручная проверка обновляет кэш: иначе карточка в настройках
      // (провайдер без force) до 30 минут показывала бы старый результат.
      final result = await fetchUpdate();
      _cachedAutoResult = result;
      _lastAutoCheckAt = DateTime.now();
      return result;
    }

    final last = _lastAutoCheckAt;
    if (last != null && DateTime.now().difference(last) < minAutoCheckGap) {
      return _cachedAutoResult;
    }
    return _autoCheckInFlight ??= _autoCheck().whenComplete(() {
      _autoCheckInFlight = null;
    });
  }

  static Future<UpdateInfo?> _autoCheck() async {
    try {
      final result = await fetchUpdate();
      _cachedAutoResult = result;
      _lastAutoCheckAt = DateTime.now();
      return result;
    } catch (_) {
      // До первой удачной проверки пустой ответ карточка показала бы
      // как актуальную версию - ошибку отдаём наружу.
      if (_lastAutoCheckAt == null) rethrow;
      return _cachedAutoResult;
    }
  }

  @visibleForTesting
  static Future<UpdateInfo?> Function() fetchUpdate = _fetchUpdate;

  /// Версия запущенного приложения. Присваивает app-слой при старте
  /// (infra не знает про app: см. test/architecture_test.dart).
  static String currentVersion = '0.0.0';

  static Future<UpdateInfo?> _fetchUpdate() async {
    final releases = await fetchReleases();
    if (releases.isEmpty) {
      throw const UpdateCheckException(UpdateCheckError.empty);
    }
    return buildUpdateInfo(releases, currentVersion);
  }

  /// Чистая функция выбора обновления - её покрывают тесты.
  @visibleForTesting
  static UpdateInfo? buildUpdateInfo(
    List<Map<String, dynamic>> releases,
    String currentVersion,
  ) {
    // Последний релиз - с наибольшим номером, а не самый свежий по дате:
    // исправление для старой ветки, выпущенное позже, не должно заслонять
    // более новую версию. Список отсортирован по дате (новые первыми),
    // поэтому при равных номерах остаётся самый свежий.
    var latest = releases.first;
    for (final r in releases.skip(1)) {
      if (compareVersions(
            (r['tag_name'] ?? '').toString(),
            (latest['tag_name'] ?? '').toString(),
          ) >
          0) {
        latest = r;
      }
    }
    final latestTag = (latest['tag_name'] ?? '').toString();
    final currentRelease = _findReleaseForVersion(releases, currentVersion);
    final latestPublished = _releaseDate(latest);
    final currentPublished =
        currentRelease != null ? _releaseDate(currentRelease) : null;

    if (!isNewerRelease(
      latestTag,
      currentVersion,
      latestPublished: latestPublished,
      currentPublished: currentPublished,
    )) {
      return null;
    }

    final assets = latest['assets'] as List?;
    final asset = _findAssetForCurrentPlatform(assets);
    if (asset == null) return null;

    final assetName = (asset['name'] ?? '').toString();
    final releaseUrl = (latest['html_url'] ??
        'https://github.com/$_owner/$_repo/releases/latest') as String;
    final checksumAsset = _findChecksumAsset(assets, assetName);

    // Установщики Linux (deb/rpm/AppImage): системный установщик пусть
    // решает пользователь - ведём на страницу релиза.
    final openInBrowser = _isSetupAsset(assetName);

    return UpdateInfo(
      currentVersion: currentVersion,
      latestVersion: latestTag,
      // Android и macOS качают файл и ставят сами (системный установщик
      // APK / монтирование DMG), остальные платформы - прямой файл.
      downloadUrl: (asset['browser_download_url'] ?? '') as String,
      releaseUrl: releaseUrl,
      releaseNotes: latest['body']?.toString(),
      assetSize: (asset['size'] ?? 0) as int,
      openInBrowser: openInBrowser,
      assetName: assetName,
      checksumUrl: checksumAsset?['browser_download_url'] as String?,
    );
  }

  // ── GitHub API ──

  @visibleForTesting
  static Future<List<Map<String, dynamic>>> fetchReleases() async {
    final filtered = <Map<String, dynamic>>[];

    // Двух страниц хватает; больше только жжёт лимит 60 запросов в час.
    for (var page = 1; page <= 2; page++) {
      final List releases;
      try {
        releases = await _getReleasesPage(page);
      } on UpdateCheckException {
        rethrow;
      }

      if (releases.isEmpty) break;

      for (final release in releases) {
        if (release is! Map) continue;
        final tagName = (release['tag_name'] ?? '').toString();
        if (!_isValidReleaseTag(tagName)) continue;
        if (release['prerelease'] == true) continue;
        if (release['draft'] == true) continue;
        if (_releaseDate(Map<String, dynamic>.from(release)) == null) continue;
        filtered.add(Map<String, dynamic>.from(release));
      }

      if (releases.length < 100) break;
    }

    filtered.sort((a, b) {
      final da = _releaseDate(a)!;
      final db = _releaseDate(b)!;
      return db.compareTo(da);
    });

    return filtered;
  }

  static Future<List> _getReleasesPage(int page) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final uri = Uri.https('api.github.com', '/repos/$_owner/$_repo/releases', {
        'per_page': '100',
        'page': '$page',
      });
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15), onTimeout: () {
        client.close(force: true);
        throw const UpdateCheckException(UpdateCheckError.timeout);
      });
      // Без User-Agent GitHub отвечает 403.
      request.headers.set(HttpHeaders.userAgentHeader, 'vysh-updater');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');

      final response = await request.close().timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          client.close(force: true);
          throw const UpdateCheckException(UpdateCheckError.timeout);
        },
      );

      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const UpdateCheckException(
          UpdateCheckError.rateLimit,
        );
      }
      if (response.statusCode != 200) {
        throw UpdateCheckException(UpdateCheckError.httpStatus, '${response.statusCode}');
      }

      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      final data = jsonDecode(body);
      return data is List ? data : const [];
    } on UpdateCheckException {
      rethrow;
    } on SocketException catch (e) {
      throw UpdateCheckException(UpdateCheckError.network, '$e');
    } on HttpException catch (e) {
      throw UpdateCheckException(UpdateCheckError.network, '$e');
    } on TimeoutException {
      throw const UpdateCheckException(UpdateCheckError.timeout);
    } on FormatException {
      throw const UpdateCheckException(UpdateCheckError.empty);
    } finally {
      client.close(force: true);
    }
  }

  static DateTime? _releaseDate(Map<String, dynamic> release) {
    return DateTime.tryParse(release['published_at']?.toString() ?? '');
  }

  static Map<String, dynamic>? _findReleaseForVersion(
    List<Map<String, dynamic>> releases,
    String currentVersion,
  ) {
    for (final release in releases) {
      final tagName = (release['tag_name'] ?? '').toString();
      if (compareVersions(tagName, currentVersion) == 0) return release;
      if (stripTag(tagName) == stripTag(currentVersion)) return release;
    }
    return null;
  }

  // ── Выбор файла под платформу ──

  /// ABI сборки APK (суффикс `--split-per-abi`) для запущенного процесса.
  /// Platform.version заканчивается на `on "android_arm64"` / `"android_arm"`
  /// / `"android_x64"` - это архитектура самого Dart VM, то есть именно та
  /// ABI, под которую надо ставить обновление.
  @visibleForTesting
  static String androidAbiFromVersion(String version) {
    if (version.contains('"android_arm64"')) return 'arm64-v8a';
    if (version.contains('"android_arm"')) return 'armeabi-v7a';
    if (version.contains('"android_x64"')) return 'x86_64';
    return 'arm64-v8a';
  }

  /// APK своей ABI: arm64 на 32-битную прошивку не встанет, первый .apk
  /// брать нельзя - до него в списке может быть чужая ABI.
  @visibleForTesting
  static Map<String, dynamic>? findApkAsset(List? assets, String abi) {
    if (assets == null) return null;
    final marker = '-${abi.toLowerCase()}.apk';
    for (final asset in assets) {
      final name = (asset['name'] ?? '').toString().toLowerCase();
      if (name.endsWith(marker)) return asset as Map<String, dynamic>;
    }
    return null;
  }

  static Map<String, dynamic>? _findAssetForCurrentPlatform(List? assets) {
    if (Platform.isWindows) {
      return _findBySuffixes(assets, const ['-windows-x64.zip', '.zip']);
    }
    if (Platform.isLinux) {
      return _findBySuffixes(assets, const ['-linux-x64.tar.gz', '.tar.gz']);
    }
    if (Platform.isMacOS) {
      return _findBySuffixes(assets, const ['-macos.dmg', '.dmg']);
    }
    if (Platform.isAndroid) {
      return findApkAsset(assets, androidAbiFromVersion(Platform.version));
    }
    return null;
  }

  static Map<String, dynamic>? _findBySuffixes(
    List? assets,
    List<String> suffixes,
  ) {
    if (assets == null) return null;
    for (final suffix in suffixes) {
      for (final asset in assets) {
        final name = (asset['name'] ?? '').toString().toLowerCase();
        if (name.endsWith(suffix)) return asset as Map<String, dynamic>;
      }
    }
    return null;
  }

  /// Хеш либо в `<имя>.sha256` рядом, либо в общем SHA256SUMS/checksums.txt.
  static Map<String, dynamic>? _findChecksumAsset(
    List? assets,
    String assetName,
  ) {
    if (assets == null || assetName.isEmpty) return null;
    final target = '${assetName.toLowerCase()}.sha256';

    for (final asset in assets) {
      final name = (asset['name'] ?? '').toString().toLowerCase();
      if (name == target) return asset as Map<String, dynamic>;
    }

    const shared = {
      'sha256sums',
      'sha256sums.txt',
      'checksums.txt',
      'checksums.sha256',
    };
    for (final asset in assets) {
      final name = (asset['name'] ?? '').toString().toLowerCase();
      if (shared.contains(name)) return asset as Map<String, dynamic>;
    }

    return null;
  }

  /// Установщики Linux (deb/rpm/AppImage в будущем): системный установщик
  /// пусть решает пользователь - ведём на страницу релиза.
  static bool _isSetupAsset(String assetName) {
    final name = assetName.toLowerCase();
    return name.endsWith('.deb') ||
        name.endsWith('.rpm') ||
        name.endsWith('.appimage');
  }

  static bool _isValidReleaseTag(String tagName) {
    return _releaseTagPattern.hasMatch(tagName.trim());
  }

  // ── Версии ──

  static String stripTag(String tag) {
    var cleaned = tag.trim();
    if (cleaned.toLowerCase().startsWith('v') &&
        cleaned.length > 1 &&
        RegExp(r'^\d').hasMatch(cleaned.substring(1))) {
      cleaned = cleaned.substring(1);
    }
    cleaned = cleaned.split(RegExp(r'[^0-9.]')).first;
    return cleaned.isEmpty ? '0.0.0' : cleaned;
  }

  static int compareVersions(String latest, String current) {
    final latestParts =
        stripTag(latest).split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final currentParts =
        stripTag(current).split('.').map((e) => int.tryParse(e) ?? 0).toList();

    final maxLen = latestParts.length > currentParts.length
        ? latestParts.length
        : currentParts.length;
    for (var i = 0; i < maxLen; i++) {
      final l = i < latestParts.length ? latestParts[i] : 0;
      final c = i < currentParts.length ? currentParts[i] : 0;
      if (l > c) return 1;
      if (l < c) return -1;
    }
    return 0;
  }

  /// Новее ли [latestTag], чем [currentTag]. Решают номера версий; даты
  /// нужны только как защита от странной истории (больший номер, но
  /// опубликован раньше текущего). Меньший номер никогда не считается
  /// обновлением, даже если опубликован позже: выпуск исправления для
  /// старой ветки не должен предлагать пользователям откат.
  static bool isNewerRelease(
    String latestTag,
    String currentTag, {
    DateTime? latestPublished,
    DateTime? currentPublished,
  }) {
    final cmp = compareVersions(latestTag, currentTag);
    if (cmp <= 0) return false;

    if (latestPublished != null &&
        currentPublished != null &&
        currentPublished.isAfter(latestPublished)) {
      return false;
    }
    return true;
  }

  // ── Пропуск версии и периодичность окна ──

  static Future<void> skipVersion(String version) async {
    final state = _readState();
    state['skipVersion'] = version;
    await _writeState(state);
  }

  static Future<bool> isSkipped(String version) async {
    return _readState()['skipVersion'] == version;
  }

  /// Пора ли показывать всплывающее окно (не чаще, чем раз в [days] дней).
  /// Часы ушли назад - отметке верить нельзя, показываем.
  static Future<bool> autoPromptDue(int days, {DateTime? now}) async {
    final last = _readState()['autoPromptedAt'];
    if (last is! int) return true;
    final since =
        (now ?? DateTime.now()).difference(DateTime.fromMillisecondsSinceEpoch(last));
    return since.isNegative || since >= Duration(days: days);
  }

  static Future<void> markAutoPrompted({DateTime? now}) async {
    final state = _readState();
    state['autoPromptedAt'] =
        (now ?? DateTime.now()).millisecondsSinceEpoch;
    await _writeState(state);
  }
}
