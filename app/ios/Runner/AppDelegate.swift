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
  }
}
