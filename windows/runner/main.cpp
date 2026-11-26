#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <ole2.h>

#include <cctype>
#include <fstream>
#include <iterator>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Which renderer to start. The choice lives in vysh settings
// (settings.json in the profile folder, key "renderer") and must be known
// before the engine starts, so the file is read here, without Dart.
//
// Default is Skia. Since Flutter 3.47 Impeller is the default on Windows and it
// holds noticeably more memory (textures, glyph atlases), while its benefits
// are barely visible in an SSH client.
//
// Comments in this file are ASCII on purpose: MSVC builds with /WX and reads
// sources in the system code page, so Cyrillic here could fail the build.

std::wstring GetEnv(const wchar_t* name) {
  const DWORD n = ::GetEnvironmentVariableW(name, nullptr, 0);
  if (n == 0) return std::wstring();
  std::wstring value(n, L'\0');
  const DWORD got = ::GetEnvironmentVariableW(name, &value[0], n);
  value.resize(got);
  return value;
}

std::wstring Trim(const std::wstring& s) {
  const size_t a = s.find_first_not_of(L" \t\r\n");
  if (a == std::wstring::npos) return std::wstring();
  const size_t b = s.find_last_not_of(L" \t\r\n");
  return s.substr(a, b - a + 1);
}

// Profile folder, same order as AppPaths in Dart: VYSH_CONFIG_DIR,
// then %APPDATA%\vysh, then %USERPROFILE%\vysh.
std::wstring ConfigDir() {
  const std::wstring custom = Trim(GetEnv(L"VYSH_CONFIG_DIR"));
  if (!custom.empty()) return custom;
  std::wstring base = GetEnv(L"APPDATA");
  if (base.empty()) base = GetEnv(L"USERPROFILE");
  if (base.empty()) base = L".";
  return base + L"\\vysh";
}

// Value of a top-level string key in the settings JSON. The file is written
// by vysh itself, so a tiny scanner is enough; it skips string contents, so a
// key name inside some other value (e.g. a path) is not mistaken for the key.
std::string ReadStringKey(const std::string& text, const std::string& key) {
  size_t i = 0;
  int depth = 0;
  while (i < text.size()) {
    const char c = text[i];
    if (c == '{' || c == '[') {
      depth++;
      i++;
    } else if (c == '}' || c == ']') {
      depth--;
      i++;
    } else if (c == '"') {
      std::string s;
      i++;
      while (i < text.size() && text[i] != '"') {
        if (text[i] == '\\' && i + 1 < text.size()) i++;
        s.push_back(text[i]);
        i++;
      }
      i++;
      size_t j = i;
      while (j < text.size() && std::isspace(static_cast<unsigned char>(text[j]))) j++;
      const bool is_key = j < text.size() && text[j] == ':';
      if (!(is_key && depth == 1 && s == key)) continue;
      j++;
      while (j < text.size() && std::isspace(static_cast<unsigned char>(text[j]))) j++;
      if (j >= text.size() || text[j] != '"') return std::string();
      std::string value;
      for (j++; j < text.size() && text[j] != '"'; j++) value.push_back(text[j]);
      return value;
    } else {
      i++;
    }
  }
  return std::string();
}

bool UseImpeller() {
  std::ifstream file(ConfigDir() + L"\\settings.json", std::ios::binary);
  if (!file) return false;
  std::string text((std::istreambuf_iterator<char>(file)),
                   std::istreambuf_iterator<char>());
  return ReadStringKey(text, "renderer") == "impeller";
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize OLE (not plain CoInitializeEx): Win32 drag-and-drop
  // (RegisterDragDrop / DoDragDrop) and OLE clipboard require OleInitialize
  // on the main STA thread for the lifetime of the message loop.
  ::OleInitialize(nullptr);

  flutter::DartProject project(L"data");
  const bool impeller = UseImpeller();
  project.set_impeller_switch(impeller ? flutter::ImpellerSwitch::Enabled
                                       : flutter::ImpellerSwitch::Disabled);
  // Keep the Dart UI isolate on its own thread (matching child windows in
  // desktop_multi_window): super_native_extensions blocks the Win32 platform
  // thread inside synchronous COM IDropTarget::Drop / IDataObject::GetData
  // calls while waiting for Dart callbacks, and window_manager style changes
  // also avoid fullscreen freezes on a separate UI thread.
  project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);
  // Tell Dart which renderer was actually started (settings can say otherwise
  // until restart).
  ::SetEnvironmentVariableW(L"VYSH_RENDERER", impeller ? L"impeller" : L"skia");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"vysh", origin, size)) {
    ::OleUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::OleUninitialize();
  return EXIT_SUCCESS;
}
