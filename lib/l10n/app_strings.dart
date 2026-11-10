import 'dart:io' show FileSystemException, Platform;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../app/settings/app_settings.dart';
import '../domain/models/local_file_failure.dart';
import '../domain/ports/local_shell.dart';
import '../domain/ports/sftp.dart';
import '../domain/ports/ssh_transport.dart';
import '../domain/services/font_info.dart' show AddFontError;
import '../infra/update/update_installer.dart'
    show UpdateInstallError, UpdateInstallException;
import '../infra/update/update_service.dart'
    show UpdateCheckError, UpdateCheckException;

part 'connection_strings.dart';
part 'hosts_strings.dart';
part 'sftp_strings.dart';
part 'terminal_strings.dart';

/// macOS: в подписях сочетаний ⌘ вместо Ctrl+Shift.
bool get _isMac => !kIsWeb && Platform.isMacOS;

/// Централизованная локализация приложения (русский и английский языки).
/// Строки по разделам - в частях этой библиотеки (`part`), все доступны
/// через один объект AppStrings.
class AppStrings {
  const AppStrings({required this.isRu});

  final bool isRu;

  bool get isRussian => isRu;

  static AppStrings of(
    BuildContext context, [
    AppLanguage language = AppLanguage.auto,
  ]) =>
      forLanguage(language, Localizations.maybeLocaleOf(context));

  /// Строки без BuildContext - для сообщений сессии и фоновых задач.
  /// [locale] - язык интерфейса; по умолчанию первый язык системы.
  static AppStrings forLanguage(AppLanguage language, [Locale? locale]) {
    if (language == AppLanguage.ru) return const AppStrings(isRu: true);
    if (language == AppLanguage.en) return const AppStrings(isRu: false);

    final loc = locale ??
        (ui.PlatformDispatcher.instance.locales.isNotEmpty
            ? ui.PlatformDispatcher.instance.locales.first
            : ui.PlatformDispatcher.instance.locale);
    final code = loc.languageCode.toLowerCase();
    final ru =
        code.startsWith('ru') || code.startsWith('be') || code.startsWith('uk');
    return AppStrings(isRu: ru);
  }

  // Общие действия
  String get ok => isRu ? 'ОК' : 'OK';
  String get cancel => isRu ? 'Отмена' : 'Cancel';
  String get save => isRu ? 'Сохранить' : 'Save';
  String get delete => isRu ? 'Удалить' : 'Delete';
  String get edit => isRu ? 'Изменить' : 'Edit';
  String get close => isRu ? 'Закрыть' : 'Close';
  String get copy => isRu ? 'Копировать' : 'Copy';
  String get paste => isRu ? 'Вставить' : 'Paste';
  String get cut => isRu ? 'Вырезать' : 'Cut';
  String get duplicate => isRu ? 'Дублировать' : 'Duplicate';
  String get reconnect => isRu ? 'Переподключить' : 'Reconnect';
  String get search => isRu ? 'Поиск' : 'Search';
  String get actions => isRu ? 'Действия' : 'Actions';
  String get retry => isRu ? 'Повторить попытку' : 'Retry';
  String get dismiss => isRu ? 'Скрыть' : 'Dismiss';
  String get more => isRu ? 'Ещё' : 'More';
  String get alreadyRunning => isRu
      ? 'vysh уже запущен.\nПереключитесь на открытое окно.'
      : 'vysh is already running.\nSwitch to the open window.';

  // Навигация и полоса вкладок
  String get home => isRu ? 'Главная' : 'Home';
  String get homeTooltip {
    final keys = _isMac ? '⌘1' : 'Alt+1';
    return isRu ? 'Главная ($keys)' : 'Home ($keys)';
  }
  String get newTabTooltip => isRu ? 'Новая вкладка' : 'New tab';
  String get newTabDesktopTooltip {
    final mac = _isMac;
    return isRu
        ? 'Новая вкладка (${mac ? '⌘T' : 'Ctrl+Shift+T'})'
        : 'New tab (${mac ? '⌘T' : 'Ctrl+Shift+T'})';
  }
  String get settingsTooltip => isRu ? 'Настройки' : 'Settings';
  String get settingsDesktopTooltip {
    final keys = _isMac ? '⌘,' : 'Ctrl+,';
    return isRu ? 'Настройки ($keys)' : 'Settings ($keys)';
  }
  String get closeTab => isRu ? 'Закрыть вкладку' : 'Close tab';
  String get hosts => isRu ? 'Хосты' : 'Hosts';
  String get settings => isRu ? 'Настройки' : 'Settings';

