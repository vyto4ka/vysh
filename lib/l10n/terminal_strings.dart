part of 'app_strings.dart';

/// Терминал: выделение, вставка, служебные подписи.
extension TerminalStrings on AppStrings {
  String get localTerminal =>
      isRu ? 'Локальный терминал' : 'Local terminal';
  String get localShellStarting =>
      isRu ? 'Запуск локальной оболочки…' : 'Starting local shell…';
  String get localShellRunning =>
      isRu ? 'Локальная сессия' : 'Local session';
  String get localShellFailed =>
      isRu ? 'Оболочка остановлена' : 'Shell stopped';
  String localShellFailure(LocalShellFailure f) {
    final detail = f.detail;
    final tail = detail == null || detail.isEmpty ? '' : ': $detail';
    return switch (f.error) {
      LocalShellError.unsupported => isRu
          ? 'Локальный терминал недоступен на этой платформе'
          : 'Local terminal is not available on this platform',
      LocalShellError.launchFailed => isRu
          ? 'Не удалось запустить локальную оболочку$tail'
          : 'Could not start the local shell$tail',
    };
  }

  String get eraseLine => isRu ? 'Стереть строку' : 'Erase line';

  String get trailingEnterTitle =>
      isRu ? 'Вставить с переводом строки?' : 'Paste with a line break?';

  String get trailingEnterDesc => isRu
      ? 'Текст заканчивается переводом строки: команда выполнится сразу после вставки.'
      : 'The text ends with a line break: the command will run right after pasting.';

  String localFileFailure(LocalFileFailure f) {
    final detail = f.args['detail'];
    final tail = detail == null || detail.isEmpty ? '' : ': $detail';
    return switch (f.error) {
      LocalFileError.publishFailed =>
        isRu ? 'Не удалось сохранить в Download$tail' : 'Could not save to Download$tail',
      LocalFileError.storagePermissionDenied => isRu
          ? 'Нет разрешения на запись в папку Download'
          : 'No permission to write to the Download folder',
      LocalFileError.badRemoteName => isRu
          ? 'Недопустимое имя файла с сервера: ${f.args['name']}'
          : 'Invalid file name from the server: ${f.args['name']}',
      LocalFileError.openFailed => isRu ? 'Не удалось открыть файл$tail' : 'Could not open the file$tail',
    };
  }

  /// Текст любой ошибки для пользователя: известные - по коду, прочие как есть.
  String errorText(Object e) => switch (e) {
        SshFailure() => sshFailure(e),
        SftpFailure() => sftpFailure(e),
        LocalShellFailure() => localShellFailure(e),
        LocalFileFailure() => localFileFailure(e),
        FileSystemException(:final message, :final osError) =>
          osError == null ? message : '$message: ${osError.message}',
        TransferCancelled() => isRu ? 'Отменено' : 'Cancelled',
        _ => '$e',
      };
}
