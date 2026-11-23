import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_strings.dart';
import '../../domain/models/host.dart';
import '../../domain/ports/secret_store.dart';
import '../../app/controllers/hosts_controller.dart';
import '../../app/dependencies.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/terminal/session_auth.dart' show expandHome;
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import '../../infra/platform/local_files.dart';
import '../../infra/storage/app_paths.dart';
import '../motion/app_motion.dart';
import '../motion/expressive_segments.dart';
import '../motion/layered_switcher.dart';
import '../motion/pressable_surface.dart';
import '../motion/smooth_scroll.dart';
import '../theme/app_theme.dart';
import '../widgets/strings_context.dart';
import 'host_form.dart';
part 'host_editor_sections.dart';
part 'host_editor_widgets.dart';

/// Открыть боковую панель создания/редактирования хоста.
Future<void> showHostEditor(
  BuildContext context, {
  Host? host,
  bool duplicate = false,
}) {
  final reduced = AppMotion.reduced(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.strings.close,
    barrierColor: Colors.black.withValues(alpha: 0.36),
    transitionDuration: reduced
        ? Duration.zero
        : const Duration(milliseconds: 320),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: _HostEditorSheet(host: host, duplicate: duplicate),
    ),
    transitionBuilder: (context, anim, _, child) {
      if (reduced) return child;
      final slide = CurvedAnimation(
        parent: anim,
        curve: AppMotion.spatialCurve,
        reverseCurve: AppMotion.emphasizedAccelerate,
      );
      final fade = CurvedAnimation(
        parent: anim,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
        reverseCurve: const Interval(0.45, 1.0, curve: Curves.easeIn),
      );
      return FadeTransition(
        opacity: fade,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(slide),
          child: child,
        ),
      );
    },
  );
}

class _HostEditorSheet extends ConsumerStatefulWidget {
  const _HostEditorSheet({this.host, this.duplicate = false});

  final Host? host;
  final bool duplicate;

  @override
  ConsumerState<_HostEditorSheet> createState() => _HostEditorSheetState();
}