  // Главная страница / список хостов
  String get searchHostsHintMobile =>
      isRu ? 'Поиск хостов...' : 'Search hosts...';
  String get searchHostsHintDesktop =>
      isRu ? 'Поиск или user@host:port' : 'Search or user@host:port';
  String get newHost => isRu ? 'Новый хост' : 'New host';
  String get quickConnectPrefix =>
      isRu ? 'Быстрое подключение: enter' : 'Quick connect: Enter';
  String get noHostsTitle => isRu ? 'Хостов пока нет' : 'No hosts yet';
  String get noHostsDesc => isRu
      ? 'Добавьте первый сервер кнопкой выше или введите user@host:port в строку поиска.'
      : 'Add your first server using the button above or enter user@host:port in the search bar.';
  String get noSearchResults => isRu ? 'Ничего не найдено' : 'Nothing found';
  String get deleteHostTitle => isRu ? 'Удалить хост?' : 'Delete host?';
  String deleteHostDesc(String title) => isRu
      ? '«$title» будет удалён из списка.'
      : '«$title» will be deleted from the list.';
  String get forgetPassword => isRu ? 'Забыть пароль' : 'Forget password';
  String get passwordForgotten =>
      isRu ? 'Пароль удалён из хранилища' : 'Password removed from storage';
  String get noGroup => isRu ? 'Без группы' : 'No group';

  // Редактор хоста
  String get editHostTitle => isRu ? 'Редактирование хоста' : 'Edit host';
  String get duplicateHostTitle =>
      isRu ? 'Дублирование хоста' : 'Duplicate host';
  String get newHostTitle => isRu ? 'Новый хост' : 'New host';
  String get labelField => isRu ? 'Название' : 'Label';
  String get labelHint =>
      isRu ? 'Например, Prod EU, Домашний NAS' : 'e.g., Prod EU, Home NAS';
  String get addressField => isRu ? 'Адрес сервера' : 'Server address';
  String get addressHint =>
      isRu ? 'IP-адрес или домен' : 'IP address or domain';
  String get portField => isRu ? 'Порт' : 'Port';
  String get userField => isRu ? 'Пользователь' : 'Username';
  String get groupField => isRu ? 'Группа (необязательно)' : 'Group (optional)';
  String get groupHint =>
      isRu ? 'Например, Продакшн, Домашние' : 'e.g., Production, Home';
  String get authMethod =>
      isRu ? 'Способ авторизации' : 'Authentication method';
  String get authPassword => isRu ? 'Пароль' : 'Password';
  String get authKey => isRu ? 'SSH-ключ' : 'SSH key';
  String get passwordField => isRu ? 'Пароль' : 'Password';
  String get passwordPlaceholderSaved =>
      isRu ? '••••••••  (сохранён)' : '••••••••  (saved)';
  String get rememberPasswordCheckbox =>
      isRu ? 'Сохранить пароль' : 'Remember password';
  String get rememberPasswordSub => isRu
      ? 'Пароль будет надёжно сохранён в системном хранилище ключей'
      : 'Password will be stored securely in the system keychain';
  String get privateKeyField =>
      isRu ? 'Путь к приватному ключу' : 'Private key path';
  String get selectKeyFile => isRu ? 'Выбрать файл' : 'Select file';
  String get cardColor => isRu ? 'Цвет карточки' : 'Card color';
  String get keepAliveField =>
      isRu ? 'SSH KeepAlive (интервал)' : 'SSH KeepAlive (interval)';
  String get keepAliveDefault =>
      isRu ? 'По умолчанию из настроек' : 'Default from settings';
  String get keepAliveOff => isRu ? 'Отключён' : 'Disabled';
  String keepAliveSecondsVal(int s) => isRu ? '$s сек' : '$s sec';
  String get connectImmediately =>
      isRu ? 'Подключиться сразу' : 'Connect immediately';
  String get requiredField => isRu ? 'Обязательное поле' : 'Required field';
  String get invalidPort => isRu ? 'Некорректный порт' : 'Invalid port';

