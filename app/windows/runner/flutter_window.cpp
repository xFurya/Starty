#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {
// Window and taskbar icon chosen in settings: app_icon.dart sends a path to an .ico;
// an empty string restores the classic icon from the exe resources.
// (ASCII only: MSVC with /WX fails on characters outside the code page.)
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_icon_channel;
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  HWND hwnd = GetHandle();
  g_icon_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "starty/icon",
      &flutter::StandardMethodCodec::GetInstance());
  g_icon_channel->SetMethodCallHandler(
      [hwnd](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "window") {
          result->NotImplemented();
          return;
        }
        const auto* path = std::get_if<std::string>(call.arguments());
        HICON big = nullptr, small = nullptr;
        if (path && !path->empty()) {
          int n = MultiByteToWideChar(CP_UTF8, 0, path->c_str(), -1, nullptr, 0);
          std::wstring w(n, L'\0');
          MultiByteToWideChar(CP_UTF8, 0, path->c_str(), -1, w.data(), n);
          big = static_cast<HICON>(LoadImageW(nullptr, w.c_str(), IMAGE_ICON, GetSystemMetrics(SM_CXICON),
                                              GetSystemMetrics(SM_CYICON), LR_LOADFROMFILE));
          small = static_cast<HICON>(LoadImageW(nullptr, w.c_str(), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                                GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE));
        } else {
          // classic icon from the exe resources (IDI_APP_ICON = 101)
          HINSTANCE inst = GetModuleHandle(nullptr);
          big = static_cast<HICON>(LoadImageW(inst, MAKEINTRESOURCEW(101), IMAGE_ICON, GetSystemMetrics(SM_CXICON),
                                              GetSystemMetrics(SM_CYICON), 0));
          small = static_cast<HICON>(LoadImageW(inst, MAKEINTRESOURCEW(101), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                                GetSystemMetrics(SM_CYSMICON), 0));
        }
        if (big) SendMessage(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(big));
        if (small) SendMessage(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(small));
        result->Success(flutter::EncodableValue(big != nullptr));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  g_icon_channel = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
