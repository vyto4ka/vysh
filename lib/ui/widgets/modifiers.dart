import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Какие модификаторы (Ctrl, Shift, Alt) сейчас зажаты - по нашим собственным
/// наблюдениям, а не по [HardwareKeyboard].
///
/// Зачем: если отпустить клавишу, когда окно vysh не в фокусе (Win+Shift+S,
/// Alt+Tab, Ctrl+Alt+Del), Flutter не узнаёт об этом до следующего нажатия
/// любой клавиши и считает модификатор зажатым. Тогда обычный клик по хосту
/// отмечал его как Ctrl+клик, а выделение в терминале становилось
/// прямоугольным, как с Alt. Здесь всё сбрасывается, как только окно теряет
/// фокус.
class Modifiers {
  Modifiers._() {
    HardwareKeyboard.instance.addHandler(_onKey);
    _life = AppLifecycleListener(
      onInactive: _down.clear,
      onHide: _down.clear,
      onPause: _down.clear,
    );
  }

  static final instance = Modifiers._();

  /// Вызвать один раз при старте, после WidgetsFlutterBinding.ensureInitialized.
  static void init() => instance;

  // ignore: unused_field
  late final AppLifecycleListener _life;
  final _down = <LogicalKeyboardKey>{};

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent) {
      _down.add(e.logicalKey);
    } else if (e is KeyUpEvent) {
      _down.remove(e.logicalKey);
    }
    return false; // только наблюдаем
  }

  bool _has(LogicalKeyboardKey left, LogicalKeyboardKey right) =>
      _down.contains(left) || _down.contains(right);

  bool get ctrl => _has(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight);
  bool get shift => _has(LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight);
  bool get alt => _has(LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight);
}