  // Настройки
  String get appearanceSection => isRu ? 'Внешний вид' : 'Appearance';
  String get themeTitle => isRu ? 'Тема' : 'Theme';
  String get themeSystem => isRu ? 'Системная' : 'System';
  String get themeLight => isRu ? 'Светлая' : 'Light';
  String get themeDark => isRu ? 'Тёмная' : 'Dark';
  String get colorSourceTitle => isRu ? 'Цвета' : 'Colors';
  String get colorSourcePreset => isRu ? 'Свои' : 'Custom';
  String get colorSourceSystem => isRu ? 'Системный акцент' : 'System accent';
  String get colorSourceSystemWin => isRu ? 'Акцент Windows' : 'Windows accent';
  String get colorSourceSystemSys => isRu ? 'Акцент системы' : 'System accent';
  String get colorSourceDots => isRu ? 'Из дотов' : 'From dots';

  /// Название источника цветов ([ExternalColors.source]).
  String colorSourceName(String source) => switch (source) {
        'windows-accent' => isRu ? 'Акцент Windows' : 'Windows accent',
        'portal-accent' => isRu ? 'Акцент системы (xdg-portal)' : 'System accent (xdg-portal)',
        'colors-file' => isRu ? 'Файл цветов' : 'Colors file',
        _ => source,
      };
  String get compactUi => isRu ? 'Компактный интерфейс' : 'Compact interface';
  String get titleBarTitle => isRu ? 'Заголовок окна' : 'Window title bar';
  String get titleBarCustom => isRu ? 'Свой с вкладками' : 'Custom with tabs';
  String get titleBarSystem => isRu ? 'Системный' : 'System';
  String get windowSection => isRu ? 'Окно' : 'Window';
  String get hostsSection => isRu ? 'Хосты' : 'Hosts';
  String get pingHostsTitle =>
      isRu ? 'Проверять доступность хостов' : 'Check host reachability';
  String get pingHostsDesc => isRu
      ? 'На главной - пинг порта SSH раз в 30 секунд. Выключите, чтобы не нагружать удалённые серверы.'
      : 'Pings the SSH port every 30 seconds on the home screen. Turn off to avoid frequent network queries.';
  String get keepAliveGlobalTitle =>
      isRu ? 'SSH KeepAlive (поддержание связи)' : 'SSH KeepAlive (heartbeat)';
  String get keepAliveRecom =>
      isRu ? '60 сек (1 мин) - рекомендовано' : '60 sec (1 min) - recommended';
  String get terminalSection => isRu ? 'Терминал' : 'Terminal';
  String get fontSizeTitle => isRu ? 'Размер шрифта' : 'Font size';
  String get rememberTerminalFontSizeTitle =>
      isRu ? 'Запоминать размер шрифта' : 'Remember terminal font size';
  String get rememberTerminalFontSizeDesc => isRu
      ? 'Сохранять размер между запусками приложения'
      : 'Keep the terminal font size between app launches';
  String get terminalFontTitle => isRu ? 'Шрифт' : 'Font';
  String get fontDefault => isRu ? 'По умолчанию' : 'Default';
  String get fontNotFound => isRu ? 'не найден' : 'not found';
  String get addFont => isRu ? 'Добавить шрифт…' : 'Add font…';
  String get removeFont => isRu ? 'Удалить шрифт' : 'Remove font';
  String get nerdFontsLink => isRu ? 'Где взять Nerd Font' : 'Get a Nerd Font';
  String get lineHeightTitle => isRu ? 'Межстрочный интервал' : 'Line spacing';
  String fontAdded(String family) => isRu ? 'Добавлен шрифт $family' : 'Font $family added';
  String fontNotMonospace(String family) => isRu
      ? '$family не моноширинный: символы будут разной ширины'
      : '$family is not monospaced: characters will have different widths';
  String fontAddFailed(AddFontError error, int maxMb, String detail) => switch (error) {
        AddFontError.tooLarge =>
          isRu ? 'Файл больше $maxMb МБ' : 'The file is larger than $maxMb MB',
        AddFontError.notFont =>
          isRu ? 'Это не шрифт TTF или OTF' : 'Not a TTF or OTF font',
        AddFontError.copyFailed => isRu
            ? 'Не удалось скопировать шрифт: $detail'
            : 'Could not copy the font: $detail',
      };
  String get copyOnSelectTitle =>
      isRu ? 'Копировать при выделении' : 'Copy on select';
  String get copyOnSelectMobileDesc => isRu
      ? 'Автоматически копировать выделенный текст в буфер'
      : 'Automatically copy highlighted text to clipboard';
  String get copyOnSelectDesktopDesc {
    final mac = _isMac;
    return isRu
        ? (mac ? 'Как в терминалах. Вставка - ⌘V' : 'Как в терминалах Linux. Вставка - Ctrl+Shift+V')
        : (mac ? 'Terminal style. Paste with ⌘V' : 'Linux terminal style. Paste with Ctrl+Shift+V');
  }
  String get accessoryBarTitle => isRu
      ? 'Панель горячих клавиш (Ctrl, Esc, стрелки)'
      : 'Terminal accessory bar (Ctrl, Esc, arrows)';
  String get accessoryBarDesc => isRu
      ? 'Однострочная панель keyboard над клавиатурой на смартфонах.'
      : 'Single-row keyboard style toolbar above the mobile keyboard.';
  String get languageTitle => isRu ? 'Язык интерфейса' : 'Interface language';
  String get languageAuto => isRu ? 'Как в системе' : 'System';
  String get languageRu => isRu ? 'Русский (Russian)' : 'Russian (Русский)';
  String get languageEn => isRu ? 'English (Английский)' : 'English';
  String get rightClickMobileTitle =>
      isRu ? 'Тап двумя пальцами' : 'Two-finger tap';
  String get rightClickDesktopTitle => isRu
      ? 'Правый клик и тап двумя пальцами'
      : 'Right click & two-finger tap';
  String get rightClickMenu => isRu ? 'Меню' : 'Menu';
  String get rightClickPaste => isRu ? 'Вставка' : 'Paste';
  String get rightClickSmart => isRu ? 'Копировать / вставить' : 'Copy / paste';
  String get rightClickHintMenu =>
      isRu ? 'Открывает контекстное меню.' : 'Opens context menu.';
  String get rightClickHintPaste => isRu
      ? 'Сразу вставляет текст из буфера обмена.'
      : 'Pastes clipboard content directly.';
  String get rightClickHintSmart => isRu
      ? 'Если есть выделение - копирует его; если нет - вставляет.'
      : 'If text is selected, copies it; otherwise pastes.';
  String get shiftRightClickNote => isRu
      ? 'Shift + правый клик всегда открывает меню.'
      : 'Shift + right click always opens the menu.';
  String get multilinePasteTitle => isRu
      ? 'Предупреждать при вставке нескольких строк'
      : 'Warn before multiline paste';
  String get multilinePasteDesc => isRu
      ? 'Защита от случайного выполнения команд при копировании скриптов'
      : 'Protection against accidental command execution when pasting scripts';
  String get copyOnSelectDesc => isRu
      ? 'Выделенный текст сразу попадает в буфер обмена'
      : 'Copy highlighted text immediately';
  String get rightClickTitle => isRu ? 'Правый клик' : 'Right click';
  String get confirmMultilinePasteTitle => isRu ? 'Предупреждать при многострочной вставке' : 'Confirm multiline paste';
  String get confirmMultilinePasteDesc => isRu ? 'Защита от случайного выполнения команд' : 'Protection from accidental command execution';
  String get aboutApp => isRu ? 'О программе' : 'About';
  String get thirdPartyLicenses => isRu ? 'Лицензии компонентов' : 'Third-party licenses';

