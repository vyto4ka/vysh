import 'dart:typed_data';

abstract interface class TerminalShell {
  Stream<Uint8List> get output;

  void write(Uint8List data);

  void resize(int columns, int rows);

  Future<void> get done;

  void close();
}
