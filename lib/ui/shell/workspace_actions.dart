import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/windows/detached_windows.dart';
import '../../l10n/app_strings.dart';
import 'ui_state.dart';

void splitSession(
  WidgetRef ref,
  String id, {
  Axis axis = Axis.horizontal,
  bool reverse = false,
}) {
  final tabs = ref.read(tabsProvider);
  final external = ref.read(detachedWindowsProvider);
  final other = tabs.tabs
      .where((t) => t.id != id && !external.containsKey(t.id))
      .firstOrNull;
  if (other == null) return;
  if (tabs.isHome ||
      tabs.activeTab?.id == id ||
      external.containsKey(tabs.activeTab?.id)) {
    ref.read(tabsProvider.notifier).activate(tabs.tabs.indexOf(other) + 1);
  }
  ref.read(splitLayoutProvider.notifier).select(axis, reverse: reverse);
  ref.read(splitTabProvider.notifier).select(id);
  ref.read(workspaceFocusProvider.notifier).select(id);
}

Future<void> chooseSplit(BuildContext context, WidgetRef ref, Axis axis) async {
  final tabs = ref.read(tabsProvider);
  final external = ref.read(detachedWindowsProvider);
  final isRu = AppStrings.of(context, ref.read(settingsProvider).language).isRu;
  final available = tabs.tabs
      .where((t) => t.id != tabs.activeTab?.id && !external.containsKey(t.id))
      .toList();
  final id = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(
        isRu
            ? 'Какую вкладку открыть рядом?'
            : 'Which tab should open beside this one?',
      ),
      children: available.isEmpty
          ? [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  isRu
                      ? 'Сначала откройте вторую сессию.'
                      : 'Open a second session first.',
                ),
              ),
            ]
          : [
              for (final tab in available)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, tab.id),
                  child: ListTile(
                    leading: const Icon(Icons.terminal),
                    title: Text(tab.title),
                  ),
                ),
            ],
    ),
  );
  if (id != null && context.mounted) splitSession(ref, id, axis: axis);
}

Future<void> detachSession(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  try {
    if (ref.read(splitTabProvider) == id) {
      ref.read(splitTabProvider.notifier).select(null);
    }
    await ref.read(detachedWindowsProvider.notifier).detach(id);
  } catch (e) {
    if (!context.mounted) return;
    final isRu = AppStrings.of(
      context,
      ref.read(settingsProvider).language,
    ).isRu;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isRu
              ? 'Не удалось открыть отдельное окно: $e'
              : 'Could not open a separate window: $e',
        ),
      ),
    );
  }
}
