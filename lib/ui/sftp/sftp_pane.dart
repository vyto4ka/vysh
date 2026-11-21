import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/controllers/transfer_queue.dart';
import '../../app/settings/app_settings.dart';
import '../../app/sftp/file_copy.dart';
import '../../app/sftp/sftp_actions.dart';
import '../../app/sftp/sftp_clipboard.dart';
import '../../app/sftp/sftp_directory.dart';
import '../../app/terminal/current_directory.dart';
import '../../app/terminal/terminal_session.dart';
import '../../domain/models/session_tab.dart';
import '../../domain/ports/sftp.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import '../../infra/platform/local_files.dart';
import '../../l10n/app_strings.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import '../motion/layered_switcher.dart';
import '../motion/smooth_scroll.dart';
import '../widgets/context_menu.dart';
import '../widgets/modifiers.dart';
import 'file_path_bar.dart';
import 'file_workspace.dart';
import 'sftp_dialogs.dart';
import 'sftp_drag.dart';
import 'sftp_entry_row.dart';
import 'sftp_text_editor.dart';
import 'transfers_view.dart';

Future<void> showSessionFiles(BuildContext context, String id) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => Consumer(
          builder: (context, ref, _) {
            final tab = ref
                .watch(tabsProvider)
                .tabs
                .where((t) => t.id == id)
                .firstOrNull;
            return Scaffold(
              appBar: AppBar(title: Text(tab?.title ?? 'Files')),
              body: SafeArea(
                top: false,
                child: tab == null
                    ? const SizedBox.shrink()
                    : SftpPane(tab: tab, active: true),
              ),
            );
          },
        ),
      ),
    );

/// Боковая или полноэкранная панель проводника, привязанная к вкладке терминала.
class SftpPane extends ConsumerStatefulWidget {
  const SftpPane({super.key, required this.tab, required this.active});

  final SessionTab tab;
  final bool active;

  @override
  ConsumerState<SftpPane> createState() => _SftpPaneState();
}

class _SftpPaneState extends ConsumerState<SftpPane> {
  final _pathField = TextEditingController();
  final _pathFocus = FocusNode(debugLabel: 'sftp-path');
  final _filterField = TextEditingController();
  final _filterFocus = FocusNode(debugLabel: 'sftp-filter');
  final _listFocus = FocusNode(debugLabel: 'sftp-list');
  final _menu = GlobalKey<ContextMenuAreaState>();
  final _history = SftpPathHistory();

  AppStrings get _s =>
      AppStrings.of(context, ref.read(settingsProvider).language);

  bool _showFilter = false;
  bool _dragOver = false;
  bool _hasStorageAccess = true;
  bool _navigatingHistory = false;
  final _selected = <String>{};
  String? _anchor;
  String? _cursorPath;
  bool? _followOverride;
  String? _lastReported;
  Timer? _directoryTimer;
  bool _pollingDirectory = false;
  TerminalSession? _directorySession;
  int _followGeneration = 0;
  ScrollController? _activeScroll;

  String _typeAhead = '';
  Timer? _typeAheadTimer;

  bool get _windowsPaths =>
      widget.tab.isLocal && PlatformCapabilities.isWindows;

  bool get _following =>
      _followOverride ?? ref.read(settingsProvider).followTerminalDirectory;

  String get _fsIdentity => widget.tab.isLocal
      ? 'local'
      : (_directorySession?.target ?? widget.tab.id);

  String _parentOf(String path) =>
      widget.tab.isLocal ? LocalFiles.parentPath(path) : remoteParent(path);

  String _joinPath(String dir, String name) =>
      widget.tab.isLocal ? LocalFiles.join(dir, name) : remoteJoin(dir, name);

  bool _isRoot(String path) =>
      widget.tab.isLocal ? LocalFiles.isRootPath(path) : path == '/';

  Future<void> _checkStorageAccess() async {
    if (!PlatformCapabilities.sharedDownloads || !widget.tab.isLocal) return;
    final ok = await LocalFiles.hasStorageAccess();
    if (mounted && ok != _hasStorageAccess) {
      setState(() => _hasStorageAccess = ok);
    }
  }

  Future<void> _requestStorageAccess() async {
    final granted = await LocalFiles.requestStorageAccess();
    if (!mounted) return;
    setState(() => _hasStorageAccess = granted);
    if (granted) {
      await _dir.home();
    }
  }

  void _onTerminalDirectory() {
    if (!mounted) return;
    final path = _directorySession?.currentDirectory.value;
    if (!_following || !widget.active) {
      setState(() {});
      return;
    }
    if (path == null || path == _lastReported) return;
    _lastReported = path;
    if (path != _cwd) {
      unawaited(_dir.open(path));
    } else {
      setState(() {});
    }
  }

