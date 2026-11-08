import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/controllers/settings_controller.dart';
import '../../infra/update/update_installer.dart';
import '../../infra/update/update_service.dart';
import '../widgets/strings_context.dart';

/// Окно «Доступно обновление»: версии, размер, что нового, прогресс
/// скачивания и применение. Скачивание с проверкой SHA-256; установка
/// на Windows и Linux перезапускает приложение.
///
/// Спроектировано по образцу keqdroid, адаптировано под vysh:
/// Markdown-заметки не рендерятся (пакета нет) - текст заметок как есть.
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _UpdateDialog(info: info),
  );
}

bool _updateDialogOpen = false;

/// Всплывающее окно о новой версии (не чаще, чем разрешено настройками).
/// Пропущенная версия не всплывает; ручная проверка в настройках её
/// показывает.
Future<void> autoPromptForUpdate(
  BuildContext context,
  WidgetRef ref,
  UpdateInfo info,
) async {
  if (_updateDialogOpen) return;
  if (await UpdateService.isSkipped(info.latestVersion)) return;
  final days = ref.read(settingsProvider).updatePromptDays;
  if (!await UpdateService.autoPromptDue(days)) return;
  if (!context.mounted) return;
  await UpdateService.markAutoPrompted();
  if (!context.mounted) return;
  if (_updateDialogOpen) return;
  _updateDialogOpen = true;
  try {
    await showUpdateDialog(context, info);
  } finally {
    _updateDialogOpen = false;
  }
}

/// Заметки релиза: HTML-теги из CHANGELOG → простой текст.
@visibleForTesting
String sanitizeReleaseNotes(String raw) {
  var text = raw;
  text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'</?p>', caseSensitive: false), '\n');
  text = text.replaceAll(
      RegExp(r'</?(details|summary)>', caseSensitive: false), '');
  text = text.replaceAll(RegExp(r'<h([1-6])>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'</h[1-6]>', caseSensitive: false), '\n');
  // Разметку бейджей-кнопок загрузки выкидываем: список файлов ниже
  // на странице релиза и так есть, а внутри диалога они бесполезны.
  text = text.replaceAll(RegExp(r'^\s*\[!\[[^\]]*\]\([^)]*\)\]\([^)]*\)\s*$', multiLine: true), '');
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');
  text = text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  // Ссылки вида [текст](https://…) → текст (https://…): пакета Markdown нет.
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]+)\]\((https?://[^)]+)\)'),
    (m) => '${m.group(1)} (${m.group(2)})',
  );
  return text.trim();
}

class _UpdateDialog extends ConsumerStatefulWidget {
  const _UpdateDialog({required this.info});

  final UpdateInfo info;

  @override
  ConsumerState<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<_UpdateDialog> {
  bool _downloading = false;
  bool _applying = false;
  double _progress = 0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = context.strings;
    final info = widget.info;
    final notes = info.releaseNotes;
    final cleanNotes =
        notes != null && notes.isNotEmpty ? sanitizeReleaseNotes(notes) : null;

    return AlertDialog(
      icon: Icon(Icons.system_update_rounded, color: scheme.primary, size: 32),
      title: Text(s.updateTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'vysh ${info.currentVersion} → ${info.displayLatestVersion}',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              s.updateSize(info.formattedSize),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (cleanNotes != null && cleanNotes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 200),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    cleanNotes,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                  ),
                ),
              ),
            ],
            if (_downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _applying || _progress <= 0 ? null : _progress,
              ),
              const SizedBox(height: 6),
              Text(
                _statusLabel(context),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading
              ? null
              : () async {
                  await UpdateService.skipVersion(info.latestVersion);
                  if (context.mounted) Navigator.pop(context);
                },
          child: Text(
            s.updateSkip,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
        TextButton(
          onPressed: _downloading ? null : () => Navigator.pop(context),
          child: Text(s.updateLater),
        ),
        FilledButton(
          onPressed: _downloading ? null : _downloadAndInstall,
          child: Text(
            info.openInBrowser ? s.updateOpenDownload : s.updateNow,
          ),
        ),
      ],
    );
  }
  String _statusLabel(BuildContext context) {
    final s = context.strings;
    if (_applying) return s.updateApplying;
    if (_progress > 0) return '${(_progress * 100).toInt()}%';
    return s.updateDownloading;
  }

  Future<void> _downloadAndInstall() async {
    final s = context.strings;
    setState(() {
      _downloading = true;
      _applying = false;
      _progress = 0;
    });

    try {
      final restarting = await UpdateInstaller.downloadAndInstall(
        widget.info,
        onProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _progress = received / total);
          }
        },
      );
      // restarting = приложение сейчас перезапустится (exit уже вызван).
      if (restarting) return;
      if (mounted) {
        setState(() => _downloading = false);
        Navigator.pop(context);
      }
    } on UpdateInstallException catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _applying = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s.updateInstallFailure(e))),
        );
      }
    }
  }
}
