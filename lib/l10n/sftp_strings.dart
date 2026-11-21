part of 'app_strings.dart';

/// Файлы (SFTP): ошибки, панель, диалоги, очередь передач.
extension SftpStrings on AppStrings {
  // ─── Ошибки ──────────────────────────────────────────────────────

  String sftpFailure(SftpFailure f) {
    String a(String k) => f.args[k] ?? '';
    final detail = f.args['detail'];
    return switch (f.code) {
      SftpFailureCode.noSuchFile =>
        isRu ? 'Нет такого файла или папки' : 'No such file or folder',
      SftpFailureCode.permissionDenied =>
        isRu ? 'Нет прав доступа' : 'Permission denied',
      SftpFailureCode.notADirectory =>
        isRu
            ? '${a('path')} существует и это не папка'
            : '${a('path')} exists and is not a folder',
      SftpFailureCode.isDirectory =>
        isRu ? '${a('path')} - это папка' : '${a('path')} is a folder',
      SftpFailureCode.exists =>
        isRu ? 'Файл уже существует' : 'File already exists',
      SftpFailureCode.failed =>
        isRu
            ? 'Операция не выполнена${detail == null ? '' : ': $detail'}'
            : 'Operation failed${detail == null ? '' : ': $detail'}',
      SftpFailureCode.unsupported =>
        isRu
            ? 'Сервер не поддерживает эту операцию'
            : 'The server does not support this operation',
      SftpFailureCode.noSftpServer =>
        isRu
            ? 'Сервер не ответил по SFTP. Возможно, на нём нет sftp-server '
                  '(на OpenWrt: opkg install openssh-sftp-server).'
            : 'The server did not answer over SFTP. It may have no sftp-server '
                  '(on OpenWrt: opkg install openssh-sftp-server).',
      SftpFailureCode.sftpUnavailable =>
        isRu
            ? 'Сервер не поддерживает SFTP: ${a('detail')}'
            : 'The server does not support SFTP: ${a('detail')}',
      SftpFailureCode.noConnection => noServerConnection,
      SftpFailureCode.connectionClosed =>
        isRu
            ? 'Соединение с сервером закрыто'
            : 'Connection to the server closed',
      SftpFailureCode.localFile =>
        isRu ? 'Локальный файл: ${a('detail')}' : 'Local file: ${a('detail')}',
      SftpFailureCode.connection =>
        isRu ? 'Соединение: ${a('detail')}' : 'Connection: ${a('detail')}',
      SftpFailureCode.stalled =>
        isRu
            ? 'Сервер перестал присылать данные (${a('seconds')} с без ответа)'
            : 'The server stopped sending data (no response for ${a('seconds')} s)',
      SftpFailureCode.other =>
        detail ??
            (isRu ? 'Ошибка SFTP (${a('code')})' : 'SFTP error (${a('code')})'),
    };
  }

  // ─── Размеры ─────────────────────────────────────────────────────

  /// 1536 → «1.5 КБ».
  String bytes(num value) {
    final units = isRu
        ? const ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ']
        : const ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = value.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    final text = v >= 100 || i == 0
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(1);
    return '$text ${units[i]}';
  }

  /// 5 д 3 ч / 3 ч 12 мин / 12 мин.
  String uptime(Duration d) {
    final days = d.inDays, hours = d.inHours % 24, mins = d.inMinutes % 60;
    if (days > 0) return isRu ? '$days д $hours ч' : '${days}d ${hours}h';
    if (hours > 0) return isRu ? '$hours ч $mins мин' : '${hours}h ${mins}m';
    return isRu ? '$mins мин' : '${mins}m';
  }

  // ─── Панель файлов ───────────────────────────────────────────────

