import 'dart:async' show unawaited;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/controllers/transfer_queue.dart';
import '../../app/dependencies.dart';
import '../../app/settings/app_settings.dart';
import '../../app/sftp/file_copy.dart';
import '../../app/sftp/sftp_actions.dart';
import '../../app/sftp/sftp_directory.dart';
import '../../domain/models/session_tab.dart';
import '../../domain/ports/sftp.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import '../../infra/platform/local_files.dart';
import '../../l10n/app_strings.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import '../motion/expressive_segments.dart';
import '../motion/layered_switcher.dart';
import '../motion/smooth_scroll.dart';
import '../shell/ui_state.dart';
import '../widgets/context_menu.dart';
import '../widgets/modifiers.dart';
import 'file_path_bar.dart';
import 'sftp_dialogs.dart';
import 'sftp_drag.dart';
import 'sftp_entry_row.dart';
import 'sftp_text_editor.dart';
import 'transfers_view.dart';

final fileWorkspaceLocalProvider = localFileSessionProvider;

Future<void> showFileWorkspace(BuildContext context) => Navigator.of(
  context,
).push<void>(MaterialPageRoute(builder: (_) => const FileWorkspace()));

class FileWorkspace extends ConsumerStatefulWidget {
  const FileWorkspace({super.key});
  @override
  ConsumerState<FileWorkspace> createState() => _FileWorkspaceState();
}

