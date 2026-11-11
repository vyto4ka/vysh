import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/session_tab.dart';
import '../../domain/ports/sftp.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/sftp/sftp_actions.dart';
import '../../app/sftp/sftp_directory.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/controllers/transfer_queue.dart';
import '../../infra/platform/desktop_env.dart';
import '../../infra/platform/local_files.dart';
import '../../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/context_menu.dart';
import '../widgets/modifiers.dart';
import 'sftp_dialogs.dart';
import 'file_workspace.dart';
import '../../app/sftp/file_copy.dart';
import 'sftp_drag.dart';
import 'sftp_entry_row.dart';
import 'transfers_view.dart';

/// Файловая панель SFTP справа от терминала.
class SftpPane extends ConsumerStatefulWidget {
  const SftpPane({super.key, required this.tab, required this.active});

  final SessionTab tab;
  final bool active;

  @override
  ConsumerState<SftpPane> createState() => _SftpPaneState();
}

class _SftpPaneState extends ConsumerState<SftpPane> {
  final _pathField = TextEditingController();

  AppStrings get _s =>
      AppStrings.of(context, ref.read(settingsProvider).language);
  bool _showHidden = false;
  bool _dragOver = false;
  final _selected = <String>{};
  String? _anchor;

  @override
  void initState() {
    super.initState();
    if (widget.tab.status == SessionStatus.ready) _init();
  }

  @override
  void didUpdateWidget(SftpPane old) {
    super.didUpdateWidget(old);
    // После переподключения SFTP-канал новый - перечитываем папку.
    if (widget.tab.status == SessionStatus.ready &&
        old.tab.status != SessionStatus.ready) {
      _cwd == null ? _init() : _open(_cwd!);
    }
  }

  @override
  void dispose() {
    _dir.dispose();
    _listFocus.dispose();
    _pathField.dispose();
    super.dispose();
  }

  SftpActions? get _actions {
    final session = ref.read(tabsProvider.notifier).sessionOf(widget.tab.id);
    if (session == null) return null;
    return SftpActions(
      tabId: widget.tab.id,
      session: session,
      queue: ref.read(transferQueueProvider.notifier),
      // На Android - системная Download, на ПК - папка из настроек.
      downloadsDir: () {
        final dir = ref.read(settingsProvider).downloadsDir;
        return DesktopEnv.isMobile || dir.isEmpty
            ? LocalFiles.defaultDownloadsDir()
            : dir;
      }(),
    );
  }

  Future<SftpSession> _sftp() =>
      ref.read(tabsProvider.notifier).sessionOf(widget.tab.id)!.sftp();

  /// Текущая папка, список, загрузка и ошибка (с защитой от устаревших ответов).
  late final _dir = SftpDirectory(
    _sftp,
    resetChannel: () =>
        ref.read(tabsProvider.notifier).sessionOf(widget.tab.id)?.resetSftp(),
  )..addListener(_onDirChanged);
  List<RemoteEntry> _shownEntries = const [];

  String? get _cwd => _dir.cwd;
  List<RemoteEntry> get _entries => _dir.entries;
  bool get _loading => _dir.loading;
  String? get _error => _dir.error == null ? null : _s.errorText(_dir.error!);

  Future<void> _init() => _dir.home();
  Future<void> _open(String path) => _dir.open(path);
  Future<void> _refresh() => _dir.refresh();

  void _onDirChanged() {
    if (!mounted) return;
    setState(() {
      // Открыли другую папку (или перечитали) - прежнее выделение не действует.
      if (!identical(_shownEntries, _dir.entries)) {
        _shownEntries = _dir.entries;
        _selected.clear();
        _anchor = null;
      }
      final shown = _dir.error != null
          ? (_dir.cwd ?? _dir.requestedPath)
          : _dir.cwd;
      if (shown != null && !_dir.loading) _pathField.text = shown;
    });
  }