  // Резервная копия (Настройки → Данные)
  String get backupSectionTitle => isRu ? 'Резервная копия' : 'Backup';
  String get backupSectionHint => isRu
      ? 'Хосты, настройки и сохранённые пароли в одном файле. С паролем файл шифруется (AES-256-GCM), без - остаётся читаемым JSON'
      : 'Hosts, settings and saved passwords in a single file. With a password the file is encrypted (AES-256-GCM); without one it stays readable JSON';
  String get backupCreate => isRu ? 'Создать резервную копию' : 'Create backup';
  String get backupRestore => isRu ? 'Восстановить из копии' : 'Restore from backup';
  String get backupPasswordTitle => isRu ? 'Пароль копии' : 'Backup password';
  String get backupPasswordField => isRu ? 'Пароль' : 'Password';
  String get backupPasswordRepeat => isRu ? 'Повторите пароль' : 'Repeat password';
  String get backupPasswordHint => isRu
      ? 'Пустой пароль - файл без шифрования. С паролем копию можно открыть только с ним'
      : 'An empty password keeps the file unencrypted. With a password the backup opens only with it';
  String get backupPasswordEnterForRestore => isRu
      ? 'Введите пароль копии' : 'Enter the backup password';
  String get backupPasswordTooShort => isRu
      ? 'Пароль - минимум 6 символов' : 'Password must be at least 6 characters';
  String get backupPasswordMismatch => isRu ? 'Пароли не совпадают' : 'Passwords do not match';
  String get backupWrongPassword => isRu ? 'Неверный пароль' : 'Wrong password';
  String backupDoneWithSecrets(int count) => isRu
      ? 'Копия создана: хосты, настройки и $count паролей'
      : 'Backup created: hosts, settings and $count passwords';
  String get backupDonePlain => isRu
      ? 'Копия создана: хосты и настройки (сохранённых паролей нет)'
      : 'Backup created: hosts and settings (no saved passwords)';
  String get backupDoneNoSecrets => isRu
      ? 'Копия создана (не зашифрована)' : 'Backup created (not encrypted)';
  String backupRestored(int hostCount) => isRu
      ? 'Восстановлено: $hostCount хостов' : 'Restored: $hostCount hosts';
  String backupFailed(String detail) => isRu
      ? 'Не удалось: $detail' : 'Failed: $detail';
  String get backupRestoreTitle => isRu ? 'Восстановление' : 'Restore';
  String backupRestoreConfirm(int hostCount) => isRu
      ? 'Заменить текущие хосты и настройки данными из копии ($hostCount хостов)? Текущие данные будут перезаписаны'
      : 'Replace current hosts and settings with the backup ($hostCount hosts)? Current data will be overwritten';
  String get restore => isRu ? 'Восстановить' : 'Restore';
  String get appDescription => isRu
      ? 'Минималистичный и красивый SSH-клиент и менеджер подключений.'
      : 'Minimalist and elegant SSH client & connection manager.';