  String get uploadAction => isRu ? 'Загрузить' : 'Upload';
  String get saveHere => isRu ? 'Сохранить сюда' : 'Save here';
  String get downloadingToDownloads => isRu
      ? 'Скачивание в папку Download'
      : 'Downloading to the Download folder';
  String downloadingTo(String dir) =>
      isRu ? 'Скачивание в $dir' : 'Downloading to $dir';
  String savedOnServer(String name) =>
      isRu ? '«$name» сохранён на сервере' : '«$name» saved on the server';
  String get newFolder => isRu ? 'Новая папка' : 'New folder';
  String get folderName => isRu ? 'Имя папки' : 'Folder name';
  String get newFile => isRu ? 'Новый файл' : 'New file';
  String get fileName => isRu ? 'Имя файла' : 'File name';
  String get open => isRu ? 'Открыть' : 'Open';
  String get openExternally =>
      isRu ? 'Открыть во внешней программе' : 'Open externally';
  String get editText => isRu ? 'Редактировать текст' : 'Edit text';
  String get save => isRu ? 'Сохранить' : 'Save';
  String get wordWrap => isRu ? 'Перенос строк' : 'Word wrap';
  String get unsavedChangesTitle =>
      isRu ? 'Несохранённые изменения' : 'Unsaved changes';
  String get unsavedChangesDesc => isRu
      ? 'В файле остались несохранённые правки. Закрыть без сохранения?'
      : 'This file has unsaved changes. Discard them?';
  String get discardChanges => isRu ? 'Не сохранять' : 'Discard';
  String get fileTooLargeForEditor => isRu
      ? 'Файл больше 2 МБ — откройте его во внешней программе'
      : 'File is larger than 2 MB — open it externally instead';
  String get binaryFileWarning => isRu
      ? 'Похоже на бинарный файл — текстовый редактор для него недоступен'
      : 'This looks like a binary file and cannot be opened as text';
  String get openFolder => isRu ? 'Открыть папку' : 'Open folder';
  String get openInTerminal =>
      isRu ? 'Открыть папку в терминале' : 'Open folder in terminal';
  String get insertPathInTerminal =>
      isRu ? 'Вставить путь в терминал' : 'Insert path in terminal';
  String get copyEntries => isRu ? 'Копировать' : 'Copy';
  String get cutEntries => isRu ? 'Вырезать' : 'Cut';
  String pasteEntries(int count) =>
      isRu ? 'Вставить ($count)' : 'Paste ($count)';
  String copiedCount(int copied, int skipped) => skipped > 0
      ? (isRu
            ? 'Готово: $copied, пропущено: $skipped'
            : 'Done: $copied, skipped: $skipped')
      : (isRu ? 'Готово: $copied' : 'Done: $copied');
  String get sortTitle => isRu ? 'Сортировка' : 'Sort by';
  String get sortByName => isRu ? 'По имени' : 'Name';
  String get sortBySize => isRu ? 'По размеру' : 'Size';
  String get sortByModified => isRu ? 'По дате изменения' : 'Modified';
  String get sortByType => isRu ? 'По типу' : 'Type';
  String get filterFiles => isRu ? 'Фильтр по имени…' : 'Filter by name…';
  String get clearFilter => isRu ? 'Очистить фильтр' : 'Clear filter';
  String get noMatchingFiles =>
      isRu ? 'Ничего не найдено' : 'No matching files';
  String get backFolder => isRu ? 'Назад' : 'Back';
  String get forwardFolder => isRu ? 'Вперёд' : 'Forward';
  String get drivesList => isRu ? 'Диски' : 'Drives';
  String get downloadTo => isRu ? 'Скачать в…' : 'Download to…';
  String get permissions => isRu ? 'Права доступа' : 'Permissions';
  String get copyPath => isRu ? 'Копировать путь' : 'Copy path';
  String get uploadFiles => isRu ? 'Загрузить файлы…' : 'Upload files…';
  String get uploadFolder => isRu ? 'Загрузить папку…' : 'Upload folder…';
  String get homeFolder => isRu ? 'Домашняя папка' : 'Home folder';
  String get refresh => isRu ? 'Обновить' : 'Refresh';
  String get hiddenFiles => isRu ? 'Скрытые файлы' : 'Hidden files';
  String get followTerminalDirectoryTitle =>
      isRu ? 'Следовать папке терминала' : 'Follow terminal directory';
  String get followTerminalDirectoryDesc => isRu
      ? 'Автоматически открывать в проводнике текущую рабочую папку оболочки'
      : 'Automatically open the shell\'s current working directory in files';
  String get goToTerminalDirectory =>
      isRu ? 'Перейти в папку терминала' : 'Go to terminal folder';
  String get selectEntry => isRu ? 'Выбрать' : 'Select';
  String get deselectEntry => isRu ? 'Снять выделение' : 'Deselect';
  String get tryAgain => isRu ? 'Повторить' : 'Try again';
  String get up => isRu ? 'Вверх' : 'Up';
  String dropToUpload(String dir) =>
      isRu ? 'Отпустите, чтобы загрузить в\n$dir' : 'Drop to upload to\n$dir';
  String todayAt(String time) => isRu ? 'сегодня $time' : 'today $time';

