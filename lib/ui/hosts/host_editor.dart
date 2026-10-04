import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/host.dart';
import '../../domain/ports/secret_store.dart';
import '../../domain/services/hosts_controller.dart';
import '../../domain/services/ports_providers.dart';
import '../../domain/services/tabs_controller.dart';
import '../../domain/services/terminal_session.dart' show expandHome;
import '../theme/app_theme.dart';

/// Открыть боковую панель создания/редактирования хоста.
Future<void> showHostEditor(BuildContext context, {Host? host, bool duplicate = false}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Закрыть',
    barrierColor: Colors.black.withValues(alpha: 0.32),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      child: _HostEditorSheet(host: host, duplicate: duplicate),
    ),
    transitionBuilder: (context, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(curved),
        child: child,
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
  final _form = GlobalKey<FormState>();
  late final TextEditingController _label;
  late final TextEditingController _address;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _password;
  late final TextEditingController _keyPath;
  late final TextEditingController _group;
  late AuthMethod _auth;
  late int _color;
  bool _rememberPassword = true;
  bool _hasSavedPassword = false;
  bool _obscure = true;
  bool _saving = false;

  bool get _isEdit => widget.host != null && !widget.duplicate;

  @override
  void initState() {
    super.initState();
    final h = widget.host;
    _label = TextEditingController(
        text: h == null ? '' : (widget.duplicate ? '${h.title} (копия)' : h.label));
    _address = TextEditingController(text: h?.address ?? '');
    _lastAddressLen = _address.text.length;
    _port = TextEditingController(text: '${h?.port ?? 22}');
    _user = TextEditingController(text: h?.username ?? 'root');
    _password = TextEditingController();
    _keyPath = TextEditingController(text: h?.keyPath ?? '');
    _group = TextEditingController(text: h?.group ?? '');
    _auth = h?.auth ?? AuthMethod.password;
    _color = h?.color ?? hostColors.first;
    if (_isEdit) _checkSavedPassword();
  }

  Future<void> _checkSavedPassword() async {
    final saved = await ref.read(secretStoreProvider).read(passwordKey(widget.host!.id));
    if (mounted && saved != null) setState(() => _hasSavedPassword = true);
  }

  @override
  void dispose() {
    for (final c in [_label, _address, _port, _user, _password, _keyPath, _group]) {
      c.dispose();
    }
    super.dispose();
  }

  int _lastAddressLen = 0;

  /// Вставили `user@host:port` в поле адреса - раскладываем по полям.
  /// Срабатывает только на вставку (скачок длины), а не при наборе по символу.
  void _onAddressChanged(String v) {
    final pasted = v.length - _lastAddressLen > 2;
    _lastAddressLen = v.length;
    final t = v.trim();
    final looksQuick =
        pasted && (t.contains('@') || RegExp(r'^[^:\[\]]+:\d+$').hasMatch(t));
    final quick = looksQuick ? Host.tryParseQuick(t) : null;
    if (quick == null) {
      setState(() {}); // обновить подсказку в поле «Название»
      return;
    }
    setState(() {
      _address.value = TextEditingValue(
        text: quick.address,
        selection: TextSelection.collapsed(offset: quick.address.length),
      );
      _port.text = '${quick.port}';
      if (t.contains('@')) _user.text = quick.username;
      _lastAddressLen = quick.address.length;
    });
  }

  Future<void> _pickKey() async {
    final file = await openFile(
      confirmButtonText: 'Выбрать',
      initialDirectory: expandHome('~/.ssh'),
    );
    if (file != null) setState(() => _keyPath.text = file.path);
  }

  Host? _buildHost() {
    if (!(_form.currentState?.validate() ?? false)) return null;
    final key = _keyPath.text.trim();
    return Host(
      id: _isEdit ? widget.host!.id : newId(),
      label: _label.text.trim(),
      address: _address.text.trim(),
      port: int.parse(_port.text.trim()),
      username: _user.text.trim(),
      auth: _auth,
      keyPath: _auth == AuthMethod.key && key.isNotEmpty ? key : null,
      group: _group.text.trim(),
      color: _color,
      lastConnectedAt: _isEdit ? widget.host!.lastConnectedAt : null,
    );
  }

  Future<void> _save({bool connect = false}) async {
    if (_saving) return;
    final host = _buildHost();
    if (host == null) return;
    setState(() => _saving = true);

    ref.read(hostsProvider.notifier).upsert(host);

    final secrets = ref.read(secretStoreProvider);
    final pwd = _password.text;
    String? warning;
    if (host.auth != AuthMethod.password || !_rememberPassword) {
      // Пароль не нужен или его просили не хранить - убираем сохранённый.
      await secrets.delete(passwordKey(host.id));
    } else if (pwd.isNotEmpty) {
      try {
        await secrets.write(passwordKey(host.id), pwd);
      } catch (_) {
        warning = 'Не удалось сохранить пароль: системное хранилище недоступно';
      }
    }

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    if (warning != null) messenger.showSnackBar(SnackBar(content: Text(warning)));
    if (connect) {
      ref.read(tabsProvider.notifier).openHost(
            host,
            password: host.auth == AuthMethod.password && pwd.isNotEmpty ? pwd : null,
          );
    }
  }

  InputDecoration _dec(String label, {String? hint, Widget? icon, String? helper, Widget? suffix}) =>
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

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 10),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  Widget _authFields() {
    switch (_auth) {
      case AuthMethod.password:
        return Column(
          key: const ValueKey('password'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _password,
              obscureText: _obscure,
              decoration: _dec(
                'Пароль',
                icon: const Icon(Icons.lock_outline),
                helper: _hasSavedPassword
                    ? 'Пароль уже сохранён. Оставьте поле пустым, чтобы не менять'
                    : 'Можно оставить пустым, спросим при подключении',
                suffix: IconButton(
                  tooltip: _obscure ? 'Показать' : 'Скрыть',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _rememberPassword,
              onChanged: (v) => setState(() => _rememberPassword = v ?? false),
              title: const Text('Запомнить пароль'),
              subtitle: const Text('В системном хранилище. Без галочки пароль '
                  'используется только для текущего подключения'),
            ),
          ],
        );
      case AuthMethod.key:
        return TextFormField(
          key: const ValueKey('key'),
          controller: _keyPath,
          decoration: _dec(
            'Приватный ключ',
            hint: '~/.ssh/id_ed25519',
            icon: const Icon(Icons.vpn_key_outlined),
            helper: 'Парольную фразу ключа спросим при подключении',
            suffix: IconButton(
              tooltip: 'Выбрать файл',
              icon: const Icon(Icons.folder_open_outlined),
              onPressed: _pickKey,
            ),
          ),
        );
      case AuthMethod.agent:
        return const _Note(
          'Попробуем стандартные ключи из ~/.ssh: id_ed25519, id_ecdsa, id_rsa '
          '(без парольной фразы). ssh-agent и Pageant появятся позже.',
          key: ValueKey('agent'),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final groups = ref.watch(hostGroupsProvider);
    final width = MediaQuery.sizeOf(context).width;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _save(),
        const SingleActivator(LogicalKeyboardKey.enter, control: true, shift: true): () =>
            _save(connect: true),
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
      },
      child: Material(
        color: scheme.surfaceContainerLow,
        elevation: 2,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width < 520 ? width : 460,
          height: double.infinity,
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 12, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(_isEdit ? 'Изменить хост' : 'Новый хост',
                            style: theme.textTheme.titleLarge),
                      ),
                      IconButton(
                        tooltip: 'Закрыть (Esc)',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    children: [
                      // ── Подключение ──
                      _sectionTitle(context, 'Подключение'),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _address,
                              autofocus: !_isEdit,
                              decoration: _dec('Адрес',
                                  hint: '10.0.0.1, example.com или user@host:port',
                                  icon: const Icon(Icons.public)),
                              onChanged: _onAddressChanged,
                              validator: (v) =>
                                  (v == null || v.trim().isEmpty) ? 'Укажите адрес' : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 96,
                            child: TextFormField(
                              controller: _port,
                              keyboardType: TextInputType.number,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              decoration: _dec('Порт'),
                              validator: (v) {
                                final p = int.tryParse(v ?? '');
                                return (p == null || p < 1 || p > 65535) ? '1-65535' : null;
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _user,
                        decoration: _dec('Пользователь', icon: const Icon(Icons.person_outline)),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Укажите логин' : null,
                      ),

                      // ── Вход ──
                      _sectionTitle(context, 'Вход'),
                      SegmentedButton<AuthMethod>(
                        segments: const [
                          ButtonSegment(value: AuthMethod.password, label: Text('Пароль'),
                              icon: Icon(Icons.password)),
                          ButtonSegment(value: AuthMethod.key, label: Text('Ключ'),
                              icon: Icon(Icons.key)),
                          ButtonSegment(value: AuthMethod.agent, label: Text('Авто'),
                              icon: Icon(Icons.auto_awesome)),
                        ],
                        selected: {_auth},
                        onSelectionChanged: (s) => setState(() => _auth = s.first),
                      ),
                      const SizedBox(height: 12),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        alignment: Alignment.topCenter,
                        child: _authFields(),
                      ),

                      // ── В списке ──
                      _sectionTitle(context, 'Как показывать в списке'),
                      TextFormField(
                        controller: _label,
                        decoration: _dec('Название',
                            hint: _address.text.trim().isEmpty
                                ? 'Например: роутер, web-prod'
                                : 'По умолчанию: ${_address.text.trim()}',
                            icon: const Icon(Icons.label_outline)),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _group,
                        decoration: _dec('Группа', hint: 'Например: prod, дом, клиенты',
                            icon: const Icon(Icons.folder_outlined)),
                        onChanged: (_) => setState(() {}),
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
                                selected: _group.text.trim() == g,
                                onSelected: (on) => setState(() => _group.text = on ? g : ''),
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
                              color: Color(_color).withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(Icons.dns_rounded, color: Color(_color), size: 20),
                          ),
                          const SizedBox(width: 12),
                          Text('Цвет значка', style: theme.textTheme.bodyLarge),
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
                              selected: c == _color,
                              onTap: () => setState(() => _color = c),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 24, 16),
                  child: Row(
                    children: [
                      if (_isEdit)
                        IconButton(
                          tooltip: 'Удалить хост',
                          color: scheme.error,
                          onPressed: () {
                            ref.read(hostsProvider.notifier).remove(widget.host!.id);
                            Navigator.of(context).pop();
                          },
                          icon: const Icon(Icons.delete_outline),
                        ),
                      const Spacer(),
                      Tooltip(
                        message: 'Ctrl+Shift+Enter',
                        child: TextButton(
                          onPressed: _saving ? null : () => _save(connect: true),
                          child: const Text('Сохранить и подключиться'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'Ctrl+Enter',
                        child: FilledButton(
                          onPressed: _saving ? null : _save,
                          child: const Text('Сохранить'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: scheme.onSecondaryContainer)),
          ),
        ],
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, required this.selected, required this.onTap});

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.onSurface : Colors.transparent,
            width: 2.5,
          ),
        ),
        child: selected ? const Icon(Icons.check, size: 18, color: Colors.white) : null,
      ),
    );
  }
}
