#include <stdio.h>
#include <Windows.h>

#include "flutter_pty.h"

#include "include/dart_api.h"
#include "include/dart_api_dl.h"
#include "include/dart_native_api.h"

// UTF-8 → UTF-16. Простое расширение байта в wchar ломало все символы вне
// ASCII: пути и переменные окружения с русскими буквами приходили в процесс
// мусором (cmd их и печатал мусором).
static LPWSTR utf8_to_wide(const char *utf8)
{
    if (utf8 == NULL)
    {
        return NULL;
    }

    int length = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);

    if (length <= 0)
    {
        return NULL;
    }

    LPWSTR wide = malloc(length * sizeof(WCHAR));

    if (wide != NULL && MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, length) <= 0)
    {
        free(wide);
        return NULL;
    }

    return wide;
}

static LPWSTR build_command(char *executable, char **arguments)
{
    // flutter_pty.dart кладёт в argv первым элементом (arguments[0]) сам
    // executable (стандартный POSIX argv для execvp). Если не пропустить
    // arguments[0], в CreateProcessW передавалось «cmd.exe cmd.exe /k ...» -
    // внешний cmd запускал внутренний как дочерний процесс, блокировал ввод
    // и ломал работу псевдотерминала.
    int start_index = 0;
    if (arguments != NULL && arguments[0] != NULL && executable != NULL)
    {
        if (strcmp(arguments[0], executable) == 0)
        {
            start_index = 1;
        }
    }

    int command_length = 0;

    if (executable != NULL)
    {
        command_length += (int)strlen(executable) + 3;
    }

    if (arguments != NULL)
    {
        int i = start_index;

        while (arguments[i] != NULL)
        {
            command_length += (int)strlen(arguments[i]) + 3;
            i++;
        }
    }

    char *command = malloc(command_length + 1);

    if (command == NULL)
    {
        return NULL;
    }

    command[0] = 0;

    if (executable != NULL)
    {
        int has_space = strchr(executable, ' ') != NULL;
        if (has_space && executable[0] != '"')
        {
            strcat(command, "\"");
            strcat(command, executable);
            strcat(command, "\"");
        }
        else
        {
            strcpy(command, executable);
        }
    }

    if (arguments != NULL)
    {
        int i = start_index;

        while (arguments[i] != NULL)
        {
            strcat(command, " ");
            int has_space = strchr(arguments[i], ' ') != NULL;
            if (has_space && arguments[i][0] != '"')
            {
                strcat(command, "\"");
                strcat(command, arguments[i]);
                strcat(command, "\"");
            }
            else
            {
                strcat(command, arguments[i]);
            }
            i++;
        }
    }

    LPWSTR wide = utf8_to_wide(command);
    free(command);
    return wide;
}

static LPWSTR build_environment(char **environment)
{
    LPWSTR environment_block = NULL;
    int environment_block_length = 0;

    if (environment != NULL)
    {
        int i = 0;

        while (environment[i] != NULL)
        {
            environment_block_length += (int)strlen(environment[i]) + 1;
            i++;
        }
    }

    char *block = malloc(environment_block_length + 1);

    if (block == NULL)
    {
        return NULL;
    }

    if (environment != NULL)
    {
        int i = 0;
        int offset = 0;

        while (environment[i] != NULL)
        {
            int length = (int)strlen(environment[i]);
            memcpy(block + offset, environment[i], length);
            offset += length;
            block[offset++] = 0;
            i++;
        }
    }

    block[environment_block_length] = 0;

    LPWSTR wide = utf8_to_wide(block);
    free(block);
    return wide;
}

static LPWSTR build_working_directory(char *working_directory)
{
    if (working_directory == NULL)
    {
        return NULL;
    }

    return utf8_to_wide(working_directory);
}

typedef struct ReadLoopOptions
{
    HANDLE fd;

    Dart_Port port;

    HANDLE hMutex;

    BOOL ackRead;

} ReadLoopOptions;

