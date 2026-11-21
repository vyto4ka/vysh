import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_strings.dart';
import '../../domain/models/host.dart';
import '../../app/controllers/hosts_controller.dart';
import '../../app/controllers/settings_controller.dart';
import '../../app/controllers/tabs_controller.dart';
import '../../infra/platform/desktop_env.dart';
import '../motion/app_motion.dart';
import '../motion/pressable_surface.dart';
import '../theme/app_theme.dart';
import '../widgets/context_menu.dart';
import '../widgets/modifiers.dart';
import 'host_editor.dart';

class HostCard extends ConsumerWidget {
  const HostCard({
    super.key,
    required this.host,
    this.selected = false,
    this.selecting = false,
    this.onToggleSelect,
  });

  final Host host;

  /// Карточка отмечена для массовых действий.
  final bool selected;

  /// Идёт выбор: клик отмечает карточку, а не подключается.
  final bool selecting;
  final VoidCallback? onToggleSelect;

  void _onTap(WidgetRef ref) {
    // Win/Meta не считаем: после Win+Shift+S он «залипал» и обычный клик
    // отмечал хост вместо подключения.
    if ((selecting || Modifiers.instance.ctrl) && onToggleSelect != null) {
      onToggleSelect!();
    } else {
      ref.read(tabsProvider.notifier).openHost(host);
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    AppStrings strings,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.deleteHostTitle),
        content: Text(strings.deleteHostDesc(host.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(hostsProvider.notifier).remove(host.id);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = Color(host.color);
    final lang = ref.watch(settingsProvider.select((s) => s.language));
    final strings = AppStrings.of(context, lang);
    final fast = AppMotion.duration(context, AppMotion.durationFast);

    return ContextMenuArea(
      child: Builder(
        builder: (areaContext) => PressableSurface(
          selected: selected,
          borderRadius: BorderRadius.circular(16),
          selectedBorderRadius: BorderRadius.circular(20),
          color: scheme.surfaceContainerLow,
          selectedColor: scheme.secondaryContainer,
          side: BorderSide.none,
          selectedSide: BorderSide(color: scheme.primary, width: 2),
          pressScale: 0.02,
          onTap: () => _onTap(ref),
          // На телефоне Ctrl нет - выбор долгим нажатием. На ПК долгое
          // нажатие мышью срабатывало вместо клика, там оно выключено.
          onLongPress: DesktopEnv.isMobile ? onToggleSelect : null,
          onSecondaryTapUp: (d) => ContextMenuArea.of(
            areaContext,
          )?.open(d.globalPosition, _items(context, ref, strings)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: fast,
                  curve: AppMotion.fastSpringCurve,
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary
                        : accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(selected ? 22 : 14),
                  ),
                  child: AnimatedSwitcher(
                    duration: fast,
                    switchInCurve: AppMotion.emphasizedDecelerate,
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: selected
                        ? Icon(
                            Icons.check_rounded,
                            key: const ValueKey('check'),
                            color: scheme.onPrimary,
                            size: 24,
                          )
                        : Icon(
                            Icons.dns_rounded,
                            key: const ValueKey('dns'),
                            color: accent,
                            size: 22,
                          ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        host.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        host.displayAddress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          context,
                          size: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (ref.watch(
                  settingsProvider.select((s) => s.pingHosts),
                )) ...[
                  const SizedBox(width: 8),
                  _Reachability(host: host, strings: strings),
                ],
                const SizedBox(width: 4),
                AnimatedSwitcher(
                  duration: fast,
                  switchInCurve: AppMotion.emphasizedDecelerate,
                  transitionBuilder: (child, anim) => ScaleTransition(
                    scale: Tween<double>(begin: 0.75, end: 1.0).animate(anim),
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: selecting
                      ? Checkbox(
                          key: const ValueKey('checkbox'),
                          value: selected,
                          onChanged: (_) => onToggleSelect?.call(),
                        )
                      : MenuIconButton(
                          key: const ValueKey('menu'),
                          tooltip: strings.actions,
                          items: _items(context, ref, strings),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _items(BuildContext context, WidgetRef ref, AppStrings strings) {
    final scheme = Theme.of(context).colorScheme;
    return [
      menuItem(
        strings.isRu ? 'Подключиться' : 'Connect',
        icon: Icons.play_arrow_rounded,
        onPressed: () => ref.read(tabsProvider.notifier).openHost(host),
      ),
      menuItem(
        strings.edit,
        icon: Icons.edit_outlined,
        onPressed: () => showHostEditor(context, host: host),
      ),
      menuItem(
        strings.duplicate,
        icon: Icons.copy_all_outlined,
        onPressed: () => showHostEditor(context, host: host, duplicate: true),
      ),
      if (onToggleSelect != null)
        menuItem(
          selected
              ? (strings.isRu ? 'Снять выбор' : 'Deselect')
              : (strings.isRu ? 'Выбрать' : 'Select'),
          icon: Icons.check_box_outlined,
          onPressed: onToggleSelect,
        ),
      menuItem(
        strings.forgetPassword,
        icon: Icons.key_off_outlined,
        onPressed: () async {
          final messenger = ScaffoldMessenger.of(context);
          // Открытые вкладки тоже забывают пароль, введённый в этой сессии.
          ref.read(tabsProvider.notifier).forgetSessionPasswords(host.id);
          String text;
          try {
            await ref.read(hostsProvider.notifier).forgetSecrets(host.id);
            text = strings.isRu
                ? 'Сохранённый пароль для «${host.title}» удалён'
                : 'Saved password for «${host.title}» removed';
          } catch (e) {
            text = strings.isRu
                ? 'Не удалось удалить пароль: системное хранилище недоступно ($e)'
                : 'Could not remove the password: system keyring unavailable ($e)';
          }
          messenger.showSnackBar(SnackBar(content: Text(text)));
        },
      ),
      menuDivider(),
      menuItem(
        strings.delete,
        icon: Icons.delete_outline,
        color: scheme.error,
        onPressed: () => _confirmDelete(context, ref, strings),
      ),
    ];
  }
}

class _Reachability extends ConsumerWidget {
  const _Reachability({required this.host, required this.strings});

  final Host host;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final ping = ref.watch(reachabilityProvider((host.address, host.port)));
    final fast = AppMotion.duration(context, AppMotion.durationFast);

    return AnimatedSize(
      duration: fast,
      curve: AppMotion.fastSpringCurve,
      child: AnimatedSwitcher(
        duration: fast,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.85, end: 1.0).animate(anim),
            child: child,
          ),
        ),
        child: ping.when(
          loading: () => const SizedBox(
            key: ValueKey('loading'),
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          error: (_, _) => const SizedBox.shrink(key: ValueKey('error')),
          data: (r) {
            final ms = r.ms;
            return Tooltip(
              key: ValueKey('ping-$ms'),
              message: ms == null
                  ? (strings.isRu
                        ? 'Порт ${host.port} не отвечает${r.error == null ? '' : '\n${r.error}'}'
                        : 'Port ${host.port} is unreachable${r.error == null ? '' : '\n${r.error}'}')
                  : (strings.isRu
                        ? 'Порт ${host.port} доступен за $ms мс'
                        : 'Port ${host.port} reachable in ${ms}ms'),
              child: AnimatedContainer(
                duration: fast,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (ms == null ? scheme.error : Colors.green).withValues(
                    alpha: 0.14,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  ms == null
                      ? (strings.isRu ? 'нет' : 'down')
                      : (strings.isRu ? '$ms мс' : '${ms}ms'),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: ms == null ? scheme.error : Colors.green.shade600,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
