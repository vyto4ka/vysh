import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/ports/background_sessions.dart';
import '../domain/ports/document_store.dart';
import '../domain/ports/local_shell.dart';
import '../domain/ports/secret_store.dart';
import '../domain/ports/session_prompts.dart';
import '../domain/ports/ssh_transport.dart';
import '../domain/services/known_hosts.dart';
import '../infra/local/process_local_shell.dart';
import '../infra/platform/android_wakelock.dart';
import '../infra/secrets/keyring_secret_store.dart';
import '../infra/ssh/dartssh2_connector.dart';
import '../infra/storage/json_store.dart';

/// Единственное место, где порты домена связываются с реализациями.
/// Тесты и main.dart переопределяют нужные providers.

final sshConnectorProvider = Provider<SshConnector>((ref) => const DartSsh2Connector());
final localShellLauncherProvider =
    Provider<LocalShellLauncher>((ref) => const ProcessLocalShellLauncher());
final secretStoreProvider = Provider<SecretStore>((ref) => KeyringSecretStore());

/// Диалоги подключения. UI переопределяет его в main.dart.
final sessionPromptsProvider = Provider<SessionPrompts>(
  (ref) => throw UnimplementedError('sessionPromptsProvider must be overridden'),
);

/// Документ конфигурации по имени файла.
final documentStoreProvider =
    Provider.family<DocumentStore, String>((ref, name) => JsonStore(name));

final backgroundSessionsProvider =
    Provider<BackgroundSessions>((ref) => const AndroidBackgroundSessions());

final knownHostsProvider = Provider<KnownHosts>(
  (ref) => KnownHosts(ref.read(documentStoreProvider('known_hosts.json'))),
);