static DWORD WINAPI read_loop(LPVOID arg)
{
    ReadLoopOptions *options = (ReadLoopOptions *)arg;

    char buffer[1024];

    while (1)
    {
        DWORD readlen = 0;

        if (options->ackRead)
        {
            WaitForSingleObject(options->hMutex, INFINITE);
        }

        BOOL ok = ReadFile(options->fd, buffer, sizeof(buffer), &readlen, NULL);

        if (!ok)
        {
            break;
        }

        if (readlen <= 0)
        {
            break;
        }

        Dart_CObject result;
        result.type = Dart_CObject_kTypedData;
        result.value.as_typed_data.type = Dart_TypedData_kUint8;
        result.value.as_typed_data.length = readlen;
        result.value.as_typed_data.values = (uint8_t *)buffer;

        Dart_PostCObject_DL(options->port, &result);
    }

    return 0;
}

static void start_read_thread(HANDLE fd, Dart_Port port, HANDLE mutex, BOOL ackRead)
{
    ReadLoopOptions *options = malloc(sizeof(ReadLoopOptions));

    options->fd = fd;
    options->port = port;
    options->hMutex = mutex;
    options->ackRead = ackRead;

    DWORD thread_id;

    HANDLE thread = CreateThread(NULL, 0, read_loop, options, 0, &thread_id);

    if (thread == NULL)
    {
        free(options);
    }
}

typedef struct WaitExitOptions
{
    HANDLE pid;

    Dart_Port port;

    HANDLE hMutex;
} WaitExitOptions;

static DWORD WINAPI wait_exit_thread(LPVOID arg)
{
    WaitExitOptions *options = (WaitExitOptions *)arg;

    DWORD exit_code = 0;

    WaitForSingleObject(options->pid, INFINITE);

    GetExitCodeProcess(options->pid, &exit_code);

    CloseHandle(options->pid);
    CloseHandle(options->hMutex);

    Dart_PostInteger_DL(options->port, exit_code);

    return 0;
}

static void start_wait_exit_thread(HANDLE pid, Dart_Port port, HANDLE mutex)
{
    WaitExitOptions *options = malloc(sizeof(WaitExitOptions));

    options->pid = pid;
    options->port = port;
    options->hMutex = mutex;

    DWORD thread_id;

    HANDLE thread = CreateThread(NULL, 0, wait_exit_thread, options, 0, &thread_id);

    if (thread == NULL)
    {
        free(options);
    }
}

typedef struct PtyHandle
{
    HANDLE inputWriteSide;

    HANDLE outputReadSide;

    HPCON hPty;

    DWORD dwProcessId;

    BOOL ackRead;

    HANDLE hMutex;

} PtyHandle;

