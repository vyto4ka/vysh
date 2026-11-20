part of 'host_editor.dart';

/// Секции формы редактора хоста. Своего состояния у них нет: всё в [HostForm].

InputDecoration _dec(
  String label, {
  String? hint,
  Widget? icon,
  String? helper,
  Widget? suffix,
}) =>
    InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      helperMaxLines: 2,
      prefixIcon: icon,
      suffixIcon: suffix,
      filled: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 14),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );
}

/// Адрес, порт, пользователь.
class _ConnectionSection extends StatelessWidget {
  const _ConnectionSection({required this.form, required this.strings, required this.autofocus});

  final HostForm form;
  final AppStrings strings;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(strings.sectionConnection),
        LayoutBuilder(
          builder: (context, constraints) {
            final address = TextFormField(
              controller: form.address,
              autofocus: autofocus,
              decoration: _dec(
                strings.addressField,
                hint: strings.addressHintFull,
                icon: const Icon(Icons.public),
              ),
              onChanged: form.onAddressChanged,
              validator: (v) => (v == null || v.trim().isEmpty) ? strings.requiredField : null,
            );
            final port = SizedBox(
              width: 96,
              child: TextFormField(
                controller: form.port,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: _dec(strings.portField),
                validator: (v) => HostForm.validPort(v) ? null : strings.invalidPort,
              ),
            );
            return constraints.maxWidth < 420
                ? Column(children: [address, const SizedBox(height: 12), port])
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Expanded(child: address), const SizedBox(width: 12), port],
                  );
          },
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: form.user,
          decoration: _dec(
            strings.userField,
            hint: 'root',
            icon: const Icon(Icons.person_outline),
          ).copyWith(floatingLabelBehavior: FloatingLabelBehavior.always),
        ),
      ],
    );
  }
}

/// Способ входа и его поля: пароль, файл ключа или стандартные ключи.
class _AuthSection extends StatelessWidget {
  const _AuthSection({
    required this.form,
    required this.strings,
    required this.hasSavedPassword,
    required this.onPickKey,
  });

  final HostForm form;
  final AppStrings strings;
  final bool hasSavedPassword;
  final VoidCallback onPickKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(strings.authMethod),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<AuthMethod>(
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          segments: [
            ButtonSegment(
              value: AuthMethod.password,
              label: Text(strings.authPassword),
              icon: const Icon(Icons.password),
            ),
            ButtonSegment(
              value: AuthMethod.key,
              label: Text(strings.authKey),
              icon: const Icon(Icons.key),
            ),
            if (!PlatformCapabilities.sharedDownloads ||
                form.auth == AuthMethod.agent)
              ButtonSegment(
                value: AuthMethod.agent,
                label: Text(strings.authAuto),
                icon: const Icon(Icons.auto_awesome),
              ),
          ],
          selected: {form.auth},
          onSelectionChanged: (s) => form.auth = s.first,
          ),
        ),
        const SizedBox(height: 12),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topCenter,
          child: _fields(),
        ),
      ],
    );
  }

  Widget _fields() => switch (form.auth) {
        AuthMethod.password => Column(
            key: const ValueKey('password'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: form.password,
                obscureText: form.obscurePassword,
                decoration: _dec(
                  strings.passwordField,
                  icon: const Icon(Icons.lock_outline),
                  helper: hasSavedPassword ? strings.passwordSavedHelper : null,
                  suffix: IconButton(
                    tooltip: form.obscurePassword ? strings.show : strings.hide,
                    icon: Icon(
                      form.obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    ),
                    onPressed: form.toggleObscure,
                  ),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: form.rememberPassword,
                onChanged: (v) => form.rememberPassword = v ?? false,
                title: Text(strings.rememberPasswordCheckbox),
              ),
            ],
          ),
        AuthMethod.key => TextFormField(
            key: const ValueKey('key'),
            controller: form.keyPath,
            decoration: _dec(
              strings.privateKeyField,
              hint: '~/.ssh/id_ed25519',
              icon: const Icon(Icons.vpn_key_outlined),
              suffix: IconButton(
                tooltip: strings.selectKeyFile,
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: onPickKey,
              ),
            ),
          ),
        AuthMethod.agent => _Note(strings.defaultKeysNote, key: const ValueKey('agent')),
      };
}

