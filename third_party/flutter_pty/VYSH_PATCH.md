# flutter_pty для vysh

Копия пакета flutter_pty 0.4.2 с pub.dev (лицензия в LICENSE). Правки vysh:

**android/build.gradle:**

- `compileSdk` 36 вместо 35 - зависимости android/androidx требуют 36,
  иначе сборка APK падает на проверке AAR;
- `minSdk` 26 вместо 21 - как в приложении.

**src/flutter_pty_win.c (Windows, ConPTY):**

- Убран флаг `STARTF_USESTDHANDLES` с NULL-хэндлами у `CreateProcessW`.
  Сам `cmd.exe` с ними ещё работал, но запущенные из него powershell, wsl
  и bash наследовали невалидный stdout и сразу падали. С атрибутом
  `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` Windows подключает потоки сам.
- UTF-8 → UTF-16 теперь через `MultiByteToWideChar` (команда, окружение,
  рабочая папка). Прежнее «побайтовое» расширение искажало всё вне ASCII:
  пути и переменные с русскими буквами приходили в процесс мусором.
- Исправлено дублирование `executable` в `build_command`: `arguments[0]`
  в `flutter_pty.dart` уже содержит имя исполняемого файла, из-за чего в
  `CreateProcessW` передавалось `cmd.exe cmd.exe /k ...`, запускавшее
  вложенный процесс и блокировавшее ввод.
- Закрываются концы пайпов ConPTY (`inputReadSide` и `outputWriteSide`)
  сразу после `CreatePseudoConsole`, убран блокирующий `FlushFileBuffers`
  в `pty_write`, убран `Sleep(1000)` и закрывается `processInfo.hThread`.

**lib/flutter_pty.dart:**

- На Windows копируется полное окружение родительского процесса, а не
  белый список из 6 переменных. Без `SYSTEMROOT` не запускался WSL, без
  `COMSPEC`/`USERPROFILE`/`TMP` ломались вложенные powershell и скрипты.
  `LANG=en_US.UTF-8` на Windows не ставится: переменной там нет, а cmd
  на неё не смотрит.

Нужен, чтобы локальный терминал на Android работал через настоящий PTY.
В Android нет `script` из toybox, поэтому раньше оболочка запускалась без
псевдотерминала: не было эха ввода и не работали Ctrl+C и полноэкранные
программы. На остальных платформах путь через PTY уже был.

Обновлять вместе с pub.dev, перенося эти правки. Когда выйдет flutter_pty2
с поддержкой всех ABI Android без build hooks или flutter_pty научится
собираться без правок, папку можно удалить.
