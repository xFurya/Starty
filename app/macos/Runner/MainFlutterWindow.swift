import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // значок Дока по выбору в настройках (app_icon.dart присылает PNG; nil — классический)
    let iconChannel = FlutterMethodChannel(
      name: "starty/icon", binaryMessenger: flutterViewController.engine.binaryMessenger)
    iconChannel.setMethodCallHandler { call, result in
      guard call.method == "window" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if let data = call.arguments as? FlutterStandardTypedData, let image = NSImage(data: data.data) {
        NSApp.applicationIconImage = image
      } else {
        NSApp.applicationIconImage = nil
      }
      result(true)
    }

    super.awakeFromNib()
  }
}
