import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/sftp/sftp_actions.dart';
import '../../domain/ports/sftp.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import '../../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Открыть текстовый файл во встроенном просмотрщике/редакторе vysh.
/// Возвращает `true`, если файл хотя бы один раз был сохранён.
Future<bool> openSftpTextEditor(
  BuildContext context, {
  required Future<SftpSession> Function() openSession,
  required RemoteEntry entry,
  required AppStrings strings,
  VoidCallback? onOpenExternally,
}) async {
  final scheme = Theme.of(context).colorScheme;
  void showError(String text, {bool offerExternal = false}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: scheme.errorContainer,
        action: offerExternal && onOpenExternally != null
            ? SnackBarAction(
                label: strings.openExternally,
                onPressed: onOpenExternally,
              )
            : null,
      ),
    );
  }

  String initialContent;
  try {
    final sftp = await openSession();
    initialContent = await readSftpTextFile(sftp, entry);
  } on SftpTextEditException catch (e) {
    showError(switch (e.error) {
      SftpTextEditError.tooLarge => strings.fileTooLargeForEditor,
      SftpTextEditError.binary => strings.binaryFileWarning,
    }, offerExternal: true);
    return false;
  } catch (e) {
    showError(strings.errorText(e));
    return false;
  }

  if (!context.mounted) return false;
  final fullScreen =
      DesktopEnv.isMobile || MediaQuery.sizeOf(context).width < 680;
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    useSafeArea: !fullScreen,
    builder: (ctx) => _SftpTextEditorDialog(
      entry: entry,
      initialContent: initialContent,
      openSession: openSession,
      strings: strings,
      fullScreen: fullScreen,
    ),
  );
  return saved ?? false;
}

class _SftpTextEditorDialog extends StatefulWidget {
  const _SftpTextEditorDialog({
    required this.entry,
    required this.initialContent,
    required this.openSession,
    required this.strings,
    required this.fullScreen,
  });

  final RemoteEntry entry;
  final String initialContent;
  final Future<SftpSession> Function() openSession;
  final AppStrings strings;
  final bool fullScreen;

  @override
  State<_SftpTextEditorDialog> createState() => _SftpTextEditorDialogState();
}

class _SftpTextEditorDialogState extends State<_SftpTextEditorDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialContent,
  )..addListener(_onChanged);
  final _scrollController = ScrollController();
  late String _savedText = widget.initialContent;
  bool _wordWrap = true;
  bool _saving = false;
  bool _everSaved = false;

  bool get _dirty => _controller.text != _savedText;

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    setState(() => _saving = true);
    final textToSave = _controller.text;
    try {
      final sftp = await widget.openSession();
      await writeSftpTextFile(sftp, widget.entry.path, textToSave);
      if (!mounted) return;
      setState(() {
        _savedText = textToSave;
        _saving = false;
        _everSaved = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.strings.savedOnServer(widget.entry.name)),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.strings.errorText(e)),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
    }
  }

  Future<void> _requestClose() async {
    if (_saving) return;
    if (!_dirty) {
      Navigator.of(context).pop(_everSaved);
      return;
    }
    final s = widget.strings;
    final decision = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.unsavedChangesTitle),
        content: Text(s.unsavedChangesDesc),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.discardChanges),
          ),
        ],
      ),
    );
    if (decision == true && mounted) {
      Navigator.of(context).pop(_everSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = widget.strings;
    final text = _controller.text;
    final lines = text.isEmpty ? 1 : '\n'.allMatches(text).length + 1;

    final editorField = TextField(
      controller: _controller,
      scrollController: _wordWrap ? _scrollController : null,
      autofocus: true,
      expands: _wordWrap,
      maxLines: _wordWrap ? null : null,
      minLines: _wordWrap ? null : 24,
      keyboardType: TextInputType.multiline,
      style: monoStyle(context, size: 13.5, color: scheme.onSurface),
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(14),
        isCollapsed: true,
      ),
    );

    final content = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        if (PlatformCapabilities.isMacOS)
          const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): _requestClose,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: s.cancel,
                  onPressed: _saving ? null : _requestClose,
                  icon: const Icon(Icons.close),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _dirty ? '• ${widget.entry.name}' : widget.entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        widget.entry.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          context,
                          size: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: s.wordWrap,
                  isSelected: _wordWrap,
                  onPressed: () => setState(() => _wordWrap = !_wordWrap),
                  icon: const Icon(Icons.wrap_text),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  onPressed: _dirty && !_saving ? _save : null,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 18),
                  label: Text(s.save),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ColoredBox(
              color: scheme.surfaceContainerLowest,
              child: _wordWrap
                  ? Scrollbar(controller: _scrollController, child: editorField)
                  : SingleChildScrollView(
                      controller: _scrollController,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 1200),
                          child: IntrinsicWidth(child: editorField),
                        ),
                      ),
                    ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              children: [
                Text(
                  s.isRu
                      ? 'Строк: $lines · Символов: ${text.length}'
                      : 'Lines: $lines · Chars: ${text.length}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  'UTF-8',
                  style: monoStyle(
                    context,
                    size: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: widget.fullScreen
          ? Dialog.fullscreen(child: SafeArea(child: content))
          : Dialog(
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 920,
                  maxHeight: 680,
                ),
                child: content,
              ),
            ),
    );
  }
}
