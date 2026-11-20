# flutter_pty для vysh

Копия пакета flutter_pty 0.4.2 с pub.dev (лицензия в LICENSE). Правки vysh:

**android/build.gradle:**

- `compileSdk` 36 вместо 35 - зависимости android/androidx требуют 36,
  иначе сборка APK падает на проверке AAR;
- `minSdk` 26 вместо 21 - как в приложении.

**src/flutter_pty_win.c (Windows, ConPTY):**

- Установлен флаг `STARTF_USESTDHANDLES` с NULL-хэндлами у `CreateProcessW`
  (`STARTUPINFOEXW`). ConPTY требует этот флаг, чтобы стандартные дескрипторы
  (stdin, stdout, stderr) процесса были корректно перенаправлены в
  псевдоконсоль, иначе ввод не поступает в процесс.
- UTF-8 → UTF-16 через `MultiByteToWideChar` (команда, окружение,
  рабочая папка). Блок переменных окружения (`build_environment`) теперь
  корректно конвертирует все переменные и завершается двойным нулём (`\0\0`),
  а не обрезается на первом же `\0` (что приводило к ошибке 87
  ERROR_INVALID_PARAMETER у `CreateProcessW`).
- Исправлено дублирование `executable` в `build_command`: `arguments[0]`
  в `flutter_pty.dart` уже содержит имя исполняемого файла, проверка
  выполняется без учёта регистра (`_stricmp`).
- Концы пайпов ConPTY (`inputReadSide` и `outputWriteSide`) закрываются
  ПОСЛЕ `CreateProcessW` (не сразу после `CreatePseudoConsole`): ConPTY не
  дублирует переданные хэндлы, а читает/пишет через них сам.
  Освобождается `lpAttributeList` через `DeleteProcThreadAttributeList` и `free`.
  Убран блокирующий `FlushFileBuffers` в `pty_write`, убран `Sleep(1000)`
  и закрывается `processInfo.hThread`.

**src/forkpty.c и src/flutter_pty_unix.c (Linux / macOS / Android):**

- В `forkpty.c` закрывается slave-дескриптор `pts` в родительском процессе,
  когда `slave == NULL` (иначе `read()` на `ptm` никогда не получал EOF и
  поток чтения вместе с дескрипторами утекал на каждую закрытую вкладку),
  а также освобождаются `ptm`/`pts` при ошибках и используется `_exit(1)`.
- В `flutter_pty_unix.c` после неудачного `execvp` в дочернем процессе
  добавлен `_exit(127)`, потоки отсоединяются через `pthread_detach`,
  освобождаются `options`, закрывается `fd` при выходе из `read_loop` и
  обрабатывается `EINTR`.

**lib/flutter_pty.dart:**

- На всех платформах (не только Windows) наследуется полное окружение
  родительского процесса; на Unix системный `LANG` не перезаписывается
  принудительно на `en_US.UTF-8`, если локаль уже задана.
- Временные нативные строки (`argv`, `envp`, `executable`, `working_directory`)
  освобождаются в `finally` сразу после `pty_create`.
- На Windows блок окружения отсортирован по алфавиту без учёта регистра
  (требование Win32 к `CreateProcessW`), `LANG` не подставляется.

Нужен, чтобы локальный терминал на Android работал через настоящий PTY.
В Android нет `script` из toybox, поэтому раньше оболочка запускалась без
псевдотерминала: не было эха ввода и не работали Ctrl+C и полноэкранные
программы. На остальных платформах путь через PTY уже был.

Обновлять вместе с pub.dev, перенося эти правки. Когда выйдет flutter_pty2
с поддержкой всех ABI Android без build hooks или flutter_pty научится
собираться без правок, папку можно удалить.