class _HostEditorSheetState extends ConsumerState<_HostEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final HostForm _form;
  bool _hasSavedPassword = false;
  bool _saving = false;
  int _shakeTrigger = 0;

  bool get _isEdit => widget.host != null && !widget.duplicate;

  @override
  void initState() {
    super.initState();
    final h = widget.host;
    _form = HostForm(
      h,
      initialLabel: h == null
          ? ''
          : (widget.duplicate
              ? AppStrings.forLanguage(ref.read(settingsProvider).language).copyOf(h.title)
              : h.label),
    );
    if (_isEdit) _checkSavedPassword();
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  Future<void> _checkSavedPassword() async {
    try {
      final saved = await ref.read(secretStoreProvider).read(passwordKey(widget.host!.id));
      if (mounted && saved != null) setState(() => _hasSavedPassword = true);
    } on SecretStoreUnavailable {
      // Хранилища нет - сохранённого пароля тоже нет; при сохранении
      // хоста пользователь увидит ошибку записи.
    }
  }

  Future<void> _pickKey() async {
    final file = await openFile(
      confirmButtonText: context.strings.choose,
      initialDirectory: PlatformCapabilities.sharedDownloads
          ? null
          : expandHome('~/.ssh'),
    );
    if (file == null) return;
    if (PlatformCapabilities.sharedDownloads) {
      // На Android file_selector возвращает копию из cacheDir, которую ОС
      // может очистить. Копируем ключ в постоянную папку профиля `keys/`.
      try {
        final keysDir = Directory(
          LocalFiles.join(AppPaths.configDir.path, 'keys'),
        );
        await keysDir.create(recursive: true);
        final name = LocalFiles.safeName(file.name);
        final target = File(LocalFiles.uniquePath(keysDir.path, name));
        try {
          await target.writeAsBytes(await file.readAsBytes(), flush: true);
        } finally {
          LocalFiles.releasePath(target.path);
        }
        _form.keyPath.text = target.path;
        return;
      } catch (e) {
        debugPrint('vysh: не удалось скопировать ключ в профиль: $e');
      }
    }
    _form.keyPath.text = file.path;
  }

  Future<void> _save({bool connect = false}) async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) {
      setState(() => _shakeTrigger++);
      return;
    }
    final host = _form.toHost(
      id: _isEdit ? widget.host!.id : newId(),
      lastConnectedAt: _isEdit ? widget.host!.lastConnectedAt : null,
    );
    setState(() => _saving = true);

    final pwd = _form.password.text;
    final strings = context.strings;
    final warning = await ref.read(hostsProvider.notifier).saveWithPassword(
          host,
          password: pwd,
          remember: _form.rememberPassword,
          previous: _isEdit ? widget.host : null,
          forgetSessionPasswords: ref.read(tabsProvider.notifier).forgetSessionPasswords,
        );

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    if (warning != null) {
      messenger.showSnackBar(SnackBar(
        content: Text(switch (warning) {
          HostSaveWarning.passwordNotDeleted => strings.passwordNotDeleted,
          HostSaveWarning.passwordNotSaved => strings.passwordNotSavedShort,
        }),
      ));
    }
    if (connect) {
      ref.read(tabsProvider.notifier).openHost(
            host,
            password: host.auth == AuthMethod.password && pwd.isNotEmpty ? pwd : null,
          );
    }
  }

  Future<void> _delete() async {
    final host = widget.host!;
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: Text(context.strings.deleteHostsTitle(1)),
        content: Text(context.strings.deleteHostsDesc([host.title])),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.strings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.strings.delete),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    ref.read(hostsProvider.notifier).remove(host.id);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lang = ref.watch(settingsProvider.select((s) => s.language));
    final strings = AppStrings.of(context, lang);
    final groups = ref.watch(hostGroupsProvider);
    final width = MediaQuery.sizeOf(context).width;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final fullWidth = width < 520;
    final title = _isEdit
        ? strings.editHostTitle
        : (widget.duplicate ? strings.duplicateHostTitle : strings.newHostTitle);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _save(),
        const SingleActivator(LogicalKeyboardKey.enter, control: true, shift: true): () =>
            _save(connect: true),
        if (PlatformCapabilities.isMacOS) ...{
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => _save(),
          const SingleActivator(LogicalKeyboardKey.enter, meta: true, shift: true): () =>
              _save(connect: true),
        },
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
      },
      child: Material(
        color: scheme.surfaceContainerLow,
        elevation: 2,
        borderRadius: fullWidth
            ? BorderRadius.zero
            : const BorderRadius.horizontal(left: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: fullWidth ? width : 460,
          height: double.infinity,
          child: AnimatedPadding(
            duration: AppMotion.duration(
              context,
              const Duration(milliseconds: 160),
            ),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.only(bottom: bottomInset),
            child: SafeArea(
              bottom: bottomInset == 0,
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 28, 12, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(title, style: theme.textTheme.titleLarge),
                          ),
                          IconButton(
                            tooltip: DesktopEnv.isDesktop
                                ? '${strings.close} (Esc)'
                                : strings.close,
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListenableBuilder(
                        listenable: _form,
                        builder: (context, _) => ScrollEdgeFade(
                          top: 18,
                          bottom: 16,
                          child: SmoothScroll(
                            builder: (context, controller) => ListView(
                              controller: controller,
                              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                              children: [
                                ShakeBox(
                                  trigger: _shakeTrigger,
                                  child: _ConnectionSection(
                                    form: _form,
                                    strings: strings,
                                    autofocus: !_isEdit,
                                  ),
                                ),
                                _AuthSection(
                                  form: _form,
                                  strings: strings,
                                  hasSavedPassword: _hasSavedPassword,
                                  onPickKey: _pickKey,
                                ),
                                _ListSection(
                                  form: _form,
                                  strings: strings,
                                  groups: groups,
                                ),
                                const SizedBox(height: 16),
                                _KeepAliveSection(form: _form, strings: strings),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Divider(),
                    _EditorActions(
                      strings: strings,
                      saving: _saving,
                      onDelete: _isEdit ? _delete : null,
                      onSave: _save,
                      onSaveAndConnect: () => _save(connect: true),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
