import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/controllers/backup_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../domain/services/backup.dart';
import '../../infra/platform/capabilities.dart';
import '../../infra/platform/desktop_env.dart';
import '../../infra/platform/local_files.dart';
import '../../l10n/app_strings.dart';

/// Раздел настроек «Резервная копия»: экспорт профиля (хосты, настройки,
/// known_hosts и сохранённые пароли) в файл - открытый JSON или
/// зашифрованный паролем. И восстановление из него.
class BackupSection extends ConsumerWidget {
  const BackupSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final strings = AppStrings.of(context, s.language);
    final theme = Theme.of(context);
    final isMobile = DesktopEnv.isMobile;
    final ctrl = ref.read(backupControllerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          strings.backupSectionHint,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.file_upload_outlined),
          label: Text(strings.backupCreate),
          onPressed: () => _create(context, ref, ctrl),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.file_download_outlined),
          label: Text(strings.backupRestore),
          // Выбрать файл для чтения на Android умеет системный выбор - ок.
          onPressed: () => _restore(context, ref, ctrl, isMobile),
        ),
      ],
    );
  }

  Future<void> _create(
      BuildContext context, WidgetRef ref, BackupController ctrl) async {
    final s = ref.read(settingsProvider);
    final strings = AppStrings.of(context, s.language);
    final messenger = ScaffoldMessenger.of(context);
    void snack(String text) => messenger.showSnackBar(
          SnackBar(content: Text(text)),
        );

    // 1. Куда сохранить. На Android своего диалога «Сохранить как» нет -
    // файл пишем во временную папку и публикуем в общую Download
    // (MediaStore), как это делает скачивание из SFTP.
    final stamp =
        DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final defaultName = 'vysh-backup-$stamp.vyshbak';
    if (PlatformCapabilities.sharedDownloads) {
      await _createOnAndroid(context, ref, ctrl, defaultName);
      return;
    }
    final path = await getSaveLocation(
      suggestedName: defaultName,
      confirmButtonText: strings.save,
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'vysh backup',
          extensions: const ['vyshbak', 'json'],
        ),
      ],
    );
    if (path == null) return;

    // 2. Пароль (можно пропустить - тогда открытый JSON).
    // ignore: use_build_context_synchronously - checked below
    final password = await _askPassword(context, strings);
    if (password == null || !context.mounted) return;
    if (password.isNotEmpty && password.length < 6) {
      snack(strings.backupPasswordTooShort);
      return;
    }

    try {
      final count = await ctrl.create(File(path.path), password: password);
      if (!context.mounted) return;
      final part = password.isEmpty
          ? strings.backupDoneNoSecrets
          : (count > 0
              ? strings.backupDoneWithSecrets(count)
              : strings.backupDonePlain);
      snack(part);
    } on Object catch (e) {
      snack(strings.backupFailed('$e'));
    }
  }

  /// Создание бэкапа на Android: пароль → временный файл → публикация
  /// в общую Download через MediaStore (системного «Сохранить как» нет).
  Future<void> _createOnAndroid(BuildContext context, WidgetRef ref,
      BackupController ctrl, String name) async {
    final strings = AppStrings.of(context, ref.read(settingsProvider).language);
    final messenger = ScaffoldMessenger.of(context);
    void snack(String text) =>
        messenger.showSnackBar(SnackBar(content: Text(text)));

    final password = await _askPassword(context, strings);
    if (password == null || !context.mounted) return;
    if (password.isNotEmpty && password.length < 6) {
      snack(strings.backupPasswordTooShort);
      return;
    }

    // Временный файл в кэше приложения, оттуда - в Download.
    final tmpDir = Directory.systemTemp;
    final tmp = File('${tmpDir.path}/$name.vysh-tmp');
    try {
      final count = await ctrl.create(tmp, password: password);
      await LocalFiles.saveToDownloads(
        tmp.path,
        name,
        mimeType: password.isEmpty
            ? 'application/json'
            : 'application/octet-stream',
      );
      if (!context.mounted) return;
      final part = password.isEmpty
          ? strings.backupDoneNoSecrets
          : (count > 0
              ? strings.backupDoneWithSecrets(count)
              : strings.backupDonePlain);
      snack(part);
    } on Object catch (e) {
      snack(strings.backupFailed('$e'));
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// null - пользователь отменил; '' - без пароля.
  Future<String?> _askPassword(BuildContext context, AppStrings strings) {
    return showDialog<String>(
      context: context,
      builder: (context) => _PasswordDialog(strings: strings),
    );
  }

  Future<void> _restore(BuildContext context, WidgetRef ref,
      BackupController ctrl, bool isMobile) async {
    final s = ref.read(settingsProvider);
    final strings = AppStrings.of(context, s.language);
    final messenger = ScaffoldMessenger.of(context);

    final file = await openFile(
      confirmButtonText: strings.choose,
      acceptedTypeGroups: [
        XTypeGroup(
          label: 'vysh backup',
          extensions: const ['vyshbak', 'json'],
          // Android отдаёт произвольные файлы как octet-stream.
          mimeTypes:
              isMobile ? const ['application/octet-stream', 'application/json'] : null,
        ),
      ],
    );
    if (file == null) return;
    final f = File(file.path);

    try {
      // 1. Что за файл, нужен ли пароль.
      final info = await BackupController.inspect(f);
      var data = info.encrypted ? null : await BackupController.readBackup(f);
      String? password;
      if (info.encrypted && context.mounted) {
        // ignore: use_build_context_synchronously
        password = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (context) => _PasswordDialog(
            strings: strings,
            restoreMode: true,
          ),
        );
        if (password == null || !context.mounted) return;
        data = await BackupController.readBackup(f, password: password);
      }

      // 2. Подтверждение: текущие данные будут заменены.
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => _RestoreConfirmDialog(
          strings: strings,
          hostCount: data!.hosts.length,
        ),
      );
      if (confirmed != true) return;

      await ctrl.restore(data!);
      ctrl.reload();
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.backupRestored(data.hosts.length))),
      );
    } on BackupException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(
          e.message == 'wrong password'
              ? strings.backupWrongPassword
              : strings.backupFailed(e.message),
        ),
      ));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(strings.backupFailed('$e'))));
    }
  }
}

