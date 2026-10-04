import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/session_tab.dart';
import '../../domain/ports/sftp.dart';
import '../../domain/services/settings_controller.dart';
import '../../domain/services/sftp_actions.dart';
import '../../domain/services/tabs_controller.dart';
import '../../domain/services/transfer_queue.dart';
import '../../infra/platform/local_files.dart';
import '../theme/app_theme.dart';
import '../widgets/context_menu.dart';
import 'sftp_dialogs.dart';
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
  String? _cwd;
  List<RemoteEntry> _entries = const [];
  bool _loading = false;
  String? _error;
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
    if (widget.tab.status == SessionStatus.ready && old.tab.status != SessionStatus.ready) {
      _cwd == null ? _init() : _open(_cwd!);
    }
  }

  @override
  void dispose() {
    _listFocus.dispose();
    _pathField.dispose();
    super.dispose();
  }

  SftpActions? get _actions {
    final session = ref.read(tabsProvider.notifier).sessionOf(widget.tab.id);
    if (session == null) return null;
    final dir = ref.read(settingsProvider).downloadsDir;
    return SftpActions(
      tabId: widget.tab.id,
      session: session,
      queue: ref.read(transferQueueProvider.notifier),
      downloadsDir: dir.isEmpty ? LocalFiles.defaultDownloadsDir() : dir,
    );
  }

  Future<SftpSession> _sftp() =>
      ref.read(tabsProvider.notifier).sessionOf(widget.tab.id)!.sftp();

  Future<void> _init() async {
    if (_error != null) {
      ref.read(tabsProvider.notifier).sessionOf(widget.tab.id)?.resetSftp();
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final home = await (await _sftp()).home();
      await _open(home);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await (await _sftp()).list(path);
      list.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _cwd = path;
        _pathField.text = path;
        _entries = list;
        _selected.clear();
        _anchor = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
        _pathField.text = _cwd ?? path;
      });
    }
  }

  Future<void> _refresh() async {
    if (_cwd != null) await _open(_cwd!);
  }

  void _toast(String text, {bool error = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: error ? scheme.errorContainer : null,
      duration: Duration(seconds: error ? 6 : 3),
    ));
  }

  Future<void> _run(Future<void> Function() action, {bool refresh = true}) async {
    try {
      await action();
      if (refresh) await _refresh();
    } catch (e) {
      _toast('$e', error: true);
    }
  }

  List<RemoteEntry> get _visible =>
      _showHidden ? _entries : _entries.where((e) => !e.isHidden).toList();

  List<RemoteEntry> get _selection =>
      _entries.where((e) => _selected.contains(e.path)).toList();

  // ─── Действия ─────────────────────────────────────────────────────

  Future<void> _uploadFiles() async {
    final files = await openFiles(confirmButtonText: 'Загрузить');
    if (files.isEmpty || _cwd == null) return;
    await _upload(files.map((f) => f.path).toList());
  }

  Future<void> _uploadFolder() async {
    final dir = await getDirectoryPath(confirmButtonText: 'Загрузить');
    if (dir == null || _cwd == null) return;
    await _upload([dir]);
  }

  Future<void> _upload(List<String> paths) async {
    final target = _cwd!;
    await _run(
      () async => _actions?.uploadPaths(paths, target, onFileDone: () {
        if (mounted && _cwd == target) _refresh();
      }),
      refresh: true,
    );
  }

  Future<void> _download(List<RemoteEntry> entries) async {
    if (entries.isEmpty) return;
    await _run(() async {
      final path = await _actions?.download(entries);
      if (path != null) {
        _toast('Скачивание в ${_parentDir(path)}');
      }
    }, refresh: false);
  }

  Future<void> _downloadTo(List<RemoteEntry> entries) async {
    if (entries.isEmpty) return;
    final dir = await getDirectoryPath(confirmButtonText: 'Сохранить сюда');
    if (dir == null) return;
    await _run(() async => _actions?.download(entries, targetDir: dir), refresh: false);
  }

  Future<void> _openLocally(RemoteEntry e) async {
    await _run(
      () async => _actions?.openLocally(e,
          onUploaded: (name) => _toast('«$name» сохранён на сервере')),
      refresh: false,
    );
  }

  Future<void> _mkdir() async {
    final name = await askText(context, title: 'Новая папка', label: 'Имя папки');
    if (name == null || name.isEmpty || _cwd == null) return;
    await _run(() async => (await _sftp()).mkdir(remoteJoin(_cwd!, name)));
  }

  Future<void> _rename(RemoteEntry e) async {
    final name = await askText(context, title: 'Переименовать', label: 'Новое имя', initial: e.name);
    if (name == null || name.isEmpty || name == e.name) return;
    await _run(() async => (await _sftp()).rename(e.path, remoteJoin(remoteParent(e.path), name)));
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
    final keys = HardwareKeyboard.instance;
    setState(() {
      if (keys.isShiftPressed && _anchor != null) {
        final list = _visible;
        final a = list.indexWhere((x) => x.path == _anchor);
        final b = list.indexOf(e);
        if (a >= 0 && b >= 0) {
          _selected
            ..clear()
            ..addAll(list.sublist(a < b ? a : b, (a < b ? b : a) + 1).map((x) => x.path));
          return;
        }
      }
      if (keys.isControlPressed) {
        _selected.contains(e.path) ? _selected.remove(e.path) : _selected.add(e.path);
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
        menuItem('Открыть', icon: Icons.open_in_new, onPressed: () => _openLocally(single)),
      if (single != null && single.isDir)
        menuItem('Открыть папку', icon: Icons.folder_open, onPressed: () => _open(single.path)),
      if (sel.isNotEmpty) ...[
        menuItem('Скачать', icon: Icons.download, onPressed: () => _download(sel)),
        menuItem('Скачать в…', icon: Icons.drive_file_move_outlined, onPressed: () => _downloadTo(sel)),
      ],
      if (single != null) ...[
        menuItem('Переименовать',
            icon: Icons.drive_file_rename_outline,
            shortcut: Keys.rename,
            onPressed: () => _rename(single)),
        menuItem('Права доступа', icon: Icons.lock_outline, onPressed: () => _chmod(single)),
        menuItem('Копировать путь',
            icon: Icons.content_copy,
            onPressed: () => Clipboard.setData(ClipboardData(text: single.path))),
      ],
      if (sel.isNotEmpty) ...[
        menuItem('Удалить',
            icon: Icons.delete_outline,
            shortcut: Keys.delete,
            color: error,
            onPressed: () => _delete(sel)),
        menuDivider(),
      ],
      ..._folderItems(),
    ]);
  }

  /// Пункты, относящиеся к текущей папке (меню «⋮» и пустое место списка).
  List<Widget> _folderItems() => [
        menuItem('Загрузить файлы…', icon: Icons.upload_file, onPressed: _uploadFiles),
        menuItem('Загрузить папку…',
            icon: Icons.drive_folder_upload_outlined, onPressed: _uploadFolder),
        menuItem('Новая папка', icon: Icons.create_new_folder_outlined, onPressed: _mkdir),
        menuDivider(),
        menuItem('Домашняя папка', icon: Icons.home_outlined, onPressed: _init),
        menuItem('Обновить', icon: Icons.refresh, shortcut: Keys.refresh, onPressed: _refresh),
        CheckboxMenuButton(
          value: _showHidden,
          onChanged: (_) => setState(() => _showHidden = !_showHidden),
          child: const Text('Скрытые файлы'),
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
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): () => setState(() {
              _selected
                ..clear()
                ..addAll(_visible.map((e) => e.path));
            }),
      };

  // ─── UI ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ready = widget.tab.status == SessionStatus.ready;

    Widget body;
    if (!ready) {
      body = _Placeholder(icon: Icons.cloud_off, text: 'Нет соединения с сервером');
    } else if (_error != null && _entries.isEmpty) {
      body = _Placeholder(
        icon: Icons.error_outline,
        text: _error!,
        action: TextButton(onPressed: _init, child: const Text('Повторить')),
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
                return _EntryRow(
                  entry: null,
                  selected: false,
                  onTap: () => _open(remoteParent(_cwd ?? '/')),
                  onDoubleTap: () => _open(remoteParent(_cwd ?? '/')),
                  onSecondary: (_) {},
                );
              }
              final e = list[i - 1];
              return _EntryRow(
                entry: e,
                selected: _selected.contains(e.path),
                onTap: () => _select(e),
                onDoubleTap: () => _activate(e),
                onSecondary: (pos) => _contextMenu(e, pos),
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
                  tooltip: 'Вверх',
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
                    style: monoStyle(context, size: 12.5, color: scheme.onSurface),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: scheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (v) => _open(v.trim().isEmpty ? '/' : v.trim()),
                  ),
                ),
                IconButton(
                  tooltip: 'Обновить',
                  visualDensity: VisualDensity.compact,
                  onPressed: ready ? _refresh : null,
                  icon: const Icon(Icons.refresh),
                ),
                MenuIconButton(enabled: ready, items: _folderItems()),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
          // Список с приёмом файлов перетаскиванием.
          Expanded(
            child: DropTarget(
              enable: widget.active && ready,
              onDragEntered: (_) => setState(() => _dragOver = true),
              onDragExited: (_) => setState(() => _dragOver = false),
              onDragDone: (d) {
                setState(() => _dragOver = false);
                final paths = d.files.map((f) => f.path).where((p) => p.isNotEmpty).toList();
                if (paths.isNotEmpty && _cwd != null) _upload(paths);
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
                            color: scheme.primaryContainer.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: scheme.primary, width: 2),
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.upload, size: 40, color: scheme.onPrimaryContainer),
                                const SizedBox(height: 8),
                                Text('Отпустите, чтобы загрузить в\n${_cwd ?? ''}',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: scheme.onPrimaryContainer)),
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

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: scheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondary,
  });

  /// null - строка «..».
  final RemoteEntry? entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final void Function(Offset globalPosition) onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = entry;
    final dim = scheme.onSurfaceVariant;

    final icon = e == null
        ? Icons.subdirectory_arrow_left
        : e.isDir
            ? (e.isLink ? Icons.folder_special_outlined : Icons.folder_rounded)
            : (e.isLink ? Icons.link : _fileIcon(e.name));
    final iconColor = e == null || e.isDir ? scheme.primary : dim;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          onSecondaryTapUp: (d) => onSecondary(d.globalPosition),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    e?.name ?? '..',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: e != null && e.isHidden ? dim : scheme.onSurface,
                    ),
                  ),
                ),
                if (e != null) ...[
                  if (!e.isDir)
                    SizedBox(
                      width: 72,
                      child: Text(formatBytes(e.size),
                          textAlign: TextAlign.end, style: TextStyle(fontSize: 12, color: dim)),
                    ),
                  const SizedBox(width: 10),
                  Tooltip(
                    message: e.permissions,
                    child: SizedBox(
                      width: 96,
                      child: Text(
                        _date(e.modified),
                        textAlign: TextAlign.end,
                        style: TextStyle(fontSize: 12, color: dim),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _date(DateTime? d) {
    if (d == null) return '';
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return 'сегодня ${_two(d.hour)}:${_two(d.minute)}';
    }
    return '${_two(d.day)}.${_two(d.month)}.${d.year % 100} ${_two(d.hour)}:${_two(d.minute)}';
  }

  static IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'sh' || 'bash' || 'zsh' || 'py' || 'js' || 'ts' || 'go' || 'rs' || 'c' || 'cpp' || 'h' ||
      'java' || 'php' || 'rb' || 'pl' || 'lua' => Icons.code,
      'conf' || 'cfg' || 'ini' || 'yaml' || 'yml' || 'toml' || 'json' || 'xml' || 'env' =>
        Icons.settings_outlined,
      'log' || 'txt' || 'md' => Icons.description_outlined,
      'zip' || 'gz' || 'tgz' || 'xz' || 'bz2' || 'zst' || '7z' || 'rar' || 'tar' || 'deb' ||
      'rpm' || 'ipk' => Icons.inventory_2_outlined,
      'iso' || 'img' || 'qcow2' || 'vmdk' => Icons.album_outlined,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'svg' || 'webp' => Icons.image_outlined,
      'pem' || 'crt' || 'key' || 'pub' => Icons.key_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}
