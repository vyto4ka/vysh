import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/controllers/transfer_queue.dart';
import '../../app/sftp/file_copy.dart';
import '../../app/sftp/sftp_directory.dart';
import '../../domain/models/session_tab.dart';
import '../../domain/ports/sftp.dart';
import '../../infra/platform/local_file_session.dart';
import '../../l10n/app_strings.dart';
import 'transfers_view.dart';

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
      appBar: AppBar(title: Text(isRu ? 'Файлы' : 'Files')),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final panes = [
                  Expanded(
                    child: _Browser(
                      key: _left,
                      tabs: tabs,
                      initial: '',
                      isRu: isRu,
                      enabled: !_busy,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: isRu ? 'Копировать вправо' : 'Copy right',
                          onPressed: _busy ? null : () => _copy(true),
                          icon: const Icon(Icons.arrow_forward),
                        ),
                        IconButton(
                          tooltip: isRu ? 'Копировать влево' : 'Copy left',
                          onPressed: _busy ? null : () => _copy(false),
                          icon: const Icon(Icons.arrow_back),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _Browser(
                      key: _right,
                      tabs: tabs,
                      initial: tabs.firstOrNull?.id ?? '',
                      isRu: isRu,
                      enabled: !_busy,
                    ),
                  ),
                ];
                return box.maxWidth > 680
                    ? Row(children: panes)
                    : Column(children: panes);
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
  });
  final List<SessionTab> tabs;
  final String initial;
  final bool isRu;
  final bool enabled;
  @override
  ConsumerState<_Browser> createState() => _BrowserState();
}

class _BrowserState extends ConsumerState<_Browser> {
  static const _local = LocalFileSession();
  SftpSession? endpoint;
  late String _source = widget.initial;
  late final directory = SftpDirectory(() async {
    if (endpoint == null) throw const SftpFailure(SftpFailureCode.noConnection);
    return endpoint!;
  });
  final _path = TextEditingController();
  final _selected = <String>{};
  int _request = 0;
  String get identity => _source.isEmpty
      ? 'local'
      : ref.read(tabsProvider.notifier).sessionOf(_source)?.target ?? _source;
  List<RemoteEntry> get selection =>
      directory.entries.where((e) => _selected.contains(e.path)).toList();
  @override
  void initState() {
    super.initState();
    directory.addListener(_changed);
    _connect();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (!directory.loading) _path.text = directory.cwd ?? '';
    });
  }

  Future<void> _connect() async {
    final request = ++_request;
    endpoint = null;
    _selected.clear();
    try {
      final connected = _source.isEmpty
          ? _local
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
    final available = widget.tabs.any((t) => t.id == _source);
    final entries = directory.entries.toList()
      ..sort(
        (a, b) => a.isDir != b.isDir
            ? (a.isDir ? -1 : 1)
            : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          DropdownButton<String>(
            isExpanded: true,
            value: _source.isEmpty || available ? _source : null,
            hint: Text(
              widget.isRu ? 'Подключение закрыто' : 'Connection closed',
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(widget.isRu ? 'Этот компьютер' : 'This computer'),
              ),
              for (final t in widget.tabs)
                DropdownMenuItem(
                  value: t.id,
                  child: Text(t.title, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: !widget.enabled
                ? null
                : (value) {
                    setState(() => _source = value!);
                    _connect();
                  },
          ),
          Row(
            children: [
              IconButton(
                tooltip: widget.isRu ? 'Выше' : 'Parent',
                onPressed: widget.enabled && directory.cwd != null
                    ? () => _open(
                        remoteParent(directory.cwd!.replaceAll('\\', '/')),
                      )
                    : null,
                icon: const Icon(Icons.arrow_upward),
              ),
              Expanded(
                child: TextField(
                  controller: _path,
                  enabled: widget.enabled,
                  onSubmitted: _open,
                  decoration: InputDecoration(
                    labelText: widget.isRu ? 'Путь' : 'Path',
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                tooltip: widget.isRu ? 'Обновить' : 'Refresh',
                onPressed: widget.enabled
                    ? () {
                        _selected.clear();
                        directory.refresh();
                      }
                    : null,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (directory.loading) const LinearProgressIndicator(),
          if (directory.error != null)
            Text(
              AppStrings.of(
                context,
                ref.read(settingsProvider).language,
              ).errorText(directory.error!),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                return ListTile(
                  dense: true,
                  selected: _selected.contains(e.path),
                  leading: Checkbox(
                    value: _selected.contains(e.path),
                    onChanged: !widget.enabled
                        ? null
                        : (v) => setState(() {
                            v!
                                ? _selected.add(e.path)
                                : _selected.remove(e.path);
                          }),
                  ),
                  title: Text(e.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    e.isDir
                        ? (widget.isRu ? 'Папка' : 'Folder')
                        : '${e.size} B',
                  ),
                  trailing: Icon(
                    e.isDir
                        ? Icons.folder_outlined
                        : Icons.insert_drive_file_outlined,
                  ),
                  onTap: !widget.enabled
                      ? null
                      : () {
                          if (e.isDir) {
                            _open(e.path);
                          } else {
                            setState(() {
                              _selected.contains(e.path)
                                  ? _selected.remove(e.path)
                                  : _selected.add(e.path);
                            });
                          }
                        },
                );
              },
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