  Future<void> _pollDirectory({bool force = false}) async {
    if (_pollingDirectory ||
        !_following ||
        !widget.active ||
        widget.tab.status != SessionStatus.ready) {
      return;
    }
    _pollingDirectory = true;
    final generation = _followGeneration;
    try {
      await _directorySession?.refreshWorkingDirectory(force: force);
      if (mounted && generation == _followGeneration) _onTerminalDirectory();
    } finally {
      _pollingDirectory = false;
    }
  }

  Future<void> _enableDirectoryReporting() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _s.isRu ? 'Связать папку с терминалом?' : 'Link folder to terminal?',
        ),
        content: Text(
          _s.isRu
              ? 'Для Bash, sh и ash: команда добавит передачу текущей папки к приглашению оболочки до конца этой сессии. Файлы настроек на сервере не изменятся. Выполняйте только в приглашении оболочки, когда другая программа не запущена.'
              : 'For Bash, sh and ash: a command will add directory reporting to the prompt for this session. Server configuration files stay unchanged. Run only at a shell prompt, with no other program running.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_s.isRu ? 'Выполнить в оболочке' : 'Run in shell'),
          ),
        ],
      ),
    );
    if (!mounted ||
        accepted != true ||
        widget.tab.status != SessionStatus.ready) {
      return;
    }
    _setFollow(true);
    _directorySession?.terminal.textInput('$posixDirectoryReporting\r');
  }

  void _setFollow(bool value) {
    setState(() {
      _followOverride = value;
      _followGeneration++;
      if (value) _lastReported = null;
    });
    if (value) {
      _onTerminalDirectory();
      unawaited(_pollDirectory(force: true));
    }
  }

  void _jumpToTerminalDirectory() {
    final path = _directorySession?.currentDirectory.value;
    if (path != null) {
      _lastReported = path;
      unawaited(_dir.open(path));
    } else {
      unawaited(_pollDirectory(force: true));
    }
  }

  void _toggleFilter() {
    setState(() {
      _showFilter = !_showFilter;
      if (!_showFilter) _filterField.clear();
    });
    if (_showFilter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _filterFocus.requestFocus();
      });
    } else {
      _listFocus.requestFocus();
    }
  }

  void _closeFilter() {
    if (!_showFilter) return;
    setState(() {
      _showFilter = false;
      _filterField.clear();
    });
    _listFocus.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    _filterField.addListener(() {
      if (mounted) setState(() {});
    });
    _directorySession = ref
        .read(tabsProvider.notifier)
        .sessionOf(widget.tab.id);
    _directorySession?.currentDirectory.addListener(_onTerminalDirectory);
    _directoryTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollDirectory(),
    );
    unawaited(_checkStorageAccess());
    if (widget.tab.status == SessionStatus.ready) _init();
  }

  @override
  void didUpdateWidget(SftpPane old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) unawaited(_pollDirectory(force: true));
    if (widget.tab.status == SessionStatus.ready &&
        old.tab.status != SessionStatus.ready) {
      _following || _cwd == null ? _init() : _dir.open(_cwd!);
    }
  }

  @override
  void dispose() {
    _typeAheadTimer?.cancel();
    _directoryTimer?.cancel();
    _directorySession?.currentDirectory.removeListener(_onTerminalDirectory);
    _dir.dispose();
    _listFocus.dispose();
    _pathFocus.dispose();
    _filterFocus.dispose();
    _pathField.dispose();
    _filterField.dispose();
    super.dispose();
  }

  SftpActions? get _actions {
    final session = ref.read(tabsProvider.notifier).sessionOf(widget.tab.id);
    if (session == null) return null;
    return SftpActions(
      tabId: widget.tab.id,
      session: session,
      queue: ref.read(transferQueueProvider.notifier),
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

  Future<void> _init() async {
    _lastReported = null;
    if (_following) {
      if (_directorySession?.currentDirectory.value == null) {
        await _pollDirectory(force: true);
        if (!mounted) return;
      }
      final termDir = _directorySession?.currentDirectory.value;
      if (termDir != null) {
        _lastReported = termDir;
        await _dir.open(termDir);
        if (!mounted) return;
        if (_dir.error == null) return;
      }
    }
    await _dir.home();
    if (!mounted) return;
    _onTerminalDirectory();
  }

  Future<void> _open(String path) => _dir.open(path);

  Future<void> _goBack() async {
    final target = _history.back();
    if (target == null) return;
    _navigatingHistory = true;
    try {
      await _dir.open(target);
    } finally {
      _navigatingHistory = false;
    }
  }

  Future<void> _goForward() async {
    final target = _history.forward();
    if (target == null) return;
    _navigatingHistory = true;
    try {
      await _dir.open(target);
    } finally {
      _navigatingHistory = false;
    }
  }

  Future<void> _refresh() => _dir.refresh();

  void _onDirChanged() {
    if (!mounted) return;
    setState(() {
      if (_dir.loading || !identical(_shownEntries, _dir.entries)) {
        _shownEntries = _dir.entries;
        _selected.clear();
        _anchor = null;
        _cursorPath = null;
      }
      if (!_dir.loading && _dir.error == null && _dir.cwd != null) {
        if (!_navigatingHistory) {
          _history.record(_dir.cwd!);
        }
      }
      final shown = _dir.error != null
          ? (_dir.requestedPath ?? _dir.cwd)
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

  List<RemoteEntry> _computeVisible(AppSettings settings) {
    final query = _filterField.text.trim().toLowerCase();
    final filtered = _entries.where((e) {
      if (!settings.showHiddenFiles && e.isHidden) return false;
      if (query.isNotEmpty && !e.name.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    });
    return sortSftpEntries(
      filtered,
      settings.sftpSortField,
      ascending: settings.sftpSortAscending,
    );
  }

  List<RemoteEntry> get _visible => _computeVisible(ref.read(settingsProvider));

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
    if (widget.tab.isLocal) {
      await _run(() => LocalFiles.openWithSystem(e.path), refresh: false);
      return;
    }
    await _run(
      () async => _actions?.openLocally(
        e,
        onUploaded: (name) => _toast(_s.savedOnServer(name)),
        onError: (message) => _toast(message(_s), error: true),
      ),
      refresh: false,
    );
  }

  Future<void> _editText(RemoteEntry e) async {
    final saved = await openSftpTextEditor(
      context,
      openSession: _sftp,
      entry: e,
      strings: _s,
      onOpenExternally: () => _openLocally(e),
    );
    if (saved && mounted) await _refresh();
  }

  Future<void> _mkdir() async {
    final name = await askText(
      context,
      title: _s.newFolder,
      label: _s.folderName,
    );
    if (name == null || name.isEmpty || _cwd == null) return;
    await _run(() async => (await _sftp()).mkdir(_joinPath(_cwd!, name)));
  }

  Future<void> _mkfile() async {
    final name = await askText(context, title: _s.newFile, label: _s.fileName);
    if (name == null || name.isEmpty || _cwd == null) return;
    final target = _joinPath(_cwd!, name);
    await _run(() async => createEmptySftpFile(await _sftp(), target));
    if (mounted) {
      setState(() {
        _selected
          ..clear()
          ..add(target);
        _anchor = target;
        _cursorPath = target;
      });
    }
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
      () async =>
          (await _sftp()).rename(e.path, _joinPath(_parentOf(e.path), name)),
    );
  }

  Future<void> _moveEntriesInto(
    List<RemoteEntry> entries,
    String targetDir,
  ) async {
    if (entries.isEmpty) return;
    await _run(() async {
      final sftp = await _sftp();
      for (final e in entries) {
        final dest = _joinPath(targetDir, e.name);
        if (dest == e.path) continue;
        await sftp.rename(e.path, dest);
      }
    });
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
    final targetCwd = _cwd;
    final hasDirs = entries.any((e) => e.isDir && !e.isLink);
    if (!hasDirs && entries.length <= 3) {
      await _run(() async => deleteSftpEntries(await _sftp(), entries));
      return;
    }
    try {
      final sftp = await _sftp();
      ref
          .read(transferQueueProvider.notifier)
          .enqueue(
            tabId: widget.tab.id,
            direction: TransferDirection.upload,
            name: '${_s.delete}: ${entries.map((e) => e.name).join(', ')}',
            localPath: '',
            remotePath: targetCwd ?? '',
            total: 0,
            run: (cancel, _) =>
                deleteSftpEntries(sftp, entries, cancel: cancel),
            onSettled: () {
              if (mounted && _cwd == targetCwd) _refresh();
            },
          );
    } catch (e) {
      _toast(_s.errorText(e), error: true);
    }
  }

  void _copyOrCut(List<RemoteEntry> entries, {required bool cut}) {
    if (entries.isEmpty) return;
    ref
        .read(sftpClipboardProvider.notifier)
        .setEntries(
          sourceIdentity: _fsIdentity,
          openSource: _sftp,
          entries: entries,
          cut: cut,
        );
  }

  Future<void> _pasteClipboard() async {
    final clip = ref.read(sftpClipboardProvider);
    final dir = _cwd;
    if (clip == null || clip.entries.isEmpty || dir == null) return;
    await _run(() async {
      final target = await _sftp();
      await pasteSftpClipboard(
        clip: clip,
        targetIdentity: _fsIdentity,
        target: target,
        targetDir: dir,
        joinPath: _joinPath,
        tabId: widget.tab.id,
        queue: ref.read(transferQueueProvider.notifier),
        resolveConflict: _resolveConflict,
        onCompleted: (copied, skipped) {
          if (clip.cut) ref.read(sftpClipboardProvider.notifier).clear();
          _toast(_s.copiedCount(copied, skipped));
        },
        onSettled: () {
          if (mounted && _cwd == dir) _refresh();
        },
      );
    }, refresh: false);
    if (mounted) await _refresh();
  }

  void _openInTerminal(String dirPath) {
    final session = _directorySession;
    if (session == null || widget.tab.status != SessionStatus.ready) return;
    session.terminal.textInput(shellCdCommand(dirPath, windows: _windowsPaths));
  }

  void _insertPathsInTerminal(List<RemoteEntry> entries) {
    final session = _directorySession;
    if (session == null ||
        entries.isEmpty ||
        widget.tab.status != SessionStatus.ready) {
      return;
    }
    final quoted = entries
        .map((e) => shellQuotePath(e.path, windows: _windowsPaths))
        .join(' ');
    session.terminal.paste('$quoted ');
  }

  void _activate(RemoteEntry e) {
    if (e.isDir) {
      _open(e.path);
    } else if (DesktopEnv.isMobile && !widget.tab.isLocal) {
      _editText(e);
    } else {
      _openLocally(e);
    }
  }

  void _select(RemoteEntry e, {bool toggle = false}) {
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
          _cursorPath = e.path;
          return;
        }
      }
      if (toggle || keys.ctrl) {
        _selected.contains(e.path)
            ? _selected.remove(e.path)
            : _selected.add(e.path);
      } else {
        _selected
          ..clear()
          ..add(e.path);
      }
      _anchor = e.path;
      _cursorPath = e.path;
    });
  }

  void _moveCursor(int delta, {bool extend = false, bool toEdge = false}) {
    final list = _visible;
    if (list.isEmpty) return;
    final currentIdx = _cursorPath == null
        ? -1
        : list.indexWhere((e) => e.path == _cursorPath);
    final int nextIdx;
    if (toEdge) {
      nextIdx = delta < 0 ? 0 : list.length - 1;
    } else if (currentIdx < 0) {
      nextIdx = delta < 0 ? list.length - 1 : 0;
    } else {
      nextIdx = (currentIdx + delta).clamp(0, list.length - 1);
    }
    final target = list[nextIdx];
    setState(() {
      if (extend && _anchor != null) {
        final a = list.indexWhere((e) => e.path == _anchor);
        if (a >= 0) {
          _selected
            ..clear()
            ..addAll(
              list
                  .sublist(
                    a < nextIdx ? a : nextIdx,
                    (a < nextIdx ? nextIdx : a) + 1,
                  )
                  .map((e) => e.path),
            );
        } else {
          _selected
            ..clear()
            ..add(target.path);
          _anchor = target.path;
        }
      } else {
        _selected
          ..clear()
          ..add(target.path);
        _anchor = target.path;
      }
      _cursorPath = target.path;
    });
    _scrollToIndex(nextIdx);
  }

  void _scrollToIndex(int visibleIndex) {
    final scroll = _activeScroll;
    if (scroll == null || !scroll.hasClients) return;
    final hasParent = _cwd != null && !_isRoot(_cwd!);
    final rowIndex = visibleIndex + (hasParent ? 1 : 0);
    final compact = Theme.of(context).visualDensity == VisualDensity.compact;
    final itemHeight = compact ? 50.0 : 58.0;
    final top = rowIndex * itemHeight;
    final bottom = top + itemHeight;
    final pos = scroll.position;
    if (top < pos.pixels) {
      scroll.animateTo(
        top,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    } else if (bottom > pos.pixels + pos.viewportDimension) {
      scroll.animateTo(
        (bottom - pos.viewportDimension).clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  KeyEventResult _onListKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = Modifiers.instance;
    if (keys.ctrl || keys.alt || keys.meta) return KeyEventResult.ignored;
    final ch = event.character;
    if (ch == null ||
        ch.isEmpty ||
        ch.codeUnitAt(0) < 0x20 ||
        event.logicalKey == LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    _typeAheadTimer?.cancel();
    _typeAhead = '$_typeAhead${ch.toLowerCase()}';
    _typeAheadTimer = Timer(
      const Duration(milliseconds: 900),
      () => _typeAhead = '',
    );
    final list = _visible;
    final idx = list.indexWhere(
      (e) => e.name.toLowerCase().startsWith(_typeAhead),
    );
    if (idx >= 0) {
      final target = list[idx];
      setState(() {
        _selected
          ..clear()
          ..add(target.path);
        _anchor = target.path;
        _cursorPath = target.path;
      });
      _scrollToIndex(idx);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _contextMenu(RemoteEntry? e, Offset pos) {
    if (e != null && !_selected.contains(e.path)) {
      setState(() {
        _selected
          ..clear()
          ..add(e.path);
        _anchor = e.path;
        _cursorPath = e.path;
      });
    }
    _listFocus.requestFocus();
    final sel = _selection;
    final single = sel.length == 1 ? sel.first : null;
    final error = Theme.of(context).colorScheme.error;
    final sharedAndroid = PlatformCapabilities.sharedDownloads;
    final mac = PlatformCapabilities.isMacOS;
    final clip = ref.read(sftpClipboardProvider);

    _menu.currentState?.open(pos, [
      if (single != null && !single.isDir) ...[
        menuItem(
          _s.editText,
          icon: Icons.edit_note,
          shortcut: SingleActivator(
            LogicalKeyboardKey.keyE,
            control: !mac,
            meta: mac,
          ),
          onPressed: () => _editText(single),
        ),
        menuItem(
          _s.openExternally,
          icon: Icons.open_in_new,
          onPressed: () => _openLocally(single),
        ),
      ],
      if (single != null && single.isDir) ...[
        menuItem(
          _s.openFolder,
          icon: Icons.folder_open,
          onPressed: () => _open(single.path),
        ),
        menuItem(
          _s.openInTerminal,
          icon: Icons.terminal,
          onPressed: () => _openInTerminal(single.path),
        ),
      ],
      if (sel.isNotEmpty) ...[
        menuItem(
          _s.insertPathInTerminal,
          icon: Icons.input,
          onPressed: () => _insertPathsInTerminal(sel),
        ),
        menuItem(
          _s.download,
          icon: Icons.download,
          onPressed: () => _download(sel),
        ),
        if (!sharedAndroid)
          menuItem(
            _s.downloadTo,
            icon: Icons.drive_file_move_outlined,
            onPressed: () => _downloadTo(sel),
          ),
        menuDivider(),
        menuItem(
          _s.copyEntries,
          icon: Icons.copy_outlined,
          shortcut: SingleActivator(
            LogicalKeyboardKey.keyC,
            control: !mac,
            meta: mac,
          ),
          onPressed: () => _copyOrCut(sel, cut: false),
        ),
        menuItem(
          _s.cutEntries,
          icon: Icons.content_cut,
          shortcut: SingleActivator(
            LogicalKeyboardKey.keyX,
            control: !mac,
            meta: mac,
          ),
          onPressed: () => _copyOrCut(sel, cut: true),
        ),
      ],
      if (clip != null && clip.entries.isNotEmpty && _cwd != null)
        menuItem(
          _s.pasteEntries(clip.entries.length),
          icon: Icons.content_paste,
          shortcut: SingleActivator(
            LogicalKeyboardKey.keyV,
            control: !mac,
            meta: mac,
          ),
          onPressed: _pasteClipboard,
        ),
      if (single != null) ...[
        menuItem(
          _s.rename,
          icon: Icons.drive_file_rename_outline,
          shortcut: Keys.rename,
          onPressed: () => _rename(single),
        ),
        if (!widget.tab.isLocal)
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

  List<Widget> _folderItems() {
    final clip = ref.read(sftpClipboardProvider);
    final showHidden = ref.read(settingsProvider).showHiddenFiles;
    final mac = PlatformCapabilities.isMacOS;
    return [
      CheckboxMenuButton(
        value: _following,
        onChanged: (v) => _setFollow(v!),
        child: Text(_s.followTerminalDirectoryTitle),
      ),
      if (_cwd != null)
        menuItem(
          _s.openInTerminal,
          icon: Icons.terminal,
          onPressed: () => _openInTerminal(_cwd!),
        ),
      if (!widget.tab.isLocal &&
          _directorySession?.currentDirectory.value == null)
        menuItem(
          _s.isRu
              ? 'Включить интеграцию оболочки…'
              : 'Enable shell integration…',
          icon: Icons.link,
          onPressed: _enableDirectoryReporting,
        ),
      menuDivider(),
      if (clip != null && clip.entries.isNotEmpty && _cwd != null)
        menuItem(
          _s.pasteEntries(clip.entries.length),
          icon: Icons.content_paste,
          shortcut: SingleActivator(
            LogicalKeyboardKey.keyV,
            control: !mac,
            meta: mac,
          ),
          onPressed: _pasteClipboard,
        ),
      menuItem(
        _s.uploadFiles,
        icon: Icons.upload_file,
        onPressed: _uploadFiles,
      ),
      if (!PlatformCapabilities.sharedDownloads)
        menuItem(
          _s.uploadFolder,
          icon: Icons.drive_folder_upload_outlined,
          onPressed: _uploadFolder,
        ),
      menuItem(_s.newFile, icon: Icons.note_add_outlined, onPressed: _mkfile),
      menuItem(
        _s.newFolder,
        icon: Icons.create_new_folder_outlined,
        onPressed: _mkdir,
      ),
      menuDivider(),
      menuItem(_s.homeFolder, icon: Icons.home_outlined, onPressed: _dir.home),
      menuItem(
        _s.refresh,
        icon: Icons.refresh,
        shortcut: Keys.refresh,
        onPressed: _refresh,
      ),
      CheckboxMenuButton(
        value: showHidden,
        onChanged: (v) =>
            ref.read(settingsProvider.notifier).setShowHiddenFiles(v!),
        child: Text(_s.hiddenFiles),
      ),
    ];
  }

  void _focusPathBar() {
    _pathFocus.requestFocus();
    _pathField.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _pathField.text.length,
    );
  }

  Map<ShortcutActivator, VoidCallback> get _paneShortcuts {
    final mac = PlatformCapabilities.isMacOS;
    return {
      SingleActivator(LogicalKeyboardKey.keyF, control: !mac, meta: mac):
          _toggleFilter,
      SingleActivator(LogicalKeyboardKey.keyL, control: !mac, meta: mac):
          _focusPathBar,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _goBack,
      const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
          _goForward,
    };
  }

  Map<ShortcutActivator, VoidCallback> get _listShortcuts {
    final mac = PlatformCapabilities.isMacOS;
    return {
      Keys.delete: () => _delete(_selection),
      Keys.rename: () {
        final sel = _selection;
        if (sel.length == 1) _rename(sel.first);
      },
      Keys.refresh: _refresh,
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => _moveCursor(1),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => _moveCursor(-1),
      const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): () =>
          _moveCursor(1, extend: true),
      const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): () =>
          _moveCursor(-1, extend: true),
      const SingleActivator(LogicalKeyboardKey.home): () =>
          _moveCursor(-1, toEdge: true),
      const SingleActivator(LogicalKeyboardKey.end): () =>
          _moveCursor(1, toEdge: true),
      const SingleActivator(LogicalKeyboardKey.space): () {
        final path = _cursorPath;
        if (path == null) {
          _moveCursor(1);
          return;
        }
        final e = _visible.where((x) => x.path == path).firstOrNull;
        if (e != null) _select(e, toggle: true);
      },
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (_showFilter) {
          _closeFilter();
        } else if (_selected.isNotEmpty) {
          setState(_selected.clear);
        }
      },
      const SingleActivator(LogicalKeyboardKey.enter): () {
        final sel = _selection;
        if (sel.length == 1) _activate(sel.first);
      },
      SingleActivator(LogicalKeyboardKey.keyE, control: !mac, meta: mac): () {
        final sel = _selection;
        if (sel.length == 1 && !sel.first.isDir) _editText(sel.first);
      },
      SingleActivator(LogicalKeyboardKey.keyC, control: !mac, meta: mac): () =>
          _copyOrCut(_selection, cut: false),
      SingleActivator(LogicalKeyboardKey.keyX, control: !mac, meta: mac): () =>
          _copyOrCut(_selection, cut: true),
      SingleActivator(LogicalKeyboardKey.keyV, control: !mac, meta: mac):
          _pasteClipboard,
      const SingleActivator(LogicalKeyboardKey.backspace): () {
        if (_cwd != null && !_isRoot(_cwd!)) _open(_parentOf(_cwd!));
      },
      SingleActivator(LogicalKeyboardKey.keyA, control: !mac, meta: mac): () =>
          setState(() {
            _selected
              ..clear()
              ..addAll(_visible.map((e) => e.path));
          }),
    };
  }

  // ─── UI ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    ref.watch(sftpClipboardProvider);
    ref.listen<bool>(
      settingsProvider.select((s) => s.followTerminalDirectory),
      (prev, next) {
        setState(() {
          _followOverride = null;
          _followGeneration++;
          if (next) _lastReported = null;
        });
        if (next) {
          _onTerminalDirectory();
          unawaited(_pollDirectory(force: true));
        }
      },
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ready = widget.tab.status == SessionStatus.ready;
    final termDir = _directorySession?.currentDirectory.value;
    final hasParentRow = _cwd != null && !_isRoot(_cwd!);
    final scopeId = 'pane:${widget.tab.id}';

    Widget body;
    if (!ready) {
      body = SftpPlaceholder(
        key: const ValueKey('offline'),
        icon: Icons.cloud_off,
        text: _s.noServerConnection,
      );
    } else if (_error != null) {
      body = SftpPlaceholder(
        key: ValueKey('error:${_dir.requestedPath}'),
        icon: Icons.error_outline,
        text: _error!,
        action: Wrap(
          alignment: WrapAlignment.center,
          children: [
            TextButton(
              onPressed: () => _dir.requestedPath == null
                  ? _init()
                  : _dir.open(_dir.requestedPath!),
              child: Text(_s.tryAgain),
            ),
            TextButton(onPressed: _dir.home, child: Text(_s.homeFolder)),
          ],
        ),
      );
    } else {
      final list = _computeVisible(settings);
      final selectedList = _selection;
      final extraParent = hasParentRow ? 1 : 0;
      final showEmpty = !_loading && list.isEmpty;
      final itemCount = showEmpty ? extraParent + 1 : list.length + extraParent;

      body = CallbackShortcuts(
        key: const ValueKey('list'),
        bindings: _listShortcuts,
        child: Focus(
          focusNode: _listFocus,
          onKeyEvent: _onListKeyEvent,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              _listFocus.requestFocus();
              setState(_selected.clear);
            },
            onSecondaryTapUp: (d) => _contextMenu(null, d.globalPosition),
            child: ScrollEdgeFade(
              top: 18,
              bottom: 14,
              child: SmoothScroll(
                builder: (context, controller) {
                  _activeScroll = controller;
                  return ListView.builder(
                    controller: controller,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: itemCount,
                    itemBuilder: (context, i) {
                      if (hasParentRow && i == 0) {
                        final parentPath = _parentOf(_cwd!);
                        return SftpFolderDropTarget(
                          scopeId: scopeId,
                          targetDirPath: parentPath,
                          enabled: ready,
                          onMoveEntries: (items) =>
                              _moveEntriesInto(items, parentPath),
                          child: SftpEntryRow(
                            entry: null,
                            selected: false,
                            onTap: () => _open(parentPath),
                            onSecondary: (_) {},
                            strings: _s,
                          ),
                        );
                      }
                      if (showEmpty) {
                        final filtering = _filterField.text.trim().isNotEmpty;
                        return SizedBox(
                          height: 180,
                          child: SftpPlaceholder(
                            icon: filtering
                                ? Icons.search_off
                                : Icons.folder_open_outlined,
                            text: filtering
                                ? _s.noMatchingFiles
                                : (_s.isRu
                                      ? 'Папка пуста'
                                      : 'This folder is empty'),
                          ),
                        );
                      }
                      final e = list[i - extraParent];
                      final mobile = DesktopEnv.isMobile;
                      Widget row = SftpEntryRow(
                        entry: e,
                        selected: _selected.contains(e.path),
                        showSelection: mobile && _selected.isNotEmpty,
                        onSelect: mobile
                            ? (_) => _select(e, toggle: true)
                            : null,
                        onIconTap: () => _select(e, toggle: true),
                        onTap: () {
                          if (mobile) {
                            if (_selected.isNotEmpty) {
                              _select(e, toggle: true);
                            } else if (e.isDir) {
                              _open(e.path);
                            } else {
                              _select(e, toggle: true);
                            }
                            return;
                          }
                          final modHeld =
                              Modifiers.instance.ctrl ||
                              Modifiers.instance.shift ||
                              (PlatformCapabilities.isMacOS &&
                                  HardwareKeyboard.instance.isMetaPressed);
                          if (e.isDir && !modHeld) {
                            _open(e.path);
                          } else {
                            _select(e);
                          }
                        },
                        onDoubleTap: e.isDir ? null : () => _activate(e),
                        onSecondary: (pos) => _contextMenu(e, pos),
                        strings: _s,
                      );

                      if (e.isDir) {
                        row = SftpFolderDropTarget(
                          scopeId: scopeId,
                          targetDirPath: e.path,
                          enabled: ready,
                          onMoveEntries: (items) =>
                              _moveEntriesInto(items, e.path),
                          child: row,
                        );
                      }

                      return SftpDragSource(
                        entry: e,
                        scopeId: scopeId,
                        selectedEntries: selectedList,
                        windowsPaths: _windowsPaths,
                        actions: () => _actions,
                        child: row,
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      );
    }

    final fastDur = AppMotion.duration(context, AppMotion.durationFast);

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (!ready) return;
        if (e.buttons == kBackMouseButton && _history.canBack) {
          _goBack();
        } else if (e.buttons == kForwardMouseButton && _history.canForward) {
          _goForward();
        }
      },
      child: CallbackShortcuts(
        bindings: _paneShortcuts,
        child: ContextMenuArea(
          key: _menu,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Material(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: scheme.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              color: scheme.surfaceContainerLow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilePathBar(
                    controller: _pathField,
                    pathFocusNode: _pathFocus,
                    enabled: ready,
                    onOpen: _open,
                    onBack: _history.canBack ? _goBack : null,
                    onForward: _history.canForward ? _goForward : null,
                    onUp: hasParentRow ? () => _open(_parentOf(_cwd!)) : null,
                    onRefresh: _refresh,
                    isRu: _s.isRu,
                    cwd: _cwd,
                    windowsPaths: _windowsPaths,
                    showFilter: _showFilter,
                    filterController: _filterField,
                    filterFocusNode: _filterFocus,
                    onToggleFilter: _toggleFilter,
                    onCloseFilter: _closeFilter,
                    sortField: settings.sftpSortField,
                    sortAscending: settings.sftpSortAscending,
                    onSortSelected: ref
                        .read(settingsProvider.notifier)
                        .setSftpSort,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (ready &&
                            termDir != null &&
                            _cwd != null &&
                            termDir != _cwd)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 34,
                              minHeight: 34,
                            ),
                            iconSize: 20,
                            tooltip: _s.goToTerminalDirectory,
                            onPressed: _jumpToTerminalDirectory,
                            icon: const Icon(Icons.my_location_outlined),
                          ),
                        MenuIconButton(
                          enabled: ready && !_loading && _error == null,
                          items: _folderItems(),
                        ),
                      ],
                    ),
                  ),
                  ExpandSection(
                    expanded:
                        PlatformCapabilities.sharedDownloads &&
                        widget.tab.isLocal &&
                        !_hasStorageAccess,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                      child: Material(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.folder_off_outlined,
                                size: 18,
                                color: scheme.onSecondaryContainer,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _s.isRu
                                      ? 'Нет доступа к памяти устройства'
                                      : 'No access to device storage',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSecondaryContainer,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: _requestStorageAccess,
                                child: Text(_s.isRu ? 'Разрешить' : 'Allow'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  ExpandSection(
                    expanded: _selected.isNotEmpty,
                    spring: AppMotion.spatialFast,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_s.isRu ? 'Выбрано' : 'Selected'}: ${_selected.length}',
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                          IconButton(
                            tooltip: _s.isRu
                                ? 'Снять выделение'
                                : 'Clear selection',
                            onPressed: () => setState(_selected.clear),
                            icon: const Icon(Icons.close),
                          ),
                          IconButton(
                            tooltip: _s.isRu
                                ? 'Скачать выделенное'
                                : 'Download selected',
                            onPressed: () => _download(_selection),
                            icon: const Icon(Icons.download_outlined),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 2,
                    child: AnimatedSwitcher(
                      duration: fastDur,
                      child: _loading
                          ? const LinearProgressIndicator(
                              key: ValueKey('loading'),
                              minHeight: 2,
                            )
                          : const SizedBox.shrink(key: ValueKey('idle')),
                    ),
                  ),
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
                          Positioned.fill(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                              child: Material(
                                color: scheme.surface,
                                borderRadius: BorderRadius.circular(16),
                                clipBehavior: Clip.antiAlias,
                                child: FadeSlideSwitcher(
                                  scaleBegin: 0.99,
                                  offset: const Offset(0, 0.02),
                                  child: body,
                                ),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: AnimatedOpacity(
                                opacity: _dragOver ? 1.0 : 0.0,
                                duration: fastDur,
                                curve: Curves.easeOutCubic,
                                child: AnimatedScale(
                                  scale: _dragOver ? 1.0 : 0.96,
                                  duration: fastDur,
                                  curve: AppMotion.fastSpringCurve,
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
          ),
        ),
      ),
    );
  }
}

String _parentDir(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i <= 0 ? path : path.substring(0, i);
}
