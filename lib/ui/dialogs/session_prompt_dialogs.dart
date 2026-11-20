import 'package:flutter/material.dart';

import '../../app/settings/app_settings.dart';
import '../../domain/models/host.dart';
import '../../domain/ports/session_prompts.dart';
import '../../domain/ports/ssh_transport.dart';
import '../../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/strings_context.dart';

/// Диалоги, которые сессия показывает во время подключения.
class DialogSessionPrompts implements SessionPrompts {
  DialogSessionPrompts(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;

  BuildContext? get _ctx => navigatorKey.currentContext;

  AppStrings get _strings {
    final ctx = _ctx;
    return ctx == null ? AppStrings.forLanguage(AppLanguage.auto) : ctx.strings;
  }

  @override
  Future<bool> confirmHostKey(
    Host host, {
    required String type,
    required String fingerprint,
    String? previous,
  }) async {
    final ctx = _ctx;
    if (ctx == null) return false;
    final changed = previous != null;
    final result = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final mono = monoStyle(context, size: 12.5, color: scheme.onSurface);
        final s = context.strings;
        final target = '${host.address}:${host.port}';
        return AlertDialog(
          icon: Icon(changed ? Icons.gpp_maybe_rounded : Icons.fingerprint,
              color: changed ? scheme.error : scheme.primary, size: 32),
          title: Text(changed ? s.hostKeyChangedTitle : s.hostKeyNewTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  changed ? s.hostKeyChangedText(target) : s.hostKeyNewText(target),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText.rich(
                    TextSpan(style: mono, children: [
                      TextSpan(text: '$type\n',
                          style: mono.copyWith(color: scheme.onSurfaceVariant)),
                      if (changed) ...[
                        TextSpan(text: '${s.fingerprintWas}$previous\n',
                            style: mono.copyWith(color: scheme.onSurfaceVariant)),
                        TextSpan(text: '${s.fingerprintNow}$fingerprint',
                            style: mono.copyWith(color: scheme.error)),
                      ] else
                        TextSpan(text: fingerprint),
                    ]),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.strings.cancel),
            ),
            FilledButton(
              style: changed
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error, foregroundColor: scheme.onError)
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(changed ? s.connectAnyway : s.trustAndConnect),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  @override
  Future<SecretAnswer?> askPassword(Host host, {bool retry = false, bool canRemember = true}) {
    return _askSecret(
      title: _strings.passwordTitle,
      subtitle: host.displayAddress,
      label: _strings.passwordTitle,
      error: retry ? _strings.wrongPasswordRetry : null,
      canRemember: canRemember,
    );
  }

  @override
  Future<SecretAnswer?> askPassphrase(Host host, String keyLabel, {bool retry = false}) {
    return _askSecret(
      title: _strings.passphraseTitle,
      subtitle: keyLabel,
      label: _strings.passphraseLabel,
      error: retry ? _strings.wrongPassphrase : null,
      canRemember: true,
    );
  }

  Future<SecretAnswer?> _askSecret({
    required String title,
    required String subtitle,
    required String label,
    String? error,
    bool canRemember = true,
  }) async {
    final ctx = _ctx;
    if (ctx == null) return null;
    return showDialog<SecretAnswer>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => _SecretDialog(
        title: title,
        subtitle: subtitle,
        label: label,
        error: error,
        canRemember: canRemember,
      ),
    );
  }

  @override
  Future<List<String>?> askInteractive(
    Host host,
    String name,
    String instruction,
    List<SshPrompt> prompts,
  ) async {
    final ctx = _ctx;
    if (ctx == null) return null;
    if (prompts.isEmpty) return const [];
    return showDialog<List<String>>(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => _InteractiveDialog(
        title: name.trim().isEmpty ? host.displayAddress : name,
        instruction: instruction,
        prompts: prompts,
      ),
    );
  }
}

class _SecretDialog extends StatefulWidget {
  const _SecretDialog({
    required this.title,
    required this.subtitle,
    required this.label,
    this.error,
    this.canRemember = true,
  });

  final String title;
  final String subtitle;
  final String label;
  final String? error;
  final bool canRemember;

  @override
  State<_SecretDialog> createState() => _SecretDialogState();
}

class _SecretDialogState extends State<_SecretDialog> {
  final _text = TextEditingController();
  bool _remember = true;
  bool _obscure = true;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop<SecretAnswer>(
      context, (value: _text.text, remember: widget.canRemember && _remember));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: Icon(Icons.lock_outline, color: theme.colorScheme.primary),
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.subtitle,
                  style: monoStyle(context, size: 13, color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              TextField(
                controller: _text,
                autofocus: true,
                obscureText: _obscure,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: widget.label,
                  errorText: widget.error,
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: IconButton(
                    tooltip: _obscure ? context.strings.show : context.strings.hide,
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (widget.canRemember) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _remember,
                  onChanged: (v) => setState(() => _remember = v ?? false),
                  title: Text(context.strings.saveInKeyring),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
        FilledButton(onPressed: _submit, child: Text(context.strings.connect)),
      ],
    );
  }
}

class _InteractiveDialog extends StatefulWidget {
  const _InteractiveDialog({
    required this.title,
    required this.instruction,
    required this.prompts,
  });

  final String title;
  final String instruction;
  final List<SshPrompt> prompts;

  @override
  State<_InteractiveDialog> createState() => _InteractiveDialogState();
}

class _InteractiveDialogState extends State<_InteractiveDialog> {
  late final _fields = [for (final _ in widget.prompts) TextEditingController()];

  @override
  void dispose() {
    for (final f in _fields) {
      f.dispose();
    }
    super.dispose();
  }

  void _submit() => Navigator.pop(context, [for (final f in _fields) f.text]);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.verified_user_outlined),
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.instruction.trim().isNotEmpty) ...[
                Text(widget.instruction.trim()),
                const SizedBox(height: 12),
              ],
              for (var i = 0; i < widget.prompts.length; i++) ...[
                TextField(
                  controller: _fields[i],
                  autofocus: i == 0,
                  obscureText: !widget.prompts[i].echo,
                  onSubmitted: (_) {
                    if (i == widget.prompts.length - 1) _submit();
                  },
                  decoration: InputDecoration(
                    labelText: widget.prompts[i].text.trim().replaceAll(RegExp(r':\s*$'), ''),
                    filled: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
        FilledButton(onPressed: _submit, child: Text(context.strings.continueAction)),
      ],
    );
  }
}
