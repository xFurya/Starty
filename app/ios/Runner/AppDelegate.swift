import Flutter
import UIKit
import UserNotifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // уведомления «за 15 минут» показываются и когда приложение открыто
    UNUserNotificationCenter.current().delegate = self
    // фоновое обновление: iOS сам будит приложение, оно подтягивает расписание и переставляет уведомления
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: "refresh", earliestBeginInSeconds: NSNumber(value: 3 * 3600))
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // иконка приложения: альтернативные из Assets.xcassets (skate_*); classic — основная
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "StartyIcon") {
      let channel = FlutterMethodChannel(name: "starty/icon", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "get":
          result(UIApplication.shared.alternateIconName ?? "classic")
        case "set":
          guard UIApplication.shared.supportsAlternateIcons else {
            result(false)
            return
          }
          let name = call.arguments as? String
          UIApplication.shared.setAlternateIconName(name == "classic" ? nil : name) { error in
            result(error == nil)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