  // Локальное редактирование.
  String editWatchFailed(String name, Object e) => isRu
      ? 'Не удалось следить за изменениями «$name»: ${errorText(e)}'
      : 'Could not watch «$name» for changes: ${errorText(e)}';
  String editTargetChanged(String name) => isRu
      ? '«$name»: адрес хоста изменился, автозагрузка остановлена'
      : '«$name»: the host address changed, auto-upload stopped';
  String editUploadFailed(String name, Object e) => isRu
      ? '«$name» не загружен на сервер: ${errorText(e)}'
      : '«$name» was not uploaded to the server: ${errorText(e)}';

  // ─── Диалоги ─────────────────────────────────────────────────────

  String deleteWhatTitle(List<String> names) {
    final what = names.length == 1
        ? '«${names.first}»'
        : (isRu ? '${names.length} элементов' : '${names.length} items');
    return isRu ? 'Удалить $what?' : 'Delete $what?';
  }

  String get deleteFoldersDesc => isRu
      ? 'Папки будут удалены вместе со всем содержимым. Это нельзя отменить.'
      : 'Folders will be deleted with all their contents. This cannot be undone.';
  String get deleteFilesDesc => isRu
      ? 'Файлы будут удалены с сервера. Это нельзя отменить.'
      : 'The files will be deleted from the server. This cannot be undone.';

  String replaceWhatTitle(List<String> names) {
    final what = names.length == 1
        ? '«${names.first}»'
        : (isRu ? '${names.length} файлов' : '${names.length} files');
    return isRu ? 'Заменить $what?' : 'Replace $what?';
  }

  String get replaceDesc => isRu
      ? 'На сервере уже есть файлы с такими именами:'
      : 'The server already has files with these names:';
  String get skip => isRu ? 'Пропустить' : 'Skip';
  String get replace => isRu ? 'Заменить' : 'Replace';
  List<String> get permissionWho => isRu
      ? const ['Владелец', 'Группа', 'Остальные']
      : const ['Owner', 'Group', 'Others'];
  List<String> get permissionWhat => isRu
      ? const ['Чтение', 'Запись', 'Выполнение']
      : const ['Read', 'Write', 'Execute'];
  String get octalHint =>
      isRu ? 'Восьмерично (например, 755)' : 'Octal (e.g. 755)';
  String get apply => isRu ? 'Применить' : 'Apply';

  // ─── Очередь передач ─────────────────────────────────────────────

  String transfersActive(int n) =>
      isRu ? 'Передачи: $n в работе' : 'Transfers: $n in progress';
  String get transfersDone =>
      isRu ? 'Передачи завершены' : 'Transfers finished';
  String transfersFailed(int n) => isRu ? 'ошибок: $n' : 'failed: $n';
  String get cancelAll => isRu ? 'Отменить все' : 'Cancel all';
  String get clearList => isRu ? 'Очистить' : 'Clear';
  String get queued => isRu ? 'в очереди' : 'queued';
  String progressOf(String done, String total, String speed) =>
      isRu ? '$done из $total · $speed/с' : '$done of $total · $speed/s';
  String get failedLower => isRu ? 'ошибка' : 'error';
  String get cancelledLower => isRu ? 'отменено' : 'cancelled';
  String get done => isRu ? 'Готово' : 'Done';
  String get showInFolder => isRu ? 'Показать в папке' : 'Show in folder';
}