  void _toast(String text, {bool error = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? scheme.errorContainer : null,
        duration: Duration(seconds: error ? 6 : 3),
      ),
    );
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool refresh = true,
  }) async {
    try {
      await action();
      if (refresh) await _refresh();
    } catch (e) {
      _toast(_s.errorText(e), error: true);
    }
  }

  List<RemoteEntry> get _visible =>
      _showHidden ? _entries : _entries.where((e) => !e.isHidden).toList();

  List<RemoteEntry> get _selection =>
      _entries.where((e) => _selected.contains(e.path)).toList();

  // ─── Действия ─────────────────────────────────────────────────────

  Future<void> _uploadFiles() async {
    final files = await openFiles(confirmButtonText: _s.uploadAction);
    if (files.isEmpty || _cwd == null) return;
    await _upload(files.map((f) => f.path).toList());
  }

  Future<void> _uploadFolder() async {
    final dir = await getDirectoryPath(confirmButtonText: _s.uploadAction);
    if (dir == null || _cwd == null) return;
    await _upload([dir]);
  }

  Future<void> _upload(List<String> paths) async {
    final target = _cwd!;
    await _run(
      () async => _actions?.uploadPaths(
        paths,
        target,
        onFileDone: () {
          if (mounted && _cwd == target) _refresh();
        },
        resolveConflict: _resolveConflict,
      ),
      refresh: true,
    );
  }

  Future<CopyDecision> _resolveConflict(String path) => mounted
      ? askCopyConflict(context, path, _s.isRu)
      : Future.value(const CopyDecision(CopyChoice.cancel));

  Future<void> _download(List<RemoteEntry> entries) async {
    if (entries.isEmpty) return;
    await _run(() async {
      final path = await _actions?.download(
        entries,
        resolveConflict: _resolveConflict,
      );
      if (path != null) {
        // На Android файл публикуется в системную папку Download.
        _toast(
          DesktopEnv.isMobile
              ? _s.downloadingToDownloads
              : _s.downloadingTo(_parentDir(path)),
        );
      }
    }, refresh: false);
  }

  Future<void> _downloadTo(List<RemoteEntry> entries) async {
    if (entries.isEmpty) return;
    final dir = await getDirectoryPath(confirmButtonText: _s.saveHere);
    if (dir == null) return;
    await _run(
      () async => _actions?.download(
        entries,
        targetDir: dir,
        resolveConflict: _resolveConflict,
      ),
      refresh: false,
    );
  }

  Future<void> _openLocally(RemoteEntry e) async {
    await _run(
      () async => _actions?.openLocally(
        e,
        onUploaded: (name) => _toast(_s.savedOnServer(name)),
        onError: (message) => _toast(message(_s), error: true),
      ),
      refresh: false,
    );
  }

  Future<void> _mkdir() async {
    final name = await askText(
      context,
      title: _s.newFolder,
      label: _s.folderName,
    );
    if (name == null || name.isEmpty || _cwd == null) return;
    await _run(() async => (await _sftp()).mkdir(remoteJoin(_cwd!, name)));
  }

  Future<void> _rename(RemoteEntry e) async {
    final name = await askText(
      context,
      title: _s.rename,
      label: _s.newNameHint,
      initial: e.name,
    );
    if (name == null || name.isEmpty || name == e.name) return;
    await _run(
      () async => (await _sftp()).rename(
        e.path,
        remoteJoin(remoteParent(e.path), name),
      ),
    );
  }

  Future<void> _chmod(RemoteEntry e) async {
    final mode = await askPermissions(context, e);
    if (mode == null) return;
    await _run(() async => (await _sftp()).chmod(e.path, mode));
  }

  Future<void> _delete(List<RemoteEntry> entries) async {
    if (entries.isEmpty) return;
    final ok = await confirmDelete(context, entries);
    if (!ok) return;
    await _run(() async {
      final sftp = await _sftp();
      for (final e in entries) {
        await _deleteRecursive(sftp, e);
      }
    });
  }

  Future<void> _deleteRecursive(SftpSession sftp, RemoteEntry e) async {
    if (e.isDir && !e.isLink) {
      for (final child in await sftp.list(e.path)) {
        await _deleteRecursive(sftp, child);
      }
      await sftp.removeDir(e.path);
    } else {
      await sftp.removeFile(e.path);
    }
  }

  void _activate(RemoteEntry e) {
    if (e.isDir) {
      _open(e.path);
    } else {
      _openLocally(e);
    }
  }

  void _select(RemoteEntry e) {
    _listFocus.requestFocus();
    final keys = Modifiers.instance;
    setState(() {
      if (keys.shift && _anchor != null) {
        final list = _visible;
        final a = list.indexWhere((x) => x.path == _anchor);
        final b = list.indexOf(e);
        if (a >= 0 && b >= 0) {
          _selected
            ..clear()
            ..addAll(
              list
                  .sublist(a < b ? a : b, (a < b ? b : a) + 1)
                  .map((x) => x.path),
            );
          return;
        }
      }
      if (keys.ctrl) {
        _selected.contains(e.path)
            ? _selected.remove(e.path)
            : _selected.add(e.path);
      } else {
        _selected
          ..clear()
          ..add(e.path);
      }
      _anchor = e.path;
    });
  }

  final _menu = GlobalKey<ContextMenuAreaState>();
  final _listFocus = FocusNode(debugLabel: 'sftp-list');

  void _contextMenu(RemoteEntry? e, Offset pos) {
    if (e != null && !_selected.contains(e.path)) {
      setState(() {
        _selected
          ..clear()
          ..add(e.path);
        _anchor = e.path;
      });
    }
    _listFocus.requestFocus();
    final sel = _selection;
    final single = sel.length == 1 ? sel.first : null;
    final error = Theme.of(context).colorScheme.error;
    _menu.currentState?.open(pos, [
      if (single != null && !single.isDir)
        menuItem(
          _s.open,
          icon: Icons.open_in_new,
          onPressed: () => _openLocally(single),
        ),
      if (single != null && single.isDir)
        menuItem(
          _s.openFolder,
          icon: Icons.folder_open,
          onPressed: () => _open(single.path),
        ),
      if (sel.isNotEmpty) ...[
        menuItem(
          _s.download,
          icon: Icons.download,
          onPressed: () => _download(sel),
        ),
        menuItem(
          _s.downloadTo,
          icon: Icons.drive_file_move_outlined,
          onPressed: () => _downloadTo(sel),
        ),
      ],
      if (single != null) ...[
        menuItem(
          _s.rename,
          icon: Icons.drive_file_rename_outline,
          shortcut: Keys.rename,
          onPressed: () => _rename(single),
        ),
        menuItem(
          _s.permissions,
          icon: Icons.lock_outline,
          onPressed: () => _chmod(single),
        ),
        menuItem(
          _s.copyPath,
          icon: Icons.content_copy,
          onPressed: () => Clipboard.setData(ClipboardData(text: single.path)),
        ),
      ],
      if (sel.isNotEmpty) ...[
        menuItem(
          _s.delete,
          icon: Icons.delete_outline,
          shortcut: Keys.delete,
          color: error,
          onPressed: () => _delete(sel),
        ),
        menuDivider(),
      ],
      ..._folderItems(),
    ]);
  }

  /// Пункты, относящиеся к текущей папке (меню «⋮» и пустое место списка).
  List<Widget> _folderItems() => [
    menuItem(_s.uploadFiles, icon: Icons.upload_file, onPressed: _uploadFiles),
    menuItem(
      _s.uploadFolder,
      icon: Icons.drive_folder_upload_outlined,
      onPressed: _uploadFolder,
    ),
    menuItem(
      _s.newFolder,
      icon: Icons.create_new_folder_outlined,
      onPressed: _mkdir,
    ),
    menuDivider(),
    menuItem(_s.homeFolder, icon: Icons.home_outlined, onPressed: _init),
    menuItem(
      _s.refresh,
      icon: Icons.refresh,
      shortcut: Keys.refresh,
      onPressed: _refresh,
    ),
    CheckboxMenuButton(
      value: _showHidden,
      onChanged: (_) => setState(() => _showHidden = !_showHidden),
      child: Text(_s.hiddenFiles),
    ),
  ];

  /// Клавиши в списке файлов.
  Map<ShortcutActivator, VoidCallback> get _keys => {
    Keys.delete: () => _delete(_selection),
    Keys.rename: () {
      final sel = _selection;
      if (sel.length == 1) _rename(sel.first);
    },
    Keys.refresh: _refresh,
    const SingleActivator(LogicalKeyboardKey.enter): () {
      final sel = _selection;
      if (sel.length == 1) _activate(sel.first);
    },
    const SingleActivator(LogicalKeyboardKey.backspace): () {
      if (_cwd != null && _cwd != '/') _open(remoteParent(_cwd!));
    },
    const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
        setState(() {
          _selected
            ..clear()
            ..addAll(_visible.map((e) => e.path));
        }),
  };

  // ─── UI ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    ref.watch(settingsProvider.select((s) => s.language)); // язык для _s
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ready = widget.tab.status == SessionStatus.ready;

    Widget body;
    if (!ready) {
      body = SftpPlaceholder(
        icon: Icons.cloud_off,
        text: _s.noServerConnection,
      );
    } else if (_error != null && _entries.isEmpty) {
      body = SftpPlaceholder(
        icon: Icons.error_outline,
        text: _error!,
        action: TextButton(onPressed: _init, child: Text(_s.tryAgain)),
      );
    } else {
      final list = _visible;
      body = CallbackShortcuts(
        bindings: _keys,
        child: Focus(
          focusNode: _listFocus,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _listFocus.requestFocus();
              setState(_selected.clear);
            },
            onSecondaryTapUp: (d) => _contextMenu(null, d.globalPosition),
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: list.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return SftpEntryRow(
                    entry: null,
                    selected: false,
                    onTap: () => _open(remoteParent(_cwd ?? '/')),
                    onDoubleTap: () => _open(remoteParent(_cwd ?? '/')),
                    onSecondary: (_) {},
                    strings: _s,
                  );
                }
                final e = list[i - 1];
                return SftpDragSource(
                  entry: e,
                  actions: () => _actions,
                  child: SftpEntryRow(
                    entry: e,
                    selected: _selected.contains(e.path),
                    onTap: () => _select(e),
                    onDoubleTap: () => _activate(e),
                    onSecondary: (pos) => _contextMenu(e, pos),
                    strings: _s,
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    return ContextMenuArea(
      key: _menu,
      child: Material(
        color: scheme.surfaceContainerLow,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Путь и кнопки.
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: _s.up,
                    visualDensity: VisualDensity.compact,
                    onPressed: ready && _cwd != null && _cwd != '/'
                        ? () => _open(remoteParent(_cwd!))
                        : null,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _pathField,
                      enabled: ready,
                      style: monoStyle(
                        context,
                        size: 12.5,
                        color: scheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: scheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (v) =>
                          _open(v.trim().isEmpty ? '/' : v.trim()),
                    ),
                  ),
                  IconButton(
                    tooltip: _s.refresh,
                    visualDensity: VisualDensity.compact,
                    onPressed: ready ? _refresh : null,
                    icon: const Icon(Icons.refresh),
                  ),
                  MenuIconButton(enabled: ready, items: _folderItems()),
                ],
              ),
            ),
            if (_loading)
              const LinearProgressIndicator(minHeight: 2)
            else
              const SizedBox(height: 2),
            // Список с приёмом файлов перетаскиванием.
            Expanded(
              child: SftpDropZone(
                enabled: widget.active && ready && _cwd != null,
                onHover: (over) {
                  if (mounted && _dragOver != over) {
                    setState(() => _dragOver = over);
                  }
                },
                onDropPaths: (paths) {
                  if (mounted) setState(() => _dragOver = false);
                  if (_cwd != null) _upload(paths);
                },
                child: Stack(
                  children: [
                    Positioned.fill(child: body),
                    if (_dragOver)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Container(
                            margin: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer.withValues(
                                alpha: 0.85,
                              ),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: scheme.primary,
                                width: 2,
                              ),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.upload,
                                    size: 40,
                                    color: scheme.onPrimaryContainer,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _s.dropToUpload(_cwd ?? ''),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: scheme.onPrimaryContainer,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            TransfersView(tabId: widget.tab.id),
          ],
        ),
      ),
    );
  }
}

/// `dirname` для локального пути без лишних зависимостей.
String _parentDir(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i <= 0 ? path : path.substring(0, i);
}
