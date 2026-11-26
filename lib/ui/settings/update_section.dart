import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/update_controller.dart';
import '../../infra/update/update_service.dart';
import '../../l10n/app_strings.dart';
import '../dialogs/update_dialog.dart';
import '../motion/app_motion.dart';
import '../motion/expand_section.dart';
import '../motion/layered_switcher.dart';
import '../widgets/strings_context.dart';
import 'setting_row.dart';

/// Раздел «Обновления»: переключатель автопроверки, периодичность
/// всплывающего окна и компактная строка статуса с точкой-индикатором.
class UpdateSection extends ConsumerStatefulWidget {
  const UpdateSection({super.key});

  @override
  ConsumerState<UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends ConsumerState<UpdateSection> {
  /// Результат ручной проверки, когда автопроверка отключена.
  UpdateInfo? _manualInfo;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final strings = AppStrings.of(context, s.language);
    final update = ref.watch(updateInfoProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(strings.updateAutoCheck),
          value: s.checkForUpdates,
          onChanged: (v) {
            setState(() => _manualInfo = null);
            ctrl.setCheckForUpdates(v);
          },
        ),
        ExpandSection(
          expanded: s.checkForUpdates,
          child: SettingRow(
            label: strings.updatePromptFrequency,
            child: SettingChoice<int>(
              value: s.updatePromptDays,
              options: [
                (1, strings.updateEveryDay),
                (3, strings.updateEvery3Days),
                (7, strings.updateEveryWeek),
              ],
              onChanged: ctrl.setUpdatePromptDays,
            ),
          ),
        ),
        const SizedBox(height: 4),
        _UpdateStatusLine(
          info: update.value ?? _manualInfo,
          loading: update.isLoading || _checking,
          hasError: update.hasError && _manualInfo == null,
          autoCheckEnabled: s.checkForUpdates,
          strings: strings,
          onCheck: () => _checkNow(context),
          onUpdate: (info) => showUpdateDialog(context, info),
        ),
      ],
    );
  }

  bool _checking = false;

  Future<void> _checkNow(BuildContext context) async {
    if (_checking) return;
    final strings = context.strings;
    setState(() => _checking = true);
    try {
      final info = await UpdateService.checkForUpdate(force: true);
      ref.invalidate(updateInfoProvider);
      if (!context.mounted) return;
      setState(() => _manualInfo = info);
      if (info != null) {
        await showUpdateDialog(context, info);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.updateLatest)));
      }
    } on UpdateCheckException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.updateCheckFailure(e))));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.updateCheckFailed)));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }
}

class _UpdateStatusLine extends StatelessWidget {
  const _UpdateStatusLine({
    required this.info,
    required this.loading,
    required this.hasError,
    required this.autoCheckEnabled,
    required this.strings,
    required this.onCheck,
    required this.onUpdate,
  });

  final UpdateInfo? info;
  final bool loading;
  final bool hasError;
  final bool autoCheckEnabled;
  final AppStrings strings;
  final VoidCallback onCheck;
  final void Function(UpdateInfo info) onUpdate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = info;
    final fastDur = AppMotion.duration(context, AppMotion.durationFast);

    final statusText = current != null
        ? 'vysh ${current.displayLatestVersion} · ${current.formattedSize}'
        : loading
        ? strings.updateCheck
        : hasError
        ? strings.updateCheckFailed
        : autoCheckEnabled
        ? strings.updateLatest
        : '';

    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 460;
        return Row(
          children: [
            ExpandSection(
              expanded: current != null,
              axis: Axis.horizontal,
              spring: AppMotion.spatialFast,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Badge(smallSize: 8, backgroundColor: scheme.primary),
              ),
            ),
            Expanded(
              child: FadeSlideSwitcher(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  statusText,
                  key: ValueKey(statusText),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: current != null
                        ? scheme.onSurface
                        : hasError
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            if (current != null) ...[
              if (wide)
                TextButton(
                  key: const ValueKey('recheck'),
                  onPressed: loading ? null : onCheck,
                  child: Text(strings.updateCheck),
                )
              else
                IconButton(
                  key: const ValueKey('recheck-icon'),
                  visualDensity: VisualDensity.compact,
                  tooltip: strings.updateCheck,
                  onPressed: loading ? null : onCheck,
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: const ValueKey('update'),
                onPressed: loading ? null : () => onUpdate(current),
                child: Text(strings.updateNow),
              ),
            ] else
              AnimatedSwitcher(
                duration: fastDur,
                child: TextButton(
                  key: const ValueKey('check'),
                  onPressed: loading ? null : onCheck,
                  child: Text(strings.updateCheck),
                ),
              ),
          ],
        );
      },
    );
  }
}
