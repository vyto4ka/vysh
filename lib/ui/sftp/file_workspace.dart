import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/controllers/transfer_queue.dart';
import '../../app/sftp/file_copy.dart';
import '../../app/sftp/sftp_directory.dart';
import '../../domain/models/session_tab.dart';
import '../../domain/ports/sftp.dart';
import '../../app/dependencies.dart';
import '../../infra/platform/capabilities.dart';
import '../../l10n/app_strings.dart';
import 'transfers_view.dart';
import 'file_path_bar.dart';
import 'sftp_entry_row.dart';
import '../widgets/modifiers.dart';
import '../widgets/context_menu.dart';
import 'package:flutter/services.dart';
import '../../infra/platform/desktop_env.dart';

final fileWorkspaceLocalProvider = localFileSessionProvider;

Future<void> showFileWorkspace(BuildContext context) => Navigator.of(
  context,
).push<void>(MaterialPageRoute(builder: (_) => const FileWorkspace()));

class FileWorkspace extends ConsumerStatefulWidget {
  const FileWorkspace({super.key});
  @override
  ConsumerState<FileWorkspace> createState() => _FileWorkspaceState();
}

class _FileWorkspaceState extends ConsumerState<FileWorkspace> {
  final _left = GlobalKey<_BrowserState>();
  final _right = GlobalKey<_BrowserState>();
  bool _busy = false;
  bool _rightVisible = false;
  double _ratio = .5;
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
  Future<void> _copy(bool right) async {
    final source = (right ? _left : _right).currentState!;
    final target = (right ? _right : _left).currentState!;
    final entries = source.selection;
    final dir = target.directory.cwd;
    if (entries.isEmpty || dir == null) return;
    final sameFilesystem = source.identity == target.identity;
    final from = source.endpoint;
    final to = target.endpoint;
    if (from == null || to == null) return;
    setState(() => _busy = true);
    // Capture source/target before queueing: changing a dropdown cannot redirect a copy.
    ref
        .read(transferQueueProvider.notifier)
        .enqueue(
          tabId: 'file-workspace',
          direction: TransferDirection.upload,
          name: entries.map((e) => e.name).join(', '),
          localPath: '',
          remotePath: dir,
          total: 0,
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
              await copier.copy(entry, copier.child(dir, entry.name));
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
            target.directory.refresh();
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ref
        .watch(tabsProvider)
        .tabs
        .where((t) => !t.isLocal && t.status == SessionStatus.ready)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(isRu ? 'Файлы' : 'Files'),
        actions: [
          if (_busy)
            Padding(
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
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= 840;
                Widget browser(bool right) => _Browser(
                  key: right ? _right : _left,
                  tabs: tabs,
                  initial: right ? (tabs.firstOrNull?.id ?? '') : '',
                  isRu: isRu,
                  enabled: !_busy,
                  onChanged: _changed,
                  onCopy: _canCopy(!right) ? () => _copy(!right) : null,
                  copyLabel: wide
                      ? (right
                            ? (isRu ? 'Копировать влево' : 'Copy to left')
                            : (isRu ? 'Копировать вправо' : 'Copy to right'))
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
                        child: SegmentedButton<bool>(
                          segments: [
                            ButtonSegment(
                              value: false,
                              label: Text(isRu ? 'Левая панель' : 'Left pane'),
                              icon: const Icon(Icons.folder_outlined),
                            ),
                            ButtonSegment(
                              value: true,
                              label: Text(
                                isRu ? 'Правая панель' : 'Right pane',
                              ),
                              icon: const Icon(Icons.folder_outlined),
                            ),
                          ],
                          selected: {_rightVisible},
                          onSelectionChanged: (v) =>
                              setState(() => _rightVisible = v.single),
                        ),
                      ),
                      Expanded(
                        child: IndexedStack(
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
                            child: GestureDetector(
                              onHorizontalDragUpdate: (d) => setState(
                                () => _ratio = (_ratio + d.delta.dx / available)
                                    .clamp(.3, .7),
                              ),
                              onDoubleTap: () => setState(() => _ratio = .5),
                              child: SizedBox(
                                width: 12,
                                child: Center(
                                  child: Icon(
                                    Icons.drag_indicator,
                                    size: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outline,
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
    );
  }
}

class _Browser extends ConsumerStatefulWidget {
  const _Browser({
    super.key,
    required this.tabs,
    required this.initial,
    required this.isRu,
    required this.enabled,
    required this.onChanged,
    required this.onCopy,
    required this.copyLabel,
    required this.copyIcon,
    required this.destination,
  });
  final List<SessionTab> tabs;
  final String initial;
  final bool isRu;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback? onCopy;
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
  final _selected = <String>{};
  int _request = 0;
  List<RemoteEntry> _previous = const [];
  String? _anchor;
  String get _sourceTitle => _source.isEmpty
      ? (PlatformCapabilities.sharedDownloads
            ? (widget.isRu ? 'Файлы приложения' : 'App files')
            : (widget.isRu ? 'Этот компьютер' : 'This computer'))
      : widget.tabs.where((t) => t.id == _source).firstOrNull?.title ??
            (widget.isRu ? 'Подключение закрыто' : 'Connection closed');
  void _select(
    RemoteEntry entry,
    List<RemoteEntry> entries, {
    bool toggle = false,
  }) {
    setState(() {
      if (Modifiers.instance.shift && _anchor != null) {
        final a = entries.indexWhere((e) => e.path == _anchor);
        final b = entries.indexOf(entry);
        if (a >= 0) {
          if (!Modifiers.instance.ctrl) _selected.clear();
          _selected.addAll(
            entries
                .sublist(a < b ? a : b, (a > b ? a : b) + 1)
                .map((e) => e.path),
          );
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
    directory.addListener(_changed);
    _connect();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (!identical(_previous, directory.entries)) {
        _previous = directory.entries;
        _selected.clear();
        _anchor = null;
      }
      if (!directory.loading) {
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
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _open(String path) async {
    _selected.clear();
    await directory.open(path);
  }

  @override
  void dispose() {
    _request++;
    directory.dispose();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = directory.entries.toList()
      ..sort(
        (a, b) => a.isDir != b.isDir
            ? (a.isDir ? -1 : 1)
            : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    final strings = AppStrings.of(
      context,
      ref.watch(settingsProvider.select((s) => s.language)),
    );
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card.filled(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
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
                        child: Text(
                          PlatformCapabilities.sharedDownloads
                              ? (widget.isRu ? 'Файлы приложения' : 'App files')
                              : (widget.isRu
                                    ? 'Этот компьютер'
                                    : 'This computer'),
                        ),
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
                          : () => menu.isOpen ? menu.close() : menu.open(),
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.onSurface,
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
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
            enabled: widget.enabled && endpoint != null,
            onOpen: _open,
            isRu: widget.isRu,
            onUp: directory.cwd != null
                ? () =>
                      _open(remoteParent(directory.cwd!.replaceAll('\\', '/')))
                : null,
            onRefresh: () {
              _clear();
              directory.refresh();
            },
          ),
          SizedBox(
            height: 2,
            child: directory.loading ? const LinearProgressIndicator() : null,
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Material(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: directory.error != null
                    ? SftpPlaceholder(
                        icon: Icons.error_outline,
                        text: strings.errorText(directory.error!),
                        action: Wrap(
                          alignment: WrapAlignment.center,
                          children: [
                            TextButton(
                              onPressed: () => directory.refresh(),
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
                    : !directory.loading && entries.isEmpty
                    ? SftpPlaceholder(
                        icon: Icons.folder_open_outlined,
                        text: widget.isRu
                            ? 'Папка пуста'
                            : 'This folder is empty',
                      )
                    : CallbackShortcuts(
                        bindings: {
                          const SingleActivator(
                            LogicalKeyboardKey.keyA,
                            control: true,
                          ): () {
                            setState(
                              () =>
                                  _selected.addAll(entries.map((e) => e.path)),
                            );
                            widget.onChanged();
                          },
                          const SingleActivator(LogicalKeyboardKey.escape):
                              _clear,
                          const SingleActivator(LogicalKeyboardKey.enter): () {
                            final selected = selection;
                            if (widget.enabled &&
                                selected.length == 1 &&
                                selected.single.isDir) {
                              _open(selected.single.path);
                            }
                          },
                        },
                        child: Focus(
                          child: ListView.builder(
                            padding: const EdgeInsets.only(bottom: 8),
                            itemCount: entries.length,
                            itemBuilder: (context, i) {
                              final entry = entries[i];
                              void open() {
                                if (widget.enabled && entry.isDir) {
                                  _open(entry.path);
                                }
                              }

                              return SftpEntryRow(
                                entry: entry,
                                enabled: widget.enabled,
                                showSelection: true,
                                selected: _selected.contains(entry.path),
                                strings: strings,
                                onSelect: widget.enabled
                                    ? (_) =>
                                          _select(entry, entries, toggle: true)
                                    : null,
                                onTap: () {
                                  if (!widget.enabled) return;
                                  if (DesktopEnv.isMobile && entry.isDir) {
                                    open();
                                  } else {
                                    _select(entry, entries);
                                  }
                                },
                                onDoubleTap: open,
                                onSecondary: (position) async {
                                  final action = await showMenu<String>(
                                    context: context,
                                    position: RelativeRect.fromLTRB(
                                      position.dx,
                                      position.dy,
                                      0,
                                      0,
                                    ),
                                    items: [
                                      if (entry.isDir)
                                        PopupMenuItem(
                                          value: 'open',
                                          child: Text(
                                            widget.isRu
                                                ? 'Открыть папку'
                                                : 'Open folder',
                                          ),
                                        ),
                                      PopupMenuItem(
                                        value: 'select',
                                        enabled: widget.enabled,
                                        child: Text(
                                          widget.isRu ? 'Выбрать' : 'Select',
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'path',
                                        child: Text(
                                          widget.isRu
                                              ? 'Копировать путь'
                                              : 'Copy path',
                                        ),
                                      ),
                                    ],
                                  );
                                  if (!mounted) return;
                                  if (action == 'open') open();
                                  if (action == 'select') {
                                    _select(entry, entries, toggle: true);
                                  }
                                  if (action == 'path') {
                                    Clipboard.setData(
                                      ClipboardData(text: entry.path),
                                    );
                                  }
                                },
                              );
                            },
                          ),
                        ),
                      ),
              ),
            ),
          ),
          if (_selected.isNotEmpty)
            Material(
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
        ],
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