  // Сессия и статус-бар
  String get statusConnecting => isRu ? 'Подключение…' : 'Connecting…';
  String get statusConnected => isRu ? 'Подключено' : 'Connected';
  String get statusLost => isRu ? 'Нет соединения' : 'Connection lost';
  String get statusClosed => isRu ? 'Сессия завершена' : 'Session closed';
  String get files => isRu ? 'Файлы' : 'Files';
  String get console => isRu ? 'Консоль' : 'Console';
  String get filesShortcut {
    final mac = _isMac;
    return isRu ? 'Файлы  ${mac ? '⌘E' : 'Ctrl+Shift+E'}' : 'Files  ${mac ? '⌘E' : 'Ctrl+Shift+E'}';
  }
  String get reconnectShort => isRu ? 'Переподкл.' : 'Reconnect';
  String get sftpPaneTitle => isRu ? 'Файлы (SFTP)' : 'Files (SFTP)';

  // Ошибка подключения
  String get connectionFailed => isRu
      ? 'Не удалось подключиться к серверу'
      : 'Failed to connect to server';
  String get connectionLostTitle => isRu
      ? 'Соединение с сервером разорвано'
      : 'Connection to server was lost';
  String get sessionLog => isRu ? 'Журнал сессии' : 'Session log';

  // Контекстное меню keyboard (зажатие пальцем)
  String get selectLine => isRu ? 'Выбрать строку' : 'Select line';
  String get selectLineToast => isRu ? 'Строка выбрана' : 'Line selected';
  String get selectAll =>
      selectLine; // Выбирает строку целиком по запросу пользователя
  String get share => isRu ? 'Поделиться' : 'Share';
  String get reset => isRu ? 'Сброс (^C)' : 'Reset (^C)';
  String get clear => isRu ? 'Очистить (^L)' : 'Clear (^L)';
  String get sftp => isRu ? 'Файлы (SFTP)' : 'Files (SFTP)';
  String get log => isRu ? 'Журнал' : 'Log';
  String get deselect => isRu ? 'Снять выделение' : 'Deselect';
  String get terminal => isRu ? 'Терминал' : 'Terminal';
  String get emptyArea => isRu ? 'Пустая область' : 'Empty area';
  String get selectedText => isRu ? 'Текст' : 'Text';