/// Название, группа и цвет карточки.
class _ListSection extends StatelessWidget {
  const _ListSection({required this.form, required this.strings, required this.groups});

  final HostForm form;
  final AppStrings strings;
  final List<String> groups;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final address = form.address.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(strings.sectionListAppearance),
        TextFormField(
          controller: form.label,
          decoration: _dec(
            strings.labelField,
            hint: address.isEmpty ? null : address,
            icon: const Icon(Icons.label_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: form.group,
          decoration: _dec(strings.groupField, icon: const Icon(Icons.folder_outlined)),
        ),
        if (groups.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final g in groups)
                ChoiceChip(
                  label: Text(g),
                  selected: form.group.text.trim() == g,
                  onSelected: (on) => form.group.text = on ? g : '',
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            // Живой предпросмотр значка, как он будет выглядеть в списке.
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Color(form.color).withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.dns_rounded, color: Color(form.color), size: 20),
            ),
            const SizedBox(width: 12),
            Text(strings.cardColor, style: theme.textTheme.bodyLarge),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in hostColors)
              _ColorDot(
                color: Color(c),
                selected: c == form.color,
                onTap: () => form.color = c,
              ),
          ],
        ),
      ],
    );
  }
}

/// KeepAlive этого хоста.
class _KeepAliveSection extends StatelessWidget {
  const _KeepAliveSection({required this.form, required this.strings});

  final HostForm form;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(strings.keepAliveGlobalTitle),
        DropdownButtonFormField<int?>(
          isExpanded: true,
          initialValue: form.keepAliveSeconds,
          decoration: _dec(strings.keepAliveField, icon: const Icon(Icons.timer_outlined)),
          items: [
            DropdownMenuItem(value: null, child: Text(strings.keepAliveDefault)),
            DropdownMenuItem(value: 0, child: Text(strings.keepAliveOff)),
            DropdownMenuItem(value: 15, child: Text(strings.keepAliveSecondsVal(15))),
            DropdownMenuItem(value: 30, child: Text(strings.keepAliveSecondsVal(30))),
            DropdownMenuItem(value: 60, child: Text(strings.keepAliveRecom)),
            DropdownMenuItem(value: 120, child: Text(strings.keepAliveMinutes(120))),
            DropdownMenuItem(value: 300, child: Text(strings.keepAliveMinutes(300))),
          ],
          onChanged: (v) => form.keepAliveSeconds = v,
        ),
      ],
    );
  }
}

/// Нижняя панель: удалить, «Сохранить и подключиться», «Сохранить».
class _EditorActions extends StatelessWidget {
  const _EditorActions({
    required this.strings,
    required this.saving,
    required this.onDelete,
    required this.onSave,
    required this.onSaveAndConnect,
  });

  final AppStrings strings;
  final bool saving;

  /// null - хост новый, удалять нечего.
  final VoidCallback? onDelete;
  final VoidCallback onSave;
  final VoidCallback onSaveAndConnect;

  @override
  Widget build(BuildContext context) {
    Widget withShortcut(String keys, Widget child) =>
        DesktopEnv.isDesktop ? Tooltip(message: keys, child: child) : child;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 16, 14),
      child: Row(
        children: [
          if (onDelete != null)
            IconButton(
              tooltip: strings.delete,
              color: Theme.of(context).colorScheme.error,
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline),
            ),
          const Spacer(),
          Flexible(
            child: withShortcut(
              PlatformCapabilities.isMacOS ? '⌘⇧Enter' : 'Ctrl+Shift+Enter',
              TextButton(
                onPressed: saving ? null : onSaveAndConnect,
                child: Text(
                  strings.saveAndConnect,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          withShortcut(
            PlatformCapabilities.isMacOS ? '⌘Enter' : 'Ctrl+Enter',
            FilledButton(
              onPressed: saving ? null : onSave,
              child: Text(strings.save),
            ),
          ),
        ],
      ),
    );
  }
}