class _FileWorkspaceState extends ConsumerState<FileWorkspace>
    with SingleTickerProviderStateMixin {
  final _left = GlobalKey<_BrowserState>();
  final _right = GlobalKey<_BrowserState>();
  bool _busy = false;
  bool _rightVisible = false;
  double _ratio = .5;
  bool _splitterHover = false;
  late final AnimationController _ratioAnim = AnimationController.unbounded(
    vsync: this,
    value: .5,
  )..addListener(_onRatioTick);

  void _onRatioTick() {
    if (_ratioAnim.isAnimating && mounted) {
      setState(() => _ratio = _ratioAnim.value.clamp(.3, .7));
    }
  }

  void _resetRatio() {
    if (AppMotion.reduced(context)) {
      setState(() => _ratio = .5);
      return;
    }
    _ratioAnim.value = _ratio;
    AppMotion.springTo(_ratioAnim, .5).whenComplete(() {
      if (mounted) setState(() => _ratio = .5);
    });
  }

  @override
  void dispose() {
    _ratioAnim.dispose();
    super.dispose();
  }

  void _changed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  bool _canCopy(bool right) {
    final source = (right ? _left : _right).currentState;
    final target = (right ? _right : _left).currentState;
    return !_busy &&
        source != null &&
        source.selection.isNotEmpty &&
        source.endpoint != null &&
        !source.directory.loading &&
        source.directory.error == null &&
        target != null &&
        target.endpoint != null &&
        !target.directory.loading &&
        target.directory.error == null &&
        target.directory.cwd != null;
  }

  bool get isRu =>
      AppStrings.of(context, ref.read(settingsProvider).language).isRu;

  Future<void> _enqueueCopy({
    required SftpSession from,
    required SftpSession to,
    required bool sameFilesystem,
    required List<RemoteEntry> entries,
    required String targetDir,
    required VoidCallback onDone,
  }) async {
    if (_busy || entries.isEmpty) return;
    setState(() => _busy = true);
    final int total;
    try {
      total = await estimateTransferBytes(from, entries);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      final strings = AppStrings.of(
        context,
        ref.read(settingsProvider).language,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.errorText(e)),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
      return;
    }
    if (!mounted) return;
    ref
        .read(transferQueueProvider.notifier)
        .enqueue(
          tabId: 'file-workspace',
          direction: TransferDirection.upload,
          name: entries.map((e) => e.name).join(', '),
          localPath: '',
          remotePath: targetDir,
          total: total,
          run: (cancel, progress) async {
            final copier = FileCopy(
              source: from,
              sameFilesystem: sameFilesystem,
              target: to,
              cancel: cancel,
              progress: progress,
              resolve: (path) => mounted
                  ? askCopyConflict(context, path, isRu)
                  : Future.value(const CopyDecision(CopyChoice.cancel)),
            );
            for (final entry in entries) {
              await copier.copy(entry, copier.child(targetDir, entry.name));
            }
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    isRu
                        ? 'Скопировано: ${copier.copied}, пропущено: ${copier.skipped}'
                        : 'Copied: ${copier.copied}, skipped: ${copier.skipped}',
                  ),
                ),
              );
            }
          },
          onSettled: () {
            if (!mounted) return;
            setState(() => _busy = false);
            onDone();
          },
        );
  }

  Future<void> _copy(bool right) async {
    final source = (right ? _left : _right).currentState!;
    final target = (right ? _right : _left).currentState!;
    final entries = source.selection;
    final dir = target.directory.cwd;
    final from = source.endpoint;
    final to = target.endpoint;
    if (entries.isEmpty || dir == null || from == null || to == null) return;
    await _enqueueCopy(
      from: from,
      to: to,
      sameFilesystem: source.identity == target.identity,
      entries: entries,
      targetDir: dir,
      onDone: target.directory.refresh,
    );
  }

  Future<void> _dropInternal({
    required bool toRight,
    required SftpInternalDrag drag,
    String? targetDir,
  }) async {
    final target = (toRight ? _right : _left).currentState;
    final to = target?.endpoint;
    final dir = targetDir ?? target?.directory.cwd;
    if (_busy ||
        target == null ||
        to == null ||
        dir == null ||
        drag.entries.isEmpty) {
      return;
    }
    SftpSession? from;
    String? sourceIdentity;
    if (drag.scopeId == 'workspace:left') {
      from = _left.currentState?.endpoint;
      sourceIdentity = _left.currentState?.identity;
    } else if (drag.scopeId == 'workspace:right') {
      from = _right.currentState?.endpoint;
      sourceIdentity = _right.currentState?.identity;
    } else if (drag.scopeId.startsWith('pane:')) {
      final tabId = drag.scopeId.substring(5);
      final session = ref.read(tabsProvider.notifier).sessionOf(tabId);
      if (session != null) {
        final tab = ref
            .read(tabsProvider)
            .tabs
            .where((t) => t.id == tabId)
            .firstOrNull;
        try {
          from = await session.sftp();
          sourceIdentity = (tab?.isLocal ?? false) ? 'local' : session.target;
        } catch (_) {
          return;
        }
      }
    }
    if (!mounted || from == null || sourceIdentity == null) return;
    await _enqueueCopy(
      from: from,
      to: to,
      sameFilesystem: sourceIdentity == target.identity,
      entries: drag.entries,
      targetDir: dir,
      onDone: target.directory.refresh,
    );
  }

  Future<void> _dropExternalPaths({
    required bool toRight,
    required List<String> paths,
  }) async {
    final target = (toRight ? _right : _left).currentState;
    final to = target?.endpoint;
    final dir = target?.directory.cwd;
    if (_busy || target == null || to == null || dir == null || paths.isEmpty) {
      return;
    }
    final local = ref.read(localFileSessionProvider);
    final List<RemoteEntry> entries;
    try {
      entries = [for (final p in paths) await local.stat(p)];
    } catch (e) {
      if (!mounted) return;
      final strings = AppStrings.of(
        context,
        ref.read(settingsProvider).language,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.errorText(e)),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
      return;
    }
    if (!mounted) return;
    await _enqueueCopy(
      from: local,
      to: to,
      sameFilesystem: target.identity == 'local',
      entries: entries,
      targetDir: dir,
      onDone: target.directory.refresh,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ref
        .watch(tabsProvider)
        .tabs
        .where((t) => !t.isLocal && t.status == SessionStatus.ready)
        .toList();
    final scheme = Theme.of(context).colorScheme;
    final macTop =
        PlatformCapabilities.isMacOS && ref.watch(customTitleBarProvider)
        ? 40.0
        : 0.0;
    return Padding(
      padding: EdgeInsets.only(top: macTop),
      child: Scaffold(
        appBar: AppBar(
          title: Text(isRu ? 'Файлы' : 'Files'),
          actions: [
            AnimatedSwitcher(
              duration: AppMotion.duration(context, AppMotion.durationFast),
              child: _busy
                  ? Padding(
                      key: const ValueKey('busy'),
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          semanticsLabel: isRu
                              ? 'Передача файлов'
                              : 'Transferring files',
                        ),
                      ),
                    )
                  : const SizedBox.shrink(key: ValueKey('idle')),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final wide = box.maxWidth >= 840;
                    Widget browser(bool right) => _Browser(
                      key: right ? _right : _left,
                      scopeId: right ? 'workspace:right' : 'workspace:left',
                      visible: wide || (right == _rightVisible),
                      tabs: tabs,
                      initial: right ? (tabs.firstOrNull?.id ?? '') : '',
                      isRu: isRu,
                      enabled: !_busy,
                      onChanged: _changed,
                      onCopy: _canCopy(!right) ? () => _copy(!right) : null,
                      onDropExternalPaths: (paths) =>
                          _dropExternalPaths(toRight: right, paths: paths),
                      onDropInternal: (drag, targetDir) => _dropInternal(
                        toRight: right,
                        drag: drag,
                        targetDir: targetDir,
                      ),
                      copyLabel: wide
                          ? (right
                                ? (isRu ? 'Копировать влево' : 'Copy to left')
                                : (isRu
                                      ? 'Копировать вправо'
                                      : 'Copy to right'))
                          : (isRu ? 'В другую панель' : 'Copy to other pane'),
                      copyIcon: wide
                          ? (right ? Icons.arrow_back : Icons.arrow_forward)
                          : Icons.copy_outlined,
                      destination:
                          (right ? _left : _right).currentState?.directory.cwd,
                    );
                    if (!wide) {
                      return Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: ExpressiveSegments<bool>(
                              expand: true,
                              segments: [
                                ExpressiveSegment(
                                  value: false,
                                  label: isRu ? 'Левая панель' : 'Left pane',
                                  icon: Icons.folder_outlined,
                                ),
                                ExpressiveSegment(
                                  value: true,
                                  label: isRu ? 'Правая панель' : 'Right pane',
                                  icon: Icons.folder_outlined,
                                ),
                              ],
                              selected: _rightVisible,
                              onChanged: (v) =>
                                  setState(() => _rightVisible = v),
                            ),
                          ),
                          Expanded(
                            child: LayeredSwitcher(
                              index: _rightVisible ? 1 : 0,
                              children: [browser(false), browser(true)],
                            ),
                          ),
                        ],
                      );
                    }
                    final available = box.maxWidth - 12;
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: LayoutBuilder(
                        builder: (context, inner) {
                          final width = inner.maxWidth - 12;
                          return Row(
                            children: [
                              SizedBox(
                                width: width * _ratio,
                                child: browser(false),
                              ),
                              MouseRegion(
                                cursor: SystemMouseCursors.resizeColumn,
                                onEnter: (_) =>
                                    setState(() => _splitterHover = true),
                                onExit: (_) =>
                                    setState(() => _splitterHover = false),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onHorizontalDragUpdate: (d) {
                                    _ratioAnim.stop();
                                    setState(
                                      () => _ratio =
                                          (_ratio + d.delta.dx / available)
                                              .clamp(.3, .7),
                                    );
                                  },
                                  onDoubleTap: _resetRatio,
                                  child: SizedBox(
                                    width: 12,
                                    child: Center(
                                      child: AnimatedContainer(
                                        duration: AppMotion.duration(
                                          context,
                                          AppMotion.durationFast,
                                        ),
                                        width: 4,
                                        height: _splitterHover ? 44 : 28,
                                        decoration: BoxDecoration(
                                          color: _splitterHover
                                              ? scheme.primary.withValues(
                                                  alpha: 0.65,
                                                )
                                              : scheme.outlineVariant,
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(child: browser(true)),
                            ],
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
              const TransfersView(tabId: 'file-workspace'),
            ],
          ),
        ),
      ),
    );
  }
}

class _Browser extends ConsumerStatefulWidget {
  const _Browser({
    super.key,
    required this.scopeId,
    required this.visible,
    required this.tabs,
    required this.initial,
    required this.isRu,
    required this.enabled,
    required this.onChanged,
    required this.onCopy,
    required this.onDropExternalPaths,
    required this.onDropInternal,
    required this.copyLabel,
    required this.copyIcon,
    required this.destination,
  });
  final String scopeId;
  final bool visible;
  final List<SessionTab> tabs;
  final String initial;
  final bool isRu;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback? onCopy;
  final ValueChanged<List<String>> onDropExternalPaths;
  final void Function(SftpInternalDrag drag, String? targetDir) onDropInternal;
  final String copyLabel;
  final IconData copyIcon;
  final String? destination;
  @override
  ConsumerState<_Browser> createState() => _BrowserState();
}

class _BrowserState extends ConsumerState<_Browser> {
  SftpSession? endpoint;
  late String _source = widget.initial;
  late final directory = SftpDirectory(() async {
    if (endpoint == null) throw const SftpFailure(SftpFailureCode.noConnection);
    return endpoint!;
  });
  final _path = TextEditingController();
  final _pathFocus = FocusNode();
  final _filterField = TextEditingController();
  final _filterFocus = FocusNode();
  final _listFocus = FocusNode();
  final _history = SftpPathHistory();
  final _selected = <String>{};
  final _menu = GlobalKey<ContextMenuAreaState>();
  bool _hasStorageAccess = true;
  bool _showFilter = false;
  bool _dragOver = false;
  bool _navigatingHistory = false;
  int _request = 0;
  List<RemoteEntry> _previous = const [];
  String? _anchor;
  String? _cursorPath;
  ScrollController? _activeScroll;

  bool get _isLocal => _source.isEmpty;
  bool get _windowsPaths => _isLocal && PlatformCapabilities.isWindows;

  String _parentOf(String path) =>
      _isLocal ? LocalFiles.parentPath(path) : remoteParent(path);
  String _joinPath(String dir, String name) =>
      _isLocal ? LocalFiles.join(dir, name) : remoteJoin(dir, name);
  bool _isRoot(String path) =>
      _isLocal ? LocalFiles.isRootPath(path) : path == '/';

  AppStrings get _s =>
      AppStrings.of(context, ref.read(settingsProvider).language);

  String get _localLabel => PlatformCapabilities.sharedDownloads
      ? (_hasStorageAccess
            ? (widget.isRu ? 'Память устройства' : 'Device storage')
            : (widget.isRu ? 'Файлы приложения' : 'App files'))
      : (widget.isRu ? 'Этот компьютер' : 'This computer');

  String get _sourceTitle => _source.isEmpty
      ? _localLabel
      : widget.tabs.where((t) => t.id == _source).firstOrNull?.title ??
            (widget.isRu ? 'Подключение закрыто' : 'Connection closed');

  Future<void> _checkStorageAccess() async {
    if (!PlatformCapabilities.sharedDownloads) return;
    final ok = await LocalFiles.hasStorageAccess();
    if (mounted && ok != _hasStorageAccess) {
      setState(() => _hasStorageAccess = ok);
    }
  }

  Future<void> _requestStorageAccess() async {
    final granted = await LocalFiles.requestStorageAccess();
    if (!mounted) return;
    setState(() => _hasStorageAccess = granted);
    if (granted && _source.isEmpty) {
      await directory.home();
    }
  }

  void _select(
    RemoteEntry entry,
    List<RemoteEntry> entries, {
    bool toggle = false,
  }) {
    _listFocus.requestFocus();
    setState(() {
      if (Modifiers.instance.shift && _anchor != null) {
        final a = entries.indexWhere((e) => e.path == _anchor);
        final b = entries.indexOf(entry);
        if (a >= 0 && b >= 0) {
          if (!Modifiers.instance.ctrl) _selected.clear();
          _selected.addAll(
            entries
                .sublist(a < b ? a : b, (a > b ? a : b) + 1)
                .map((e) => e.path),
          );
          _cursorPath = entry.path;
        }
      } else {
        final remove = _selected.contains(entry.path);
        if (!toggle &&
            !Modifiers.instance.ctrl &&
            !HardwareKeyboard.instance.isMetaPressed) {
          _selected.clear();
        }
        if (remove &&
            (toggle ||
                Modifiers.instance.ctrl ||
                HardwareKeyboard.instance.isMetaPressed)) {
          _selected.remove(entry.path);
        } else {
          _selected.add(entry.path);
        }
        _anchor = entry.path;
        _cursorPath = entry.path;
      }
    });
    widget.onChanged();
  }

  void _clear() {
    setState(_selected.clear);
    widget.onChanged();
  }

  String get identity => _source.isEmpty
      ? 'local'
      : ref.read(tabsProvider.notifier).sessionOf(_source)?.target ?? _source;

  List<RemoteEntry> get selection =>
      directory.entries.where((e) => _selected.contains(e.path)).toList();

  List<RemoteEntry> _computeVisible(AppSettings settings) {
    final query = _filterField.text.trim().toLowerCase();
    final filtered = directory.entries.where((e) {
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

  @override
  void didUpdateWidget(_Browser old) {
    super.didUpdateWidget(old);
    if (_source.isEmpty) return;
    final alive = widget.tabs.any((t) => t.id == _source);
    if (!alive && endpoint != null) {
      _request++;
      endpoint = null;
      _selected.clear();
      widget.onChanged();
    } else if (alive && !old.tabs.any((t) => t.id == _source)) {
      _connect();
    }
  }

  @override
  void initState() {
    super.initState();
    _filterField.addListener(() {
      if (mounted) setState(() {});
    });
    directory.addListener(_changed);
    unawaited(_checkStorageAccess());
    _connect();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (!identical(_previous, directory.entries)) {
        _previous = directory.entries;
        _selected.clear();
        _anchor = null;
        _cursorPath = null;
      }
      if (!directory.loading) {
        if (directory.error == null &&
            directory.cwd != null &&
            !_navigatingHistory) {
          _history.record(directory.cwd!);
        }
        _path.text =
            (directory.error != null
                ? directory.requestedPath
                : directory.cwd) ??
            '';
      }
    });
    widget.onChanged();
  }

  Future<void> _connect() async {
    final request = ++_request;
    endpoint = null;
    _selected.clear();
    _history.clear();
    try {
      final connected = _source.isEmpty
          ? ref.read(fileWorkspaceLocalProvider)
          : await ref.read(tabsProvider.notifier).sessionOf(_source)!.sftp();
      if (!mounted || request != _request) return;
      endpoint = connected;
      await directory.home();
    } catch (e) {
      if (mounted && request == _request) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_s.errorText(e))));
      }
    }
  }

  Future<void> _open(String path) async {
    _selected.clear();
    await directory.open(path);
  }

  Future<void> _goBack() async {
    final target = _history.back();
    if (target == null) return;
    _navigatingHistory = true;
    try {
      await _open(target);
    } finally {
      _navigatingHistory = false;
    }
  }

  Future<void> _goForward() async {
    final target = _history.forward();
    if (target == null) return;
    _navigatingHistory = true;
    try {
      await _open(target);
    } finally {
      _navigatingHistory = false;
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

  Future<void> _run(Future<void> Function() fn) async {
    try {
      await fn();
      if (mounted) await directory.refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_s.errorText(e)),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
    }
  }

  Future<void> _mkdir() async {
    final cwd = directory.cwd;
    if (cwd == null || endpoint == null) return;
    final name = await askText(
      context,
      title: _s.newFolder,
      label: _s.folderName,
    );
    if (name == null || name.isEmpty) return;
    await _run(() => endpoint!.mkdir(_joinPath(cwd, name)));
  }

  Future<void> _mkfile() async {
    final cwd = directory.cwd;
    if (cwd == null || endpoint == null) return;
    final name = await askText(context, title: _s.newFile, label: _s.fileName);
    if (name == null || name.isEmpty) return;
    await _run(() => createEmptySftpFile(endpoint!, _joinPath(cwd, name)));
  }

  Future<void> _rename(RemoteEntry e) async {
    if (endpoint == null) return;
    final name = await askText(
      context,
      title: _s.rename,
      label: _s.newNameHint,
      initial: e.name,
    );
    if (name == null || name.isEmpty || name == e.name) return;
    await _run(
      () => endpoint!.rename(e.path, _joinPath(_parentOf(e.path), name)),
    );
  }

  SftpActions? get _actions {
    if (_isLocal) return null;
    final session = ref.read(tabsProvider.notifier).sessionOf(_source);
    if (session == null) return null;
    return SftpActions(
      tabId: 'file-workspace',
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

  Future<void> _moveEntriesInto(
    List<RemoteEntry> items,
    String targetDir,
  ) async {
    if (items.isEmpty || endpoint == null) return;
    await _run(() async {
      for (final e in items) {
        final dest = _joinPath(targetDir, e.name);
        if (dest == e.path) continue;
        await endpoint!.rename(e.path, dest);
      }
    });
  }

  Future<void> _chmod(RemoteEntry e) async {
    if (endpoint == null) return;
    final mode = await askPermissions(context, e);
    if (mode == null) return;
    await _run(() => endpoint!.chmod(e.path, mode));
  }

  Future<void> _delete(List<RemoteEntry> entries) async {
    if (entries.isEmpty || endpoint == null) return;
    final ok = await confirmDelete(context, entries);
    if (!ok) return;
    await _run(() => deleteSftpEntries(endpoint!, entries));
  }

  Future<void> _editText(RemoteEntry e) async {
    if (endpoint == null) return;
    final saved = await openSftpTextEditor(
      context,
      openSession: () async => endpoint!,
      entry: e,
      strings: _s,
    );
    if (saved && mounted) await directory.refresh();
  }

  void _moveCursor(
    List<RemoteEntry> list,
    int delta, {
    bool extend = false,
    bool toEdge = false,
  }) {
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
    widget.onChanged();
    final scroll = _activeScroll;
    if (scroll != null && scroll.hasClients) {
      final hasParent = directory.cwd != null && !_isRoot(directory.cwd!);
      final rowIdx = nextIdx + (hasParent ? 1 : 0);
      final h = Theme.of(context).visualDensity == VisualDensity.compact
          ? 50.0
          : 58.0;
      final top = rowIdx * h;
      final bottom = top + h;
      final pos = scroll.position;
      if (top < pos.pixels) {
        scroll.jumpTo(top);
      } else if (bottom > pos.pixels + pos.viewportDimension) {
        scroll.jumpTo(
          (bottom - pos.viewportDimension).clamp(0.0, pos.maxScrollExtent),
        );
      }
    }
  }

  List<Widget> _folderMenuItems(AppStrings strings, bool showHidden) => [
    menuItem(
      strings.newFile,
      icon: Icons.note_add_outlined,
      onPressed: widget.enabled ? _mkfile : null,
    ),
    menuItem(
      strings.newFolder,
      icon: Icons.create_new_folder_outlined,
      onPressed: widget.enabled ? _mkdir : null,
    ),
    menuDivider(),
    menuItem(
      strings.homeFolder,
      icon: Icons.home_outlined,
      onPressed: widget.enabled
          ? () {
              _clear();
              directory.home();
            }
          : null,
    ),
    menuItem(
      strings.refresh,
      icon: Icons.refresh,
      shortcut: Keys.refresh,
      onPressed: widget.enabled
          ? () {
              _clear();
              directory.refresh();
            }
          : null,
    ),
    CheckboxMenuButton(
      value: showHidden,
      onChanged: (v) =>
          ref.read(settingsProvider.notifier).setShowHiddenFiles(v!),
      child: Text(strings.hiddenFiles),
    ),
  ];

  void _openEntryMenu(
    Offset position,
    RemoteEntry? entry,
    List<RemoteEntry> entries,
    AppStrings strings,
    bool showHidden,
  ) {
    if (entry != null && !_selected.contains(entry.path)) {
      setState(() {
        _selected
          ..clear()
          ..add(entry.path);
        _anchor = entry.path;
        _cursorPath = entry.path;
      });
      widget.onChanged();
    }
    final sel = selection;
    final single = sel.length == 1 ? sel.first : null;
    final mac = PlatformCapabilities.isMacOS;
    final errorColor = Theme.of(context).colorScheme.error;

    _menu.currentState?.open(position, [
      if (single != null && !single.isDir)
        menuItem(
          strings.editText,
          icon: Icons.edit_note,
          shortcut: SingleActivator(
            LogicalKeyboardKey.keyE,
            control: !mac,
            meta: mac,
          ),
          onPressed: widget.enabled ? () => _editText(single) : null,
        ),
      if (single != null && single.isDir)
        menuItem(
          strings.openFolder,
          icon: Icons.folder_open,
          onPressed: widget.enabled ? () => _open(single.path) : null,
        ),
      if (entry != null)
        menuItem(
          _selected.contains(entry.path)
              ? strings.deselectEntry
              : strings.selectEntry,
          icon: Icons.check_box_outlined,
          onPressed: widget.enabled
              ? () => _select(entry, entries, toggle: true)
              : null,
        ),
      if (single != null) ...[
        menuItem(
          strings.rename,
          icon: Icons.drive_file_rename_outline,
          shortcut: Keys.rename,
          onPressed: widget.enabled ? () => _rename(single) : null,
        ),
        if (!_isLocal)
          menuItem(
            strings.permissions,
            icon: Icons.lock_outline,
            onPressed: widget.enabled ? () => _chmod(single) : null,
          ),
        menuItem(
          strings.copyPath,
          icon: Icons.content_copy,
          onPressed: () => Clipboard.setData(ClipboardData(text: single.path)),
        ),
      ],
      if (sel.isNotEmpty) ...[
        menuItem(
          strings.delete,
          icon: Icons.delete_outline,
          shortcut: Keys.delete,
          color: errorColor,
          onPressed: widget.enabled ? () => _delete(sel) : null,
        ),
        menuDivider(),
      ],
      ..._folderMenuItems(strings, showHidden),
    ]);
  }

  @override
  void dispose() {
    _request++;
    directory.dispose();
    _path.dispose();
    _pathFocus.dispose();
    _filterField.dispose();
    _filterFocus.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final entries = _computeVisible(settings);
    final strings = AppStrings.of(context, settings.language);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasParentRow = directory.cwd != null && !_isRoot(directory.cwd!);
    final mac = PlatformCapabilities.isMacOS;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        if (!widget.enabled || endpoint == null) return;
        if (e.buttons == kBackMouseButton && _history.canBack) {
          _goBack();
        } else if (e.buttons == kForwardMouseButton && _history.canForward) {
          _goForward();
        }
      },
      child: CallbackShortcuts(
        bindings: {
          SingleActivator(LogicalKeyboardKey.keyF, control: !mac, meta: mac):
              _toggleFilter,
          SingleActivator(
            LogicalKeyboardKey.keyL,
            control: !mac,
            meta: mac,
          ): () {
            _pathFocus.requestFocus();
            _path.selection = TextSelection(
              baseOffset: 0,
              extentOffset: _path.text.length,
            );
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              _goBack,
          const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
              _goForward,
        },
        child: ContextMenuArea(
          key: _menu,
          child: Card.filled(
            color: scheme.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: MenuAnchor(
                          menuChildren: [
                            MenuItemButton(
                              leadingIcon: const Icon(Icons.computer_outlined),
                              trailingIcon: _source.isEmpty
                                  ? const Icon(Icons.check)
                                  : null,
                              onPressed: widget.enabled
                                  ? () {
                                      setState(() => _source = '');
                                      _connect();
                                    }
                                  : null,
                              child: Text(_localLabel),
                            ),
                            if (widget.tabs.isNotEmpty) menuDivider(),
                            for (final t in widget.tabs)
                              MenuItemButton(
                                leadingIcon: const Icon(Icons.dns_outlined),
                                trailingIcon: t.id == _source
                                    ? const Icon(Icons.check)
                                    : null,
                                onPressed: widget.enabled
                                    ? () {
                                        setState(() => _source = t.id);
                                        _connect();
                                      }
                                    : null,
                                child: Text(t.title),
                              ),
                          ],
                          builder: (context, menu, _) => TextButton(
                            onPressed: !widget.enabled
                                ? null
                                : () =>
                                      menu.isOpen ? menu.close() : menu.open(),
                            style: TextButton.styleFrom(
                              foregroundColor: scheme.onSurface,
                              minimumSize: const Size(48, 44),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _source.isEmpty
                                      ? Icons.computer_outlined
                                      : Icons.dns_outlined,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _sourceTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall,
                                  ),
                                ),
                                const Icon(Icons.expand_more),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (directory.cwd != null)
                        Text(
                          '${entries.length}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                FilePathBar(
                  controller: _path,
                  pathFocusNode: _pathFocus,
                  enabled: widget.enabled && endpoint != null,
                  onOpen: _open,
                  onBack: _history.canBack ? _goBack : null,
                  onForward: _history.canForward ? _goForward : null,
                  isRu: widget.isRu,
                  cwd: directory.cwd,
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
                  onUp: hasParentRow
                      ? () => _open(_parentOf(directory.cwd!))
                      : null,
                  onRefresh: () {
                    _clear();
                    directory.refresh();
                  },
                  trailing: MenuIconButton(
                    enabled:
                        widget.enabled &&
                        endpoint != null &&
                        !directory.loading &&
                        directory.error == null,
                    items: _folderMenuItems(strings, settings.showHiddenFiles),
                  ),
                ),
                ExpandSection(
                  expanded:
                      PlatformCapabilities.sharedDownloads &&
                      _isLocal &&
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
                                widget.isRu
                                    ? 'Показана папка приложения. Разрешите доступ к файлам устройства.'
                                    : 'Showing app folder. Allow access to device files.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _requestStorageAccess,
                              child: Text(widget.isRu ? 'Разрешить' : 'Allow'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 2,
                  child: AnimatedSwitcher(
                    duration: AppMotion.duration(
                      context,
                      AppMotion.durationFast,
                    ),
                    child: directory.loading
                        ? const LinearProgressIndicator(
                            key: ValueKey('loading'),
                            minHeight: 2,
                          )
                        : const SizedBox.shrink(key: ValueKey('idle')),
                  ),
                ),
                Expanded(
                  child: SftpDropZone(
                    scopeId: widget.scopeId,
                    enabled:
                        widget.visible &&
                        widget.enabled &&
                        endpoint != null &&
                        directory.error == null &&
                        directory.cwd != null,
                    onHover: (over) {
                      if (mounted && _dragOver != over) {
                        setState(() => _dragOver = over);
                      }
                    },
                    onDropPaths: (paths) {
                      if (mounted) setState(() => _dragOver = false);
                      widget.onDropExternalPaths(paths);
                    },
                    onDropInternal: (drag) {
                      if (mounted) setState(() => _dragOver = false);
                      widget.onDropInternal(drag, null);
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
                                child: directory.error != null
                                    ? SftpPlaceholder(
                                        key: ValueKey(
                                          'error:${directory.requestedPath}',
                                        ),
                                        icon: Icons.error_outline,
                                        text: strings.errorText(
                                          directory.error!,
                                        ),
                                        action: Wrap(
                                          alignment: WrapAlignment.center,
                                          children: [
                                            if (PlatformCapabilities
                                                    .sharedDownloads &&
                                                _isLocal &&
                                                !_hasStorageAccess)
                                              FilledButton.tonal(
                                                onPressed:
                                                    _requestStorageAccess,
                                                child: Text(
                                                  widget.isRu
                                                      ? 'Разрешить доступ'
                                                      : 'Allow access',
                                                ),
                                              ),
                                            TextButton(
                                              onPressed: () =>
                                                  directory.refresh(),
                                              child: Text(strings.tryAgain),
                                            ),
                                            TextButton(
                                              onPressed: () {
                                                _clear();
                                                directory.home();
                                              },
                                              child: Text(strings.homeFolder),
                                            ),
                                          ],
                                        ),
                                      )
                                    : !directory.loading &&
                                          entries.isEmpty &&
                                          !hasParentRow
                                    ? SftpPlaceholder(
                                        key: const ValueKey('empty'),
                                        icon:
                                            _filterField.text.trim().isNotEmpty
                                            ? Icons.search_off
                                            : Icons.folder_open_outlined,
                                        text:
                                            _filterField.text.trim().isNotEmpty
                                            ? strings.noMatchingFiles
                                            : (widget.isRu
                                                  ? 'Папка пуста'
                                                  : 'This folder is empty'),
                                      )
                                    : CallbackShortcuts(
                                        key: const ValueKey('list'),
                                        bindings: {
                                          Keys.delete: () => _delete(selection),
                                          Keys.rename: () {
                                            final sel = selection;
                                            if (sel.length == 1) {
                                              _rename(sel.first);
                                            }
                                          },
                                          Keys.refresh: () {
                                            _clear();
                                            directory.refresh();
                                          },
                                          const SingleActivator(
                                            LogicalKeyboardKey.arrowDown,
                                          ): () =>
                                              _moveCursor(entries, 1),
                                          const SingleActivator(
                                            LogicalKeyboardKey.arrowUp,
                                          ): () =>
                                              _moveCursor(entries, -1),
                                          const SingleActivator(
                                            LogicalKeyboardKey.arrowDown,
                                            shift: true,
                                          ): () => _moveCursor(
                                            entries,
                                            1,
                                            extend: true,
                                          ),
                                          const SingleActivator(
                                            LogicalKeyboardKey.arrowUp,
                                            shift: true,
                                          ): () => _moveCursor(
                                            entries,
                                            -1,
                                            extend: true,
                                          ),
                                          const SingleActivator(
                                            LogicalKeyboardKey.home,
                                          ): () => _moveCursor(
                                            entries,
                                            -1,
                                            toEdge: true,
                                          ),
                                          const SingleActivator(
                                            LogicalKeyboardKey.end,
                                          ): () => _moveCursor(
                                            entries,
                                            1,
                                            toEdge: true,
                                          ),
                                          const SingleActivator(
                                            LogicalKeyboardKey.space,
                                          ): () {
                                            final p = _cursorPath;
                                            if (p == null) {
                                              _moveCursor(entries, 1);
                                              return;
                                            }
                                            final e = entries
                                                .where((x) => x.path == p)
                                                .firstOrNull;
                                            if (e != null) {
                                              _select(e, entries, toggle: true);
                                            }
                                          },
                                          SingleActivator(
                                            LogicalKeyboardKey.keyA,
                                            control: !mac,
                                            meta: mac,
                                          ): () {
                                            setState(
                                              () => _selected.addAll(
                                                entries.map((e) => e.path),
                                              ),
                                            );
                                            widget.onChanged();
                                          },
                                          const SingleActivator(
                                            LogicalKeyboardKey.escape,
                                          ): () {
                                            if (_showFilter) {
                                              _closeFilter();
                                            } else {
                                              _clear();
                                            }
                                          },
                                          const SingleActivator(
                                            LogicalKeyboardKey.backspace,
                                          ): () {
                                            if (hasParentRow) {
                                              _open(_parentOf(directory.cwd!));
                                            }
                                          },
                                          SingleActivator(
                                            LogicalKeyboardKey.keyE,
                                            control: !mac,
                                            meta: mac,
                                          ): () {
                                            final sel = selection;
                                            if (widget.enabled &&
                                                sel.length == 1 &&
                                                !sel.single.isDir) {
                                              _editText(sel.single);
                                            }
                                          },
                                          const SingleActivator(
                                            LogicalKeyboardKey.enter,
                                          ): () {
                                            final sel = selection;
                                            if (!widget.enabled ||
                                                sel.length != 1) {
                                              return;
                                            }
                                            if (sel.single.isDir) {
                                              _open(sel.single.path);
                                            } else {
                                              _editText(sel.single);
                                            }
                                          },
                                        },
                                        child: Focus(
                                          focusNode: _listFocus,
                                          child: GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap: () {
                                              _listFocus.requestFocus();
                                              _clear();
                                            },
                                            onSecondaryTapUp: (d) =>
                                                _openEntryMenu(
                                                  d.globalPosition,
                                                  null,
                                                  entries,
                                                  strings,
                                                  settings.showHiddenFiles,
                                                ),
                                            child: ScrollEdgeFade(
                                              top: 18,
                                              bottom: 14,
                                              child: SmoothScroll(
                                                builder: (context, controller) {
                                                  _activeScroll = controller;
                                                  final selectedList =
                                                      selection;
                                                  final extra = hasParentRow
                                                      ? 1
                                                      : 0;
                                                  final showEmpty =
                                                      !directory.loading &&
                                                      entries.isEmpty;
                                                  return ListView.builder(
                                                    controller: controller,
                                                    padding:
                                                        const EdgeInsets.only(
                                                          bottom: 8,
                                                        ),
                                                    itemCount: showEmpty
                                                        ? extra + 1
                                                        : entries.length +
                                                              extra,
                                                    itemBuilder: (context, i) {
                                                      if (hasParentRow &&
                                                          i == 0) {
                                                        final parentPath =
                                                            _parentOf(
                                                              directory.cwd!,
                                                            );
                                                        return SftpFolderDropTarget(
                                                          scopeId:
                                                              widget.scopeId,
                                                          targetDirPath:
                                                              parentPath,
                                                          enabled:
                                                              widget.visible &&
                                                              widget.enabled &&
                                                              endpoint != null,
                                                          onMoveEntries: (items) =>
                                                              _moveEntriesInto(
                                                                items,
                                                                parentPath,
                                                              ),
                                                          onCopyExternal:
                                                              (drag) => widget
                                                                  .onDropInternal(
                                                                    drag,
                                                                    parentPath,
                                                                  ),
                                                          child: SftpEntryRow(
                                                            entry: null,
                                                            selected: false,
                                                            showSelection:
                                                                false,
                                                            enabled:
                                                                widget.enabled,
                                                            strings: strings,
                                                            onTap: () => _open(
                                                              parentPath,
                                                            ),
                                                            onSecondary: (_) {},
                                                          ),
                                                        );
                                                      }
                                                      if (showEmpty) {
                                                        final filtering =
                                                            _filterField.text
                                                                .trim()
                                                                .isNotEmpty;
                                                        return SizedBox(
                                                          height: 180,
                                                          child: SftpPlaceholder(
                                                            icon: filtering
                                                                ? Icons
                                                                      .search_off
                                                                : Icons
                                                                      .folder_open_outlined,
                                                            text: filtering
                                                                ? strings
                                                                      .noMatchingFiles
                                                                : (widget.isRu
                                                                      ? 'Папка пуста'
                                                                      : 'This folder is empty'),
                                                          ),
                                                        );
                                                      }
                                                      final entry =
                                                          entries[i - extra];
                                                      void open() {
                                                        if (widget.enabled &&
                                                            entry.isDir) {
                                                          _open(entry.path);
                                                        }
                                                      }

                                                      Widget row = SftpEntryRow(
                                                        entry: entry,
                                                        enabled: widget.enabled,
                                                        showSelection: true,
                                                        selected: _selected
                                                            .contains(
                                                              entry.path,
                                                            ),
                                                        strings: strings,
                                                        onSelect: widget.enabled
                                                            ? (_) => _select(
                                                                entry,
                                                                entries,
                                                                toggle: true,
                                                              )
                                                            : null,
                                                        onIconTap:
                                                            widget.enabled
                                                            ? () => _select(
                                                                entry,
                                                                entries,
                                                                toggle: true,
                                                              )
                                                            : null,
                                                        onTap: () {
                                                          if (!widget.enabled) {
                                                            return;
                                                          }
                                                          final modHeld =
                                                              !DesktopEnv
                                                                  .isMobile &&
                                                              (Modifiers
                                                                      .instance
                                                                      .ctrl ||
                                                                  Modifiers
                                                                      .instance
                                                                      .shift ||
                                                                  (PlatformCapabilities
                                                                          .isMacOS &&
                                                                      HardwareKeyboard
                                                                          .instance
                                                                          .isMetaPressed));
                                                          if (entry.isDir &&
                                                              !modHeld) {
                                                            open();
                                                          } else {
                                                            _select(
                                                              entry,
                                                              entries,
                                                            );
                                                          }
                                                        },
                                                        onDoubleTap: entry.isDir
                                                            ? null
                                                            : () => _editText(
                                                                entry,
                                                              ),
                                                        onSecondary:
                                                            (
                                                              position,
                                                            ) => _openEntryMenu(
                                                              position,
                                                              entry,
                                                              entries,
                                                              strings,
                                                              settings
                                                                  .showHiddenFiles,
                                                            ),
                                                      );

                                                      if (entry.isDir) {
                                                        row = SftpFolderDropTarget(
                                                          scopeId:
                                                              widget.scopeId,
                                                          targetDirPath:
                                                              entry.path,
                                                          enabled:
                                                              widget.visible &&
                                                              widget.enabled &&
                                                              endpoint != null,
                                                          onMoveEntries: (items) =>
                                                              _moveEntriesInto(
                                                                items,
                                                                entry.path,
                                                              ),
                                                          onCopyExternal:
                                                              (drag) => widget
                                                                  .onDropInternal(
                                                                    drag,
                                                                    entry.path,
                                                                  ),
                                                          child: row,
                                                        );
                                                      }

                                                      return SftpDragSource(
                                                        entry: entry,
                                                        scopeId: widget.scopeId,
                                                        selectedEntries:
                                                            selectedList,
                                                        windowsPaths:
                                                            _windowsPaths,
                                                        localFiles: _isLocal,
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
                                      ),
                              ),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: IgnorePointer(
                            child: AnimatedOpacity(
                              opacity: _dragOver ? 1.0 : 0.0,
                              duration: AppMotion.duration(
                                context,
                                AppMotion.durationFast,
                              ),
                              curve: Curves.easeOutCubic,
                              child: AnimatedScale(
                                scale: _dragOver ? 1.0 : 0.96,
                                duration: AppMotion.duration(
                                  context,
                                  AppMotion.durationFast,
                                ),
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
                                          strings.dropToUpload(
                                            directory.cwd ?? '',
                                          ),
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
                ExpandSection(
                  expanded: _selected.isNotEmpty,
                  spring: AppMotion.spatialFast,
                  child: Material(
                    color: scheme.secondaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 16, right: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${widget.isRu ? 'Выбрано' : 'Selected'}: ${_selected.length}',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: scheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: widget.isRu
                                ? 'Снять выделение'
                                : 'Clear selection',
                            onPressed: _clear,
                            icon: const Icon(Icons.close),
                          ),
                          Tooltip(
                            message:
                                widget.destination ??
                                (widget.isRu
                                    ? 'Выберите папку назначения'
                                    : 'Choose destination folder'),
                            child: TextButton.icon(
                              onPressed: widget.onCopy,
                              icon: Icon(widget.copyIcon),
                              label: Text(widget.copyLabel),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<CopyDecision> askCopyConflict(
  BuildContext context,
  String path,
  bool isRu,
) async {
  var all = false;
  return await showDialog<CopyDecision>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(isRu ? 'Файл уже существует' : 'File already exists'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(path),
                Text(
                  isRu
                      ? 'Содержимое отличается. Папки объединяются; заменить файл папкой или папку файлом нельзя.'
                      : 'Contents differ. Folders are merged; replacing a folder with a file or a file with a folder is unsupported.',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(isRu ? 'Применить ко всем' : 'Apply to all'),
                  value: all,
                  onChanged: (v) => setState(() => all = v!),
                ),
              ],
            ),
            actions: [
              for (final option in CopyChoice.values)
                TextButton(
                  onPressed: () => Navigator.pop(
                    context,
                    CopyDecision(option, applyToAll: all),
                  ),
                  child: Text(switch (option) {
                    CopyChoice.replace => isRu ? 'Заменить' : 'Replace',
                    CopyChoice.skip => isRu ? 'Пропустить' : 'Skip',
                    CopyChoice.keepBoth => isRu ? 'Сохранить оба' : 'Keep both',
                    CopyChoice.cancel => isRu ? 'Отмена' : 'Cancel',
                  }),
                ),
            ],
          ),
        ),
      ) ??
      const CopyDecision(CopyChoice.cancel);
}