  String charCount(int count) => isRu ? '$count симв.' : '$count chars';
  String copiedToast(int count) => isRu
      ? 'Скопировано в буфер ($count симв.)'
      : 'Copied to clipboard ($count chars)';
  String cutToast(int count) => isRu
      ? 'Вырезано в буфер ($count симв.)'
      : 'Cut to clipboard ($count chars)';
  String get pastedToast => isRu ? 'Вставлено' : 'Pasted';
  String get nothingToCopy =>
      isRu ? 'Нет текста для копирования' : 'No text to copy';
  String get resetToast =>
      isRu ? 'Отправлен сигнал прерывания (^C)' : 'Interrupt signal sent (^C)';
  String get clearToast => isRu ? 'Экран очищен' : 'Screen cleared';

  // Диалог вставки нескольких строк
  String multilineTitle(int count) =>
      isRu ? 'Вставить $count строк?' : 'Paste $count lines?';
  String get multilineDesc => isRu
      ? 'Каждая строка выполнится как отдельная команда.'
      : 'Each line will execute as a separate command.';
  String get pasteSingleLine => isRu ? 'Одной строкой' : 'Single line';
  String get pasteConfirm => isRu ? 'Вставить' : 'Paste';

  // Быстрые команды Ctrl (вспомогательная панель)
  String get ctrlQuickTitle =>
      isRu ? 'Быстрые команды Ctrl' : 'Ctrl Quick Commands';
  String get ctrlCSigint =>
      isRu ? 'Прервать процесс (SIGINT)' : 'Interrupt process (SIGINT)';
  String get ctrlDEof =>
      isRu ? 'Выход / Конец ввода (EOF)' : 'Exit / End of input (EOF)';
  String get ctrlZSuspend => isRu
      ? 'Приостановить в фон (SIGTSTP)'
      : 'Suspend to background (SIGTSTP)';
  String get ctrlLClear => isRu ? 'Очистить экран' : 'Clear screen';
  String get ctrlABeginning => isRu ? 'В начало строки' : 'Move to line start';
  String get ctrlEEnd => isRu ? 'В конец строки' : 'Move to line end';
  String get ctrlRSearch =>
      isRu ? 'Поиск по истории команд' : 'Reverse history search';

  // SFTP файловый менеджер
  String get pathField => isRu ? 'Путь' : 'Path';
  String get uploadFile => isRu ? 'Загрузить файл' : 'Upload file';
  String get createFolder => isRu ? 'Создать папку' : 'Create folder';
  String get folderNameHint => isRu ? 'Имя новой папки' : 'New folder name';
  String get emptyFolder => isRu ? 'В этой папке пусто' : 'Folder is empty';
  String get download => isRu ? 'Скачать' : 'Download';
  String get rename => isRu ? 'Переименовать' : 'Rename';
  String get newNameHint => isRu ? 'Новое имя' : 'New name';
  String get deleteFileConfirm =>
      isRu ? 'Удалить этот файл?' : 'Delete this file?';
  String get deleteFolderConfirm =>
      isRu ? 'Удалить эту папку?' : 'Delete this folder?';
  String get itemDeleted => isRu ? 'Удалено' : 'Deleted';
  String get downloadStarted => isRu ? 'Скачивание начато' : 'Download started';
  String get uploadStarted => isRu ? 'Загрузка начата' : 'Upload started';

  // Хранение данных
  String profileUnavailable(String path, String error) => isRu
      ? 'Папка профиля $path недоступна ($error). Хосты и настройки сейчас сохраняются во временную папку.'
      : 'Profile folder $path is unavailable ($error). Hosts and settings are saved to a temporary folder for now.';

  String saveFailed(String file, String error) => isRu
      ? 'Не удалось сохранить $file: $error'
      : 'Could not save $file: $error';

