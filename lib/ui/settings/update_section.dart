import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/update_controller.dart';
import '../../infra/update/update_service.dart';
import '../../l10n/app_strings.dart';
import '../dialogs/update_dialog.dart';
import '../widgets/strings_context.dart';
import 'setting_row.dart';

/// Раздел «Обновления»: периодичность всплывающего окна и статус.
///
/// Карточка показывает найденное обновление из [updateInfoProvider] (он
/// проверяет GitHub в фоне); кнопка «Проверить обновления» делает
/// принудительную проверку и открывает окно, если что-то нашлось.
class UpdateSection extends ConsumerWidget {
  const UpdateSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final ctrl = ref.read(settingsProvider.notifier);
    final strings = AppStrings.of(context, s.language);
    final update = ref.watch(updateInfoProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingRow(
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
        const SizedBox(height: 8),
        _UpdateStatusCard(
          state: update,
          strings: strings,
          onCheck: () => _checkNow(context, ref),
          onUpdate: (info) => showUpdateDialog(context, info),
        ),
      ],
    );
  }

  Future<void> _checkNow(BuildContext context, WidgetRef ref) async {
    final strings = context.strings;
    try {
      final info = await UpdateService.checkForUpdate(force: true);
      ref.invalidate(updateInfoProvider);
      if (!context.mounted) return;
      if (info != null) {
        await showUpdateDialog(context, info);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(strings.updateLatest)),
        );
      }
    } on UpdateCheckException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.updateCheckFailure(e))),
      );
    }
  }
}

class _UpdateStatusCard extends StatelessWidget {
  const _UpdateStatusCard({
    required this.state,
    required this.strings,
    required this.onCheck,
    required this.onUpdate,
  });

  final AsyncValue<UpdateInfo?> state;
  final AppStrings strings;
  final VoidCallback onCheck;
  final void Function(UpdateInfo info) onUpdate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = state.value;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            info != null
                ? Icons.system_update_alt_rounded
                : Icons.verified_outlined,
            size: 20,
            color: info != null ? scheme.primary : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              info != null
                  ? 'vysh ${info.displayLatestVersion} · ${info.formattedSize}'
                  : state.isLoading
                      ? strings.updateCheck
                      : strings.updateLatest,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          if (info != null)
            FilledButton.tonal(
              onPressed: () => onUpdate(info),
              child: Text(strings.updateNow),
            )
          else
            TextButton(
              onPressed: state.isLoading ? null : onCheck,
              child: Text(strings.updateCheck),
            ),
        ],
      ),
    );
  }
}
