import 'dart:typed_data';

abstract interface class TerminalShell {
  Stream<Uint8List> get output;

  void write(Uint8List data);

  void resize(int columns, int rows);

  Future<void> get done;

  void close();
}

/// Optional OS-backed directory information. No commands are written to stdin.
abstract interface class DirectoryAwareShell {
  String? get initialDirectory;
  Future<String?> workingDirectory();
}
