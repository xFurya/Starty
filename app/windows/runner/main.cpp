#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shobjidl.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Same AppUserModelID as the Start menu shortcut (tools/windows/starty.iss)
  // and the toast registration (lib/reminders.dart): the taskbar groups the
  // window with the shortcut and pins the shortcut, not this exe path.
  // Must be set before any window is created.
  ::SetCurrentProcessExplicitAppUserModelID(L"ru.furya.starty");

  // "App is running" marker for the installer (AppMutex in starty.iss): it
  // waits for this to go away before replacing files. Released by the OS when
  // the process exits; intentionally never closed.
  ::CreateMutexW(nullptr, FALSE, L"ru.furya.starty.app");

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(80, 40);
  Win32Window::Size size(1180, 820);
  if (!window.Create(L"\u0424\u0438\u0433\u0443\u0440\u043D\u043E\u0435 \u043A\u0430\u0442\u0430\u043D\u0438\u0435", origin, size)) {
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