char *error_message = NULL;

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options)
{
    HANDLE inputReadSide = NULL;
    HANDLE inputWriteSide = NULL;

    HANDLE outputReadSide = NULL;
    HANDLE outputWriteSide = NULL;

    if (!CreatePipe(&inputReadSide, &inputWriteSide, NULL, 0))
    {
        error_message = "Failed to create input pipe";
        return NULL;
    }

    if (!CreatePipe(&outputReadSide, &outputWriteSide, NULL, 0))
    {
        error_message = "Failed to create output pipe";
        return NULL;
    }

    COORD size;

    size.X = options->cols;
    size.Y = options->rows;

    HPCON hPty;

    HRESULT result = CreatePseudoConsole(size, inputReadSide, outputWriteSide, 0, &hPty);

    // Концы пайпов, переданные в CreatePseudoConsole (inputReadSide и
    // outputWriteSide), нельзя закрывать до запуска процесса: ConPTY не
    // дублирует их, а читает/пишет через эти же хэндлы. Если закрыть их
    // сразу после CreatePseudoConsole, канал ввода псевдоконсоли умирает:
    // cmd печатает промпт, но нажатия клавиш до него не доходят.
    // По образцу Microsoft их закрывают ПОСЛЕ CreateProcessW.
    if (FAILED(result))
    {
        CloseHandle(inputWriteSide);
        CloseHandle(outputReadSide);
        error_message = "Failed to create pseudo console";
        return NULL;
    }

    STARTUPINFOEX startupInfo;

    ZeroMemory(&startupInfo, sizeof(startupInfo));
    startupInfo.StartupInfo.cb = sizeof(startupInfo);

    // STARTF_USESTDHANDLES с NULL-хэндлами не ставится: с атрибутом
    // PSEUDOCONSOLE Windows сам подключает std-потоки процесса к
    // псевдоконсоли. С NULL-хэндлами cmd работает, но запущенные из него
    // powershell / wsl / bash наследуют невалидный stdout и сразу падают.
    SIZE_T bytesRequired;
    InitializeProcThreadAttributeList(NULL, 1, 0, &bytesRequired);
    startupInfo.lpAttributeList = (PPROC_THREAD_ATTRIBUTE_LIST)malloc(bytesRequired);

    BOOL ok = InitializeProcThreadAttributeList(startupInfo.lpAttributeList, 1, 0, &bytesRequired);

    if (!ok)
    {
        error_message = "Failed to initialize proc thread attribute list";
        return NULL;
    }

    ok = UpdateProcThreadAttribute(startupInfo.lpAttributeList,
                                   0,
                                   PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                   hPty,
                                   sizeof(hPty),
                                   NULL,
                                   NULL);

    if (!ok)
    {
        error_message = "Failed to update proc thread attribute list";
        return NULL;
    }

    LPWSTR command = build_command(options->executable, options->arguments);

    LPWSTR environment_block = build_environment(options->environment);

    LPWSTR working_directory = build_working_directory(options->working_directory);

    PROCESS_INFORMATION processInfo;
    ZeroMemory(&processInfo, sizeof(processInfo));

    ok = CreateProcessW(NULL,
                        command,
                        NULL,
                        NULL,
                        FALSE,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                        environment_block,
                        working_directory,
                        &startupInfo.StartupInfo,
                        &processInfo);

    if (command != NULL)
    {
        free(command);
    }

    if (environment_block != NULL)
    {
        free(environment_block);
    }

    if (working_directory != NULL)
    {
        free(working_directory);
    }

    if (!ok)
    {
        CloseHandle(inputReadSide);
        CloseHandle(outputWriteSide);
        ClosePseudoConsole(hPty);
        error_message = "Failed to create process";
        DWORD error = GetLastError();
        printf("error no: %d\n", error);
        return NULL;
    }

    CloseHandle(inputReadSide);
    CloseHandle(outputWriteSide);

    CloseHandle(processInfo.hThread);

    HANDLE mutex = CreateSemaphore(
        NULL, // default security attributes
        1,    // initial count
        1,    // maximum count
        NULL);

    start_read_thread(outputReadSide, options->stdout_port, mutex, options->ackRead);

    start_wait_exit_thread(processInfo.hProcess, options->exit_port, mutex);

    PtyHandle *pty = malloc(sizeof(PtyHandle));

    if (pty == NULL)
    {
        error_message = "Failed to allocate pty handle";
        return NULL;
    }

    pty->inputWriteSide = inputWriteSide;
    pty->outputReadSide = outputReadSide;
    pty->hPty = hPty;
    pty->dwProcessId = processInfo.dwProcessId;
    pty->ackRead = options->ackRead;
    pty->hMutex = mutex;

    return pty;
}

FFI_PLUGIN_EXPORT void pty_write(PtyHandle *handle, char *buffer, int length)
{
    DWORD bytesWritten;

    WriteFile(handle->inputWriteSide, buffer, length, &bytesWritten, NULL);

    return;
}

FFI_PLUGIN_EXPORT void pty_ack_read(PtyHandle *handle)
{
    if (handle->ackRead)
    {
        ReleaseSemaphore(handle->hMutex, 1, NULL);
    }
}

FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols)
{
    COORD size;

    size.X = cols;
    size.Y = rows;

    return ResizePseudoConsole(handle->hPty, size);
}

FFI_PLUGIN_EXPORT int pty_getpid(PtyHandle *handle)
{
    return (int)handle->dwProcessId;
}

FFI_PLUGIN_EXPORT char *pty_error()
{
    return error_message;
}