/// Диалог пароля бэкапа. При экспорте - два поля (подтверждение),
/// при импорте - одно.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.strings,
    this.restoreMode = false,
  });

  final AppStrings strings;
  final bool restoreMode;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  var _obscure = true;
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final s = widget.strings;
    final pass = _first.text;
    if (widget.restoreMode) {
      Navigator.of(context).pop(pass);
      return;
    }
    if (pass.isEmpty) {
      Navigator.of(context).pop(''); // без пароля - открытый JSON
      return;
    }
    if (pass.length < 6) {
      setState(() => _error = s.backupPasswordTooShort);
      return;
    }
    if (pass != _second.text) {
      setState(() => _error = s.backupPasswordMismatch);
      return;
    }
    Navigator.of(context).pop(pass);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    return AlertDialog(
      title: Text(s.backupPasswordTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.restoreMode
              ? s.backupPasswordEnterForRestore
              : s.backupPasswordHint),
          const SizedBox(height: 16),
          TextField(
            controller: _first,
            autofocus: true,
            obscureText: _obscure,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: s.backupPasswordField,
              errorText: _error,
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          if (!widget.restoreMode) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _second,
              obscureText: _obscure,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: s.backupPasswordRepeat),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(s.ok),
        ),
      ],
    );
  }
}

class _RestoreConfirmDialog extends StatelessWidget {
  const _RestoreConfirmDialog({
    required this.strings,
    required this.hostCount,
  });

  final AppStrings strings;
  final int hostCount;

  @override
  Widget build(BuildContext context) {
    final s = strings;
    return AlertDialog(
      title: Text(s.backupRestoreTitle),
      content: Text(s.backupRestoreConfirm(hostCount)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(s.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(s.restore),
        ),
      ],
    );
  }
}
