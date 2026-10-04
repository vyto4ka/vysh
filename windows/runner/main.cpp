#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cctype>
#include <fstream>
#include <iterator>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Which renderer to start. The choice lives in vysh settings
// (%APPDATA%\vysh\settings.json, key "renderer") and must be known before the
// engine starts, so the file is read here, without Dart. No real JSON parsing
// is needed: we look for one key/value pair with whitespace removed.
//
// Default is Skia. Since Flutter 3.47 Impeller is the default on Windows and it
// holds noticeably more memory (textures, glyph atlases), while its benefits
// are barely visible in an SSH client.
//
// Comments in this file are ASCII on purpose: MSVC builds with /WX and reads
// sources in the system code page, so Cyrillic here could fail the build.
bool UseImpeller() {
  wchar_t appdata[MAX_PATH];
  const DWORD n = ::GetEnvironmentVariableW(L"APPDATA", appdata, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) return false;
  std::wstring path(appdata);
  path += L"\\vysh\\settings.json";
  std::ifstream file(path, std::ios::binary);
  if (!file) return false;
  std::string text((std::istreambuf_iterator<char>(file)),
                   std::istreambuf_iterator<char>());
  std::string compact;
  compact.reserve(text.size());
  for (const char c : text) {
    if (!std::isspace(static_cast<unsigned char>(c))) compact.push_back(c);
  }
  return compact.find("\"renderer\":\"impeller\"") != std::string::npos;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_impeller_switch(UseImpeller() ? flutter::ImpellerSwitch::Enabled
                                            : flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"vysh", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