  // Обновление приложения
  String get updateTitle => isRu ? 'Доступно обновление' : 'Update available';
  String get updateWhatsNew => isRu ? 'Что нового' : "What's new";
  String get updateLater => isRu ? 'Позже' : 'Later';
  String get updateNow => isRu ? 'Обновить' : 'Update';
  String get updateSkip => isRu ? 'Пропустить версию' : 'Skip this version';
  String get updateOpenDownload => isRu ? 'Открыть загрузку' : 'Open download';
  String get updateDownloading => isRu ? 'Скачивание…' : 'Downloading…';
  String get updateApplying => isRu ? 'Установка обновления…' : 'Applying update…';
  String updateSize(String size) =>
      isRu ? 'Размер: $size' : 'Size: $size';
  String get updateCheck => isRu ? 'Проверить обновления' : 'Check for updates';
  String get updateLatest =>
      isRu ? 'Установлена последняя версия' : 'Latest version installed';
  String get updateCheckFailed => isRu
      ? 'Не удалось проверить обновления'
      : 'Could not check for updates';
  String get updatesSection => isRu ? 'Обновления' : 'Updates';
  String get updateAutoCheck => isRu
      ? 'Проверять обновления автоматически'
      : 'Check for updates automatically';
  String get updatePromptFrequency => isRu
      ? 'Сообщать о новой версии'
      : 'Notify about new versions';
  String get updateEveryDay => isRu ? 'Раз в день' : 'Daily';
  String get updateEvery3Days => isRu ? 'Раз в 3 дня' : 'Every 3 days';
  String get updateEveryWeek => isRu ? 'Раз в неделю' : 'Weekly';

  String updateCheckFailure(UpdateCheckException e) {
    final detail = e.detail;
    final tail = detail == null || detail.isEmpty ? '' : ' ($detail)';
    return switch (e.error) {
      UpdateCheckError.empty => isRu
          ? 'GitHub вернул нечитаемый список релизов'
          : 'GitHub returned an unreadable release list',
      UpdateCheckError.network => isRu
          ? 'Нет соединения с GitHub$tail'
          : 'No connection to GitHub$tail',
      UpdateCheckError.timeout => isRu
          ? 'GitHub не ответил вовремя'
          : 'GitHub did not respond in time',
      UpdateCheckError.rateLimit => isRu
          ? 'Лимит GitHub API исчерпан, попробуйте через пару минут'
          : 'GitHub API rate limit reached, try again in a few minutes',
      UpdateCheckError.httpStatus => isRu
          ? 'GitHub ответил ошибкой$tail'
          : 'GitHub responded with an error$tail',
    };
  }

  String updateInstallFailure(UpdateInstallException e) {
    final detail = e.detail;
    final tail = detail == null || detail.isEmpty ? '' : ': $detail';
    return switch (e.error) {
      UpdateInstallError.unsupportedType => isRu
          ? 'Неизвестный тип файла обновления$tail'
          : 'Unknown update file type$tail',
      UpdateInstallError.downloadFailed => isRu
          ? 'Скачивание не удалось$tail'
          : 'Download failed$tail',
      UpdateInstallError.writeFailed => isRu
          ? 'Не удалось записать файл$tail'
          : 'Could not write the file$tail',
      UpdateInstallError.checksumMissing => isRu
          ? 'Для ${tail.isEmpty ? 'файла' : 'файла $detail'} не опубликован SHA-256; '
              'отказ устанавливать непроверенную сборку'
          : 'No SHA-256 published for ${detail ?? 'the file'}; '
              'refusing to install an unverified build',
      UpdateInstallError.checksumMismatch => isRu
          ? 'Файл${tail.isEmpty ? '' : ' $detail'} не совпал с контрольной суммой; '
              'загрузка отброшена'
          : 'The file${detail == null ? '' : ' $detail'} failed the checksum; '
              'the download was discarded',
      UpdateInstallError.badArchive => isRu
          ? 'Архив обновления повреждён или без приложения$tail'
          : 'The update archive is corrupt or has no app$tail',
      UpdateInstallError.wrongPlatform => isRu
          ? 'Такой формат обновления не подходит этой платформе ($detail)'
          : 'This update format does not fit this platform ($detail)',
      UpdateInstallError.copyFailed => isRu
          ? 'Не удалось скопировать файлы обновления$tail'
          : 'Could not copy the update files$tail',
    };
  }

  String updateInstallUnexpected(String error) => isRu
      ? 'Не удалось установить обновление: $error'
      : 'Could not install the update: $error';
}
