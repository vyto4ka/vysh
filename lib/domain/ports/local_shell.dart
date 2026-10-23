import 'terminal_shell.dart';

enum LocalShellError { unsupported, launchFailed }

class LocalShellFailure implements Exception {
  const LocalShellFailure(this.error, [this.detail]);

  final LocalShellError error;
  final String? detail;

  @override
  String toString() =>
      detail == null ? 'LocalShellFailure(${error.name})' : 'LocalShellFailure(${error.name}, $detail)';
}

abstract interface class LocalShellLauncher {
  bool get supported;

  String get shellName;

  Future<TerminalShell> start({required int columns, required int rows});
}
